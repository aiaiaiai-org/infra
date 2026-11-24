#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Reads the secrets a set of running containers hold and prints them as one JSON document on stdout,
# for sealing with seal-stdin.rb. Only the environment names a workload contract declares under
# spec.runtime.secrets are taken; everything else a container holds is left alone. A report of names
# and set/empty/missing counts, never a value, goes to stderr. Every value is registered with the
# runner's log masking before anything else happens.
#
#   EXPORT_SSH_ARGV_JSON='["ssh","-o","BatchMode=yes","user@host"]' extract-workload-secrets.rb NAME...
#
# The command that reads one container's environment is appended to that argv.

require "json"
require "open3"
require "yaml"

ROOT = File.expand_path("..", __dir__)
NAME = /\A[a-z0-9][a-z0-9_.-]*\z/
ENV_NAME = /\A[A-Za-z_][A-Za-z0-9_]*\z/

argv = JSON.parse(ENV.fetch("EXPORT_SSH_ARGV_JSON"))
abort "EXPORT_SSH_ARGV_JSON must be a non-empty array of strings" unless argv.is_a?(Array) && !argv.empty? && argv.all?(String)
names = ARGV
abort "usage: extract-workload-secrets.rb WORKLOAD..." if names.empty?
abort "invalid workload name" unless names.all? { NAME.match?(_1) }

def declared(workload)
  contract = YAML.safe_load_file(File.join(ROOT, "contracts", "services", "#{workload}.yaml"))
  Array(contract.dig("spec", "runtime", "secrets")).map { _1.to_s.split("=", 2).first }.tap do |list|
    abort "#{workload}: a declared secret has an invalid name" unless list.all? { ENV_NAME.match?(_1) }
  end
end

result = {}
report = []
names.each do |workload|
  wanted = declared(workload)
  if wanted.empty?
    report << "#{workload}: contract declares no secrets, nothing taken"
    next
  end
  out, status = Open3.capture2(*argv, "docker inspect #{workload} --format '{{range .Config.Env}}{{println .}}{{end}}'")
  abort "#{workload}: cannot read the container environment" unless status.success?

  environment = {}
  out.each_line(chomp: true) do |line|
    next if line.empty?

    key, value = line.split("=", 2)
    abort "#{workload}: an environment entry spans lines, refusing to guess" if value.nil?
    environment[key] = value
  end

  taken = environment.slice(*wanted).reject { |_, value| value.empty? }
  taken.each_value { |value| $stderr.puts("::add-mask::#{value}") }
  missing = wanted - environment.keys
  empty = wanted.select { environment[_1]&.empty? }
  result[workload] = taken unless taken.empty?
  report << "#{workload}: declared=#{wanted.length} exported=#{taken.length} missing=#{missing.inspect} empty=#{empty.inspect}"
end

abort "nothing to export" if result.empty?

$stderr.puts report
puts JSON.generate(result)
