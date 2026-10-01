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

prepare_runtime_path() {
  local home="${HOME:-}"
  local candidate

  if [[ -z "$home" || ! -d "$home" ]]; then
    home="$(getent passwd "$(id -un)" | cut -d: -f6)"
  fi

  local -a runtime_paths=(
    "$home/.rbenv/shims"
    "$home/.rbenv/bin"
    "$home/.asdf/shims"
    "$home/.asdf/bin"
    "$home/.local/share/mise/shims"
    "$home/.local/bin"
  )

  for candidate in "${runtime_paths[@]}"; do
    if [[ -d "$candidate" ]]; then
      case ":$PATH:" in
        *":$candidate:"*) ;;
        *) PATH="$candidate:$PATH" ;;
      esac
    fi
  done

  export PATH
}


ensure_ruby_runtime() {
  local expected_version="$1"
  local ruby_prefix="/opt/ruby/$expected_version"
  local ruby_current="/opt/ruby/current"
  local ruby_bin="$ruby_prefix/bin/ruby"
  local archive="/opt/ruby/ruby-$expected_version.tar.gz"
  local source_dir="/opt/ruby/ruby-$expected_version"
  local url
  local checksum
  local bundler_version
  local actual_checksum

  if command -v ruby >/dev/null 2>&1 &&
     [[ "$(ruby -e 'print RUBY_VERSION')" == "$expected_version" ]] &&
     command -v bundle >/dev/null 2>&1; then
    return 0
  fi

  case "$expected_version" in
    4.0.6)
      url="https://cache.ruby-lang.org/pub/ruby/4.0/ruby-4.0.6.tar.gz"
      checksum="837d299e8f7ddf2d14347dd56dfd8fe5c3130abf5117bfaacb3b32b1a9be262a"
      ;;
    *)
      echo "Ruby $expected_version is not provisionable by the host runtime bootstrap" >&2
      return 1
      ;;
  esac

  command -v sudo >/dev/null 2>&1 || { echo "sudo is required to provision Ruby $expected_version" >&2; return 1; }
  sudo -n true || { echo "passwordless sudo is required to provision Ruby $expected_version" >&2; return 1; }

  if [[ ! -x "$ruby_bin" ]]; then
    sudo -n apt-get update
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y \
      build-essential autoconf bison libssl-dev libyaml-dev zlib1g-dev \
      libffi-dev libreadline-dev libgmp-dev curl ca-certificates

    sudo -n install -d -m 0755 /opt/ruby
    if [[ ! -f "$archive" ]]; then
      sudo -n curl -fL --retry 3 --retry-all-errors -o "$archive" "$url"
    fi

    actual_checksum="$(sudo -n sha256sum "$archive" | awk '{print $1}')"
    [[ "$actual_checksum" == "$checksum" ]] || {
      echo "Ruby source checksum mismatch for $expected_version" >&2
      return 1
    }

    sudo -n rm -rf "$source_dir"
    sudo -n tar -xzf "$archive" -C /opt/ruby
    sudo -n bash -c "cd '$source_dir' && ./configure --prefix='$ruby_prefix' --disable-install-doc && make -j\$(nproc) && make install"
  fi

  sudo -n ln -sfn "$ruby_prefix" "$ruby_current"
  PATH="$ruby_current/bin:$PATH"
  export PATH

  bundler_version="$(awk '/^BUNDLED WITH$/ { getline; gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }' Gemfile.lock 2>/dev/null || true)"
  if [[ -n "$bundler_version" ]] && ! "$ruby_bin" -S bundle _"$bundler_version"_ --version >/dev/null 2>&1; then
    sudo -n "$ruby_bin" -S gem install --no-document bundler -v "$bundler_version"
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "required command not found: $command_name" >&2
    return 1
  fi
}

require_runtime() {
  prepare_runtime_path
  if [[ -n "${expected_ruby_version:-}" ]]; then
    ensure_ruby_runtime "$expected_ruby_version"
    prepare_runtime_path
  fi
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
  expected_ruby_version="$(sed -n '1p' .ruby-version 2>/dev/null || true)"
  if [[ -n "$expected_ruby_version" ]]; then
    actual_ruby_version="$(ruby -e 'print RUBY_VERSION')"
    if [[ "$actual_ruby_version" != "$expected_ruby_version" ]]; then
      echo "Ruby version mismatch: release requires $expected_ruby_version, runtime provides $actual_ruby_version" >&2
      exit 1
    fi
  fi
  bundle config set --local deployment true
  bundle config set --local path "$bundle_dir"
  bundle install --jobs 4 --retry 3
}

validate_release() {
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
  expected_ruby_version="$(sed -n '1p' .ruby-version 2>/dev/null || true)"
  require_runtime
  if [[ -n "$expected_ruby_version" ]]; then
    actual_ruby_version="$(ruby -e 'print RUBY_VERSION')"
    if [[ "$actual_ruby_version" != "$expected_ruby_version" ]]; then
      echo "Ruby version mismatch: release requires $expected_ruby_version, runtime provides $actual_ruby_version" >&2
      exit 1
    fi
  fi
  bundle config set --local deployment true
  bundle config set --local path "$bundle_dir"
  bundle install --jobs 4 --retry 3
  bundle exec rake env:check
  rm -rf "$release_dir"
}

activate_release() {
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

  # Newest first by install time; release names are commit SHAs, not an order.
  mapfile -t old_releases < <(find "$releases_dir" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' | sort -rn | cut -f2)
  for old_release in "${old_releases[@]:$keep_releases}"; do
    [[ "$old_release" == "$release_dir" || "$old_release" == "$previous_target" ]] && continue
    rm -rf "$old_release"
  done

  rm -f "$archive_path"
  echo "workload $release_id is active via $service"
}

case "$mode" in
  validate) validate_release ;;
  activate) activate_release ;;
esac
