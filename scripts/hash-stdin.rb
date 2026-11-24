#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Reads stdin and prints {"sha256","bytes"} as JSON. Used to check decrypted data without writing it.

require "digest"
require "json"

$stdin.binmode
digest = Digest::SHA256.new
bytes = 0
while (chunk = $stdin.read(65_536))
  digest << chunk
  bytes += chunk.bytesize
end
puts JSON.generate("sha256" => digest.hexdigest, "bytes" => bytes)
