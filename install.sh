#!/usr/bin/env bash
# GitHub entry point. All work happens inside main so a truncated download does
# not run half of an installation. Release files are always version matched.
set -euo pipefail

main() {
  local version='' destination='' port='' work archive tag api digest docker_mode=0 directory='pocketimg-docker' flavor='linux-amd64'
  while [[ $# -gt 0 ]]; do
    case $1 in
      --docker) docker_mode=1; flavor=docker; shift ;;
      --directory) [[ $# -ge 2 ]] || { echo '--directory requires a directory' >&2; return 1; }; directory=$2; shift 2 ;;
      --version) [[ $# -ge 2 ]] || { echo '--version requires a version' >&2; return 1; }; version=${2#server-v}; shift 2 ;;
      --download-only) [[ $# -ge 2 ]] || { echo '--download-only requires an empty directory' >&2; return 1; }; destination=$2; shift 2 ;;
      --port) [[ $# -ge 2 ]] || { echo '--port requires a port' >&2; return 1; }; port=$2; shift 2 ;;
      --help|-h)
        printf '%s\n' 'PocketIMG Linux 一键安装' '用法：bash install.sh [--version X.Y.Z] [--port PORT] [--download-only DIRECTORY]' '新安装默认端口 18746；--port 支持 1024–65535，已有安装默认保留原端口。' '默认选择带安装包的最新稳定 Server 版本，校验后安装 systemd 服务。' '环境参数：PIH_ADDR、PIH_COOKIE_SECURE、PIH_ADMIN_SPACE_ID、PIH_INSTALL_QUIET。'
        printf '%s\n' 'Docker：bash install.sh --docker [--directory pocketimg-docker] [--version X.Y.Z] [--port PORT]' 'Docker 模式下载部署包并拉取发布镜像，无需 Git、Go 或 Node.js。'
        return 0 ;;
      *) printf '未知参数：%s\n' "$1" >&2; return 1 ;;
    esac
  done
  if [[ -n $port ]]; then
    [[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1024 && 10#$port <= 65535)) || { echo '端口必须为 1024–65535 的整数。' >&2; return 1; }
    port=$((10#$port))
  fi
  if [[ $docker_mode == 0 ]]; then
    [[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo '目前支持 Linux x86_64。' >&2; return 1; }
  fi
  if [[ $docker_mode == 0 && -z $destination && $EUID -ne 0 ]]; then
    echo '安装系统服务需要 root，请使用 sudo bash 执行。' >&2; return 1
  fi
  for tool in curl python3 tar sha256sum; do
    command -v "$tool" >/dev/null || { printf '缺少命令：%s；请先安装后重试。\n' "$tool" >&2; return 1; }
  done
  if [[ $docker_mode == 1 && -z $destination ]]; then
    command -v docker >/dev/null || { echo '请先安装 Docker Engine 与 Compose v2。' >&2; return 1; }
    docker compose version >/dev/null
    docker info >/dev/null
  elif [[ -z $destination ]]; then
    for tool in systemctl runuser useradd install flock ss; do command -v "$tool" >/dev/null || { printf '缺少命令：%s\n' "$tool" >&2; return 1; }; done
    [[ -d /run/systemd/system ]] || { echo '需要运行 systemd 的 Linux 主机。' >&2; return 1; }
  fi
  if [[ -n $version && ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo '版本格式必须为 X.Y.Z。' >&2; return 1
  fi
  work=$(mktemp -d /tmp/pocketimg-download.XXXXXX)
  # Validated mktemp directory; do not change work after installing this trap.
  trap "rm -rf -- '$work'" EXIT
  download() { curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 300 --proto '=https' "$1" -o "$2"; }
  api='https://api.github.com/repos/gmch1/pocket-img/releases'
  if [[ -z $version ]]; then
    # GitHub Latest belongs to the Mac component. Enumerate releases instead,
    # ignoring Android, fnOS, drafts, prereleases and servers without bundles.
    local page page_count
    for ((page=1; ; page++)); do
      download "$api?per_page=100&page=$page" "$work/releases-$page.json"
      page_count=$(python3 -c 'import json,sys; data=json.load(open(sys.argv[1])); assert isinstance(data,list), "invalid GitHub releases response"; print(len(data))' "$work/releases-$page.json")
      [[ $page_count == 100 ]] || break
    done
    version=$(python3 - "$work" "$flavor" <<'PY'
import glob, json, re, sys
versions = []
for path in glob.glob(sys.argv[1] + '/releases-*.json'):
    for release in json.load(open(path)):
        match = re.fullmatch(r'server-v(\d+\.\d+\.\d+)', release.get('tag_name', ''))
        if not match or release.get('draft') or release.get('prerelease'):
            continue
        version = match[1]
        bundle = f'PocketIMG-{version}-{sys.argv[2]}-install.tar.gz'
        assets = {asset['name'] for asset in release.get('assets', [])}
        if {bundle, bundle + '.sha256'} <= assets:
            versions.append(version)
if not versions:
    sys.exit('尚无支持一键安装的 Server Release，请等待新版本发布；不会安装旧版或 Mac 客户端。')
print(max(versions, key=lambda value: tuple(map(int, value.split('.')))))
PY
)
  fi
  tag="server-v$version"
  archive="PocketIMG-$version-$flavor-install.tar.gz"
  printf '下载 PocketIMG Server %s…\n' "$version"
  download "https://github.com/gmch1/pocket-img/releases/download/$tag/$archive" "$work/$archive"
  download "https://github.com/gmch1/pocket-img/releases/download/$tag/$archive.sha256" "$work/$archive.sha256"
  digest=$(python3 - "$work/$archive.sha256" "$archive" <<'PY'
import re, sys
fields = open(sys.argv[1]).read().split()
if len(fields) != 2 or not re.fullmatch(r'[a-fA-F0-9]{64}', fields[0]) or fields[1] not in (sys.argv[2], '*' + sys.argv[2]):
    sys.exit('无效的安装包校验文件。')
print(fields[0])
PY
)
  printf '%s  %s\n' "$digest" "$work/$archive" | sha256sum --check --status || { echo '安装包 SHA-256 不匹配，已停止。' >&2; return 1; }
  python3 - "$work/$archive" "$docker_mode" <<'PY'
import sys, tarfile
expected = {'pocketimg', 'scripts/install-linux.sh', 'deploy/linux/pocketimg.service'}
if sys.argv[2] == '1':
    expected = {'compose.yaml', 'scripts/install-docker.sh', 'scripts/deploy-docker.py'}
with tarfile.open(sys.argv[1], 'r:gz') as bundle:
    members = bundle.getmembers()
    if len(members) != len(expected) or {m.name for m in members} != expected or any(not m.isfile() or m.size > 128 * 1024 * 1024 for m in members):
        sys.exit('安装包结构异常，已停止。')
PY
  mkdir "$work/unpacked"
  tar -xzf "$work/$archive" -C "$work/unpacked" --no-same-owner --no-same-permissions
  if [[ $docker_mode == 0 ]]; then chmod 0755 "$work/unpacked/pocketimg"; fi
  if [[ -n $destination ]]; then
    [[ ! -L $destination ]] || { echo '下载目标不能是符号链接。' >&2; return 1; }
    mkdir -p "$destination"
    [[ -z $(ls -A "$destination") ]] || { echo '下载目标必须为空目录。' >&2; return 1; }
    cp -R "$work/unpacked/." "$destination/"
    printf '已校验并解压至：%s（尚未安装服务）\n' "$destination"
  elif [[ $docker_mode == 1 ]]; then
    python3 "$work/unpacked/scripts/deploy-docker.py" "$work/unpacked" "$directory" "$port"
  else
    local install_args=("$work/unpacked/pocketimg")
    if [[ -n $port ]]; then install_args+=(--port "$port"); fi
    bash "$work/unpacked/scripts/install-linux.sh" "${install_args[@]}"
  fi
  rm -rf -- "$work"
  trap - EXIT
}

main "$@"
