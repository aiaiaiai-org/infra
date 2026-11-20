#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Auto-reconcile ONLY signed site images from GitHub's authoritative master/tag
# refs. This is independent of product credentials and never changes DNS/ingress.
set -Eeuo pipefail

channel="${1:-all}"
case "$channel" in all|beta|release) ;; *) echo 'Expected all|beta|release' >&2; exit 2 ;; esac
test "$GITHUB_REF" = refs/heads/master
: "${GH_TOKEN:?GH_TOKEN required}"
: "${SSH_HOST:?SSH_HOST required}"
: "${SSH_USER:?SSH_USER required}"
: "${SSH_HOST_ED25519_PUBKEY:?SSH_HOST_ED25519_PUBKEY required}"
: "${SSH_PRIVATE_KEY:?SSH_PRIVATE_KEY required}"
: "${SSH_PORT:=22}"
test "$SSH_HOST" = 158.220.74.54
test "$SSH_USER" = deploy
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 ))
[[ "$SSH_HOST_ED25519_PUBKEY" =~ ^ssh-ed25519[[:space:]][A-Za-z0-9+/=]+$ ]]

source_repo=aiaiaiai-org/aiaiaiai.org
image=ghcr.io/aiaiaiai-org/aiaiaiai.org
ssh_dir="$(mktemp -d)"
cleanup() { rm -rf "$ssh_dir"; }
trap cleanup EXIT
chmod 700 "$ssh_dir"
printf '%s\n' "$SSH_PRIVATE_KEY" > "$ssh_dir/id_ed25519"
chmod 600 "$ssh_dir/id_ed25519"
ssh-keygen -y -P '' -f "$ssh_dir/id_ed25519" >/dev/null
if [[ "$SSH_PORT" == 22 ]]; then host_label="$SSH_HOST"; else host_label="[$SSH_HOST]:$SSH_PORT"; fi
printf '%s %s\n' "$host_label" "$SSH_HOST_ED25519_PUBKEY" > "$ssh_dir/known_hosts"
chmod 600 "$ssh_dir/known_hosts"
ssh_opts=(-T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$ssh_dir/known_hosts" -i "$ssh_dir/id_ed25519"
  -p "$SSH_PORT")

# This deployment intentionally requires the already established private
# nilx-candidate network. It must not create another public ingress listener.
ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
  "test \"\$(hostname)\" = edge-dev-1 && test \"\$(id -un)\" = deploy && docker network inspect nilx-candidate >/dev/null"

remote_dir=.local/share/aiaiaiai-infra/aiaiaiai-site
ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" "install -d -m 0700 '$remote_dir'"
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$ssh_dir/known_hosts" -i "$ssh_dir/id_ed25519" \
  -P "$SSH_PORT" deploy/aiaiaiai-site-snapshots/Caddyfile \
  "$SSH_USER@$SSH_HOST:$remote_dir/archive.Caddyfile"
scp -q -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$ssh_dir/known_hosts" -i "$ssh_dir/id_ed25519" \
  -P "$SSH_PORT" deploy/aiaiaiai-site-snapshots/stage.sh \
  "$SSH_USER@$SSH_HOST:$remote_dir/stage.sh"
ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
  "chmod 600 '$remote_dir/archive.Caddyfile'; chmod 700 '$remote_dir/stage.sh'"

printf '%s' "$GH_TOKEN" | docker login ghcr.io -u "$GITHUB_ACTOR" --password-stdin >/dev/null

digest_for() {
  local version="$1" manifest digest err
  # A not-yet-published image is normal while upstream Full CI/publisher runs.
  # Authentication or network failures must be observable, not treated as 404.
  err="$(mktemp)"
  if ! manifest="$(docker buildx imagetools inspect "$image:$version" --format '{{json .Manifest}}' 2>"$err")"; then
    if grep -Eqi 'manifest unknown|not found|404' "$err"; then
      echo "::notice::Artifact $version is not yet published."
      rm -f "$err"
      return 1
    fi
    cat "$err" >&2
    rm -f "$err"
    echo "::error::Registry lookup failed for $version" >&2
    return 2
  fi
  rm -f "$err"
  digest="$(jq -er '.digest | select(test("^sha256:[0-9a-f]{64}$"))' <<<"$manifest")"
  printf '%s\n' "$digest"
}

stage_remote() {
  local kind="$1" version="$2" ref="$3" digest="$4"
  local target="$image@$digest"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]]

  # The image digest may be publicly readable, but we use an ephemeral registry
  # config and never leave GHCR credentials on the target VPS.
  printf '%s' "$GH_TOKEN" | ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
    "set -eu; umask 077; dir=\$(mktemp -d); trap 'rm -rf \"\$dir\"' EXIT; export DOCKER_CONFIG=\"\$dir\"; docker login ghcr.io -u '$GITHUB_ACTOR' --password-stdin >/dev/null; docker pull '$target' >/dev/null"
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
    "bash '$remote_dir/stage.sh' stage '$kind' '$version' '$target'"
}

activate_remote() {
  local kind="$1" version="$2" digest="$3"
  local target="$image@$digest"
  ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
    "bash '$remote_dir/stage.sh' activate '$kind' '$version' '$target'"
}

