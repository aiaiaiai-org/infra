#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
#
# The preflight must report ALL missing names, without leaking secret values.
require "open3"

script = File.expand_path("validate-prism-backup-env.sh", __dir__)
settings = {
  "SSH_HOST" => "62.238.19.244",
  "SSH_USER" => "deploy",
  "SSH_PRIVATE_KEY" => "test-private-key-never-log",
  "SSH_PORT" => "22",
  "BACKUP_S3_ENDPOINT" => "https://fsn1.your-objectstorage.com",
  "BACKUP_S3_BUCKET" => "prism-backup-test",
  "BACKUP_S3_REGION" => "fsn1",
  "BACKUP_AGE_RECIPIENT" => "age1testpublicrecipientneverlog",
  "AWS_ACCESS_KEY_ID" => "test-access-key-never-log",
  "AWS_SECRET_ACCESS_KEY" => "test-secret-never-log",
  "GITHUB_RUN_ID" => "12345",
  "GITHUB_RUN_ATTEMPT" => "1"
}.freeze

run = ->(env) { Open3.capture3(env, "bash", script) }

stdout, stderr, status = run.call(settings)
abort "valid shape rejected: #{stderr}" unless status.success? && stdout.include?("required values are present")
abort "unexpected error on valid shape" unless stderr.empty?

missing = settings.merge(
  "BACKUP_S3_ENDPOINT" => "",
  "BACKUP_S3_BUCKET" => "",
  "BACKUP_S3_REGION" => "",
  "BACKUP_AGE_RECIPIENT" => "",
  "AWS_ACCESS_KEY_ID" => "",
  "AWS_SECRET_ACCESS_KEY" => ""
)
stdout, stderr, status = run.call(missing)
abort "missing settings accepted" unless status.exitstatus == 78
%w[
  BACKUP_S3_ENDPOINT BACKUP_S3_BUCKET BACKUP_S3_REGION BACKUP_AGE_RECIPIENT
  AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
].each do |name|
  abort "missing diagnostic for #{name}" unless stderr.include?("Missing backup configuration: #{name}")
end
abort "preflight must not log secret values" if (settings.values + ["test-private-key-never-log"]).any? do |value|
  stderr.include?(value) || stdout.include?(value)
end

{
  "BACKUP_S3_ENDPOINT" => "http://insecure.example",
  "BACKUP_S3_BUCKET" => "InvalidBucketName",
  "BACKUP_S3_REGION" => "INVALID",
  "BACKUP_AGE_RECIPIENT" => "line-one\nline-two"
}.each do |key, invalid|
  stdout, stderr, status = run.call(settings.merge(key => invalid))
  abort "bad #{key} accepted" if status.success?
  abort "bad #{key} leaked" if stderr.include?(invalid) || stdout.include?(invalid)
  abort "bad #{key} diagnostic missing" unless stderr.include?(key)
end

puts "Prism backup environment preflight tests passed"
