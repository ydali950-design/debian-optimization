#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

CONFIG_FILE="/etc/default/mtu-mss-fix"
APPLY_SCRIPT="/usr/local/sbin/mtu-mss-apply.sh"
SERVICE_FILE="/etc/systemd/system/mtu-mss-fix.service"
CHAIN_FORWARD="MSS_FIX_FORWARD"
CHAIN_OUTPUT="MSS_FIX_OUTPUT"

GREEN='\033[32;1m'
YELLOW='\033[33;1m'
RED='\033[31;1m'
NC='\033[0m'

green() { printf "${GREEN}%s${NC}\n" "$*"; }
yellow() { printf "${YELLOW}%s${NC}\n" "$*"; }
red() { printf "${RED}%s${NC}\n" "$*"; }

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    red "请使用 root 用户执行。"
    exit 1
  fi
}

need_debian() {
  if [[ ! -r /etc/os-release ]]; then
    red "仅支持 Debian 10/11/12/13。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ "${ID:-}" != "debian" ]]; then
    red "仅支持 Debian，当前系统 ID=${ID:-unknown}。"
    exit 1
  fi
  case "${VERSION_ID:-}" in
    10|11|12|13) ;;
    *) yellow "当前 Debian 版本为 ${VERSION_ID:-unknown}，脚本会继续尝试执行。" ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends iptables iproute2 procps
}

valid_mss() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]+$ ]] && (( value >= 536 && value <= 1460 ))
}

write_config() {
  local mode="${1:-clamp}"
  local mss_value="${2:-}"
  local clamp_forward="${3:-1}"
  local clamp_output="${4:-1}"

  if [[ "${mode}" != "clamp" && "${mode}" != "fixed" ]]; then
    red "模式必须是 clamp 或 fixed。"
    exit 1
  fi

  if [[ "${mode}" == "fixed" ]]; then
    if ! valid_mss "${mss_value}"; then
      red "固定 MSS 必须是 536-1460 之间的数字。"
      exit 1
    fi
  fi

  install -d "$(dirname "${CONFIG_FILE}")"
  cat > "${CONFIG_FILE}" <<EOF
MSS_MODE=${mode}
MSS_VALUE=${mss_value}
CLAMP_FORWARD=${clamp_forward}
CLAMP_OUTPUT=${clamp_output}
EOF
  chmod 0644 "${CONFIG_FILE}"
}

