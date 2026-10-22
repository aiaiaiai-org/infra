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

  health_kind = spec["healthKind"] || "http"
  abort("#{service_path}: healthKind must be http, tcp or process") unless %w[http tcp process].include?(health_kind)
  health = spec["health"].to_s
  abort("#{service_path}: health must start with /") if health_kind == "http" && !health.start_with?("/")

  network = spec["network"]
  abort("#{service_path}: network is required") unless network.is_a?(String) && !network.empty?

  environment = Array(runtime["environment"])
  abort("#{service_path}: runtime.environment entries must be KEY=VALUE strings") unless environment.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:@+,-]*\z}) }
  producer_environment = Array(runtime["producerEnvironment"])
  abort("#{service_path}: runtime.producerEnvironment must contain unique environment names") unless
    producer_environment.all? { |name| name.is_a?(String) && name.match?(/\A[A-Z][A-Z0-9_]*\z/) } &&
    producer_environment.uniq.length == producer_environment.length
  static_names = environment.map { |entry| entry.split("=", 2).first }
  abort("#{service_path}: producer environment overlaps static environment") unless
    (producer_environment & static_names).empty?

  labels = Array(runtime["labels"])
  abort("#{service_path}: runtime.labels entries must be KEY=VALUE strings") unless labels.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*=[A-Za-z0-9_./:@+-]+\z}) }
  volumes = Array(runtime["volumes"])
  abort("#{service_path}: runtime.volumes entries must be SOURCE:TARGET strings") unless volumes.all? { |entry| entry.is_a?(String) && entry.match?(%r{\A[a-z0-9][a-z0-9_.-]*:/[A-Za-z0-9_./-]+(?::ro|:rw)?\z}) }

  command = runtime["command"] || []
  abort("#{service_path}: runtime.command must be a safe argv array") unless
    command.is_a?(Array) && command.length <= 16 &&
    command.all? { |arg| arg.is_a?(String) && arg.match?(/\A[A-Za-z0-9_.\/-]+\z/) }
  abort("#{service_path}: process health requires explicit command") if health_kind == "process" && command.empty?

  secret_mappings = Array(runtime["secrets"])
  abort("#{service_path}: runtime.secrets entries must be ENV_NAME=SECRET_NAME") unless secret_mappings.all? { |entry| entry.is_a?(String) && entry.match?(/\A[A-Z][A-Z0-9_]*=[A-Z][A-Z0-9_]*\z/) }

  secret_names = secret_mappings.map { |mapping| mapping.split("=", 2).first }
  abort("#{service_path}: producer environment overlaps runtime secrets") unless
    (producer_environment & secret_names).empty?

  prepare_env = runtime["prepareEnv"].to_s
  if !prepare_env.empty?
    owner = service.dig("metadata", "owner")
    abort("#{service_path}: metadata.owner must be owner/name when prepareEnv is set") unless owner.is_a?(String) && owner.match?(/\A[a-zA-Z0-9_.-]+\/[a-zA-Z0-9_.-]+\z/)
    result["repository"] = owner
  end

  result.merge!(
    "network" => network,
    "alias" => aliases.first,
    "port" => port.to_s,
    "health" => health,
    "health_kind" => health_kind,
    "command" => command.empty? ? "" : Base64.strict_encode64(command.join("\n") + "\n"),
    "contract_image" => runtime["image"].to_s,
    "secrets" => secret_mappings.empty? ? "" : Base64.strict_encode64(secret_mappings.join("\n") + "\n"),
    "environment" => Base64.strict_encode64(environment.join("\n") + "\n"),
    "producer_environment" => producer_environment.empty? ? "" : Base64.strict_encode64(producer_environment.join("\n") + "\n"),
    "labels" => Base64.strict_encode64(labels.join("\n") + "\n"),
    "volumes" => Base64.strict_encode64(volumes.join("\n") + "\n"),
    "prepare_env" => prepare_env,
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
