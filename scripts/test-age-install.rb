#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# `age` is installed by three workflows: the Contracts check, the deploy that decrypts a workload's
# secrets, and the Prism backup. All three used one `apt-get install` from the runner's default
# mirror, so a long outage of that mirror stopped CI, deploys and backups at once. Each now installs
# through the same block: apt with retries, then the Ubuntu archive itself. This test keeps the
# three blocks identical and runs the block against a stubbed apt, for each way it can go.

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

def run_block(block, primary_fails:, fallback_fails:)
  Dir.mktmpdir("age-install") do |dir|
    bin = File.join(dir, "bin")
    FileUtils.mkdir_p(bin)
    log = File.join(dir, "apt.log")
    {
      "sudo" => "#!/bin/sh\nexec \"$@\"\n",
      "lsb_release" => "#!/bin/sh\necho noble\n",
      "age" => "#!/bin/sh\nexit 0\n",
      "tee" => "#!/bin/sh\ncat > \"#{dir}/fallback.list\"\n",
      "apt-get" => <<~SH
        #!/bin/sh
        echo "$*" >> "#{log}"
        # Once the fallback list has been updated, the install that follows reads from it.
        case "$*" in
          *Dir::Etc::sourcelist*)
            [ "#{fallback_fails}" = true ] && { echo "E: fallback down" >&2; exit 100; }
            touch "#{dir}/fallback-updated"
            ;;
          *)
            if [ ! -e "#{dir}/fallback-updated" ] && [ "#{primary_fails}" = true ]; then
              echo "E: Temporary failure resolving azure.archive.ubuntu.com" >&2; exit 100
            fi
            ;;
        esac
        exit 0
      SH
    }.each do |name, body|
      File.write(File.join(bin, name), body)
      File.chmod(0o755, File.join(bin, name))
    end
    output, status = Open3.capture2e({ "PATH" => "#{bin}:#{ENV.fetch('PATH')}" }, "bash", "-c", "set -Eeuo pipefail\n#{block}\n")
    calls = File.exist?(log) ? File.read(log) : ""
    [status.success?, output, calls, File.exist?(File.join(dir, "fallback.list")) ? File.read(File.join(dir, "fallback.list")) : nil]
  end
end

# The mirror answers: no fallback, no warning, and every apt call retries.
ok, output, calls, list = run_block(reference, primary_fails: false, fallback_fails: false)
abort("healthy mirror failed:\n#{output}") unless ok
abort("fallback used with a healthy mirror") if calls.include?("Dir::Etc::sourcelist") || list || output.include?("::warning::")
abort("an apt call does not retry:\n#{calls}") unless calls.lines.all? { |line| line.include?("Acquire::Retries=2") }
abort("the block does not bound its apt calls with timeout:\n#{reference}") unless reference.scan(/timeout -k 5 \d+ sudo apt-get/).length == 4

# The mirror is down: the Ubuntu archive is used, signed, with a warning, and the install succeeds.
ok, output, calls, list = run_block(reference, primary_fails: true, fallback_fails: false)
abort("fallback did not rescue the install:\n#{output}") unless ok
abort("no warning that the mirror is down") unless output.include?("::warning::")
abort("fallback list is not the signed Ubuntu archive:\n#{list}") unless list&.include?("[signed-by=/usr/share/keyrings/ubuntu-archive-keyring.gpg] http://archive.ubuntu.com/ubuntu noble universe")
abort("fallback does not install age:\n#{calls}") unless calls.lines.last.include?("install") && calls.lines.last.include?(" age")

# Both are down: the step fails. It never reports success without age.
ok, = run_block(reference, primary_fails: true, fallback_fails: true)
abort("install succeeded with every source down") if ok

puts "age install: three identical blocks, healthy mirror, mirror down, everything down: passed"