write_apply_script() {
  install -d "$(dirname "${APPLY_SCRIPT}")"
  cat > "${APPLY_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/default/mtu-mss-fix"
CHAIN_FORWARD="MSS_FIX_FORWARD"
CHAIN_OUTPUT="MSS_FIX_OUTPUT"

MSS_MODE="clamp"
MSS_VALUE=""
CLAMP_FORWARD="1"
CLAMP_OUTPUT="1"

if [[ -r "${CONFIG_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${CONFIG_FILE}"
fi

ipt() {
  local family="$1"
  shift
  if [[ "${family}" == "v6" ]]; then
    ip6tables "$@"
  else
    iptables "$@"
  fi
}

table_available() {
  local family="$1"
  ipt "${family}" -t mangle -L >/dev/null 2>&1
}

ensure_chain() {
  local family="$1"
  local chain="$2"
  table_available "${family}" || return 0
  ipt "${family}" -t mangle -N "${chain}" 2>/dev/null || true
  ipt "${family}" -t mangle -F "${chain}" 2>/dev/null || true
}

ensure_jump() {
  local family="$1"
  local base_chain="$2"
  local target_chain="$3"
  table_available "${family}" || return 0
  ipt "${family}" -t mangle -C "${base_chain}" -j "${target_chain}" 2>/dev/null ||
    ipt "${family}" -t mangle -A "${base_chain}" -j "${target_chain}"
}

remove_jump() {
  local family="$1"
  local base_chain="$2"
  local target_chain="$3"
  table_available "${family}" || return 0
  while ipt "${family}" -t mangle -C "${base_chain}" -j "${target_chain}" 2>/dev/null; do
    ipt "${family}" -t mangle -D "${base_chain}" -j "${target_chain}" || break
  done
}

flush_or_create() {
  local family="$1"
  ensure_chain "${family}" "${CHAIN_FORWARD}"
  ensure_chain "${family}" "${CHAIN_OUTPUT}"
  remove_jump "${family}" FORWARD "${CHAIN_FORWARD}"
  remove_jump "${family}" OUTPUT "${CHAIN_OUTPUT}"
}

delete_family() {
  local family="$1"
  remove_jump "${family}" FORWARD "${CHAIN_FORWARD}"
  remove_jump "${family}" OUTPUT "${CHAIN_OUTPUT}"
  table_available "${family}" || return 0
  ipt "${family}" -t mangle -F "${CHAIN_FORWARD}" 2>/dev/null || true
  ipt "${family}" -t mangle -F "${CHAIN_OUTPUT}" 2>/dev/null || true
  ipt "${family}" -t mangle -X "${CHAIN_FORWARD}" 2>/dev/null || true
  ipt "${family}" -t mangle -X "${CHAIN_OUTPUT}" 2>/dev/null || true
}

add_mss_rule() {
  local family="$1"
  local chain="$2"
  table_available "${family}" || return 0

  if [[ "${MSS_MODE}" == "fixed" ]]; then
    ipt "${family}" -t mangle -A "${chain}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --set-mss "${MSS_VALUE}"
  else
    ipt "${family}" -t mangle -A "${chain}" -p tcp --tcp-flags SYN,RST SYN \
      -j TCPMSS --clamp-mss-to-pmtu
  fi
}

apply_family() {
  local family="$1"
  flush_or_create "${family}"

  if [[ "${CLAMP_FORWARD}" == "1" ]]; then
    ensure_jump "${family}" FORWARD "${CHAIN_FORWARD}"
    add_mss_rule "${family}" "${CHAIN_FORWARD}"
  fi

  if [[ "${CLAMP_OUTPUT}" == "1" ]]; then
    ensure_jump "${family}" OUTPUT "${CHAIN_OUTPUT}"
    add_mss_rule "${family}" "${CHAIN_OUTPUT}"
  fi
}

modprobe ip_tables 2>/dev/null || true
modprobe iptable_mangle 2>/dev/null || true

apply_family v4
delete_family v6
EOF
  chmod 0755 "${APPLY_SCRIPT}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=MTU/MSS clamp rules for relay and VPN hosts
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

enable_rules() {
  local mode="${1:-clamp}"
  local mss_value="${2:-}"
  local clamp_forward="${CLAMP_FORWARD:-1}"
  local clamp_output="${CLAMP_OUTPUT:-1}"

  install_packages
  write_config "${mode}" "${mss_value}" "${clamp_forward}" "${clamp_output}"
  write_apply_script
  write_service
  "${APPLY_SCRIPT}"
  systemctl enable --now mtu-mss-fix.service
  green "MTU/MSS 修正已启用：mode=${mode} forward=${clamp_forward} output=${clamp_output} ipv6=0"
}

disable_rules() {
  write_apply_script
  write_config clamp "" 0 0
  "${APPLY_SCRIPT}" || true
  systemctl disable --now mtu-mss-fix.service 2>/dev/null || true
  rm -f "${CONFIG_FILE}" "${APPLY_SCRIPT}" "${SERVICE_FILE}"
  systemctl daemon-reload 2>/dev/null || true
  green "MTU/MSS 修正规则已禁用并清理。"
}

status() {
  green "配置文件：${CONFIG_FILE}"
  if [[ -r "${CONFIG_FILE}" ]]; then
    cat "${CONFIG_FILE}"
  else
    yellow "暂无配置。"
  fi

  green "IPv4 mangle 规则："
  iptables -t mangle -S "${CHAIN_FORWARD}" 2>/dev/null || true
  iptables -t mangle -S "${CHAIN_OUTPUT}" 2>/dev/null || true

  green "IPv6 mangle 规则："
  yellow "默认关闭并清理。"

  green "服务状态："
  systemctl is-enabled mtu-mss-fix.service 2>/dev/null || true
  systemctl is-active mtu-mss-fix.service 2>/dev/null || true
}

menu() {
  while true; do
    clear
    green "====================================="
    green " MTU/MSS 修正"
    green "====================================="
    printf " 1. 启用自动 MSS clamp 推荐\n"
    printf " 2. 启用固定 MSS 值\n"
    printf " 3. 查看状态\n"
    printf " 4. 禁用并清理规则\n"
    printf " 0. 返回\n"
    printf "\n"
    yellow "默认会同时修正 FORWARD 和本机 OUTPUT 的 TCP SYN MSS。"
    yellow "适用于 Debian 10/11/12/13 的中转、NAT、VPN、落地机场景。"
    printf "\n"

    if ! read -r -p "请输入数字: " num; then
      return 0
    fi

    case "${num}" in
      1)
        enable_rules clamp
        read -r -n 1 -s -p "按任意键继续..." || true
        printf "\n"
        ;;
      2)
        read -r -p "请输入固定 MSS，常见值 1360/1380/1400: " mss_value
        enable_rules fixed "${mss_value}"
        read -r -n 1 -s -p "按任意键继续..." || true
        printf "\n"
        ;;
      3) status; read -r -n 1 -s -p "按任意键继续..." || true; printf "\n" ;;
      4) disable_rules; read -r -n 1 -s -p "按任意键继续..." || true; printf "\n" ;;
      0) return 0 ;;
      *) red "请输入正确数字。"; sleep 1 ;;
    esac
  done
}

need_root
need_debian

case "${1:-menu}" in
  enable|clamp) enable_rules clamp ;;
  fixed) enable_rules fixed "${2:?mss_value}" ;;
  disable|clear) disable_rules ;;
  status) status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|enable|fixed <mss>|disable|status]"; exit 1 ;;
esac
