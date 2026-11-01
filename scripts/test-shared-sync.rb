#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Exercises check-shared-sync.rb against throwaway canonical and consumer trees.
# Shared file: keep it identical to the canonical source (scripts/check-shared-sync.rb).

require 'fileutils'
require 'open3'
require 'rbconfig'
require 'tmpdir'

Encoding.default_external = Encoding::UTF_8

ROOT = File.expand_path('..', __dir__)
CHECKER = File.join(ROOT, 'scripts/check-shared-sync.rb')
FILES = %w[
  scripts/check-commit-attribution.rb
  scripts/test-commit-attribution.rb
  scripts/check-shared-sync.rb
  scripts/test-shared-sync.rb
].freeze
AGENTS = "# AGENTS.md\n\nShared rule.\n\nAnother shared rule.\n"
SPECIFIC = "<!-- project-specific -->\nLocal rule.\n<!-- /project-specific -->\n"
WITH_BLOCK = "# AGENTS.md\n\nShared rule.\n\n#{SPECIFIC}\nAnother shared rule.\n".freeze
CASES = {
  'identical' => [AGENTS, true],
  'project-specific block' => [WITH_BLOCK, true],
  'notice line' => ["#{AGENTS}\n<!-- © 2026 example -->\n", true],
  'changed shared rule' => ["# AGENTS.md\n\nShared rule, edited.\n\nAnother shared rule.\n", false],
  'unclosed block' => ["#{AGENTS}<!-- project-specific -->\nLocal rule.\n", false],
  'stray closing marker' => ["#{AGENTS}<!-- /project-specific -->\n", false]
}.freeze

def tree(dir, agents, pin)
  FILES.each do |path|
    FileUtils.mkdir_p(File.dirname(File.join(dir, path)))
    FileUtils.cp(File.join(ROOT, path), File.join(dir, path))
  end
  File.write(File.join(dir, 'AGENTS.md'), agents)
  FileUtils.mkdir_p(File.join(dir, '.github'))
  File.write(File.join(dir, '.github/shared-sync.yml'), pin)
end

def passes?(agents, pin: "source: example/canonical\n", args: nil)
  Dir.mktmpdir do |dir|
    canonical = File.join(dir, 'canonical')
    consumer = File.join(dir, 'consumer')
    tree(canonical, AGENTS, pin)
    tree(consumer, agents, pin)
    env = { 'GITHUB_REPOSITORY' => 'example/consumer' }
    command = [RbConfig.ruby, CHECKER, *(args || ['--source-dir', canonical])]
    Open3.capture2e(env, *command, chdir: consumer).last.success?
  end
end

CASES.each do |name, (agents, valid)|
  abort "#{name}: expected #{valid ? 'pass' : 'failure'}" unless passes?(agents) == valid
end
self_pin = "source: example/consumer\n"
abort 'canonical source: expected pass' unless passes?(AGENTS, pin: self_pin, args: [])
abort 'pin without ref: expected failure' if passes?(AGENTS, args: [])
puts "Shared sync checker: #{CASES.length + 2} cases passed"
