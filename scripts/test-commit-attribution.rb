#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# Exercises check-commit-attribution.rb against throwaway commits.
require 'open3'
require 'tmpdir'

checker = File.expand_path('check-commit-attribution.rb', __dir__)
cases = {
  "Assisted-by: OpenAI Codex" => true,
  "Assisted-by: X" => true,
  "Co-authored-by: Name <name@example.org>" => true,
  "Co-Authored-By: Name <name@example.org>" => true,
  "co-authored-by: Name <name@example.org>" => true,
  "Co-authored-by: garbage" => false,
  "Co-Authored-By: garbage" => false,
  "co-authored-by: garbage" => false,
  "ASSISTED-BY: " => false,
  "Signed-off-by: anything" => true
}

Dir.mktmpdir do |dir|
  git = lambda do |*args|
    out, status = Open3.capture2e('git', '-C', dir, '-c', 'user.name=t', '-c', 'user.email=t@example.org', *args)
    abort "git #{args.join(' ')} failed: #{out}" unless status.success?
    out.strip
  end
  git.call('init', '-q')
  git.call('commit', '-q', '--allow-empty', '-m', 'base')
  base = git.call('rev-parse', 'HEAD')

  cases.each do |trailer, valid|
    git.call('commit', '-q', '--allow-empty', '--cleanup=verbatim', '-m', "change\n\n#{trailer}")
    head = git.call('rev-parse', 'HEAD')
    _, status = Open3.capture2e({ 'BASE_SHA' => base, 'HEAD_SHA' => head }, 'ruby', checker, chdir: dir)
    abort "#{trailer.inspect}: expected #{valid ? 'pass' : 'failure'}" unless status.success? == valid
    git.call('reset', '-q', '--hard', base)
  end
end
puts "Commit attribution checker: #{cases.length} cases passed"
