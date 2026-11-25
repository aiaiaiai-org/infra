#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
#
# Runs on a GitHub runner, never on the server. Brings the aiaiaiai core up on edge-dev-1 from a sealed
# export of edge-prod-2, with the same deploy/workload/deploy.sh and the values of the same reviewed
# contracts that Deploy workload uses, but on the private Docker network of edge-dev-1's existing ingress.
# Nothing is published on a host port: the workloads are reachable only through that ingress.
#
#   migrate.sh data    prism-postgres (database restored from the export), then prism-hub
#   migrate.sh hubot   prism-hubot (its state volume restored from the export)
#   migrate.sh hubot-credential
#                      persist a Hub credential on the target and redeploy with the existing workload configuration
#
# Environment: SSH_HOST SSH_USER SSH_PORT SSH_DIR (id_ed25519 and known_hosts) EXPORT_DIR IDENTITY
#              HUB_IMAGE HUBOT_IMAGE (image references without a digest) GH_TOKEN GHCR_USER
set -Eeuo pipefail
# A failing command inside $(...) must stop the script too (Bash clears -e there by default).
shopt -s inherit_errexit
umask 077

stage="${1:-}"
case "$stage" in data | hubot | hubot-credential) ;; *) echo 'usage: migrate.sh data|hubot|hubot-credential' >&2; exit 2 ;; esac
: "${SSH_HOST:?}" "${SSH_USER:?}" "${SSH_PORT:?}" "${SSH_DIR:?}" "${EXPORT_DIR:?}" "${IDENTITY:?}"
: "${HUB_IMAGE:?}" "${HUBOT_IMAGE:?}" "${GH_TOKEN:?}" "${GHCR_USER:?}" "${RUNNER_TEMP:?}"

NETWORK=nilx-candidate
INGRESS=nilx-public-edge-managed
ssh_opts=(-o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
  -o "UserKnownHostsFile=$SSH_DIR/known_hosts" -o ConnectTimeout=10 -i "$SSH_DIR/id_ed25519")
remote() { ssh -T "${ssh_opts[@]}" -p "$SSH_PORT" "$SSH_USER@$SSH_HOST" "$@"; }
upload() { scp -q "${ssh_opts[@]}" -P "$SSH_PORT" "$1" "$SSH_USER@$SSH_HOST:$2"; }
# Decrypts one sealed item into a pipe; plaintext is not written by this script.
open_item() { age -d -i "$IDENTITY" "$EXPORT_DIR/$1.age"; }

secret_files=()
abandon_id=""
# Runs deploy/aiaiaiai-edge-dev-1/issue-hubot-credential.rb inside the hub: issue | keep ID | abandon ID.
hub_credential() {
  local mode="$1" id="${2:-}"
  [[ -z "$id" || "$id" =~ ^[0-9a-f-]{36}$ ]] || { echo '::error::malformed credential id' >&2; return 1; }
  remote "docker exec -i -e HUBOT_CREDENTIAL_MODE=$mode -e HUBOT_CREDENTIAL_ID=$id prism-hub bin/rails runner 'eval(\$stdin.read)'" \
    <deploy/aiaiaiai-edge-dev-1/issue-hubot-credential.rb
}
cleanup() {
  local status=$?
  # A credential issued by this run that was not proved is revoked again, so none is left behind.
  if [[ -n "$abandon_id" ]]; then hub_credential abandon "$abandon_id" >/dev/null 2>&1 || echo "::warning::could not revoke the unproved issue $abandon_id" >&2; fi
  for file in "${secret_files[@]}"; do rm -f "$file"; done
  return "$status"
}
trap cleanup EXIT

remote 'test "$(hostname)" = edge-dev-1 && test "$(id -un)" = deploy'
remote "docker network inspect $NETWORK >/dev/null"
remote "test \"\$(docker inspect -f '{{.State.Running}}' $INGRESS)\" = true"

# Registry credential for the pull on the server: infra's short-lived token, the same as Deploy workload.
printf '%s' "$GH_TOKEN" | remote "docker login ghcr.io -u '$GHCR_USER' --password-stdin" >/dev/null

