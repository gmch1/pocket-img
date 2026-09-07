#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

# Uses only its own temporary Compose project and data volume.
export COMPOSE_PROJECT_NAME="pocketimg-token-smoke-$$"
export PIH_IMAGE=${PIH_TEST_IMAGE:-pocketimg:local}
export PIH_INSTALL_PULL=0
export PIH_PORT=${PIH_TEST_PORT:-18976}
tested_port=$PIH_PORT
export PIH_TOKEN='' PIH_TOKENS='' PIH_TOKENS_FILE='' PIH_ADMIN_SPACE_ID=''
export PIH_COOKIE_SECURE=false
unset PIH_INSTALL_QUIET
cleanup() { docker compose down --volumes --remove-orphans >/dev/null 2>&1; }
trap cleanup EXIT

first=$(bash scripts/install-docker.sh --port "$tested_port")
token=$(printf '%s\n' "$first" | sed -n 's/^登录 Token：//p')
[[ $token =~ ^[a-f0-9]{64}$ ]]
container=$(docker compose ps -q pocketimg)
[[ $(docker exec "$container" stat -c '%u:%g:%a' /data/tokens.json) == '10001:10001:600' ]]
[[ $(docker exec "$container" stat -c '%u:%g:%a' /data) == '10001:10001:700' ]]
[[ $(docker inspect --format '{{.HostConfig.ReadonlyRootfs}}' "$container") == true ]]
login() {
  # Keep the test credential out of process arguments and command output.
  printf 'header = "Authorization: Bearer %s"\n' "$token" |
    curl --config - --fail --silent --output /dev/null --request POST \
      "http://127.0.0.1:$tested_port/api/auth/session"
}
login
unset PIH_PORT
second=$(bash scripts/install-docker.sh)
[[ $(printf '%s\n' "$second" | sed -n 's/^登录 Token：//p') == "$token" ]]
[[ $second == *":$tested_port"* ]]
login
export PIH_PORT=$tested_port
docker compose up --detach --no-build --force-recreate --wait --wait-timeout 90 pocketimg >/dev/null
login
logs=$(docker compose logs --no-color pocketimg)
[[ $logs != *"$token"* ]]
printf '%s\n' 'PASS: automatic installation, custom port retention, login, permissions, reinstall, container recreation and log redaction'
