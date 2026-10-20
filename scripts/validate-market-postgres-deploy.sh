#!/usr/bin/env bash
# © 2026 aiaiaiai · aiaiaiai.org
# Isolated deploy validation: NEVER use production Docker resources.
set -Eeuo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
contract="$root/contracts/services/market-postgres-production.yaml"

# Derive the actual image, network-facing settings, volume target and credential
# environment variable from the reviewed contract.
configuration="$(ruby -ryaml -e '
  spec = YAML.safe_load(File.read(ARGV.fetch(0)), aliases: false).fetch("spec")
  runtime = spec.fetch("runtime")
  environment = runtime.fetch("environment").map { |entry| entry.split("=", 2) }.to_h
  mount = runtime.fetch("volumes").fetch(0).split(":", 2).fetch(1).split(":", 2).first
  puts runtime.fetch("image")
  puts spec.fetch("aliases").fetch(0)
  puts spec.fetch("port")
  puts environment.fetch("POSTGRES_USER")
  puts environment.fetch("POSTGRES_DB")
  puts environment.fetch("PGPORT")
  puts mount
  puts runtime.fetch("secrets").fetch(0).split("=", 2).fetch(0)
' "$contract")"
mapfile -t settings <<< "$configuration"
[[ "${#settings[@]}" -eq 8 ]] || { echo "Unexpected market PostgreSQL contract"; exit 1; }

image="${settings[0]}"
alias_name="${settings[1]}"
port="${settings[2]}"
db_user="${settings[3]}"
db_name="${settings[4]}"
server_port="${settings[5]}"
mount_path="${settings[6]}"
secret_key="${settings[7]}"

[[ "$port" == "$server_port" ]] || { echo "Postgres listener/contract port mismatch"; exit 1; }
[[ "$secret_key" == "POSTGRES_PASSWORD" ]] || { echo "Unexpected Postgres credential mapping"; exit 1; }

# Unique scratch resources with no overlap with edge-prod-1 networks or volumes.
suffix="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-$RANDOM"
network="ci-market-pg-$suffix"
volume="ci-market-pg-data-$suffix"
container="ci-market-pg-$suffix"
password="ci-only-$suffix-no-real-credentials"

cleanup() {
  docker rm --force "$container" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "Pulling the exact contract-pinned PostgreSQL image"
docker pull "$image"
docker network create --driver bridge --internal "$network" >/dev/null
docker volume create "$volume" >/dev/null

start_container() {
  docker run --detach \
    --name "$container" \
    --network "$network" \
    --network-alias "$alias_name" \
    --volume "$volume:$mount_path" \
    --env "PGPORT=$server_port" \
    --env "POSTGRES_USER=$db_user" \
    --env "POSTGRES_DB=$db_name" \
    --env "$secret_key=$password" \
    "$image" >/dev/null
  [[ -z "$(docker port "$container")" ]] || {
    echo "Validation fixture unexpectedly published a host port" >&2
    exit 1
  }
}

wait_ready() {
  local attempt
  for attempt in $(seq 1 45); do
    if docker exec "$container" pg_isready \
      -h 127.0.0.1 -p "$port" -U "$db_user" -d "$db_name" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "PostgreSQL never became ready" >&2
  docker logs --tail 60 "$container" >&2 || true
  return 1
}

client() {
  # Separate disposable client on the isolated Docker network: no host port.
  docker run --rm --network "$network" \
    --env "PGPASSWORD=$password" \
    --entrypoint psql "$image" \
    --no-password --no-psqlrc -v ON_ERROR_STOP=1 --tuples-only --no-align \
    -h "$alias_name" -p "$port" -U "$db_user" -d "$db_name" -c "$1"
}

start_container
wait_ready

docker run --rm --network "$network" \
  --entrypoint pg_isready "$image" \
  -h "$alias_name" -p "$port" -U "$db_user" -d "$db_name" >/dev/null

identity="$(client "SELECT current_user || ':' || current_database() || ':' || inet_server_port()")"
[[ "$identity" == "$db_user:$db_name:$port" ]] || {
  echo "Authenticated SQL query did not match contracted identity and port" >&2
  exit 1
}

# pg_isready alone does not validate credentials; a wrong password must fail.
if docker run --rm --network "$network" \
  --env "PGPASSWORD=ci-intentionally-invalid" \
  --entrypoint psql "$image" \
  --no-password --no-psqlrc -v ON_ERROR_STOP=1 \
  -h "$alias_name" -p "$port" -U "$db_user" -d "$db_name" \
  -c "SELECT 1" >/dev/null 2>&1; then
  echo "PostgreSQL accepted an incorrect password" >&2
  exit 1
fi

client "CREATE TABLE ci_persistence (id integer PRIMARY KEY, value text NOT NULL)" >/dev/null
client "INSERT INTO ci_persistence VALUES (1, 'survived')" >/dev/null

# Re-create only the ephemeral container; preserve the same scratch volume.
docker rm --force "$container" >/dev/null
start_container
wait_ready

persisted="$(client "SELECT value FROM ci_persistence WHERE id = 1")"
[[ "$persisted" == "survived" ]] || {
  echo "Database data did not survive container re-creation" >&2
  exit 1
}

echo "Validated pinned image, isolated TCP readiness, authenticated SQL, rejection of bad credentials and durable volume"
