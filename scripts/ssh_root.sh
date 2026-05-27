#!/usr/bin/env bash
set -euo pipefail

DROPIN_DIR="/etc/ssh/sshd_config.d"
DROPIN_FILE="${DROPIN_DIR}/99-root-login.conf"
SSHD_CONFIG="/etc/ssh/sshd_config"

green() { printf '\033[32;1m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33;1m%s\033[0m\n' "$*"; }
red() { printf '\033[31;1m%s\033[0m\n' "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "请使用 root 用户执行。"
    exit 1
  fi
}

need_debian() {
  if [[ ! -r /etc/os-release ]]; then
    red "仅支持 Debian 系统。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    red "仅支持 Debian 系统，当前系统 ID=${ID:-unknown}。"
    exit 1
  fi
}

detect_ssh_service() {
  if systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    echo ssh
  elif systemctl list-unit-files sshd.service >/dev/null 2>&1; then
    echo sshd
  else
    echo ssh
  fi
}

install_ssh_server() {
  if command -v sshd >/dev/null 2>&1; then
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends openssh-server
}

ensure_include() {
  if [[ ! -f "${SSHD_CONFIG}" ]]; then
    red "未找到 ${SSHD_CONFIG}。"
    exit 1
  fi

  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' "${SSHD_CONFIG}"; then
    cp -a "${SSHD_CONFIG}" "${SSHD_CONFIG}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "${SSHD_CONFIG}"
  fi
}

reload_ssh() {
  local svc
  svc="$(detect_ssh_service)"
  sshd -t
  systemctl restart "${svc}" 2>/dev/null || systemctl restart ssh 2>/dev/null || systemctl restart sshd
}

set_root_password() {
  install_ssh_server
  passwd root
}

enable_root_login() {
  install_ssh_server
  install -d "${DROPIN_DIR}"
  ensure_include
  cat > "${DROPIN_FILE}" <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
PubkeyAuthentication yes
KbdInteractiveAuthentication yes
EOF
  reload_ssh
  green "root SSH 登录已启用。"
}

disable_root_login() {
  install_ssh_server
  install -d "${DROPIN_DIR}"
  ensure_include
  cat > "${DROPIN_FILE}" <<'EOF'
PermitRootLogin prohibit-password
PasswordAuthentication no
PubkeyAuthentication yes
KbdInteractiveAuthentication no
EOF
  reload_ssh
  green "root 密码 SSH 登录已关闭，仅保留密钥登录策略。"
}

status() {
  install_ssh_server
  green "当前 SSH 有效配置："
  sshd -T 2>/dev/null | awk '/^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication) /' || true
  if [[ -f "${DROPIN_FILE}" ]]; then
    yellow "本脚本配置文件：${DROPIN_FILE}"
    cat "${DROPIN_FILE}"
  fi
}

menu() {
  while true; do
    clear
    green "=============================="
    green " Root SSH 管理"
    green "=============================="
    printf " 1. 设置 root 密码\n"
    printf " 2. 启用 root 密码 SSH 登录\n"
    printf " 3. 关闭 root 密码 SSH 登录\n"
    printf " 4. 查看 SSH 登录状态\n"
    printf " 0. 返回\n"
    read -r -p "请输入数字: " num
    case "${num}" in
      1) set_root_password; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      2) enable_root_login; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      3) disable_root_login; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      4) status; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      0) return 0 ;;
      *) red "请输入正确数字。"; sleep 1 ;;
    esac
  done
}

need_root
need_debian

case "${1:-menu}" in
  password) set_root_password ;;
  enable) enable_root_login ;;
  disable) disable_root_login ;;
  status) status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|password|enable|disable|status]"; exit 1 ;;
esac