# Resolve one workload's reviewed contract values (Deploy workload's resolver) and deploy it.
deploy_workload() {
  local workload="$1" image="$2" resolved key value
  declare -A r=()
  resolved="$(env -u GITHUB_OUTPUT ruby scripts/resolve-workload-target.rb "$workload")"
  while IFS= read -r line; do
    key="${line%%=*}"
    value="${line#*=}"
    r["$key"]="$value"
  done <<<"$resolved"
  [[ "${r[runtime]}" == container ]] || { echo "::error::$workload is not a container workload" >&2; exit 1; }
  [[ -z "${r[contract_image]}" ]] || image="${r[contract_image]}"

  local env_file="$RUNNER_TEMP/workload-$workload.env"
  secret_files+=("$env_file")
  {
    printf 'WORKLOAD=%s\n' "$workload"
    printf 'IMAGE_REF=%s\n' "$image"
    printf 'EDGE_NETWORK=%s\n' "$NETWORK"
    printf 'WORKLOAD_ALIAS=%s\n' "${r[alias]}"
    printf 'WORKLOAD_PORT=%s\n' "${r[port]}"
    printf 'WORKLOAD_HEALTH=%s\n' "${r[health]}"
    printf 'WORKLOAD_HEALTH_KIND=%s\n' "${r[health_kind]}"
    printf 'WORKLOAD_COMMAND=%s\n' "${r[command]}"
    printf 'WORKLOAD_ENVIRONMENT=%s\n' "${r[environment]}"
    printf 'WORKLOAD_LABELS=%s\n' "${r[labels]}"
    printf 'WORKLOAD_VOLUMES=%s\n' "${r[volumes]}"
  } >"$env_file"

  if [[ -n "${r[secrets]}" ]]; then
    local cred_file="$RUNNER_TEMP/credentials-$workload.env" secret_env
    secret_files+=("$cred_file")
    open_item secrets | ruby scripts/export-credentials-env.rb "$workload" >"$cred_file"
    secret_env="$(WORKLOAD="$workload" WORKLOAD_SECRETS="${r[secrets]}" WORKLOAD_SECRET_SOURCE_FILE="$cred_file" \
      WORKLOAD_SECRETS_FROM='' WORKLOAD_PRODUCER_ENVIRONMENT='' ruby scripts/workload-secret-env.rb)"
    printf 'WORKLOAD_SECRET_ENV=%s\n' "$secret_env" >>"$env_file"
  fi

  local dir=".local/share/aiaiaiai-infra/workloads/$workload"
  remote "mkdir -p '$dir' && chmod 700 '$dir'"
  tar -C deploy/workload -czf - deploy.sh | remote "tar -xzf - -C '$dir'"
  upload "$env_file" "$dir/.env"
  remote "chmod 600 '$dir/.env' && chmod 700 '$dir/deploy.sh'"
  remote "cd '$dir' && DEPLOY_MODE=validate bash ./deploy.sh"
  remote "cd '$dir' && DEPLOY_MODE=activate bash ./deploy.sh"
  echo "deployed $workload from $image on $NETWORK"
}

# Reachable from the ingress container, which is how the public route will reach it.
check_through_ingress() {
  local alias_name="$1" port="$2" path="$3"
  for _ in $(seq 1 30); do
    if remote "docker exec $INGRESS wget -q -T 5 -O /dev/null http://$alias_name:$port$path" 2>/dev/null; then
      echo "ok  $alias_name answers $path through the ingress container"
      return 0
    fi
    sleep 2
  done
  echo "::error::$alias_name does not answer $path from the ingress container" >&2
  return 1
}

# The image is pinned and its provenance proved before it is run. Every failure here returns non-zero
# explicitly, and callers resolve the image in a checked assignment BEFORE anything is changed.
pinned_verified_image() {
  local image="$1" repository="$2" digest manifest
  manifest="$(docker buildx imagetools inspect "$image" --format '{{json .Manifest}}')" || return 1
  digest="$(printf '%s' "$manifest" | ruby -rjson -e 'puts JSON.parse(STDIN.read).fetch("digest")')" || return 1
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "::error::cannot resolve the digest of $image" >&2; return 1; }
  local name="${image%:*}"
  gh attestation verify "oci://$name@$digest" --repo "$repository" \
    --signer-workflow "$repository/.github/workflows/publish.yml" >/dev/null || {
    echo "::error::the provenance of $name@$digest could not be verified" >&2
    return 1
  }
  echo "$name@$digest"
}

if [[ "$stage" == data ]]; then
  hub_ref="$(pinned_verified_image "$HUB_IMAGE" aiaiaiai-org/prism-hub)"
  deploy_workload prism-postgres "ignored-contract-pins-it"

  for _ in $(seq 1 30); do
    remote 'docker exec prism-postgres pg_isready -U prism_hub -d prism_hub' >/dev/null 2>&1 && break
    sleep 2
  done
  remote 'docker exec prism-postgres pg_isready -U prism_hub -d prism_hub'

  tables="$(remote 'docker exec prism-postgres psql -U prism_hub -d prism_hub -Atc "select count(*) from pg_stat_user_tables"')"
  if [[ "$tables" == 0 ]]; then
    open_item db-prism_hub | remote 'docker exec -i prism-postgres pg_restore --username=prism_hub --dbname=prism_hub --no-owner --no-acl --exit-on-error'
    tables="$(remote 'docker exec prism-postgres psql -U prism_hub -d prism_hub -Atc "select count(*) from pg_stat_user_tables"')"
    [[ "$tables" =~ ^[0-9]+$ ]] && ((tables > 0)) || { echo '::error::the restored database holds no tables' >&2; exit 1; }
    echo "restored prism_hub: $tables tables"
  else
    echo "prism_hub already holds $tables tables; not restoring it again"
  fi

  deploy_workload prism-hub "$hub_ref"
  check_through_ingress prism-hub 1927 /healthz
