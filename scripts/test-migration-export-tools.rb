#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# The tools behind "Export aiaiaiai edge for migration": sealing a stream with age, hashing what a
# receiver decrypts, and taking exactly the secrets a workload contract declares. It uses the real
# age and a stub in place of ssh; no server is touched.

require "digest"
require "fileutils"
require "json"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)

def run(*command, stdin: "", env: {})
  out, err, status = Open3.capture3(env, *command, stdin_data: stdin, binmode: true)
  [out, err, status]
end

def check(condition, message)
  abort("FAIL: #{message}") unless condition
end

Dir.mktmpdir("export-tools") do |dir|
  identity = File.join(dir, "key.txt")
  _, err, status = run("age-keygen", "-o", identity)
  check(status.success?, "age-keygen failed")
  recipient = err[/age1[0-9a-z]+/] or abort("FAIL: no recipient printed")

  # --- seal-stdin: only ciphertext on disk, plaintext hash on stdout, round trip works
  payload = ("secret-é\n".b * 5000) + "\x00\xff".b
  sealed = File.join(dir, "item.age")
  out, _, status = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", recipient, sealed, stdin: payload)
  check(status.success?, "seal-stdin should succeed")
  info = JSON.parse(out)
  check(info == {"sha256" => Digest::SHA256.hexdigest(payload), "bytes" => payload.bytesize}, "seal-stdin must report the plaintext hash and size")
  check(!File.binread(sealed).include?("secret-"), "the sealed file must not contain the plaintext")
  decrypted, = run("age", "-d", "-i", identity, sealed)
  check(decrypted.b == payload, "decrypting must give the original bytes")
  hashed, = run("ruby", "#{ROOT}/scripts/hash-stdin.rb", stdin: decrypted)
  check(JSON.parse(hashed) == info, "hash-stdin must agree with seal-stdin")

  # --- seal-stdin refuses what it must
  empty = File.join(dir, "empty.age")
  _, _, status = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", recipient, empty, stdin: "")
  check(!status.success? && !File.exist?(empty), "an empty input must fail and leave no file")
  _, _, status = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", "not a recipient", File.join(dir, "x.age"), stdin: "data")
  check(!status.success?, "a bad recipient must fail")
  _, _, status = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", recipient)
  check(!status.success?, "missing arguments must fail")

  # --- extract-workload-secrets: contract allowlist, no extras, no values on stderr
  fake_ssh = File.join(dir, "fake-ssh")
  File.write(fake_ssh, <<~SH)
    #!/bin/sh
    case "$*" in
      *"docker inspect prism-hubot "*)
        printf '%s\\n' 'PATH=/usr/bin' 'PRISM_BOT_TELEGRAM_TOKEN=tok-123:abc' 'PRISM_BOT_TELEGRAM_WEBHOOK_SECRET=whs' \\
          'PRISM_HUB_API_TOKEN=' 'PRISM_BOT_DELIVERY_SECRET=del=with=equals' 'UNDECLARED_API_KEY=must-not-leak' ;;
      *"docker inspect h-ua-bot "*)
        printf '%s\\n' 'HUA_TELEGRAM_TOKEN=hua' 'HUA_HUB_TOKEN=hub' 'HUA_DELIVERY_SECRET=dlv' ;;
      *) exit 1 ;;
    esac
  SH
  FileUtils.chmod(0o755, fake_ssh)
  env = {"EXPORT_SSH_ARGV_JSON" => JSON.generate([fake_ssh, "host"])}
  out, err, status = run("ruby", "#{ROOT}/scripts/extract-workload-secrets.rb", "prism-hubot", "h-ua-bot", env: env)
  check(status.success?, "extraction should succeed: #{err}")
  document = JSON.parse(out)
  check(document["prism-hubot"] == {
    "PRISM_BOT_TELEGRAM_TOKEN" => "tok-123:abc", "PRISM_BOT_TELEGRAM_WEBHOOK_SECRET" => "whs",
    "PRISM_BOT_DELIVERY_SECRET" => "del=with=equals"
  }, "only declared, non-empty secrets are taken, and a value may contain '='")
  check(document["h-ua-bot"].keys.sort == %w[HUA_DELIVERY_SECRET HUA_HUB_TOKEN HUA_TELEGRAM_TOKEN], "h-ua-bot secrets")
  check(!out.include?("must-not-leak"), "an undeclared variable must not be exported")
  check(err.include?('prism-hubot: declared=4 exported=3 missing=[] empty=["PRISM_HUB_API_TOKEN"]'), "the report names the empty secret: #{err}")
  report_lines = err.lines.reject { _1.start_with?("::add-mask::") }.join
  %w[tok-123 whs del=with hua dlv must-not-leak].each { |value| check(!report_lines.include?(value), "the report must never show a value (#{value})") }
  check(err.lines.count { _1.start_with?("::add-mask::") } == 6, "every exported value is registered for masking")

  # --- extract-workload-secrets refuses what it must
  _, _, status = run("ruby", "#{ROOT}/scripts/extract-workload-secrets.rb", "no-such-workload", env: env)
  check(!status.success?, "an unknown workload has no contract and must fail")
  _, _, status = run("ruby", "#{ROOT}/scripts/extract-workload-secrets.rb", "prism-hubot; rm -rf /", env: env)
  check(!status.success?, "an invalid workload name must fail")
  _, _, status = run("ruby", "#{ROOT}/scripts/extract-workload-secrets.rb", "prism-hubot", env: {"EXPORT_SSH_ARGV_JSON" => JSON.generate([fake_ssh, "host", "x"])}.merge("PATH" => ENV["PATH"]))
  check(status.success?, "extra ssh argv is allowed (the command is appended)")
  _, _, status = run("ruby", "#{ROOT}/scripts/extract-workload-secrets.rb", "4x-ais", env: env)
  check(!status.success?, "a workload that declares no secrets exports nothing and must fail")

  # --- manifest and verification, end to end with real age and tampering
  export = File.join(dir, "export")
  FileUtils.mkdir_p(export)
  items = {
    "postgres-globals" => "CREATE ROLE prism_hub;\n",
    "db-prism_hub" => "PGDMP\x01\x0e\x00".b + ("row\n" * 100),
    "secrets" => JSON.generate("prism-hubot" => {"PRISM_BOT_TELEGRAM_TOKEN" => "tok-789:xyz"}),
    "volume-prism-hubot-state" => nil
  }
  tar_dir = File.join(dir, "vol")
  FileUtils.mkdir_p(tar_dir)
  File.write(File.join(tar_dir, "state.json"), "{}")
  items["volume-prism-hubot-state"], = run("tar", "-C", tar_dir, "-cf", "-", ".")
  items.each do |name, data|
    out, _, status = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", recipient, File.join(export, "#{name}.age"), stdin: data)
    check(status.success?, "sealing #{name}")
    File.write(File.join(export, "#{name}.plain.json"), out)
  end
  _, err, status = run("ruby", "#{ROOT}/scripts/build-export-manifest.rb", export, env: {"RECIPIENT" => recipient})
  check(status.success?, "the manifest builds: #{err}")
  out, err, status = run("ruby", "#{ROOT}/scripts/verify-export.rb", export, identity)
  check(status.success?, "an intact export verifies: #{err}")
  %w[ok\ \ db-prism_hub PostgreSQL\ custom\ format entries ok\ \ secrets ok\ \ postgres-globals].each do |expected|
    check(out.include?(expected), "the report covers #{expected}")
  end
  check(out.include?("prism-hubot: PRISM_BOT_TELEGRAM_TOKEN"), "the report lists secret names")
  check(!out.include?("tok-789") && !err.include?("tok-789"), "verification must never print a secret value")

  tampered = File.join(dir, "tampered")
  FileUtils.cp_r(export, tampered)
  File.binwrite(File.join(tampered, "db-prism_hub.age"), File.binread(File.join(tampered, "db-prism_hub.age")) + "x")
  _, _, status = run("ruby", "#{ROOT}/scripts/verify-export.rb", tampered, identity)
  check(!status.success?, "a changed ciphertext must fail verification")

  manifest_path = File.join(export, "manifest.json")
  wrong = File.join(dir, "wrong")
  FileUtils.cp_r(export, wrong)
  doc = JSON.parse(File.read(File.join(wrong, "manifest.json")))
  doc["items"].find { _1["name"] == "secrets" }["plaintext_sha256"] = "0" * 64
  File.write(File.join(wrong, "manifest.json"), JSON.generate(doc))
  _, err, status = run("ruby", "#{ROOT}/scripts/verify-export.rb", wrong, identity)
  check(!status.success? && err.include?("does not decrypt to what was sealed"), "a wrong plaintext hash must fail")

  other_identity = File.join(dir, "other.txt")
  run("age-keygen", "-o", other_identity)
  _, _, status = run("ruby", "#{ROOT}/scripts/verify-export.rb", export, other_identity)
  check(!status.success?, "a different identity must not open the export")

  not_a_dump = File.join(dir, "notadump")
  FileUtils.cp_r(export, not_a_dump)
  out, = run("ruby", "#{ROOT}/scripts/seal-stdin.rb", recipient, File.join(not_a_dump, "db-prism_hub.age"), stdin: "plain text, not a dump")
  doc = JSON.parse(File.read(File.join(not_a_dump, "manifest.json")))
  entry = doc["items"].find { _1["name"] == "db-prism_hub" }
  entry["ciphertext_sha256"] = Digest::SHA256.file(File.join(not_a_dump, "db-prism_hub.age")).hexdigest
  entry["plaintext_sha256"] = JSON.parse(out)["sha256"]
  entry["plaintext_bytes"] = JSON.parse(out)["bytes"]
  File.write(File.join(not_a_dump, "manifest.json"), JSON.generate(doc))
  _, err, status = run("ruby", "#{ROOT}/scripts/verify-export.rb", not_a_dump, identity)
  check(!status.success? && err.include?("not a PostgreSQL custom-format dump"), "a database item that is not a dump must fail")
  check(File.exist?(manifest_path), "the manifest file exists")
end

puts "migration export tools are valid"
