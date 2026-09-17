#!/usr/bin/env ruby
# frozen_string_literal: true

require "yaml"

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

aliases = Array(spec["aliases"])
abort("#{service_path}: aliases must be non-empty") if aliases.empty?

port = spec["port"]
abort("#{service_path}: port must be between 1 and 65535") unless port.is_a?(Integer) && port.between?(1, 65_535)

health = spec["health"]
abort("#{service_path}: health must start with /") unless health.is_a?(String) && health.start_with?("/")

network = spec["network"]
abort("#{service_path}: network is required") unless network.is_a?(String) && !network.empty?

target_name = nil
Dir.glob(SERVER_GLOB).sort.each do |path|
  server = load_yaml(path)
  next unless server["kind"] == "ServerContract"

  workloads = Array(server.dig("spec", "workloads"))
  next unless workloads.include?(workload)

  abort("workload #{workload} is placed on more than one server contract") if target_name
  target_name = server.dig("metadata", "name")
end
abort("workload #{workload} is not placed on any server contract") unless target_name

result = {
  "target" => target_name,
  "network" => network,
  "alias" => aliases.first,
  "port" => port.to_s,
  "health" => health,
}

output_path = ENV["GITHUB_OUTPUT"]
if output_path
  File.open(output_path, "a") { |f| result.each { |key, value| f.puts("#{key}=#{value}") } }
else
  result.each { |key, value| puts("#{key}=#{value}") }
end
