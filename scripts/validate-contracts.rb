#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"

ROOT = File.expand_path("..", __dir__)
EDGE_PATH = File.join(ROOT, "contracts", "edge.yaml")
SERVER_GLOB = File.join(ROOT, "contracts", "servers", "*.yaml")
SERVICE_GLOB = File.join(ROOT, "contracts", "services", "*.yaml")


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


edge = load_yaml(EDGE_PATH)
abort("edge contract: unsupported apiVersion") unless edge["apiVersion"] == "infra.nilx.one/v1"
abort("edge contract: unsupported kind") unless edge["kind"] == "EdgeContract"
abort("edge contract: owner must be aiaiaiai-org/infra") unless edge.dig("metadata", "owner") == "aiaiaiai-org/infra"

edge_spec = fetch!(edge, "spec", EDGE_PATH)
network = fetch!(edge_spec, "network", EDGE_PATH)
network_name = fetch!(network, "name", EDGE_PATH)
abort("edge contract: network must be external") unless network["external"] == true

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
  abort("#{path}: edgeNetwork must be #{network_name}") unless spec["edgeNetwork"] == network_name

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
    abort("#{path}: network must be #{network_name}") unless spec["network"] == network_name

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

placement = fetch!(edge_spec, "placement", EDGE_PATH)
target_name = fetch!(placement, "target", EDGE_PATH)
target = servers[target_name] || abort("edge placement: unknown server target #{target_name}")

entrypoint = fetch!(edge_spec, "entrypoint", EDGE_PATH)
entrypoint_ports = Array(fetch!(entrypoint, "ports", EDGE_PATH))
target_ports = Array(target.dig("spec", "publicPorts"))
missing_ports = entrypoint_ports - target_ports
abort("edge placement: target #{target_name} is missing ports #{missing_ports.join(', ')}") unless missing_ports.empty?

routes = Array(edge_spec["routes"])
abort("edge contract: routes must not be empty") if routes.empty?

seen_routes = {}
routed_services = []
routes.each do |route|
  route_id = fetch!(route, "id", EDGE_PATH)
  service_id = fetch!(route, "service", EDGE_PATH)
  service = services[service_id] || abort("edge route #{route_id}: unknown service #{service_id}")
  routed_services << service_id
  host = fetch!(route, "host", EDGE_PATH)
  prefix = fetch!(route, "pathPrefix", EDGE_PATH)
  key = [host, prefix]
  abort("edge route #{route_id}: duplicate host/path #{key.join}") if seen_routes[key]
  seen_routes[key] = true

  upstream = fetch!(route, "upstream", EDGE_PATH)
  alias_name, port_text = upstream.split(":", 2)
  expected_aliases = Array(service.dig("spec", "aliases"))
  expected_port = service.dig("spec", "port").to_s

  abort("edge route #{route_id}: upstream alias #{alias_name} is not declared") unless expected_aliases.include?(alias_name)
  abort("edge route #{route_id}: upstream port #{port_text} must be #{expected_port}") unless port_text == expected_port
  abort("edge route #{route_id}: pathPrefix must start with /") unless prefix.start_with?("/")
  abort("edge route #{route_id}: health must start with /") unless fetch!(route, "health", EDGE_PATH).start_with?("/")
end

target_workloads = Array(target.dig("spec", "workloads"))
missing_workloads = routed_services.uniq - target_workloads
abort("edge placement: target #{target_name} is missing workloads #{missing_workloads.join(', ')}") unless missing_workloads.empty?

puts("validated #{servers.length} server, #{services.length} workload contracts, and #{routes.length} edge routes")
