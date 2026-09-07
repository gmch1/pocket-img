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
bundle_work=''
cleanup() {
  docker compose down --volumes --remove-orphans >/dev/null 2>&1
  if [[ -n $bundle_work ]]; then rm -rf -- "$bundle_work"; fi
}
trap cleanup EXIT

if [[ ${PIH_TEST_RELEASE_BUNDLE:-0} == 1 ]]; then
  bundle_work=$(mktemp -d /tmp/pocketimg-bundle-smoke.XXXXXX)
  # Local smoke image overrides the placeholder digest; no registry writes.
  bash scripts/package-docker-installer.sh 0.0.0 "sha256:$(printf '%064d' 0)" "$bundle_work"
  mkdir "$bundle_work/source"
  tar -xzf "$bundle_work/PocketIMG-0.0.0-docker-install.tar.gz" -C "$bundle_work/source"
  export COMPOSE_FILE="$bundle_work/installed/compose.yaml"
fi
install_test() {
  if [[ -n $bundle_work ]]; then
    python3 "$bundle_work/source/scripts/deploy-docker.py" "$bundle_work/source" "$bundle_work/installed" "${2:-}"
  else
    bash scripts/install-docker.sh "$@"
  fi
}

first=$(install_test --port "$tested_port")
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
python3 scripts/test-docker-api.py "$container" "http://127.0.0.1:$tested_port"
unset PIH_PORT
second=$(install_test)
[[ $(printf '%s\n' "$second" | sed -n 's/^登录 Token：//p') == "$token" ]]
[[ $second == *":$tested_port"* ]]
login
export PIH_PORT=$tested_port
docker compose up --detach --no-build --force-recreate --wait --wait-timeout 90 pocketimg >/dev/null
login
logs=$(docker compose logs --no-color pocketimg)
[[ $logs != *"$token"* ]]
printf '%s\n' 'PASS: automatic installation, custom port retention, login, permissions, reinstall, container recreation and log redaction'
