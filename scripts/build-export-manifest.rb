#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Writes manifest.json beside the sealed files of an export: for each NAME.age, the ciphertext hash and
# size and the plaintext hash and size that seal-stdin.rb recorded in NAME.plain.json. It also adds a
# summary to the job summary when GITHUB_STEP_SUMMARY is set. Neither holds anything secret.

require "digest"
require "json"
require "time"

out = ARGV.fetch(0) { abort "usage: build-export-manifest.rb DIRECTORY" }
items = Dir[File.join(out, "*.age")].sort.map do |file|
  name = File.basename(file, ".age")
  plain = JSON.parse(File.read(File.join(out, "#{name}.plain.json")))
  {
    "name" => name,
    "file" => File.basename(file),
    "ciphertext_sha256" => Digest::SHA256.file(file).hexdigest,
    "ciphertext_bytes" => File.size(file),
    "plaintext_sha256" => plain.fetch("sha256"),
    "plaintext_bytes" => plain.fetch("bytes")
  }
end
abort "nothing was sealed" if items.empty?

File.write(File.join(out, "manifest.json"), JSON.pretty_generate(
  "exported_at" => Time.now.utc.iso8601,
  "run_id" => ENV.fetch("GITHUB_RUN_ID", "local"),
  "source" => "edge-prod-2",
  "recipient" => ENV.fetch("RECIPIENT", ""),
  "items" => items
))

if ENV["GITHUB_STEP_SUMMARY"]
  File.open(ENV.fetch("GITHUB_STEP_SUMMARY"), "a") do |summary|
    summary.puts "### Sealed export of edge-prod-2", "", "| item | plaintext bytes | ciphertext bytes |", "| --- | ---: | ---: |"
    items.each { |item| summary.puts "| `#{item["name"]}` | #{item["plaintext_bytes"]} | #{item["ciphertext_bytes"]} |" }
    summary.puts "", "Ciphertext only; it opens with edge-dev-1's deploy key. Nothing on edge-prod-2 was changed."
  end
end
puts "manifest written for #{items.length} item(s)"
