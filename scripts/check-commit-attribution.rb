#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Validates attribution trailer syntax without restricting contributor identities.
# Shared file: keep it identical to the canonical source (scripts/check-shared-sync.rb).

require 'open3'

Encoding.default_external = Encoding::UTF_8

SHA = /\A[0-9a-f]{40}\z/
TRAILER = /\A[A-Za-z][A-Za-z-]*: /
# Git trailer keys are case-insensitive, so every spelling is validated.
ATTRIBUTION = /\A(?:assisted-by|co-authored-by):/i
VALID = [
  /\AAssisted-by: \S(?:.*\S)?\z/i,
  /\ACo-authored-by: [^<>\n]+ <[^<>\s]+@[^<>\s]+>\z/i
].freeze

def git(*args)
  out, status = Open3.capture2('git', *args)
  abort "git #{args.first} failed" unless status.success?
  out
end

# Only the final paragraph of a commit message holds trailers.
def trailers(message)
  lines = message.lines.map(&:chomp).reverse.drop_while { |line| line.strip.empty? }
  lines.take_while { |line| line.match?(TRAILER) }
end

def invalid_trailer(message)
  trailers(message).find do |line|
    line.match?(ATTRIBUTION) && VALID.none? { |pattern| line.match?(pattern) }
  end
end

base = ENV.fetch('BASE_SHA')
head = ENV.fetch('HEAD_SHA')
abort 'Invalid commit SHA' unless [base, head].all? { |sha| sha.match?(SHA) }

commits = git('rev-list', '--reverse', "#{base}..#{head}").lines.map(&:strip)
abort 'No PR commits to validate' if commits.empty?

commits.each do |sha|
  line = invalid_trailer(git('show', '-s', '--format=%B', sha))
  abort "Invalid attribution trailer on #{sha}: #{line}" if line
end
puts "Validated attribution syntax for #{commits.length} PR commit(s)"
