#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: package-linux-installer.sh VERSION BINARY OUTPUT_DIR' >&2; exit 1; }
version=$1
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid version' >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
binary=$(realpath "$2")
mkdir -p "$3"
output=$(realpath "$3")
work=$(mktemp -d /tmp/pocketimg-package.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
install -d "$work/scripts" "$work/deploy/linux"
install -m 0755 "$binary" "$work/pocketimg"
install -m 0755 "$root/scripts/install-linux.sh" "$work/scripts/install-linux.sh"
install -m 0644 "$root/deploy/linux/pocketimg.service" "$work/deploy/linux/pocketimg.service"
archive="PocketIMG-$version-linux-amd64-install.tar.gz"
tar -czf "$output/$archive" -C "$work" pocketimg scripts/install-linux.sh deploy/linux/pocketimg.service
cd "$output"
sha256sum "$archive" > "$archive.sha256"
