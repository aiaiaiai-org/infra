#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Prints what scripts/resolve-workload-target.rb answers for a workload on a temporary copy of the
# contracts where retired servers are active. CI uses it to keep checking the shape of a contract
# whose server is retired; the real resolver refuses such a workload, so nothing here can select
# a retired server's Environment (the copy is thrown away, and this script has no outputs).

require_relative "lib/live_copy"

workload = ARGV.first.to_s
abort("usage: resolve-on-live-copy.rb <workload>") unless workload.match?(/\A[a-z0-9][a-z0-9-]*\z/)

stdout, stderr, status = LiveCopy.resolve(File.expand_path("..", __dir__), workload)
warn(stderr) unless stderr.empty?
print(stdout)
exit(status.success? ? 0 : 1)
