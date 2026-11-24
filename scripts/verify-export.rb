#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Opens a sealed export with the receiver's identity and checks it against manifest.json, without
# writing any plaintext: every item must match its ciphertext hash, decrypt to exactly the plaintext
# hash and size the exporter recorded, and look like what its name says (a PostgreSQL custom-format
# dump, a tar of the volume, a JSON document of secrets). Only names, sizes and counts are printed.
#
#   verify-export.rb DIRECTORY IDENTITY_FILE

require "digest"
require "json"
require "open3"

directory, identity = ARGV
abort "usage: verify-export.rb DIRECTORY IDENTITY_FILE" unless ARGV.length == 2
NAME = /\A[A-Za-z0-9_.-]+\z/

manifest = JSON.parse(File.read(File.join(directory, "manifest.json")))
items = manifest.fetch("items")
abort "the manifest lists no items" if items.empty?
failures = []

items.each do |item|
  name = item.fetch("name")
  (failures << "#{name.inspect}: unexpected item name"; next) unless NAME.match?(name)

  file = File.join(directory, item.fetch("file"))
  (failures << "#{name}: sealed file is missing"; next) unless File.file?(file)
  (failures << "#{name}: ciphertext differs from the manifest"; next) unless Digest::SHA256.file(file).hexdigest == item.fetch("ciphertext_sha256")

  digest = Digest::SHA256.new
  bytes = 0
  head = +"".b
  ok = IO.popen(["age", "-d", "-i", identity, file], "rb") do |plain|
    while (chunk = plain.read(65_536))
      digest << chunk
      bytes += chunk.bytesize
      head << chunk.byteslice(0, 8 - head.bytesize) if head.bytesize < 8
    end
    true
  end
  (failures << "#{name}: age could not open it"; next) unless ok && $?.success?
  unless digest.hexdigest == item.fetch("plaintext_sha256") && bytes == item.fetch("plaintext_bytes")
    failures << "#{name}: does not decrypt to what was sealed"
    next
  end

  case name
  when /\Adb-/
    (failures << "#{name}: not a PostgreSQL custom-format dump"; next) unless head.start_with?("PGDMP")
    puts "ok  #{name}  (#{bytes} bytes, PostgreSQL custom format)"
  when /\Avolume-/
    listing, status = Open3.capture2("bash", "-o", "pipefail", "-c", 'age -d -i "$1" "$2" | tar -tf - | wc -l', "bash", identity, file)
    (failures << "#{name}: not a readable tar"; next) unless status.success? && listing.to_i.positive?
    puts "ok  #{name}  (#{bytes} bytes, #{listing.to_i} entries)"
  when "secrets"
    document, status = Open3.capture2("age", "-d", "-i", identity, file)
    parsed = status.success? ? (JSON.parse(document) rescue nil) : nil
    (failures << "#{name}: not a JSON document of secrets"; next) unless parsed.is_a?(Hash) && parsed.values.all?(Hash)
    puts "ok  #{name}  (#{bytes} bytes); workloads and secret names only:"
    parsed.sort.each { |workload, values| puts "      #{workload}: #{values.keys.sort.join(" ")}" }
  else
    puts "ok  #{name}  (#{bytes} bytes)"
  end
end

unless failures.empty?
  warn failures.map { "FAIL #{_1}" }
  abort "the export does not match its manifest"
end
puts "The export opens with the receiver's identity and matches its manifest."
