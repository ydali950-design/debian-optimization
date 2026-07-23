#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/ydali950-design/debian-optimization/refs/heads/main}"
AUTO_UPDATE_SUPPORT="${AUTO_UPDATE_SUPPORT:-0}"
OPTIMIZER="${SCRIPT_DIR}/sysctl_optimization_debian_overwrite.sh"
SWAP_SCRIPT="${SCRIPT_DIR}/scripts/swap.sh"
SSH_ROOT_SCRIPT="${SCRIPT_DIR}/scripts/ssh_root.sh"
UDP_MULTINIC_SCRIPT="${SCRIPT_DIR}/scripts/udp_multinic.sh"
MTU_MSS_SCRIPT="${SCRIPT_DIR}/scripts/mtu_mss.sh"
MARK_FILE="/root/.debian_optimization_done"

RED='\033[31;1m'
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
BLUE='\033[34;1m'
NC='\033[0m'

info() { printf "${BLUE}%s${NC}\n" "$*"; }
ok() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
fail() { printf "${RED}%s${NC}\n" "$*"; }

download_file() {
  local url="$1"
  local target="$2"
  local tmp
  tmp="$(mktemp)"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${tmp}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${tmp}" "${url}"
  else
    fail "未找到 curl 或 wget，无法下载配套脚本。"
    rm -f "${tmp}"
    exit 1
  fi

  install -d "$(dirname "${target}")"
  mv "${tmp}" "${target}"
  chmod 0755 "${target}"
}

ensure_support_scripts() {
  local path url
  for path in \
    "sysctl_optimization_debian_overwrite.sh" \
    "scripts/swap.sh" \
    "scripts/ssh_root.sh" \
    "scripts/udp_multinic.sh" \
    "scripts/mtu_mss.sh"; do
    if [[ "${AUTO_UPDATE_SUPPORT}" == "1" || ! -f "${SCRIPT_DIR}/${path}" ]]; then
      url="${RAW_BASE_URL}/${path}"
      warn "正在同步 ${SCRIPT_DIR}/${path} ..."
      download_file "${url}" "${SCRIPT_DIR}/${path}"
    fi
  done
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    fail "请使用 root 用户执行。"
    exit 1
  fi
}

require_supported_os() {
  if [[ ! -r /etc/os-release ]]; then
    fail "仅支持 Debian 或 Ubuntu 系统。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) fail "仅支持 Debian 或 Ubuntu 系统，当前系统 ID=${ID:-unknown}。"; exit 1 ;;
  esac
}

system_id() {
  # shellcheck disable=SC1091
  . /etc/os-release
  printf "%s" "${ID}"
}

pause() {
  read -r -n 1 -s -p "按任意键继续..."
  printf "\n"
}

confirm() {
  local prompt="$1"
  local answer
  read -r -p "${prompt} [y/N]: " answer
  [[ "${answer}" == "y" || "${answer}" == "Y" ]]
}

detect_codename() {
  local codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    codename="${VERSION_CODENAME:-}"
  fi

  if [[ -z "${codename}" ]]; then
    case "$(cat /etc/debian_version)" in
      13*) codename="trixie" ;;
      12*) codename="bookworm" ;;
      11*) codename="bullseye" ;;
      10*) codename="buster" ;;
      *) fail "无法识别 Debian 版本。"; exit 1 ;;
    esac
  fi

  printf "%s" "${codename}"
}

apt_update() {
  apt-get \
    -o Acquire::AllowReleaseInfoChange::Suite=true \
    -o Acquire::AllowReleaseInfoChange::Version=true \
    -o Acquire::AllowReleaseInfoChange::Codename=true \
    update
}

