#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Reads stdin, encrypts it with age to one public recipient and writes only the ciphertext to OUTFILE.
# Prints {"sha256","bytes"} of the plaintext as JSON, so the receiver can check what it decrypts.
# The plaintext lives only in this process and in the pipe to age; it never touches a disk.

require "digest"
require "json"

RECIPIENT = /\A(?:age1[0-9a-z]+|ssh-(?:ed25519|rsa) [A-Za-z0-9+\/=]+)\z/

recipient, outfile = ARGV
abort "usage: seal-stdin.rb RECIPIENT OUTFILE" unless ARGV.length == 2 && recipient && outfile
abort "recipient must be an age public key or an ssh-ed25519/ssh-rsa public key" unless RECIPIENT.match?(recipient)

$stdin.binmode
digest = Digest::SHA256.new
bytes = 0
IO.popen(["age", "-r", recipient, "-o", outfile], "wb") do |age|
  while (chunk = $stdin.read(65_536))
    digest << chunk
    bytes += chunk.bytesize
    age.write(chunk)
  end
end
unless $?.success? && bytes.positive?
  File.delete(outfile) if File.exist?(outfile)
  abort(bytes.zero? ? "refusing an empty input" : "age failed")
end

puts JSON.generate("sha256" => digest.hexdigest, "bytes" => bytes)
