#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Checks that shared agent rules and scripts match the canonical source pinned in
# .github/shared-sync.yml. Two kinds of content may differ per repository: blocks
# between project-specific markers in AGENTS.md, and comment-only lines carrying
# copyright or license notices. Everything else must match exactly.
# Shared file: keep it identical to the canonical source.
#
# Usage: check-shared-sync.rb [--latest] [--source-dir DIR]
#   --latest      compare with the canonical default branch instead of the pin
#   --source-dir  compare with a local checkout (used by the tests)

require 'open3'
require 'tmpdir'
require 'yaml'

Encoding.default_external = Encoding::UTF_8

SHARED_FILES = %w[
  AGENTS.md
  scripts/check-commit-attribution.rb
  scripts/test-commit-attribution.rb
  scripts/check-shared-sync.rb
  scripts/test-shared-sync.rb
].freeze
PIN_FILE = '.github/shared-sync.yml'
MARKERS = ['<!-- project-specific -->', '<!-- /project-specific -->'].freeze
OPEN_LINE = /^[ \t]*#{Regexp.escape(MARKERS.first)}[ \t]*\n/
BLOCK = /#{OPEN_LINE}.*?^[ \t]*#{Regexp.escape(MARKERS.last)}[ \t]*(?:\n|\z)/m
NOTICE = %r{\A\s*(?:#|//|<!--).*(?:©|SPDX)}

def git(*args)
  out, status = Open3.capture2e('git', *args)
  abort "git #{args.join(' ')} failed:\n#{out}" unless status.success?
  out.strip
end

def shared_text(text, label)
  stripped = text.gsub(BLOCK, '')
  if stripped.each_line.any? { |line| MARKERS.include?(line.strip) }
    abort "#{label}: unbalanced project-specific markers"
  end

  lines = stripped.lines(chomp: true).grep_v(NOTICE).map(&:rstrip)
  lines.join("\n").gsub(/\n{3,}/, "\n\n").strip
end

def read_pin
  pin = YAML.safe_load_file(PIN_FILE)
  source = pin.fetch('source').to_s
  abort "#{PIN_FILE}: source must be owner/repo" unless source.match?(%r{\A[\w.-]+/[\w.-]+\z})
  [source, pin['ref'].to_s]
end

def current_repository
  ENV.fetch('GITHUB_REPOSITORY') do
    git('remote', 'get-url', 'origin').sub(/\.git\z/, '').split(%r{[/:]}).last(2).join('/')
  end
end

def fetch_canonical(source, ref, dir)
  git('init', '-q', dir)
  git('-C', dir, 'fetch', '-q', '--depth', '1', "https://github.com/#{source}.git", ref)
  git('-C', dir, 'checkout', '-q', 'FETCH_HEAD')
  git('-C', dir, 'rev-parse', 'HEAD')
end

def unified_diff(expected, actual)
  Dir.mktmpdir do |dir|
    canonical = File.join(dir, 'canonical')
    local = File.join(dir, 'local')
    File.write(canonical, "#{expected}\n")
    File.write(local, "#{actual}\n")
    Open3.capture2('diff', '-u', canonical, local).first
  end
end

def mismatch(path, root)
  canonical = File.join(root, path)
  return "#{path}: missing from the canonical source" unless File.file?(canonical)
  return "#{path}: missing" unless File.file?(path)

  expected = shared_text(File.read(canonical), "canonical #{path}")
  actual = shared_text(File.read(path), path)
  "#{path}: shared content differs\n#{unified_diff(expected, actual)}" unless expected == actual
end

def report(problems, source, resolved, latest)
  if problems.empty?
    puts "Shared files match #{source}@#{resolved[0, 12]} (#{SHARED_FILES.length} files)"
    return
  end

  warn problems.join("\n")
  warn hint(source, latest)
  exit 1
end

def hint(source, latest)
  return "#{source} changed: sync these files and update ref in #{PIN_FILE}." if latest

  "Change shared text in #{source} first; keep repository rules in project-specific blocks."
end

latest = ARGV.delete('--latest')
source_index = ARGV.index('--source-dir')
source_dir = source_index && ARGV.fetch(source_index + 1)
source, ref = read_pin
SHARED_FILES.each { |path| shared_text(File.read(path), path) if File.file?(path) }

if source_dir.nil? && source == current_repository
  puts "#{source} is the canonical source; project-specific markers are balanced"
  exit
end

unless source_dir || latest || ref.match?(/\A[0-9a-f]{40}\z/)
  abort "#{PIN_FILE}: ref must be a full commit SHA of #{source}"
end

Dir.mktmpdir do |dir|
  wanted = latest ? 'HEAD' : ref
  resolved = source_dir ? 'local-checkout' : fetch_canonical(source, wanted, dir)
  problems = SHARED_FILES.filter_map { |path| mismatch(path, source_dir || dir) }
  puts "Pinned ref #{ref[0, 12]} differs from latest #{resolved[0, 12]}" if latest && ref != resolved
  report(problems, source, resolved, latest)
end