is_debian_official_source_file() {
  local file="$1"

  if grep -Eiq 'download\.docker\.com|cloudflare|tailscale|nodesource|nginx\.org|packages\.microsoft\.com' "${file}"; then
    return 1
  fi

  if grep -Eiq '(deb\.debian\.org/debian|security\.debian\.org/debian-security|ftp\.[^[:space:]/]+\.debian\.org/debian|httpredir\.debian\.org/debian|archive\.debian\.org/debian|archive\.debian\.org/debian-security)' "${file}"; then
    return 0
  fi

  grep -Eiq '(^|[[:space:]])(buster|bullseye|bookworm|trixie)-backports([[:space:]]|$)' "${file}" \
    && grep -Eiq '/debian([[:space:]]|$)|/debian-security([[:space:]]|$)' "${file}"
}

disable_conflicting_debian_source_files() {
  local stamp file disabled
  stamp="$(date +%Y%m%d%H%M%S)"

  shopt -s nullglob
  for file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
    [[ -f "${file}" ]] || continue
    if is_debian_official_source_file "${file}"; then
      cp -a "${file}" "${file}.bak.${stamp}"
      disabled="${file}.disabled.${stamp}"
      mv "${file}" "${disabled}"
      warn "已禁用旧 Debian 源文件：${file} -> ${disabled}"
    fi
  done
  shopt -u nullglob
}

install_base_tools() {
  require_supported_os
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release iproute2 ethtool procps gawk
  ok "基础组件安装完成。"
}

set_debian_sources() {
  require_supported_os
  local codename backup components
  codename="$(detect_codename)"
  backup="/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"

  case "${codename}" in
    bookworm|trixie)
      components="main contrib non-free non-free-firmware"
      ;;
    *)
      components="main contrib non-free"
      ;;
  esac

  disable_conflicting_debian_source_files

  if [[ -e /etc/apt/sources.list ]]; then
    cp -a /etc/apt/sources.list "${backup}"
  else
    touch /etc/apt/sources.list
    backup="无，原文件不存在"
  fi

  if [[ "${codename}" == "buster" ]]; then
    cat > /etc/apt/sources.list <<EOF
deb [check-valid-until=no] http://archive.debian.org/debian ${codename} ${components}
deb [check-valid-until=no] http://archive.debian.org/debian ${codename}-updates ${components}
deb [check-valid-until=no] http://archive.debian.org/debian-security ${codename}/updates ${components}
EOF
  else
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${codename} ${components}
deb http://deb.debian.org/debian ${codename}-updates ${components}
deb http://security.debian.org/debian-security ${codename}-security ${components}
EOF
  fi

  apt_update
  ok "Debian ${codename} 官方源已设置，原文件备份为 ${backup}"
}

set_system_sources() {
  case "$(system_id)" in
    debian) set_debian_sources ;;
    ubuntu)
      apt_update
      ok "Ubuntu 软件源已刷新，保留系统现有镜像与组件配置。"
      ;;
  esac
}

run_network_optimization() {
  local profile="$1"
  if [[ ! -f "${OPTIMIZER}" ]]; then
    fail "未找到 ${OPTIMIZER}"
    exit 1
  fi

  chmod +x "${OPTIMIZER}"
  PROFILE="${profile}" bash "${OPTIMIZER}"
  touch "${MARK_FILE}"
  ok "网络优化完成。建议重启一次。"
}

run_local_script() {
  local script="$1"
  if [[ ! -f "${script}" ]]; then
    fail "未找到 ${script}"
    return 1
  fi
  chmod +x "${script}"
  bash "${script}"
}

install_irqbalance() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y irqbalance
  systemctl start irqbalance
  systemctl enable irqbalance
  ok "irqbalance 已安装并启用。"
}

install_chrony() {
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get install -y chrony
  systemctl enable chrony
  systemctl restart chrony
  chronyc makestep
  ok "Chrony 已安装、启用并完成立即校时。"
}

enable_mtu_mss_fix() {
  if [[ ! -f "${MTU_MSS_SCRIPT}" ]]; then
    fail "未找到 ${MTU_MSS_SCRIPT}"
    return 1
  fi
  chmod +x "${MTU_MSS_SCRIPT}"
  bash "${MTU_MSS_SCRIPT}" enable
  ok "MTU/MSS 修正已启用。"
}

