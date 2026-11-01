#!/usr/bin/env ruby
# frozen_string_literal: true

# © 2026 aiaiaiai · aiaiaiai.org
# Exercises check-commit-attribution.rb against throwaway commits.
# Shared file: keep it identical to the canonical source (scripts/check-shared-sync.rb).

require 'open3'
require 'rbconfig'
require 'tmpdir'

CHECKER = File.expand_path('check-commit-attribution.rb', __dir__)
CASES = {
  'Assisted-by: OpenAI Codex' => true,
  'Assisted-by: X' => true,
  'Co-authored-by: Name <name@example.org>' => true,
  'Co-Authored-By: Name <name@example.org>' => true,
  'co-authored-by: Name <name@example.org>' => true,
  'Co-authored-by: garbage' => false,
  'Co-Authored-By: garbage' => false,
  'co-authored-by: garbage' => false,
  'ASSISTED-BY: ' => false,
  'Signed-off-by: anything' => true
}.freeze

def git(dir, *args)
  identity = ['-c', 'user.name=t', '-c', 'user.email=t@example.org']
  out, status = Open3.capture2e('git', '-C', dir, *identity, *args)
  abort "git #{args.join(' ')} failed: #{out}" unless status.success?
  out.strip
end

def passes?(dir, base, trailer)
  git(dir, 'commit', '-q', '--allow-empty', '--cleanup=verbatim', '-m', "change\n\n#{trailer}")
  env = { 'BASE_SHA' => base, 'HEAD_SHA' => git(dir, 'rev-parse', 'HEAD') }
  _, status = Open3.capture2e(env, RbConfig.ruby, CHECKER, chdir: dir)
  git(dir, 'reset', '-q', '--hard', base)
  status.success?
end

Dir.mktmpdir do |dir|
  git(dir, 'init', '-q')
  git(dir, 'commit', '-q', '--allow-empty', '-m', 'base')
  base = git(dir, 'rev-parse', 'HEAD')
  CASES.each do |trailer, valid|
    next if passes?(dir, base, trailer) == valid

    abort "#{trailer.inspect}: expected #{valid ? 'pass' : 'failure'}"
  end
end
puts "Commit attribution checker: #{CASES.length} cases passed"
