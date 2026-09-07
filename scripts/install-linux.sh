#!/usr/bin/env bash
set -euo pipefail

if [[ $EUID -ne 0 || $# -ne 1 ]]; then
  printf '%s\n' '用法：sudo bash scripts/install-linux.sh /绝对路径/PocketIMG-linux-amd64' >&2
  exit 1
fi
for tool in systemctl runuser useradd install curl flock; do command -v "$tool" >/dev/null; done
exec 9>/run/lock/pocketimg-install.lock
flock -n 9 || { printf '%s\n' '另一个安装进程正在运行，请稍后重试。' >&2; exit 1; }
[[ $(uname -m) == x86_64 ]] || { printf '%s\n' '此安装入口支持 Linux x86_64。' >&2; exit 1; }
[[ -f $1 && ! -L $1 ]] || { printf '%s\n' '需要已校验的后端发布文件。' >&2; exit 1; }
unit=/etc/systemd/system/pocketimg.service
config=/etc/pocketimg/service.env
marker='# Managed by PocketIMG installer v1'
existing_unit=$(systemctl show --property=FragmentPath --value pocketimg 2>/dev/null || true)
if [[ -n $existing_unit && $existing_unit != "$unit" ]]; then
  printf '发现已有服务配置 %s，不会覆盖。\n' "$existing_unit" >&2
  exit 1
fi
for dir in /etc/pocketimg /etc/pocketimg/credentials /var/lib/pocketimg; do
  [[ ! -L $dir ]] || { printf '不支持符号链接安装目录：%s\n' "$dir" >&2; exit 1; }
done
if [[ -L $unit || -L $config ]]; then
  printf '%s\n' '不支持符号链接服务配置。' >&2
  exit 1
fi
if [[ -e $unit ]]; then
  IFS= read -r first_line < "$unit"
  [[ $first_line == "$marker" && -f $config && ! -L $config ]] || {
    printf '%s\n' '发现已有非本安装器管理的服务；请沿用原部署配置，不会覆盖。' >&2
    exit 1
  }
fi
if [[ -e $config ]]; then
  # Also accept a complete config left before unit installation by an interrupted run.
  [[ $(stat -c '%u:%a' "$config") == '0:640' ]] || { printf '%s\n' '安装配置必须由 root 拥有且权限为 0640。' >&2; exit 1; }
  IFS= read -r first_line < "$config"
  [[ $first_line == "$marker" ]] || { printf '%s\n' '不会覆盖已有的非安装器配置。' >&2; exit 1; }
  source "$config"
fi
if [[ -e /usr/local/bin/pocketimg && ! -e $config ]]; then
  printf '%s\n' '发现已有手工安装的 /usr/local/bin/pocketimg，不会覆盖；请沿用原升级流程。' >&2
  exit 1
fi

if ! id pocketimg >/dev/null 2>&1; then
  useradd --system --home-dir /var/lib/pocketimg --shell /usr/sbin/nologin pocketimg
fi
# Protect installer scripts/configuration from modification by the service.
install -d -o root -g pocketimg -m 0750 /etc/pocketimg
install -d -o pocketimg -g pocketimg -m 0700 /var/lib/pocketimg
install -d -o pocketimg -g pocketimg -m 0700 /etc/pocketimg/credentials

export PIH_DATA_DIR=${PIH_DATA_DIR:-/var/lib/pocketimg}
[[ $PIH_DATA_DIR == /var/lib/pocketimg ]] || { printf '%s\n' '自动 systemd 安装使用 /var/lib/pocketimg；自定义数据路径请沿用手工部署。' >&2; exit 1; }
export PIH_ADDR=${PIH_ADDR:-127.0.0.1:8080}
export PIH_COOKIE_SECURE=${PIH_COOKIE_SECURE:-true}
export PIH_TOKEN=${PIH_TOKEN:-} PIH_TOKENS=${PIH_TOKENS:-}
export PIH_TOKENS_FILE=${PIH_TOKENS_FILE:-} PIH_ADMIN_SPACE_ID=${PIH_ADMIN_SPACE_ID:-}
[[ -z ${PIH_FNOS_SOCKET:-} ]] || { printf '%s\n' '飞牛请使用应用包安装。' >&2; exit 1; }

staged=$(mktemp /usr/local/bin/.pocketimg-install.XXXXXX)
trap 'rm -f -- "$staged"' EXIT
install -o root -g root -m 0755 "$1" "$staged"
result=$(runuser --preserve-environment -u pocketimg -- "$staged" init --output /etc/pocketimg/credentials/tokens.json)
if [[ -z $PIH_TOKEN && -z $PIH_TOKENS && -z $PIH_TOKENS_FILE ]]; then
  export PIH_TOKENS_FILE=/etc/pocketimg/credentials/tokens.json
fi
# Bash quoting preserves arbitrary provided values without evaluating them.
if [[ ! -e $config ]]; then
  umask 077
  staged_config=$(mktemp /etc/pocketimg/.service-env.XXXXXX)
  {
    printf '%s\n' "$marker"
    for key in PIH_DATA_DIR PIH_ADDR PIH_COOKIE_SECURE PIH_TOKEN PIH_TOKENS PIH_TOKENS_FILE PIH_ADMIN_SPACE_ID; do
      printf 'export %s=%q\n' "$key" "${!key}"
    done
  } > "$staged_config"
  chown root:pocketimg "$staged_config"
  chmod 0640 "$staged_config"
  mv -f -- "$staged_config" "$config"
fi
mv -f -- "$staged" /usr/local/bin/pocketimg
if [[ ! -e $unit ]]; then
  install -o root -g root -m 0644 "$(dirname "${BASH_SOURCE[0]}")/../deploy/linux/pocketimg.service" "$unit"
fi
systemctl daemon-reload
if ! systemctl enable pocketimg || ! systemctl restart pocketimg; then
  printf '%s\n' '服务启动失败；凭证已保留，请检查 journalctl -u pocketimg。' >&2
  exit 1
fi
health_addr=$PIH_ADDR
case $health_addr in
  0.0.0.0:*) health_addr="127.0.0.1:${health_addr##*:}" ;;
  '[::]:'*) health_addr="[::1]:${health_addr##*:}" ;;
esac
healthy=false
for ((attempt=0; attempt<30; attempt++)); do
  if systemctl is-active --quiet pocketimg && curl --noproxy '*' --fail --silent --max-time 2 "http://$health_addr/healthz" >/dev/null; then
    sleep 1
    if systemctl is-active --quiet pocketimg; then
      healthy=true
      break
    fi
  fi
  sleep 1
done
if [[ $healthy != true ]]; then
  printf '%s\n' '健康检查失败；凭证已保留，请检查 journalctl -u pocketimg 后重试。' >&2
  exit 1
fi
if [[ ${PIH_INSTALL_QUIET:-0} == 1 ]]; then result='凭证已复用或保存；未输出明文。'; fi
printf '\nPocketIMG 安装完成\n访问地址：http://%s\n%s\n' "$health_addr" "$result"
printf '%s\n' '回环地址仅服务器本机可访问。部署参数保存在 /etc/pocketimg/service.env。'
