#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
EDGE_GLOB = File.join(ROOT, "contracts", "edges", "*.yaml")
SERVER_GLOB = File.join(ROOT, "contracts", "servers", "*.yaml")
SERVICE_GLOB = File.join(ROOT, "contracts", "services", "*.yaml")
# The image references deploy/workload/deploy.sh accepts.
IMAGE_PATTERN = %r{\A[a-z0-9.-]+(/[a-z0-9._-]+)*(:[A-Za-z0-9_.-]+|@sha256:[0-9a-f]{64})\z}
SECRET_MAPPING_PATTERN = /\A([A-Z][A-Z0-9_]*)=([A-Z][A-Z0-9_]*)\z/


def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
rescue Psych::SyntaxError => e
  abort("#{path}: invalid YAML: #{e.message}")
end


def fetch!(object, key, path)
  value = object[key]
  abort("#{path}: missing #{key}") if value.nil? || value == ""
  value
end


# Each edge is one public entrypoint on one server, with its own Docker network. A product's
# workloads join the network of the edge on the server they are placed on, and no other.
edges = {}
Dir.glob(EDGE_GLOB).sort.each do |path|
  edge = load_yaml(path)
  abort("#{path}: unsupported apiVersion") unless edge["apiVersion"] == "infra.nilx.one/v1"
  abort("#{path}: unsupported kind") unless edge["kind"] == "EdgeContract"
  abort("#{path}: owner must be aiaiaiai-org/infra") unless edge.dig("metadata", "owner") == "aiaiaiai-org/infra"

  name = fetch!(fetch!(edge, "metadata", path), "name", path)
  abort("#{path}: duplicate edge id #{name}") if edges.key?(name)
  spec = fetch!(edge, "spec", path)
  network = fetch!(spec, "network", path)
  fetch!(network, "name", path)
  abort("#{path}: network must be external") unless network["external"] == true
  edges[name] = { "path" => path, "spec" => spec }
end
abort("edge contracts: at least one edge is required") if edges.empty?

edge_networks = edges.values.map { |edge| edge.dig("spec", "network", "name") }
abort("edge contracts: two edges share a network") unless edge_networks.uniq.length == edge_networks.length

servers = {}
Dir.glob(SERVER_GLOB).sort.each do |path|
  contract = load_yaml(path)
  abort("#{path}: unsupported apiVersion") unless contract["apiVersion"] == "infra.nilx.one/v1"
  abort("#{path}: unsupported kind") unless contract["kind"] == "ServerContract"
  abort("#{path}: owner must be aiaiaiai-org/infra") unless contract.dig("metadata", "owner") == "aiaiaiai-org/infra"

  name = fetch!(fetch!(contract, "metadata", path), "name", path)
  spec = fetch!(contract, "spec", path)
  abort("#{path}: duplicate server id #{name}") if servers.key?(name)
  fetch!(spec, "role", path)
  abort("#{path}: edgeNetwork must be the network of an edge") unless edge_networks.include?(spec["edgeNetwork"])

  ports = Array(fetch!(spec, "publicPorts", path))
  abort("#{path}: publicPorts must be non-empty strings") unless ports.any? && ports.all? { |value| value.is_a?(String) && !value.empty? }

  runtime_root = fetch!(spec, "runtimeRoot", path)
  abort("#{path}: runtimeRoot must be absolute") unless runtime_root.is_a?(String) && runtime_root.start_with?("/")

  workloads = Array(fetch!(spec, "workloads", path))
  abort("#{path}: workloads must be non-empty strings") unless workloads.any? && workloads.all? { |value| value.is_a?(String) && !value.empty? }

  servers[name] = contract
end
abort("server contracts: at least one server is required") if servers.empty?

