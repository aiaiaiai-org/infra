# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Tests that check a contract's shape through the resolver. The resolver refuses a workload placed
# on a retired server (so no Environment is selected for it); those tests run it on a temporary
# copy where the retired servers are active, which keeps the shape checked without saying the
# workload can be deployed.

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

module LiveCopy
  SCRIPT = "resolve-workload-target.rb"

  # Yields the root of a copy of `contracts/` and the given scripts, retired servers made active.
  def self.with(root, *scripts)
    Dir.mktmpdir("live-copy") do |dir|
      FileUtils.cp_r(File.join(root, "contracts"), File.join(dir, "contracts"))
      FileUtils.mkdir_p(File.join(dir, "scripts"))
      scripts.each { |name| FileUtils.cp(File.join(root, "scripts", name), File.join(dir, "scripts", name)) }
      Dir.glob(File.join(dir, "contracts", "servers", "*.yaml")).each do |path|
        text = File.read(path, encoding: "UTF-8")
        File.write(path, text.sub(/^  state: retired\n/, ""))
      end
      yield dir
    end
  end

  # [stdout, stderr, status] of the resolver for `workload` on such a copy.
  def self.resolve(root, workload)
    with(root, SCRIPT) do |dir|
      Open3.capture3({ "GITHUB_OUTPUT" => nil }, RbConfig.ruby, File.join(dir, "scripts", SCRIPT), workload)
    end
  end
end
