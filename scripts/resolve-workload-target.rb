#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

require "yaml"
require "base64"

ROOT = File.expand_path("..", __dir__)
SERVER_GLOB = File.join(ROOT, "contracts", "servers", "*.yaml")


def load_yaml(path)
  YAML.safe_load(File.read(path), permitted_classes: [], aliases: false)
rescue Psych::SyntaxError => e
  abort("#{path}: invalid YAML: #{e.message}")
end


workload = ARGV[0]
abort("usage: resolve-workload-target.rb <workload>") if workload.nil? || workload.empty?
abort("workload must be a lowercase identifier") unless workload =~ /\A[a-z0-9][a-z0-9-]*\z/

service_path = File.join(ROOT, "contracts", "services", "#{workload}.yaml")
abort("unknown workload contract: #{workload}") unless File.exist?(service_path)

service = load_yaml(service_path)
abort("#{service_path}: unsupported kind") unless service["kind"] == "WorkloadContract"
spec = service["spec"] || abort("#{service_path}: missing spec")

runtime = spec["runtime"] || { "kind" => "container" }
runtime_kind = runtime["kind"]
abort("#{service_path}: unsupported runtime kind") unless %w[container systemd-release].include?(runtime_kind)

result = {
  "target" => nil,
  "runtime" => runtime_kind,
}

if runtime_kind == "container"
  aliases = Array(spec["aliases"])
  abort("#{service_path}: aliases must be non-empty") if aliases.empty?

  port = spec["port"]
  abort("#{service_path}: port must be between 1 and 65535") unless port.is_a?(Integer) && port.between?(1, 65_535)

  health = spec["health"]
  abort("#{service_path}: health must start with /") unless health.is_a?(String) && health.start_with?("/")

  network = spec["network"]
  abort("#{service_path}: network is required") unless network.is_a?(String) && !network.empty?

  environment = Array(runtime["environment"])
  abort("#{service_path}: runtime.environment entries must be KEY=VALUE strings") unless environment.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:@+-]*\z}) }
  labels = Array(runtime["labels"])
  abort("#{service_path}: runtime.labels entries must be KEY=VALUE strings") unless labels.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*=[A-Za-z0-9_./:@+-]+\z}) }
  volumes = Array(runtime["volumes"])
  abort("#{service_path}: runtime.volumes entries must be SOURCE:TARGET strings") unless volumes.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*:/[A-Za-z0-9_./-]+(?::ro|:rw)?\z}) }

  result.merge!(
    "network" => network,
    "alias" => aliases.first,
    "port" => port.to_s,
    "health" => health,
    "environment" => Base64.strict_encode64(environment.join("\n") + "\n"),
    "labels" => Base64.strict_encode64(labels.join("\n") + "\n"),
    "volumes" => Base64.strict_encode64(volumes.join("\n") + "\n"),
  )
else
  repository = spec["repository"]
  abort("#{service_path}: repository must be owner/name") unless repository.is_a?(String) && repository.match?(/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/)

  deployment_path = runtime["deploymentPath"]
  abort("#{service_path}: deploymentPath must be absolute") unless deployment_path.is_a?(String) && deployment_path.start_with?("/")

  service_name = runtime["service"]
  abort("#{service_path}: service must be a systemd unit name") unless service_name.is_a?(String) && service_name.match?(/\A[a-zA-Z0-9@_.:-]+\.service\z/)

  retention = runtime["releaseRetention"]
  abort("#{service_path}: releaseRetention must be between 1 and 100") unless retention.is_a?(Integer) && retention.between?(1, 100)

  post_activate = runtime["postActivateCommand"]
  abort("#{service_path}: postActivateCommand must be a non-empty string") unless post_activate.is_a?(String) && !post_activate.strip.empty?

  result.merge!(
    "repository" => repository,
    "deployment_path" => deployment_path,
    "service" => service_name,
    "release_retention" => retention.to_s,
    "post_activate_command" => post_activate,
  )
end

Dir.glob(SERVER_GLOB).sort.each do |path|
  server = load_yaml(path)
  next unless server["kind"] == "ServerContract"

  workloads = Array(server.dig("spec", "workloads"))
  next unless workloads.include?(workload)

  abort("workload #{workload} is placed on more than one server contract") if result["target"]
  result["target"] = server.dig("metadata", "name")
end
abort("workload #{workload} is not placed on any server contract") unless result["target"]

output_path = ENV["GITHUB_OUTPUT"]
if output_path
  File.open(output_path, "a") { |f| result.each { |key, value| f.puts("#{key}=#{value}") } }
else
  result.each { |key, value| puts("#{key}=#{value}") }
end