services = {}
Dir.glob(SERVICE_GLOB).sort.each do |path|
  contract = load_yaml(path)
  abort("#{path}: unsupported apiVersion") unless contract["apiVersion"] == "infra.nilx.one/v1"
  abort("#{path}: unsupported kind") unless contract["kind"] == "WorkloadContract"

  metadata = fetch!(contract, "metadata", path)
  name = fetch!(metadata, "name", path)
  owner = fetch!(metadata, "owner", path)
  abort("#{path}: duplicate service id #{name}") if services.key?(name)

  spec = fetch!(contract, "spec", path)
  runtime = spec["runtime"] || { "kind" => "container" }
  runtime_kind = runtime["kind"]
  abort("#{path}: runtime.kind must be container or systemd-release") unless %w[container systemd-release].include?(runtime_kind)

  if runtime_kind == "container"
    abort("#{path}: network must be the network of an edge") unless edge_networks.include?(spec["network"])

    aliases = Array(fetch!(spec, "aliases", path))
    abort("#{path}: aliases must be non-empty strings") unless aliases.any? && aliases.all? { |value| value.is_a?(String) && !value.empty? }

    deployment = fetch!(spec, "deployment", path)
    abort("#{path}: deployment must be test or production") unless %w[test production].include?(deployment)

    port = fetch!(spec, "port", path)
    abort("#{path}: port must be between 1 and 65535") unless port.is_a?(Integer) && port.between?(1, 65_535)
    expected_default_port = deployment == "test" ? 1703 : 1927
    abort("#{path}: #{deployment} workload must use default port #{expected_default_port}") unless port == expected_default_port

    health_kind = spec["healthKind"] || "http"
    abort("#{path}: healthKind must be http or tcp") unless %w[http tcp].include?(health_kind)
    if health_kind == "http"
      health = fetch!(spec, "health", path)
      abort("#{path}: health must start with /") unless health.is_a?(String) && health.start_with?("/")
    elsif spec.key?("health")
      abort("#{path}: a tcp health check takes no health path")
    end

    image = runtime["image"]
    unless image.nil?
      abort("#{path}: runtime.image must be an image reference with a tag or a digest") unless image.is_a?(String) && image.match?(IMAGE_PATTERN)
    end

    environment = runtime["environment"] || []
    abort("#{path}: runtime.environment must be an array") unless environment.is_a?(Array)
    environment.each do |entry|
      abort("#{path}: runtime.environment entries must be KEY=VALUE strings") unless entry.is_a?(String) && entry.match?(%r{\A[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:@+,-]*\z})
    end

    labels = runtime["labels"] || []
    abort("#{path}: runtime.labels must be an array") unless labels.is_a?(Array)
    labels.each do |entry|
      abort("#{path}: runtime.labels entries must be KEY=VALUE strings") unless entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*=[A-Za-z0-9_./:@+-]+\z})
    end

    volumes = runtime["volumes"] || []
    abort("#{path}: runtime.volumes must be an array") unless volumes.is_a?(Array)
    volumes.each do |entry|
      abort("#{path}: runtime.volumes entries must be SOURCE:TARGET strings") unless entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*:/[A-Za-z0-9_./-]+(?::ro|:rw)?\z})
    end

    # Secrets are named, never written: ENV_NAME=SECRET_NAME, the value coming from the target
    # server's GitHub Environment at deployment.
    secrets = runtime["secrets"] || []
    abort("#{path}: runtime.secrets must be an array") unless secrets.is_a?(Array)
    plain_names = environment.map { |entry| entry.split("=", 2).first }
    secret_names = secrets.map do |entry|
      match = entry.is_a?(String) && SECRET_MAPPING_PATTERN.match(entry)
      abort("#{path}: runtime.secrets entries must be ENV_NAME=SECRET_NAME") unless match
      match[1]
    end
    abort("#{path}: runtime.secrets sets a variable twice") unless secret_names.uniq.length == secret_names.length
    overlap = secret_names & plain_names
    abort("#{path}: #{overlap.join(', ')} is both a plain and a secret variable") unless overlap.empty?
    if secrets.any? && runtime["prepareEnv"]
      abort("#{path}: runtime.secrets and runtime.prepareEnv are mutually exclusive")
    end
  else
    repository = fetch!(spec, "repository", path)
    abort("#{path}: repository must be owner/name") unless repository.is_a?(String) && repository.match?(/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/)

    deployment_path = fetch!(runtime, "deploymentPath", path)
    abort("#{path}: deploymentPath must be absolute") unless deployment_path.is_a?(String) && deployment_path.start_with?("/")

    service_name = fetch!(runtime, "service", path)
    abort("#{path}: service must be a systemd unit name") unless service_name.is_a?(String) && service_name.match?(/\A[a-zA-Z0-9@_.:-]+\.service\z/)

    retention = fetch!(runtime, "releaseRetention", path)
    abort("#{path}: releaseRetention must be between 1 and 100") unless retention.is_a?(Integer) && retention.between?(1, 100)

    post_activate = fetch!(runtime, "postActivateCommand", path)
    abort("#{path}: postActivateCommand must be a non-empty string") unless post_activate.is_a?(String) && !post_activate.strip.empty?
  end

  services[name] = contract
