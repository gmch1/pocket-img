#!/usr/bin/env bash
set -euo pipefail

device="${ANDROID_SERIAL:-}"
adb_command=(adb)
if [[ -n "$device" ]]; then
  adb_command+=( -s "$device" )
fi

package_name="com.gmch.pocketimg"
legacy_dir="/data/local/tmp/phone-image-host-dev"
app_dir="/data/user/0/$package_name"
files_dir="$app_dir/files"
data_dir="$files_dir/service-data"
data_backup="$files_dir/service-data.before-root-migration"
token_file="$files_dir/runtime/tokens.json"
token_backup="$files_dir/runtime/tokens.json.before-root-migration"

run_root() {
  local encoded
  encoded="$(printf '%s' "$1" | base64 --wrap=0)"
  "${adb_command[@]}" shell "su -c 'printf %s $encoded | base64 -d | sh'"
}

preflight() {
  [[ "$("${adb_command[@]}" get-state)" == "device" ]]
  run_root "test -d '$legacy_dir/data'"
  run_root "test -f '$legacy_dir/tokens.json'"
  run_root "test -d '$app_dir'"
}

migrate() {
  preflight
  if run_root "test -e '$data_backup' -o -e '$token_backup'"; then
    echo "migration backup already exists; inspect or roll back before retrying" >&2
    exit 1
  fi

  "${adb_command[@]}" shell am force-stop "$package_name"
  run_root "'$legacy_dir/stop-dev.sh'"

  app_uid="$(run_root "stat -c %u '$app_dir'" | tr -d '\r')"
  app_gid="$(run_root "stat -c %g '$app_dir'" | tr -d '\r')"
  [[ "$app_uid" =~ ^[0-9]+$ && "$app_gid" =~ ^[0-9]+$ ]]

  run_root "set -eu
    mv '$data_dir' '$data_backup'
    mkdir -p '$data_dir'
    cp -a '$legacy_dir/data/.' '$data_dir/'
    mv '$token_file' '$token_backup'
    cp '$legacy_dir/tokens.json' '$token_file'
    chown -R '$app_uid:$app_gid' '$files_dir'
    find '$data_dir' -type d -exec chmod 700 {} \;
    find '$data_dir' -type f -exec chmod 600 {} \;
    chmod 600 '$token_file'
  "

  echo "migration complete; legacy service remains stopped and intact"
  echo "open PocketIMG, select the intended access mode, and start the App service"
}

rollback() {
  preflight
  run_root "test -d '$data_backup'"
  run_root "test -f '$token_backup'"
  "${adb_command[@]}" shell am force-stop "$package_name"

  failed_suffix="$(date -u +%Y%m%dT%H%M%SZ)"
  run_root "set -eu
    mv '$data_dir' '$files_dir/service-data.failed-$failed_suffix'
    mv '$data_backup' '$data_dir'
    mv '$token_file' '$files_dir/runtime/tokens.json.failed-$failed_suffix'
    mv '$token_backup' '$token_file'
    '$legacy_dir/start-dev.sh'
  "
  echo "App data restored and legacy service restarted"
}

case "${1:-migrate}" in
  migrate) migrate ;;
  rollback) rollback ;;
  *) echo "usage: $0 [migrate|rollback]" >&2; exit 2 ;;
esac
