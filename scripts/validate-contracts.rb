#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
EDGE_GLOB = File.join(ROOT, "contracts", "edges", "*.yaml")
SERVER_GLOB = File.join(ROOT, "contracts", "servers", "*.yaml")
SERVICE_GLOB = File.join(ROOT, "contracts", "services", "*.yaml")

DOMAIN_PATTERN = /\A(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}\z/
LOOPBACK_LISTEN_PATTERN = /\A127\.0\.0\.1:(\d{1,5})\z/
# Hook commands are embedded in a single-quoted remote shell string.
HOOK_COMMAND_PATTERN = /\A[^'\n\r]+\z/


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


def within_domain?(host, domain)
  host == domain || host.end_with?(".#{domain}")
end


# Top-level site addresses of a Caddyfile, with `{$VAR:default}` resolved to
# its default. Snippets `(name) {` and the global options block are skipped.
def caddy_site_hosts(path)
  hosts = []
  File.foreach(path, encoding: "UTF-8") do |line|
    next unless line.match?(/\A[^\s#(]/)
    next unless (match = line.match(/\A(.+?)\s*\{\s*\z/))

    match[1].split(/[,\s]+/).reject(&:empty?).each do |address|
      address = address.gsub(/\{\$[A-Z0-9_]+(?::([^}]*))?\}/) do
        default = Regexp.last_match(1)
        abort("#{path}: site address #{address} has no default to validate") if default.nil? || default.empty?
        default
      end
      host = address.sub(%r{\A[a-z]+://}, "").sub(%r{[:/].*\z}, "")
      hosts << host unless host.empty?
    end
  end
  hosts
end


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
  fetch!(spec, "edgeNetwork", path)

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
  fetch!(metadata, "owner", path)
  abort("#{path}: duplicate service id #{name}") if services.key?(name)

  spec = fetch!(contract, "spec", path)
  runtime = spec["runtime"] || { "kind" => "container" }
  runtime_kind = runtime["kind"]
  abort("#{path}: runtime.kind must be container or systemd-release") unless %w[container systemd-release].include?(runtime_kind)

  if runtime_kind == "container"
    fetch!(spec, "network", path)

    aliases = Array(fetch!(spec, "aliases", path))
    abort("#{path}: aliases must be non-empty strings") unless aliases.any? && aliases.all? { |value| value.is_a?(String) && !value.empty? }

    deployment = fetch!(spec, "deployment", path)
    abort("#{path}: deployment must be test or production") unless %w[test production].include?(deployment)

    port = fetch!(spec, "port", path)
    abort("#{path}: port must be between 1 and 65535") unless port.is_a?(Integer) && port.between?(1, 65_535)
    expected_default_port = deployment == "test" ? 1703 : 1927
    abort("#{path}: #{deployment} workload must use default port #{expected_default_port}") unless port == expected_default_port

    health = fetch!(spec, "health", path)
    abort("#{path}: health must start with /") unless health.is_a?(String) && health.start_with?("/")

    environment = runtime["environment"] || []
    abort("#{path}: runtime.environment must be an array") unless environment.is_a?(Array)
    environment.each do |entry|
      abort("#{path}: runtime.environment entries must be KEY=VALUE strings") unless entry.is_a?(String) && entry.match?(%r{\A[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:@+-]*\z})
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
  else
    repository = fetch!(spec, "repository", path)
    abort("#{path}: repository must be owner/name") unless repository.is_a?(String) && repository.match?(/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/)

    deployment_path = fetch!(runtime, "deploymentPath", path)
    abort("#{path}: deploymentPath must be absolute") unless deployment_path.is_a?(String) && deployment_path.start_with?("/")

    service_name = fetch!(runtime, "service", path)
    abort("#{path}: service must be a systemd unit name") unless service_name.is_a?(String) && service_name.match?(/\A[a-zA-Z0-9@_.:-]+\.service\z/)

    retention = fetch!(runtime, "releaseRetention", path)
    abort("#{path}: releaseRetention must be between 1 and 100") unless retention.is_a?(Integer) && retention.between?(1, 100)

    %w[validateCommand preActivateCommand postActivateCommand].each do |key|
      next unless runtime.key?(key)

      command = runtime[key]
      abort("#{path}: #{key} must be a non-empty single-line string without single quotes") unless command.is_a?(String) && !command.strip.empty? && command.match?(HOOK_COMMAND_PATTERN)
    end

    hook_environment = runtime.fetch("hookEnvironment", "release")
    abort("#{path}: hookEnvironment must be release or service") unless %w[release service].include?(hook_environment)

    if spec.key?("listen")
      listen = spec["listen"]
      match = listen.is_a?(String) && listen.match(LOOPBACK_LISTEN_PATTERN)
      abort("#{path}: listen must be 127.0.0.1:<port>") unless match && match[1].to_i.between?(1, 65_535)

      health = fetch!(spec, "health", path)
      abort("#{path}: health must start with /") unless health.is_a?(String) && health.start_with?("/")
    end
  end

  services[name] = contract
end

# Placement: every workload a server names exists and lives on exactly one server.
placement = {}
servers.each do |server_name, server|
  Array(server.dig("spec", "workloads")).each do |workload|
    abort("server #{server_name}: unknown workload #{workload}") unless services.key?(workload)
    abort("workload #{workload} is placed on both #{placement[workload]} and #{server_name}") if placement.key?(workload)

    placement[workload] = server_name
  end
end

# Host-native workloads share the host port namespace.
servers.each_key do |server_name|
  listens = placement.select { |_, target| target == server_name }.keys.filter_map { |workload| services[workload].dig("spec", "listen") }
  duplicate = listens.tally.find { |_, count| count > 1 }
  abort("server #{server_name}: listen address #{duplicate.first} is used by more than one workload") if duplicate
end

edges = {}
Dir.glob(EDGE_GLOB).sort.each do |path|
  edge = load_yaml(path)
  abort("#{path}: unsupported apiVersion") unless edge["apiVersion"] == "infra.nilx.one/v1"
  abort("#{path}: unsupported kind") unless edge["kind"] == "EdgeContract"
  abort("#{path}: owner must be aiaiaiai-org/infra") unless edge.dig("metadata", "owner") == "aiaiaiai-org/infra"

  edge_spec = fetch!(edge, "spec", path)
  target_name = fetch!(fetch!(edge_spec, "placement", path), "target", path)
  target = servers[target_name] || abort("#{path}: unknown server target #{target_name}")
  abort("#{path}: server #{target_name} already has an edge contract") if edges.key?(target_name)

  network = fetch!(edge_spec, "network", path)
  network_name = fetch!(network, "name", path)
  abort("#{path}: network must be external") unless network["external"] == true
  host_network = network["driver"] == "host"
  abort("#{path}: the host driver requires the network name host") if host_network ^ (network_name == "host")
  abort("#{path}: server #{target_name} edgeNetwork must be #{network_name}") unless target.dig("spec", "edgeNetwork") == network_name

  domains = Array(fetch!(edge_spec, "domains", path))
  abort("#{path}: domains must be lowercase DNS names") unless domains.all? { |domain| domain.is_a?(String) && domain.match?(DOMAIN_PATTERN) }

  entrypoint = fetch!(edge_spec, "entrypoint", path)
  missing_ports = Array(fetch!(entrypoint, "ports", path)) - Array(target.dig("spec", "publicPorts"))
  abort("#{path}: target #{target_name} is missing ports #{missing_ports.join(', ')}") unless missing_ports.empty?

  config = fetch!(entrypoint, "config", path)
  config_path = File.join(ROOT, config)
  abort("#{path}: entrypoint config #{config} does not exist") unless File.file?(config_path)
  caddy_site_hosts(config_path).each do |host|
    bare = host.delete_prefix("*.")
    abort("#{config}: site #{host} is outside the domains of #{target_name}: #{domains.join(', ')}") unless domains.any? { |domain| within_domain?(bare, domain) }
  end

  routes = Array(edge_spec["routes"])
  abort("#{path}: routes must not be empty") if routes.empty?

  seen_routes = {}
  routes.each do |route|
    route_id = fetch!(route, "id", path)
    service_id = fetch!(route, "service", path)
    service = services[service_id] || abort("#{path}: route #{route_id}: unknown service #{service_id}")
    abort("#{path}: route #{route_id}: service #{service_id} is not placed on #{target_name}") unless placement[service_id] == target_name

    host = fetch!(route, "host", path)
    abort("#{path}: route #{route_id}: host #{host} must be a literal DNS name") unless host.match?(DOMAIN_PATTERN)
    abort("#{path}: route #{route_id}: host #{host} is outside #{domains.join(', ')}") unless domains.any? { |domain| within_domain?(host, domain) }

    prefix = fetch!(route, "pathPrefix", path)
    abort("#{path}: route #{route_id}: pathPrefix must start with /") unless prefix.start_with?("/")
    key = [host, prefix]
    abort("#{path}: route #{route_id}: duplicate host/path #{key.join}") if seen_routes[key]
    seen_routes[key] = true
    abort("#{path}: route #{route_id}: health must start with /") unless fetch!(route, "health", path).start_with?("/")

    upstream = fetch!(route, "upstream", path)
    service_spec = service["spec"]
    if (service_spec["runtime"] || {})["kind"] == "systemd-release"
      listen = service_spec["listen"] || abort("#{path}: route #{route_id}: host-native service #{service_id} declares no listen address")
      abort("#{path}: route #{route_id}: host-native service #{service_id} needs a host-network edge") unless host_network
      abort("#{path}: route #{route_id}: upstream must be #{listen}") unless upstream == listen
    else
      abort("#{path}: route #{route_id}: container upstreams need a bridge edge network") if host_network
      alias_name, port_text = upstream.split(":", 2)
      abort("#{path}: route #{route_id}: upstream alias #{alias_name} is not declared") unless Array(service_spec["aliases"]).include?(alias_name)
      abort("#{path}: route #{route_id}: upstream port #{port_text} must be #{service_spec['port']}") unless port_text == service_spec["port"].to_s
    end
  end

  edges[target_name] = edge
end
abort("edge contracts: at least one edge is required") if edges.empty?

# A domain belongs to exactly one edge.
claims = edges.flat_map { |target_name, edge| edge.dig("spec", "domains").map { |domain| [domain, target_name] } }
claims.combination(2).each do |(domain_a, edge_a), (domain_b, edge_b)|
  next unless within_domain?(domain_a, domain_b) || within_domain?(domain_b, domain_a)

  abort("domain #{domain_a} (#{edge_a}) overlaps #{domain_b} (#{edge_b})")
end

# Container workloads join the edge network of the server they are placed on.
services.each do |name, service|
  next unless (service.dig("spec", "runtime") || {}).fetch("kind", "container") == "container"

  target_name = placement[name] || abort("workload #{name} is not placed on any server")
  expected = servers[target_name].dig("spec", "edgeNetwork")
  abort("workload #{name}: network must be #{expected} on #{target_name}") unless service.dig("spec", "network") == expected
end

route_count = edges.values.sum { |edge| Array(edge.dig("spec", "routes")).length }
puts("validated #{servers.length} servers, #{edges.length} edges, #{services.length} workload contracts, and #{route_count} edge routes")
