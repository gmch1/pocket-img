#!/usr/bin/env bash

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <PocketIMGShot.app>" >&2
  exit 1
fi

app="$1"
if [[ ! -d "${app}" ]]; then
  echo "macOS application bundle does not exist: ${app}" >&2
  exit 1
fi

binaries=(
  "Contents/MacOS/PocketIMGShot"
  "Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle"
  "Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
  "Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app/Contents/MacOS/Updater"
  "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc/Contents/MacOS/Installer"
  "Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
)

for relative_path in "${binaries[@]}"; do
  binary="${app}/${relative_path}"
  if [[ ! -f "${binary}" ]]; then
    echo "required macOS executable is missing: ${relative_path}" >&2
    exit 1
  fi

  architectures="$(lipo -archs "${binary}")"
  if [[ " ${architectures} " != *" arm64 "* ]]; then
    echo "required arm64 slice is missing from ${relative_path}: ${architectures}" >&2
    exit 1
  fi

  if [[ "${architectures}" != "arm64" ]]; then
    thinned_binary="${binary}.arm64-thin"
    lipo -thin arm64 "${binary}" -output "${thinned_binary}"
    chmod +x "${thinned_binary}"
    mv "${thinned_binary}" "${binary}"
  fi

  final_architectures="$(lipo -archs "${binary}")"
  if [[ "${final_architectures}" != "arm64" ]]; then
    echo "macOS executable was not reduced to arm64: ${relative_path}: ${final_architectures}" >&2
    exit 1
  fi
done

echo "Verified Apple Silicon-only macOS bundle: ${app}"
