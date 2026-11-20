#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Stage immutable, digest-addressed site content on edge-dev-1; never publish ports.
set -Eeuo pipefail

mode=$1
channel=$2
version=$3
image_ref=$4
case "$mode" in stage|activate) ;; *) echo "Expected stage or activate" >&2; exit 2 ;; esac
case "$channel" in
  beta) [[ "$version" =~ ^[0-9a-f]{40}$ ]] ;;
  release) [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ;;
  *) echo "Invalid channel" >&2; exit 2 ;;
esac
[[ "$image_ref" =~ ^ghcr\.io/aiaiaiai-org/aiaiaiai\.org@sha256:[0-9a-f]{64}$ ]]
test "$(hostname)" = edge-dev-1
test "$(id -un)" = deploy
docker network inspect nilx-candidate >/dev/null
docker image inspect "$image_ref" >/dev/null

base="$HOME/.local/share/aiaiaiai-infra/aiaiaiai-site"
store="$base/versions"
manifest_dir="$base/manifests/$channel"
snapshot="$store/$channel/$version"
marker="$manifest_dir/$version"
config="$base/archive.Caddyfile"
install -d -m 0755 "$store/$channel" "$manifest_dir"
test -s "$config"

if [[ "$mode" == stage ]]; then
  if [[ -e "$snapshot" || -L "$snapshot" || -e "$marker" ]]; then
    test -d "$snapshot"
    test -f "$marker"
    test "$(cat "$marker")" = "$image_ref" || {
      echo "Version already exists with another digest: immutable archive" >&2; exit 1;
    }
    echo "Verified pre-existing immutable $channel/$version"
  else
    temp="$(mktemp -d "$store/$channel/.stage.XXXXXXXX")"
    cid=""
    cleanup() {
      test -z "$cid" || docker rm "$cid" >/dev/null 2>&1 || true
      test ! -d "$temp" || rm -rf "$temp"
    }
    trap cleanup EXIT
    cid="$(docker create "$image_ref")"
    docker cp "$cid:/srv/site/." "$temp/"
    docker rm "$cid" >/dev/null
    cid=""
    test -s "$temp/index.html"
    if [[ "$channel" == beta ]]; then
      test -s "$temp/beta/index.html"
      cp "$temp/beta/index.html" "$temp/index.html"
      grep -Fq 'id="awakening"' "$temp/index.html"
    fi
    # Prevent mutable-root assets in a snapshot: its generated bundles must
    # refer to /<version>/_astro, not to the current root's /_astro.
    if grep -REn '(src|href)="/_astro/' "$temp" --include='*.html'; then
      echo "Unversioned asset URL in snapshot" >&2; exit 1
    fi
    printf '%s\n' "$image_ref" > "$marker.tmp.$$"
    mv -T "$temp" "$snapshot"
    mv -T "$marker.tmp.$$" "$marker"
    trap - EXIT
    echo "Staged immutable $channel/$version"
  fi
fi

# Create or reuse the one private Caddy container serving the read-only archive.
if ! docker container inspect aiaiaiai-site-archive >/dev/null 2>&1; then
  docker run --detach --name aiaiaiai-site-archive \
    --network nilx-candidate --restart unless-stopped \
    --security-opt no-new-privileges:true \
    --volume "$store:/srv/versions:ro" \
    --volume "$config:/etc/caddy/Caddyfile:ro" \
    caddy:2-alpine >/dev/null
else
  test "$(docker inspect -f '{{.State.Running}}' aiaiaiai-site-archive)" = true
fi
test -z "$(docker port aiaiaiai-site-archive)"
ready=false
for attempt in $(seq 1 15); do
  if docker exec aiaiaiai-site-archive wget -q -T 3 -O /dev/null http://127.0.0.1:1927/healthz; then
    ready=true
    break
  fi
  sleep 1
done
test "$ready" = true || { echo 'Private snapshot server did not become ready' >&2; exit 1; }
docker exec aiaiaiai-site-archive caddy validate --config /etc/caddy/Caddyfile >/dev/null
docker exec aiaiaiai-site-archive caddy reload --config /etc/caddy/Caddyfile >/dev/null

if [[ "$mode" == activate ]]; then
  test -d "$snapshot" && test "$(cat "$marker")" = "$image_ref"
  alias_path="$store/$channel/current"
  old=""
  if [[ -L "$alias_path" ]]; then old="$(readlink "$alias_path")"; fi
  if [[ "$old" == "$version" ]]; then
    echo "$channel/current already points at $version; no activation necessary"
    exit 0
  fi
  # Never let a delayed older release image silently downgrade the apex.
  if [[ "$channel" == release && -n "$old" ]]; then
    [[ "$old" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid existing release alias' >&2; exit 1; }
    if [[ "$(printf '%s\n%s\n' "$old" "$version" | sort -V | head -n 1)" != "$old" ]]; then
      echo "Automatic release downgrade refused: $old -> $version" >&2
      exit 1
    fi
  fi
  ln -s "$version" "$alias_path.new.$"
  mv -Tf "$alias_path.new.$$" "$alias_path"
  check=0
  if [[ "$channel" == beta ]]; then
    docker exec aiaiaiai-site-archive wget -q -T 10 -O /dev/null \
      --header "Host: beta.aiaiaiai.org" http://127.0.0.1:1927/ || check=1
  else
    docker exec aiaiaiai-site-archive wget -q -T 10 -O /dev/null \
      --header "Host: aiaiaiai.org" http://127.0.0.1:1927/ || check=1
  fi
  if [[ "$check" != 0 ]]; then
    if [[ -n "$old" ]]; then
      ln -s "$old" "$alias_path.rollback.$$"
      mv -Tf "$alias_path.rollback.$$" "$alias_path"
    else
      rm -f "$alias_path"
    fi
    echo "Snapshot alias failed health; previous alias restored" >&2
    exit 1
  fi
  echo "Activated $channel/current -> $version (private archive)"
fi
