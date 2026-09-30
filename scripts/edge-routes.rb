#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# usage: edge-routes.rb <edge-target>
#
# Emits what a deployment of one edge needs from its merged contract:
#   zone          the single domain the edge owns (DNS zone);
#   hosts         public hosts, space-separated;
#   public_urls   https health URL per route, space-separated;
#   upstream_urls loopback health URL per host-native upstream, space-separated.

require "yaml"

ROOT = File.expand_path("..", __dir__)

target = ARGV[0].to_s
abort("usage: edge-routes.rb <edge-target>") unless target.match?(/\A[a-z0-9][a-z0-9._-]*\z/)

edge = Dir.glob(File.join(ROOT, "contracts", "edges", "*.yaml")).sort
  .map { |path| YAML.safe_load(File.read(path, encoding: "UTF-8"), permitted_classes: [], aliases: false) }
  .find { |contract| contract.dig("spec", "placement", "target") == target }
abort("no edge contract is placed on #{target}") unless edge

domains = Array(edge.dig("spec", "domains"))
abort("#{target}: this helper supports exactly one domain per edge") unless domains.length == 1

routes = Array(edge.dig("spec", "routes"))
public_urls = routes.map do |route|
  prefix = route.fetch("stripPrefix") ? route.fetch("pathPrefix").chomp("/") : ""
  "https://#{route.fetch('host')}#{prefix}#{route.fetch('health')}"
end
upstream_urls = routes.filter_map do |route|
  "http://#{route.fetch('upstream')}#{route.fetch('health')}" if route.fetch("upstream").start_with?("127.0.0.1:")
end

result = {
  "zone" => domains.first,
  "hosts" => routes.map { |route| route.fetch("host") }.uniq.join(" "),
  "public_urls" => public_urls.uniq.join(" "),
  "upstream_urls" => upstream_urls.uniq.join(" "),
}

output_path = ENV["GITHUB_OUTPUT"]
if output_path
  File.open(output_path, "a") { |f| result.each { |key, value| f.puts("#{key}=#{value}") } }
else
  result.each { |key, value| puts("#{key}=#{value}") }
end