end

# Where each workload runs: exactly one server places it.
placed_on = {}
servers.each do |server_name, server|
  Array(server.dig("spec", "workloads")).each do |workload|
    abort("server #{server_name}: unknown workload #{workload}") unless services.key?(workload)
    abort("workload #{workload} is placed on more than one server") if placed_on.key?(workload)
    placed_on[workload] = server_name
  end
end

edge_on_server = {}
route_count = 0
edges.each do |edge_name, edge|
  path = edge.fetch("path")
  spec = edge.fetch("spec")
  network_name = spec.dig("network", "name")

  placement = fetch!(spec, "placement", path)
  target_name = fetch!(placement, "target", path)
  target = servers[target_name] || abort("#{path}: unknown server target #{target_name}")
  abort("#{path}: server #{target_name} already has an edge") if edge_on_server.key?(target_name)
  edge_on_server[target_name] = edge_name
  abort("#{path}: server #{target_name} must use edgeNetwork #{network_name}") unless target.dig("spec", "edgeNetwork") == network_name

  entrypoint = fetch!(spec, "entrypoint", path)
  entrypoint_ports = Array(fetch!(entrypoint, "ports", path))
  missing_ports = entrypoint_ports - Array(target.dig("spec", "publicPorts"))
  abort("#{path}: target #{target_name} is missing ports #{missing_ports.join(', ')}") unless missing_ports.empty?

  routes = Array(spec["routes"])
  abort("#{path}: routes must not be empty") if routes.empty?

  seen_routes = {}
  routes.each do |route|
    route_id = fetch!(route, "id", path)
    service_id = fetch!(route, "service", path)
    service = services[service_id] || abort("#{path}: route #{route_id}: unknown service #{service_id}")
    host = fetch!(route, "host", path)
    prefix = fetch!(route, "pathPrefix", path)
    key = [host, prefix]
    abort("#{path}: route #{route_id}: duplicate host/path #{key.join}") if seen_routes[key]
    seen_routes[key] = true

    # An edge routes only to workloads on its own server, in its own network.
    abort("#{path}: route #{route_id}: #{service_id} is not placed on #{target_name}") unless placed_on[service_id] == target_name
    abort("#{path}: route #{route_id}: #{service_id} is not in network #{network_name}") unless service.dig("spec", "network") == network_name

    upstream = fetch!(route, "upstream", path)
    alias_name, port_text = upstream.split(":", 2)
    expected_aliases = Array(service.dig("spec", "aliases"))
    expected_port = service.dig("spec", "port").to_s

    abort("#{path}: route #{route_id}: upstream alias #{alias_name} is not declared") unless expected_aliases.include?(alias_name)
    abort("#{path}: route #{route_id}: upstream port #{port_text} must be #{expected_port}") unless port_text == expected_port
    abort("#{path}: route #{route_id}: pathPrefix must start with /") unless prefix.start_with?("/")
    abort("#{path}: route #{route_id}: health must start with /") unless fetch!(route, "health", path).start_with?("/")
    route_count += 1
  end
end

# A container joins the network of the edge on its server.
services.each do |name, service|
  runtime = service.dig("spec", "runtime") || { "kind" => "container" }
  next unless runtime["kind"] == "container"

  server_name = placed_on[name]
  next if server_name.nil?

  edge_name = edge_on_server[server_name] || abort("workload #{name}: server #{server_name} has no edge for its network")
  expected = edges.dig(edge_name, "spec", "network", "name")
  abort("workload #{name}: network must be #{expected}, the network of #{edge_name} on #{server_name}") unless service.dig("spec", "network") == expected
end

puts("validated #{edges.length} edges, #{servers.length} servers, #{services.length} workload contracts, and #{route_count} edge routes")
