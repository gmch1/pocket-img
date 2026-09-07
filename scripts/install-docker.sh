#!/usr/bin/env bash
set -euo pipefail

# Run from the checkout so build context and Compose project identity are stable.
cd "$(dirname "${BASH_SOURCE[0]}")/.."
command -v docker >/dev/null
docker compose version >/dev/null

while [[ $# -gt 0 ]]; do
  case $1 in
    --port) [[ $# -ge 2 ]] || { echo '--port requires a port' >&2; exit 1; }; export PIH_PORT=$2; shift 2 ;;
    *) printf '未知参数：%s\n' "$1" >&2; exit 1 ;;
  esac
done
# Explicit environment/.env wins; otherwise preserve a running or stopped
# container's existing host mapping when upgrading an installation.
configured_port=$(docker compose config --environment | sed -n 's/^PIH_PORT=//p')
if [[ -z $configured_port ]]; then
  existing_container=$(docker compose ps --all --quiet pocketimg)
  if [[ -n $existing_container ]]; then
    configured_port=$(docker inspect --format '{{with index .HostConfig.PortBindings "8080/tcp"}}{{(index . 0).HostPort}}{{end}}' "$existing_container")
  fi
fi
export PIH_PORT=${configured_port:-18746}
[[ $PIH_PORT =~ ^[0-9]{1,5}$ ]] && ((10#$PIH_PORT >= 1024 && 10#$PIH_PORT <= 65535)) || { echo '端口必须为 1024–65535 的整数。' >&2; exit 1; }
export PIH_PORT=$((10#$PIH_PORT))

if [[ -n ${PIH_IMAGE:-} || ! -f Dockerfile ]]; then
  if [[ ${PIH_INSTALL_PULL:-1} != 0 ]]; then docker compose pull pocketimg; fi
else
  docker compose build pocketimg
fi

# The one-off container uses the same UID, volume and token environment as the
# service. Capture credentials privately and print only after the health check.
result=$(docker compose run --rm --no-deps -T pocketimg init)
if ! docker compose up --detach --no-build --wait --wait-timeout 90 pocketimg; then
  printf '%s\n' '启动失败；已保存的凭证会保留，修复后重新运行安装脚本。' >&2
  exit 1
fi
if [[ ${PIH_INSTALL_QUIET:-0} == 1 ]]; then result='凭证已复用或保存；未输出明文。'; fi
printf '\nPocketIMG 安装完成\n访问地址：http://<部署主机>:%s\n%s\n' "$PIH_PORT" "$result"
printf '%s\n' '未提供自定义凭证时，凭证保存在数据卷 /data/tokens.json；重启与重建容器会复用。'
