#!/usr/bin/env ruby
# © 2026 aiaiaiai · aiaiaiai.org
# frozen_string_literal: true

# The boundaries of "Migrate aiaiaiai core to edge-dev-1" and its scripts, checked from the files: only
# master, an explicit confirmation, the pinned edge-dev-1 server, no second public Caddy, nothing published
# on a host port, nothing on edge-prod-2, and no way to print a secret.

require "yaml"

ROOT = File.expand_path("..", __dir__)
workflow_path = File.join(ROOT, ".github", "workflows", "migrate-aiaiaiai-edge-dev-1.yml")
workflow_text = File.read(workflow_path)
workflow = YAML.safe_load(workflow_text)
migrate = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "migrate.sh"))
route = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "route.sh"))
snippet = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "api.Caddyfile"))

def check(condition, message)
  abort("FAIL: #{message}") unless condition
end

triggers = workflow[true] || workflow["on"]
check(triggers.keys == ["workflow_dispatch"], "the workflow is manual only")
check(workflow.dig("permissions") == {"contents" => "read", "packages" => "read", "actions" => "read"}, "least privilege")
workflow["jobs"].each do |name, job|
  check(job["if"].to_s.include?("github.ref == 'refs/heads/master'"), "#{name} runs only from master")
  check(job.dig("environment", "name") == "edge-dev-1", "#{name} uses only the edge-dev-1 environment")
end
check(workflow_text.lines.reject { _1.strip.start_with?("#") }.none? { _1.include?("edge-prod-2") }, "edge-prod-2 appears only in comments")
check(!workflow_text.match?(/62\.238\.19\.244/), "the old server's address is not used")
check(workflow_text.scan("test \"$CONFIRMATION\" = MIGRATE").length == 2, "both jobs require MIGRATE")
check(workflow_text.scan("test \"$SSH_HOST\" = 158.220.74.54").length == 2, "both jobs pin the edge-dev-1 address")
workflow["jobs"].each_value do |job|
  job["steps"].each do |step|
    check(!step["run"].to_s.include?("${{"), "no expression is interpolated into a shell command (#{step["name"]})")
  end
end

check(migrate.include?("NETWORK=nilx-candidate"), "workloads join the ingress's private network")
check(!migrate.match?(/docker run[^\n]*(?:\s-p\s|--publish)/) && !migrate.include?("--network host"), "no host port is published")
check(migrate.include?("pinned_verified_image") && migrate.include?("gh attestation verify"), "images are pinned and verified")
check(migrate.include?("test \"$(hostname)\" = edge-dev-1"), "the script refuses any other host")
check(!migrate.match?(/\becho\b[^\n]*(?:secret|credential|token)[^\n]*\$/i), "no secret value is echoed")
check(migrate.scan("DEPLOY_MODE=validate").length == 3 && migrate.scan("DEPLOY_MODE=activate").length == 3, "validate before activate")

check(route.include?("never binds 80/443 twice"), "the route reuses the existing ingress")
check(!route.match?(/docker run[^\n]*(?:-p |--publish)/) && !route.include?("--network host"), "no second public Caddy")
check(route.include?('cmp -s -n "$(stat -c %s "$live")" "$live" "$candidate"'), "what was live is preserved")
check(route.include?("healthy_nilx") && route.scan("healthy_nilx").length >= 4, "nilx.one is checked around every change")
check(snippet.scan(/^[a-z0-9.-]+ \{/).sort == ["api.aiaiaiai.org {"], "the snippet adds exactly one host")
check(!snippet.match?(/nilx\.one|aiaiaiai\.org,/), "the snippet touches no other host")

issue = File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "issue-hubot-credential.rb"))
check(workflow_text.include?("hubot-credential") && migrate.include?("hubot-credential"), "the credential stage is wired in the workflow and the script")
check(issue.scan(/^\s*puts /).length == 2 && issue.include?('puts "ISSUED_TOKEN=') && issue.include?('puts "ISSUED_ID='), "the issuing script prints only the credential id and token, and only when issuing")
check(!issue.match?(/publications:|alert_subscriptions:/), "prism-hubot is not granted publications or alert subscriptions")
check(issue.include?("channel_ids: []"), "prism-hubot is granted no channels")
check(migrate.include?("mv -f .hub-token.next .hub-token") && migrate.include?("the hub accepts prism-hubot's credential"), "the stage swaps the token and proves the hub accepts it")

