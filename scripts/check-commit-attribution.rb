#!/usr/bin/env ruby
# Validate attribution trailer syntax without restricting contributor identities.
require 'open3'

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')
abort 'Invalid commit SHA' unless [base, head].all? { |s| s.match?(/\A[0-9a-f]{40}\z/) }

out, status = Open3.capture2('git', 'rev-list', '--reverse', "#{base}..#{head}")
abort 'Cannot enumerate PR commits' unless status.success?
commits = out.lines.map(&:strip)
abort 'No PR commits to validate' if commits.empty?

commits.each do |sha|
  message, ok = Open3.capture2('git', 'show', '-s', '--format=%B', sha)
  abort "Cannot inspect #{sha}" unless ok.success?
  # Only recognize attribution in the final trailer block.
  lines = message.lines.map(&:chomp)
  trailers = []
  lines.reverse_each do |line|
    if line.strip.empty?
      break unless trailers.empty?
    elsif line.match?(/\A[A-Za-z][A-Za-z-]*: /)
      trailers << line
    else
      break
    end
  end
  trailers.each do |line|
    case line
    when /\AAssisted-by: [^\s].*\S\z/
      next
    when /\ACo-authored-by: [^<>\n]+ <[^<>\s]+@[^<>\s]+>\z/
      next
    when /\A(?:Assisted-by|Co-authored-by):/
      abort "Invalid attribution trailer on #{sha}: #{line}"
    end
  end
end
puts "Validated attribution syntax for #{commits.length} PR commit(s)"
