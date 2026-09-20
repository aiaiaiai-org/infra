#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
set -Eeuo pipefail

mode="${DEPLOY_MODE:-validate}"
deploy_path="${DEPLOY_PATH:-}"
service="${SERVICE_NAME:-}"
post_activate_command="${POST_ACTIVATE_COMMAND:-}"
release_id="${RELEASE_ID:-}"
keep_releases="${KEEP_RELEASES:-5}"
archive="${RELEASE_ARCHIVE:-}"

case "$mode" in
  validate|activate) ;;
  *)
    echo "DEPLOY_MODE must be validate or activate" >&2
    exit 1
    ;;
esac

[[ "$deploy_path" == /* ]] || { echo "DEPLOY_PATH must be absolute" >&2; exit 1; }
[[ "$service" =~ ^[A-Za-z0-9@_.:-]+\.service$ ]] || { echo "SERVICE_NAME is invalid" >&2; exit 1; }
test -n "$post_activate_command" || { echo "POST_ACTIVATE_COMMAND is required" >&2; exit 1; }
[[ "$release_id" =~ ^[0-9a-f]{40}$ ]] || { echo "RELEASE_ID must be a 40-character commit SHA" >&2; exit 1; }
[[ "$keep_releases" =~ ^[0-9]+$ ]] && (( keep_releases >= 1 && keep_releases <= 100 )) || {
  echo "KEEP_RELEASES must be between 1 and 100" >&2
  exit 1
}

releases_dir="$deploy_path/releases"
shared_dir="$deploy_path/shared"
bundle_dir="$shared_dir/bundle"
state_dir="$shared_dir/var/interaction-state"
delivery_state_dir="$shared_dir/var/delivery-idempotency"
staging_dir="$deploy_path/.deploy"
release_dir="$releases_dir/$release_id"
current_link="$deploy_path/current"
archive_path="$staging_dir/$release_id.tar.gz"

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required command not found: $command_name" >&2
    return 1
  fi
}

require_runtime() {
  require_command ruby
  require_command bundle
  require_command git
  require_command systemctl

  if [[ ! -f "$shared_dir/.env" ]]; then
    echo "shared environment file missing: $shared_dir/.env" >&2
    return 1
  fi

  if ! systemctl cat "$service" >/dev/null 2>&1; then
    echo "systemd service not found or unreadable: $service" >&2
    return 1
  fi
}

prepare_layout() {
  install -d -m 0755 "$releases_dir" "$bundle_dir" "$state_dir" "$delivery_state_dir" "$staging_dir"
  chmod 700 "$state_dir" "$delivery_state_dir"
}

install_release() {
  rm -rf "$release_dir"
  install -d -m 0755 "$release_dir"
  tar -xzf "$archive_path" -C "$release_dir"

  ln -sfn "$shared_dir/.env" "$release_dir/.env"
  install -d -m 0755 "$release_dir/var"
  ln -sfn "$state_dir" "$release_dir/var/interaction-state"
  ln -sfn "$delivery_state_dir" "$release_dir/var/delivery-idempotency"

  cd "$release_dir"
  bundle config set --local deployment true
  bundle config set --local path "$bundle_dir"
  bundle install --jobs 4 --retry 3
}

validate_release() {
  require_runtime
  prepare_layout
  test -f "$archive_path" || { echo "release archive is missing: $archive_path" >&2; exit 1; }
  rm -rf "$release_dir"
  install -d -m 0755 "$release_dir"
  tar -xzf "$archive_path" -C "$release_dir"
  ln -sfn "$shared_dir/.env" "$release_dir/.env"
  install -d -m 0755 "$release_dir/var"
  ln -sfn "$state_dir" "$release_dir/var/interaction-state"
  ln -sfn "$delivery_state_dir" "$release_dir/var/delivery-idempotency"
  cd "$release_dir"
  bundle config set --local deployment true
  bundle config set --local path "$bundle_dir"
  bundle install --jobs 4 --retry 3
  bundle exec rake env:check
  rm -rf "$release_dir"
}

activate_release() {
  require_runtime
  prepare_layout
  test -f "$archive_path" || { echo "release archive is missing: $archive_path" >&2; exit 1; }

  previous_target=""
  if [[ -L "$current_link" ]]; then
    previous_target="$(readlink "$current_link")"
  fi

  install_release
  ln -sfn "$release_dir" "$deploy_path/current.tmp"
  mv -Tf "$deploy_path/current.tmp" "$current_link"

  if ! sudo -n systemctl restart "$service" || ! sudo -n systemctl is-active --quiet "$service"; then
    echo "service $service failed after activation" >&2
    journalctl --no-pager -u "$service" -n 100 >&2 || true

    if [[ -n "$previous_target" ]]; then
      ln -sfn "$previous_target" "$deploy_path/current.tmp"
      mv -Tf "$deploy_path/current.tmp" "$current_link"
      sudo -n systemctl restart "$service" || true
    fi
    exit 1
  fi

  if ! (cd "$release_dir" && bash -lc "$post_activate_command"); then
    echo "post-activation command failed: $post_activate_command" >&2
    journalctl --no-pager -u "$service" -n 100 >&2 || true
    if [[ -n "$previous_target" ]]; then
      ln -sfn "$previous_target" "$deploy_path/current.tmp"
      mv -Tf "$deploy_path/current.tmp" "$current_link"
      sudo -n systemctl restart "$service" || true
    fi
    exit 1
  fi

  mapfile -t old_releases < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort -r)
  for old_release in "${old_releases[@]:$keep_releases}"; do
    rm -rf "$releases_dir/$old_release"
  done

  rm -f "$archive_path"
  echo "workload $release_id is active via $service"
}

case "$mode" in
  validate) validate_release ;;
  activate) activate_release ;;
esac
