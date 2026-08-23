#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/build_fnos_package.sh \
    --version <x.y.z[-prerelease]> \
    --macos-zip <PocketIMGShot zip> \
    [--output-dir <directory>] \
    [--stage-only]

The script never downloads release assets. It copies the supplied, already
signed macOS archive into the fnOS package, records its SHA-256, replaces all
package placeholders, and then invokes fnpack. Use --stage-only to produce the
fully rendered fnOS package directory without requiring fnpack.
EOF
}

fail() {
  echo "build_fnos_package: $*" >&2
  exit 1
}

version=""
macos_zip=""
output_dir=""
stage_only="false"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      [ "$#" -ge 2 ] || fail "--version requires a value"
      version="$2"
      shift 2
      ;;
    --macos-zip)
      [ "$#" -ge 2 ] || fail "--macos-zip requires a value"
      macos_zip="$2"
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || fail "--output-dir requires a value"
      output_dir="$2"
      shift 2
      ;;
    --stage-only)
      stage_only="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1"
      ;;
  esac
done

[ -n "$version" ] || fail "--version is required"
[ -n "$macos_zip" ] || fail "--macos-zip is required"

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$ ]]; then
  fail "version must look like 1.2.3 or 1.2.3-rc.1"
fi

[ -f "$macos_zip" ] || fail "macOS archive does not exist: $macos_zip"
case "$macos_zip" in
  *.zip) ;;
  *) fail "macOS archive must be a .zip file" ;;
esac

macos_filename="PocketIMGShot-${version}-macos-arm64.zip"
[ "$(basename "$macos_zip")" = "$macos_filename" ] || \
  fail "macOS archive must be named $macos_filename"

command -v unzip >/dev/null 2>&1 || fail "unzip is required to validate the macOS archive"
unzip -tqq "$macos_zip" >/dev/null || fail "macOS archive is not a valid ZIP file"

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/.." && pwd)"
template_dir="$repo_root/deploy/fnos/pocket-img"
[ -d "$template_dir" ] || fail "fnOS package template is missing: $template_dir"

if [ -z "$output_dir" ]; then
  output_dir="$repo_root/dist/fnos"
elif [[ "$output_dir" != /* ]]; then
  output_dir="$repo_root/$output_dir"
fi

if command -v sha256sum >/dev/null 2>&1; then
  macos_sha256="$(sha256sum "$macos_zip" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  macos_sha256="$(shasum -a 256 "$macos_zip" | awk '{print $1}')"
else
  fail "sha256sum or shasum is required"
fi

[[ "$macos_sha256" =~ ^[0-9a-f]{64}$ ]] || fail "failed to calculate macOS archive SHA-256"

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/pocket-img-fnos.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
stage_dir="$temporary_root/pocket-img"
cp -R "$template_dir" "$stage_dir"

cp "$macos_zip" "$stage_dir/app/downloads/$macos_filename"

replace_literal() {
  local file="$1"
  local placeholder="$2"
  local replacement="$3"
  local temporary_file="${file}.rendered"

  grep -Fq "$placeholder" "$file" || fail "missing placeholder $placeholder in $file"
  sed "s|${placeholder}|${replacement}|g" "$file" > "$temporary_file"
  mv "$temporary_file" "$file"
}

replace_literal "$stage_dir/manifest" "__VERSION__" "$version"
replace_literal "$stage_dir/app/docker/docker-compose.yaml" "__VERSION__" "$version"
replace_literal "$stage_dir/app/downloads/manifest.json" "__VERSION__" "$version"
replace_literal "$stage_dir/app/downloads/manifest.json" "__MACOS_ZIP_SHA256__" "$macos_sha256"

if grep -R -E -n '__[A-Z0-9_]+__' "$stage_dir"; then
  fail "unresolved package placeholder found"
fi

grep -Fxq "appname=pocket-img" "$stage_dir/manifest" || fail "rendered manifest changed appname"
grep -Fxq "version=$version" "$stage_dir/manifest" || fail "rendered manifest version is invalid"
grep -Fq "image: \"ghcr.io/gmch1/pocket-img:$version\"" "$stage_dir/app/docker/docker-compose.yaml" || \
  fail "rendered Docker image reference is invalid"
grep -Fq "\"filename\": \"$macos_filename\"" "$stage_dir/app/downloads/manifest.json" || \
  fail "rendered download manifest filename is invalid"
grep -Fq "\"sha256\": \"$macos_sha256\"" "$stage_dir/app/downloads/manifest.json" || \
  fail "rendered download manifest checksum is invalid"

mkdir -p "$output_dir"

if [ "$stage_only" = "true" ]; then
  stage_output="$output_dir/pocket-img-$version"
  [ ! -e "$stage_output" ] || fail "stage output already exists: $stage_output"
  cp -R "$stage_dir" "$stage_output"
  echo "Staged fnOS package: $stage_output"
  echo "macOS archive SHA-256: $macos_sha256"
  exit 0
fi

command -v fnpack >/dev/null 2>&1 || \
  fail "fnpack is not installed; install fnpack or rerun with --stage-only"

(
  cd "$temporary_root"
  fnpack build --directory "$stage_dir"
)

built_package_list="$(find "$temporary_root" -type f -name '*.fpk' -print)"
if [ -z "$built_package_list" ]; then
  fail "expected exactly one .fpk from fnpack, found 0"
fi
case "$built_package_list" in
  *$'\n'*) fail "expected exactly one .fpk from fnpack, found multiple files" ;;
esac

package_output="$output_dir/pocket-img-$version.fpk"
[ ! -e "$package_output" ] || fail "package output already exists: $package_output"
cp "$built_package_list" "$package_output"

echo "Built fnOS package: $package_output"
echo "macOS archive SHA-256: $macos_sha256"