verify_artifact() {
  local kind="$1" version="$2" sha="$3" digest="$4" signer ref
  if [[ "$kind" == beta ]]; then
    signer="$source_repo/.github/workflows/ci.yml"
    ref=refs/heads/master
  else
    signer="$source_repo/.github/workflows/ci.yml"
    ref="refs/tags/$version"
  fi
  gh attestation verify "oci://$image@$digest" \
    --repo "$source_repo" \
    --signer-workflow "$signer" \
    --source-ref "$ref" \
    --source-digest "$sha" \
    --deny-self-hosted-runners >/dev/null
}

current_master() {
  local sha
  sha="$(gh api "repos/$source_repo/branches/master" --jq '.commit.sha')"
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
  printf '%s\n' "$sha"
}

if [[ "$channel" == all || "$channel" == beta ]]; then
  master="$(current_master)"

  # Capture already archived SHAs in one SSH request; do not repeatedly pull
  # old immutable images on every scheduled reconciliation.
  manifest_list="$(ssh "${ssh_opts[@]}" "$SSH_USER@$SSH_HOST" \
    'dir="$HOME/.local/share/aiaiaiai-infra/aiaiaiai-site/manifests/beta"; test -d "$dir" || exit 0; for f in "$dir"/*; do test -f "$f" || continue; printf "%s %s\n" "${f##*/}" "$(cat "$f")"; done')"
  declare -A archived_beta=()
  while read -r archived_sha archived_ref; do
    if [[ "$archived_sha" =~ ^[0-9a-f]{40}$ && "$archived_ref" =~ ^ghcr\.io/aiaiaiai-org/aiaiaiai\.org@sha256:[0-9a-f]{64}$ ]]; then
      archived_beta[$archived_sha]="${archived_ref##*@}"
    fi
  done <<<"$manifest_list"

  # The most recent master history covers multiple PR merges while earlier CI
  # runs were still publishing; all signed snapshots are retained, not just
  # whichever commit happens to be HEAD at the next scheduler tick.
  raw_commits="$(gh api "repos/$source_repo/commits?sha=master&per_page=100" --jq '.[].sha')"
  mapfile -t commits < <(printf '%s\n' "$raw_commits" | grep -E '^[0-9a-f]{40}$' | awk '!seen[$0]++')
  (( ${#commits[@]} > 0 )) && test "${commits[0]}" = "$master"
  beta_digest=""
  for ((i=${#commits[@]}-1; i>=0; i--)); do
    version="${commits[i]}"
    if [[ -n "${archived_beta[$version]:-}" ]]; then
      # Re-verify the source attestation when considering an already archived
      # image for the mutable latest alias; historical versions stay immutable.
      if [[ "$version" == "$master" ]]; then
        beta_digest="${archived_beta[$version]}"
        verify_artifact beta "$version" "$version" "$beta_digest"
      fi
      continue
    fi
    if published_digest="$(digest_for "$version")"; then
      verify_artifact beta "$version" "$version" "$published_digest"
      stage_remote beta "$version" "$version" "$published_digest"
      if [[ "$version" == "$master" ]]; then
        beta_digest="$published_digest"
      fi
    else
      status=$?
      if [[ "$status" != 1 ]]; then exit "$status"; fi
    fi
  done
  if [[ -n "$beta_digest" ]]; then
    # Do not roll back a newer merge if master advances during this run.
    if [[ "$(current_master)" == "$master" ]]; then
      activate_remote beta "$master" "$beta_digest"
      echo "Verified beta/current -> $master"
    else
      echo "::notice::Master moved during staging; skip stale beta alias"
    fi
  fi
fi

if [[ "$channel" == all || "$channel" == release ]]; then
  # Enumerate ALL SemVer tags (not only latest), so every published release
  # retains its stable /vX.Y.Z URL even after newer releases are published.
  raw_tags="$(gh api --paginate "repos/$source_repo/tags?per_page=100" --jq '.[].name')"
  mapfile -t tags < <(printf '%s\n' "$raw_tags" | grep -E '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' | sort -Vu)
  latest_tag=""
  latest_digest=""
  latest_sha=""
  for tag in "${tags[@]}"; do
    sha="$(gh api "repos/$source_repo/commits/$tag" --jq '.sha')"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]]
    if digest="$(digest_for "$tag")"; then
      verify_artifact release "$tag" "$sha" "$digest"
      stage_remote release "$tag" "$sha" "$digest"
      latest_tag="$tag"
      latest_digest="$digest"
      latest_sha="$sha"
    else
      status=$?
      if [[ "$status" != 1 ]]; then exit "$status"; fi
    fi
  done
  if [[ -n "$latest_tag" ]]; then
    # Re-validate the current tag target before moving the release alias.
    current="$(gh api "repos/$source_repo/commits/$latest_tag" --jq '.sha')"
    if [[ "$current" == "$latest_sha" ]]; then
      activate_remote release "$latest_tag" "$latest_digest"
      echo "Verified release/current -> $latest_tag ($latest_sha)"
    else
      echo "::error::Release tag changed during reconciliation; refusing activation" >&2
      exit 1
    fi
  fi
fi

echo 'aiaiaiai.org snapshot reconciliation complete; DNS/ingress unchanged.'
