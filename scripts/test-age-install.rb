#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# `age` is installed by three workflows: the Contracts check, the deploy that decrypts a workload's
# secrets, and the Prism backup. All three used one `apt-get install` from the runner's default
# mirror, so an outage of Ubuntu's mirrors stopped CI, deploys and backups at once. On 2026-11-11 the
# runner could not resolve azure.archive.ubuntu.com or archive.ubuntu.com for over an hour, so no
# apt fallback could help. Each workflow now installs through the same block: apt, bounded, and if
# that fails the pinned release built from the Go module proxy. This test keeps the three blocks
# identical and runs the block against stubbed tools for each way it can go.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
FILES = %w[ci.yml deploy-workload.yml backup-prism-postgres.yml].map { |name| File.join(ROOT, ".github", "workflows", name) }

def block_of(path)
  text = File.read(path, encoding: "UTF-8")
  found = text.scan(/^[ ]*# BEGIN install-age.*?^[ ]*# END install-age$/m)
  abort("#{path}: expected exactly one install-age block, found #{found.length}") unless found.length == 1
  found.first.lines.map(&:strip).join("\n")
end

blocks = FILES.map { |path| [path, block_of(path)] }
reference = blocks.first.last
blocks.each { |path, block| abort("#{path}: install-age block differs from #{blocks.first.first}") unless block == reference }
FILES.each do |path|
  text = File.read(path, encoding: "UTF-8")
  abort("#{path}: a bare `apt-get install ... age` is back") if text.match?(/^\s*sudo apt-get install -y[^\n]* age\s*$/)
end
abort("the block does not bound its apt calls with timeout") unless reference.scan(/timeout -k 5 \d+ sudo apt-get/).length == 2
abort("the block does not bound go install with timeout") unless reference.include?("timeout -k 5 240 go install filippo.io/age/cmd/age@v1.2.1")

def run_block(block, apt_fails:, go_fails:)
  Dir.mktmpdir("age-install") do |dir|
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    home = File.join(dir, "home")
    FileUtils.mkdir_p(home)
    log = File.join(dir, "calls.log")
    github_path = File.join(dir, "github_path")
    File.write(github_path, "")
    {
      "sudo" => "#!/bin/sh\nexec \"$@\"\n",
      "age" => "#!/bin/sh\nexit 0\n",
      "apt-get" => <<~SH,
        #!/bin/sh
        echo "apt-get $*" >> "#{log}"
        [ "#{apt_fails}" = true ] && { echo "E: Temporary failure resolving azure.archive.ubuntu.com" >&2; exit 100; }
        exit 0
      SH
      "go" => <<~SH
        #!/bin/sh
        echo "go $* GOBIN=$GOBIN" >> "#{log}"
        [ "#{go_fails}" = true ] && { echo "go: module proxy down" >&2; exit 1; }
        exit 0
      SH
    }.each do |name, body|
      File.write(File.join(bin, name), body)
      File.chmod(0o755, File.join(bin, name))
    end
    env = { "PATH" => "#{bin}:#{ENV.fetch('PATH')}", "HOME" => home, "GITHUB_PATH" => github_path }
    output, status = Open3.capture2e(env, "bash", "-c", "set -Eeuo pipefail\n#{block}\n")
    calls = File.exist?(log) ? File.read(log) : ""
    [status.success?, output, calls, File.read(github_path), home]
  end
end

# Ubuntu's mirror answers: no Go, no warning, and every apt call retries.
ok, output, calls, = run_block(reference, apt_fails: false, go_fails: false)
abort("healthy mirror failed:\n#{output}") unless ok
abort("Go used with a healthy mirror:\n#{calls}") if calls.include?("go ") || output.include?("::warning::")
abort("an apt call does not retry:\n#{calls}") unless calls.lines.all? { |line| line.include?("Acquire::Retries=2") }

# Ubuntu's mirrors are down: the pinned release is built from the module proxy, with a warning, into
# a directory that is put on PATH for this step and the ones after it.
ok, output, calls, github_path, home = run_block(reference, apt_fails: true, go_fails: false)
abort("the Go fallback did not rescue the install:\n#{output}") unless ok
abort("no warning that apt is down") unless output.include?("::warning::")
go_calls = calls.lines.grep(/^go /)
abort("expected exactly one go install, got:\n#{calls}") unless go_calls.length == 1
abort("go install is not the pinned release:\n#{go_calls.first}") unless go_calls.first.start_with?("go install filippo.io/age/cmd/age@v1.2.1 ")
abort("go install does not write into ~/.local/bin:\n#{go_calls.first}") unless go_calls.first.include?("GOBIN=#{home}/.local/bin")
abort("~/.local/bin is not on PATH for later steps") unless github_path.include?("#{home}/.local/bin")

# Everything is down: the step fails. It never reports success without age.
ok, = run_block(reference, apt_fails: true, go_fails: true)
abort("install succeeded with every source down") if ok

puts "age install: three identical blocks, healthy mirror, mirror down, everything down: passed"
