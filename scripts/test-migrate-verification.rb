#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# Runs the REAL `pinned_verified_image` function of deploy/aiaiaiai-edge-dev-1/migrate.sh, with stubbed
# `docker` and `gh`, the way the script calls it: in a checked assignment under `set -e`. A failed
# provenance check, an unresolvable digest or a failing registry call must stop the caller before a
# usable image reference is produced.

require "fileutils"
require "open3"
require "tmpdir"

ROOT = File.expand_path("..", __dir__)
script = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "migrate.sh"))
function = script[/^pinned_verified_image\(\) \{\n.*?^\}\n/m] or abort("FAIL: pinned_verified_image is not in migrate.sh")
header = script[/^shopt -s inherit_errexit$/] || ""

def check(condition, message)
  abort("FAIL: #{message}") unless condition
end

DIGEST = "sha256:#{"ab" * 32}"

Dir.mktmpdir do |dir|
  bin = File.join(dir, "bin")
  FileUtils.mkdir_p(bin)
  File.write(File.join(bin, "docker"), <<~SH)
    #!/usr/bin/env bash
    [[ "${STUB_DOCKER:-ok}" == fail ]] && exit 1
    printf '{"digest":"%s"}' "${STUB_DIGEST:-#{DIGEST}}"
  SH
  File.write(File.join(bin, "gh"), <<~SH)
    #!/usr/bin/env bash
    [[ "${STUB_GH:-ok}" == fail ]] && { echo "attestation verification failed" >&2; exit 1; }
    exit 0
  SH
  FileUtils.chmod(0o755, Dir[File.join(bin, "*")])

  caller_script = <<~SH
    set -Eeuo pipefail
    #{header}
    #{function}
    image="$(pinned_verified_image ghcr.io/aiaiaiai-org/prism-hubot:#{"c" * 40} aiaiaiai-org/prism-hubot)"
    echo "deploying:$image"
  SH

  run = lambda do |env|
    Open3.capture3({"PATH" => "#{bin}:#{ENV["PATH"]}"}.merge(env), "bash", "-c", caller_script)
  end

  out, _err, status = run.call({})
  check(status.success? && out.strip == "deploying:ghcr.io/aiaiaiai-org/prism-hubot@#{DIGEST}", "a verified image resolves to its digest: #{out.inspect}")

  out, err, status = run.call("STUB_GH" => "fail")
  check(!status.success?, "a failed attestation stops the caller")
  check(!out.include?("deploying:") && !out.include?("@sha256"), "a failed attestation yields no usable image reference: #{out.inspect}")
  check(err.include?("could not be verified"), "the failure names the image, not a secret: #{err.inspect}")

  out, _err, status = run.call("STUB_DOCKER" => "fail")
  check(!status.success? && !out.include?("deploying:"), "an unreachable registry stops the caller")

  out, _err, status = run.call("STUB_DIGEST" => "latest")
  check(!status.success? && !out.include?("deploying:"), "a malformed digest stops the caller")
end

check(script.include?("shopt -s inherit_errexit"), "the script makes failures inside $(...) fatal")
check(script.scan(/pinned_verified_image "\$HUB(?:OT)?_IMAGE"/).length == 3 && script.scan(/\$\(pinned_verified_image/).length == 3 &&
  script.scan(/^\s*(?:hub|hubot)_ref="\$\(pinned_verified_image/).length == 3,
  "every stage resolves its image in a checked assignment")
check(!script.match?(/deploy_workload \S+ "\$\(pinned_verified_image/), "no stage passes an unchecked substitution to deploy_workload")

# Rotation order: the running prism-hubot's credential is revoked only after the new one is proved.
credential_stage = script[/elif \[\[ "\$stage" == hubot-credential \]\].*?^else$/m] or abort("FAIL: no hubot-credential stage")
index = ->(needle) { credential_stage.index(needle) or abort("FAIL: #{needle} is missing from the credential stage") }
check(index.call("pinned_verified_image") < index.call("hub_credential issue"), "the image is verified before a credential is issued")
check(index.call("hub_credential issue") < index.call("deploy_workload"), "the credential is issued before the deployment")
check(index.call("answered $status") < index.call("hub_credential keep"), "earlier credentials are revoked only after the hub accepted the new one")
check(index.call('abandon_id="$new_id"') < index.call("deploy_workload") && index.call('abandon_id=""') > index.call("answered $status"),
  "an issued credential is revoked again on every failure path until proved")

issue = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "issue-hubot-credential.rb"))
issue_branch = issue[/when "issue".*?when "keep"/m]
check(!issue_branch.include?("revoke"), "issuing never revokes")

puts "migration verification and rotation order are valid"