default_setup() {
  if [[ "${SKIP_INIT:-0}" == "1" ]]; then
    ok "已跳过默认初始化。"
    return 0
  fi

  warn "开始默认初始化：刷新系统软件源 -> 安装并校准 Chrony -> 关闭 IPv6 -> 执行网络优化 -> 启用 MTU/MSS 修正 -> 安装并启用 irqbalance。"
  set_system_sources
  install_base_tools
  install_chrony
  run_network_optimization "${PROFILE:-balanced}"
  enable_mtu_mss_fix
  install_irqbalance
  touch "${MARK_FILE}"
  ok "默认初始化完成。"
}

install_warp_menu() {
  local url="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
  local target="/root/warp-menu.sh"

  warn "即将下载并执行第三方 WARP 脚本：${url}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target}"
  else
    wget -O "${target}" "${url}"
  fi

  chmod +x "${target}"
  bash "${target}"
}

show_status() {
  local ipv4_precedence os_pretty_name
  ipv4_precedence="$(grep -E '^[[:space:]]*precedence[[:space:]]+::ffff:0:0/96[[:space:]]+100' /etc/gai.conf 2>/dev/null | tail -n 1 || true)"
  # shellcheck disable=SC1091
  . /etc/os-release
  os_pretty_name="${PRETTY_NAME:-${ID}}"

  info "系统信息"
  printf "System: %s\n" "${os_pretty_name}"
  printf "Kernel: %s\n" "$(uname -r)"
  printf "Memory: %s\n" "$(awk '/MemTotal:/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"

  info "网络参数"
  printf "tcp_congestion_control: %s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf "default_qdisc: %s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf "ipv4_forward: %s\n" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  printf "ipv6_disabled: %s\n" "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  printf "ipv4_precedence: %s\n" "${ipv4_precedence:-missing}"
  printf "nf_conntrack_max: %s\n" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo unknown)"
  printf "ip_local_port_range: %s\n" "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo unknown)"

  info "队列状态"
  ip -o link show | awk -F': ' '{print $2}' | while read -r dev; do
    [[ "${dev}" == "lo" ]] && continue
    tc qdisc show dev "${dev}" 2>/dev/null | sed "s/^/${dev}: /" || true
  done
}

main_menu() {
  while true; do
    clear
    ok "====================================="
    ok " Debian / Ubuntu Optimization"
    ok " 中转机 / VPN 落地机网络优化"
    ok "====================================="
    printf " 1. 安装基础组件\n"
    printf " 2. 刷新系统软件源\n"
    printf " 3. 执行网络优化 balanced\n"
    printf " 4. 执行网络优化 max\n"
    printf " 5. Swap 管理\n"
    printf " 6. Root SSH 管理\n"
    printf " 7. UDP 多网卡防丢包映射\n"
    printf " 8. MTU/MSS 修正管理\n"
    printf " 9. 安装/管理 WARP\n"
    printf "10. 查看优化状态\n"
    printf "11. 重启系统\n"
    printf " 0. 退出\n"
    printf "\n"

    if ! read -r -p "请输入数字: " num; then
      exit 0
    fi
    case "${num}" in
      1) install_base_tools; pause ;;
      2) set_system_sources; pause ;;
      3) run_network_optimization balanced; pause ;;
      4) run_network_optimization max; pause ;;
      5) run_local_script "${SWAP_SCRIPT}" ;;
      6) run_local_script "${SSH_ROOT_SCRIPT}" ;;
      7) run_local_script "${UDP_MULTINIC_SCRIPT}" ;;
      8) run_local_script "${MTU_MSS_SCRIPT}" ;;
      9) install_warp_menu; pause ;;
      10) show_status; pause ;;
      11)
        if confirm "确认重启系统吗？"; then
          reboot
        fi
        ;;
      0) exit 0 ;;
      *) fail "请输入正确数字。"; sleep 1 ;;
    esac
  done
}

require_root
require_supported_os
ensure_support_scripts
default_setup
main_menu
