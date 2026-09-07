#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 ]] || { echo 'Usage: package-docker-installer.sh VERSION IMAGE_DIGEST OUTPUT_DIR' >&2; exit 1; }
version=$1
digest=$2
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && $digest =~ ^sha256:[a-f0-9]{64}$ ]] || { echo 'Invalid version or digest' >&2; exit 1; }
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mkdir -p "$3"
output=$(realpath "$3")
work=$(mktemp -d /tmp/pocketimg-docker-package.XXXXXX)
trap 'rm -rf -- "$work"' EXIT
mkdir "$work/scripts"
install -m 0755 "$root/scripts/install-docker.sh" "$work/scripts/install-docker.sh"
install -m 0644 "$root/scripts/deploy-docker.py" "$work/scripts/deploy-docker.py"
# Keep runtime settings aligned with the development Compose file, but never
# ship build context or require a source checkout in the release bundle.
python3 - "$root/compose.yaml" "$work/compose.yaml" "$digest" <<'PY'
from pathlib import Path
import sys
content = Path(sys.argv[1]).read_text()
old = '    image: ${PIH_IMAGE:-pocketimg:local}\n    build:\n      context: .\n      dockerfile: Dockerfile\n'
if content.count(old) != 1:
    sys.exit('Compose build structure changed; update the Docker packager.')
image = 'ghcr.io/gmch1/pocket-img@' + sys.argv[3]
Path(sys.argv[2]).write_text(content.replace(old, '    image: ${PIH_IMAGE:-' + image + '}\n'))
PY
archive="PocketIMG-$version-docker-install.tar.gz"
tar -czf "$output/$archive" -C "$work" compose.yaml scripts/install-docker.sh scripts/deploy-docker.py
cd "$output"
sha256sum "$archive" > "$archive.sha256"
