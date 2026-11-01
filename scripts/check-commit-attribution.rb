#!/usr/bin/env ruby
# Validates commit authorship on pull requests against repository policy.
require 'yaml'
require 'open3'

policy = YAML.safe_load_file('.github/contributors.yml')
identities = policy.fetch('identities').map do |entry|
  [entry.fetch('name'), entry.fetch('email')]
end
abort 'Empty contributor identity allowlist' if identities.empty?

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')
abort 'Invalid base or head SHA' unless [base, head].all? { |s| s.match?(/\A[0-9a-f]{40}\z/) }
out, status = Open3.capture2('git', 'rev-list', '--reverse', "#{base}..#{head}")
abort 'Cannot enumerate commits' unless status.success?
commits = out.lines.map(&:strip)
abort 'No commits to validate' if commits.empty?

commits.each do |sha|
  raw, ok = Open3.capture2('git', 'show', '-s', '--format=%an%x00%ae%x00%cn%x00%ce%x00%B', sha)
  abort "Cannot inspect #{sha}" unless ok.success?
  author, email, committer, committer_email, message = raw.split("\0", 5)
  abort "Unrecognized author on #{sha}: #{author} <#{email}>" unless identities.include?([author, email])
  abort "Unrecognized committer on #{sha}: #{committer} <#{committer_email}>" unless identities.include?([committer, committer_email])
  trailers = message.to_s.lines.grep(/\A(?:Assisted-by|Co-authored-by):/)
  trailers.each do |line|
    case line
    when /\AAssisted-by: [^\s].+\z/
      next
    when /\ACo-authored-by: ([^<>\n]+) <([^<>\s]+@[^<>\s]+)>\s*\z/
      next if identities.include?([$1.strip, $2])
    end
    abort "Invalid attribution trailer on #{sha}: #{line.strip}"
  end
  abort "Missing Assisted-by trailer on agent commit #{sha}" if author == 'x0skai' && trailers.none? { |line| line.start_with?('Assisted-by: ') }
end
puts "Validated #{commits.length} commit(s)"