elif [[ "$stage" == hubot-credential ]]; then
  # Nothing is issued or changed until the image is verified and the hub is up.
  hubot_ref="$(pinned_verified_image "$HUBOT_IMAGE" aiaiaiai-org/prism-hubot)"
  remote "test \"\$(docker inspect -f '{{.State.Running}}' prism-hub)\" = true"

  issued="$RUNNER_TEMP/hubot-issued.out"
  token_file="$RUNNER_TEMP/hubot-hub-token"
  secret_files+=("$issued" "$token_file")
  # The script runs inside the hub. Issuing does NOT revoke: the credential the running prism-hubot uses
  # stays valid until the new one has been proved.
  hub_credential issue >"$issued"
  [[ "$(grep -c '^ISSUED_TOKEN=prism_client_v1_' "$issued")" == 1 && "$(grep -c '^ISSUED_ID=' "$issued")" == 1 ]] ||
    { echo '::error::the hub did not return exactly one credential' >&2; exit 1; }
  new_id="$(sed -n 's/^ISSUED_ID=//p' "$issued")"
  [[ "$new_id" =~ ^[0-9a-f-]{36}$ ]] || { echo '::error::the issued credential id is malformed' >&2; exit 1; }
  abandon_id="$new_id" # revoked again by the exit trap unless the proof below succeeds
  sed -n 's/^ISSUED_TOKEN=//p' "$issued" >"$token_file"
  echo "::add-mask::$(cat "$token_file")"

  dir=.local/share/aiaiaiai-infra/workloads/prism-hubot
  remote "cd '$dir' && test -s .env"
  tar -C deploy/workload -czf - deploy.sh | remote "tar -xzf - -C '$dir'"
  # From this point an interrupted SSH call may have installed the candidate.
  # Keep it valid for retries. Earlier credentials remain valid until proof.
  abandon_id=""
  remote "cd '$dir' && umask 077 && cat > .hub-token.next && mv -f .hub-token.next .hub-token" <"$token_file"
  remote "cd '$dir' && sed -i 's|^IMAGE_REF=.*|IMAGE_REF=$hubot_ref|' .env && grep -Fxq 'IMAGE_REF=$hubot_ref' .env"
  remote "cd '$dir' && DEPLOY_MODE=validate bash ./deploy.sh"
  remote "cd '$dir' && DEPLOY_MODE=activate bash ./deploy.sh"
  check_through_ingress prism-hubot 1927 /healthz

  # Proof that matters: the token now inside the container is accepted by the hub (200, not 401).
  status="$(remote 'docker exec -i prism-hubot ruby -' <<'RUBY'
require "net/http"
uri = URI("#{ENV.fetch("PRISM_HUB_BASE_URL")}/api/v1/channels")
request = Net::HTTP::Get.new(uri)
request["authorization"] = "Bearer #{ENV.fetch("PRISM_HUB_API_TOKEN")}"
response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: 10, read_timeout: 15) { |http| http.request(request) }
print response.code
RUBY
)"
  [[ "$status" == 200 ]] || { echo "::error::the hub answered $status to prism-hubot's credential, not 200" >&2; exit 1; }
  echo "ok  the hub accepts prism-hubot's credential (200 on /api/v1/channels)"

  # Only now is the superseded credential revoked, and the new one is no longer to be abandoned.
  abandon_id=""
  hub_credential keep "$new_id" >/dev/null
  echo "ok  earlier credentials of prism-hubot revoked"
else
  hubot_ref="$(pinned_verified_image "$HUBOT_IMAGE" aiaiaiai-org/prism-hubot)"
  volume=prism-hubot-state
  entries="$(remote "docker run --rm --network none -v $volume:/v:ro caddy:2-alpine sh -c 'ls -A /v | wc -l'")"
  if [[ "$entries" == 0 ]]; then
    open_item "volume-$volume" | remote "docker run --rm -i --network none -v $volume:/v caddy:2-alpine tar -C /v -xf -"
    echo "restored $volume"
  else
    echo "$volume already holds $entries entries; not restoring it again"
  fi

  deploy_workload prism-hubot "$hubot_ref"
  check_through_ingress prism-hubot 1927 /healthz
  remote "cd .local/share/aiaiaiai-infra/workloads/prism-hubot && test -s .hub-token" || echo "::notice::run hubot-credential to provision Hub access"
fi