speech = migrate[/^elif \[\[ "\$stage" == speech \]\]; then\n.*?^else\n/m] or abort("FAIL: the speech stage is not in migrate.sh")
tts_contract = File.read(File.join(ROOT, "contracts", "services", "prism-ai-tts.yaml"))
check(workflow_text.include?("speech") && workflow_text.include?("tts_sha") && workflow_text.include?("TTS_IMAGE="), "the speech stage is wired in the workflow")
check(speech.index("pinned_verified_image \"$TTS_IMAGE\"") < speech.index("deploy_workload") && speech.index("pinned_verified_image \"$HUBOT_IMAGE\"") < speech.index("deploy_workload"), "both images are verified before anything changes")
check(speech.index('"$ENVELOPE_DIR/hubot_sha"') < speech.index("deploy_workload") && speech.index("workload-secret-env.rb") < speech.index("deploy_workload"), "the resealed envelope is bound to hubot_sha and its secrets derived before anything changes")
check(speech.include?('| remote "cd \'$dir\' && cat >> .env') && !speech.match?(/remote "[^\n]*\$hubot_secret_env/), "the secrets travel on stdin, never in a command line")
check(speech.include?('::add-mask::$hubot_secret_env'), "the derived secret environment is masked in the log")
check(speech.include?("Speech::Configuration.build(ENV)") && speech.include?("voice.call("), "the stage proves the voice end to end from inside hubot")
check(!speech.include?("open_item") && !workflow_text[/operation != 'hubot-credential' && inputs.operation != 'speech'/].nil?, "the speech stage needs no migration export")
check(!tts_contract.match?(/^\s*public:/) && !tts_contract.match?(/^\s*secrets:/), "the TTS service has no public route and no secret")
check(tts_contract.include?("mode: manual"), "the TTS service is released only on purpose")

reseal = File.read(File.join(ROOT, ".github", "workflows", "reseal-hubot-envelope-edge-dev-1.yml"))
check(reseal.include?("name: edge-dev-1") && reseal.include?("name: edge-prod-2"), "the reseal reads edge-dev-1's public key and opens with edge-prod-2's deploy key")
check(reseal.include?("gh attestation verify") && reseal.include?("--signer-workflow aiaiaiai-org/prism-hubot/.github/workflows/publish.yml"), "the envelope's provenance is verified before it is opened")
check(reseal.match?(/age --decrypt --identity "\$key" [^\n]*\| age --recipient "\$RECIPIENT" --output/), "plaintext lives only in the pipe between the two age calls")
check(!reseal.match?(/age --decrypt[^|\n]*--output/), "the envelope is never decrypted to a file")
check(reseal.include?("is not the key edge-prod-2's contract publishes"), "the opening key is proved to be the contract's recipient")
check(reseal.include?("retention-days: 1") && !reseal.include?("ssh -") && !reseal.include?("scp "), "the artifact is short-lived ciphertext and no server is contacted")

# edge-dev-1 is the contract home of the Prism chain, on the network of its one existing public Caddy.
require "yaml"
dev1 = YAML.safe_load(File.read(File.join(ROOT, "contracts", "servers", "edge-dev-1.yaml")))
dev_edge = YAML.safe_load(File.read(File.join(ROOT, "contracts", "edges", "aiaiaiai-dev-edge.yaml")))
check(dev1.dig("spec", "workloads").sort == %w[h-ua-bot prism-ai-tts prism-hub prism-hubot prism-postgres], "edge-dev-1 places exactly the Prism chain and its bot")
check(dev1.dig("spec", "state").nil? && dev1.dig("spec", "encryptionRecipient").to_s.start_with?("ssh-ed25519 "), "edge-dev-1 is active and publishes an encryption recipient")
check(migrate[/^NETWORK=(\S+)/, 1] == dev_edge.dig("spec", "network", "name") && dev1.dig("spec", "edgeNetwork") == dev_edge.dig("spec", "network", "name"), "migrate.sh, the server and its edge name one network")
check(dev_edge.dig("spec", "placement", "target") == "edge-dev-1" && dev_edge.dig("spec", "entrypoint", "ports") == dev1.dig("spec", "publicPorts"), "the edge describes the one public Caddy and ports of edge-dev-1")
check(dev_edge.dig("spec", "routes").map { _1["service"] }.sort == %w[h-ua-bot prism-hub prism-hubot], "only hub, hubot and the bot are routed; the TTS service has no public route")

check(File.read(File.join(ROOT, "deploy", "aiaiaiai-edge-dev-1", "api.Caddyfile")).include?("reverse_proxy h-ua-bot:1927"), "the reviewed api block routes the bot")
check(route.include?("replace_api_block") && route.include?("without_api_block") && route.include?("ingress.before-update.Caddyfile"), "an already-routed host is updated in place with its own undo")

hua = YAML.safe_load(File.read(File.join(ROOT, "contracts", "services", "h-ua-bot.yaml")))
check(hua.dig("spec", "delivery", "image") == "ghcr.io/0x0sky/h-ua-bot" && hua.dig("spec", "delivery", "signerWorkflow") == ".github/workflows/publish.yml" && hua.dig("spec", "delivery", "mode") == "manual", "h-ua-bot is pulled by infra from its attested publish workflow, on purpose")

puts "migration workflow boundaries are valid"
