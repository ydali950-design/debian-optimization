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

need_supported_os() {
  if [[ ! -r /etc/os-release ]]; then
    red "仅支持 Debian 或 Ubuntu 系统。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) red "仅支持 Debian 或 Ubuntu 系统，当前系统 ID=${ID:-unknown}。"; exit 1 ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends iptables iproute2 procps
}

valid_mss() {
  local value="$1"
  [[ "${value}" =~ ^(0|[1-9][0-9]{0,3})$ ]] &&
    (( 10#${value} >= 536 && 10#${value} <= 1460 ))
}

file_sha256_is() {
  local path="$1"
  local expected="$2"
  local actual
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  command -v sha256sum >/dev/null 2>&1 || return 1
  actual="$(sha256sum -- "${path}" | awk '{print $1}')"
  [[ "${actual}" == "${expected}" ]]
}

is_managed_config_file() {
  local path="$1"
  local mode mss_value
  local -a lines=()
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  mapfile -t lines < "${path}"
  (( ${#lines[@]} == 4 )) || return 1
  [[ "${lines[0]}" =~ ^MSS_MODE=(clamp|fixed)$ ]] || return 1
  mode="${BASH_REMATCH[1]}"
  [[ "${lines[1]}" == MSS_VALUE=* ]] || return 1
  mss_value="${lines[1]#MSS_VALUE=}"
  [[ "${lines[2]}" =~ ^CLAMP_FORWARD=[01]$ ]] || return 1
  [[ "${lines[3]}" =~ ^CLAMP_OUTPUT=[01]$ ]] || return 1
  if [[ "${mode}" == "clamp" ]]; then
    [[ -z "${mss_value}" ]]
  else
    valid_mss "${mss_value}"
  fi
}

require_runtime_paths_safe() {
  if [[ -e "${APPLY_SCRIPT}" || -L "${APPLY_SCRIPT}" ]]; then
    if ! file_sha256_is "${APPLY_SCRIPT}" 9b7efb88f963a36150a47feb680cfae0b088e3921368d4a07ba0bd94e40b6afd &&
       ! file_sha256_is "${APPLY_SCRIPT}" f5ce5cf993b2093d96f2c11b7e67326219178b8aa05a5cf35df1ba4eeaec94b3 &&
       ! file_sha256_is "${APPLY_SCRIPT}" 69d179289daff5e4db9034ffbfe898ba579e85922b4c92f3b3f306c741745bed &&
       ! file_sha256_is "${APPLY_SCRIPT}" 275cc980595314c1f01ded261a28a1ce2fb9f838a7b0eb5609287b99db6054f0; then
      red "拒绝覆盖不属于仓库旧版或 main2 的同名文件：${APPLY_SCRIPT}"
      exit 1
    fi
  fi
  if [[ -e "${SERVICE_FILE}" || -L "${SERVICE_FILE}" ]]; then
    if ! file_sha256_is "${SERVICE_FILE}" 5696d6de58dc07facf0aedc07f23937bee822090d1caf8fbbf69a980fe22b6b1; then
      red "拒绝覆盖不属于仓库旧版或 main2 的同名文件：${SERVICE_FILE}"
      exit 1
    fi
  fi
  if [[ -e "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ]]; then
    if ! is_managed_config_file "${CONFIG_FILE}"; then
      red "拒绝覆盖格式不属于仓库旧版或 main2 的同名文件：${CONFIG_FILE}"
      exit 1
    fi
  fi
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
  elif [[ -n "${mss_value}" ]]; then
    red "自动 clamp 模式不能设置固定 MSS。"
    exit 1
  fi

  case "${clamp_forward}" in
    0|1) ;;
    *) red "CLAMP_FORWARD 必须是 0 或 1。"; exit 1 ;;
  esac
  case "${clamp_output}" in
    0|1) ;;
    *) red "CLAMP_OUTPUT 必须是 0 或 1。"; exit 1 ;;
  esac

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

load_config() {
  local mode mss_value
  local -a lines=()
  if [[ ! -e "${CONFIG_FILE}" && ! -L "${CONFIG_FILE}" ]]; then
    return 0
  fi
  if [[ ! -f "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ]]; then
    echo "Refusing to load non-regular file ${CONFIG_FILE}." >&2
    exit 1
  fi

  mapfile -t lines < "${CONFIG_FILE}"
  if (( ${#lines[@]} != 4 )); then
    echo "Invalid ${CONFIG_FILE} format." >&2
    exit 1
  fi
  if [[ ! "${lines[0]}" =~ ^MSS_MODE=(clamp|fixed)$ ]]; then
    echo "Invalid ${CONFIG_FILE} format." >&2
    exit 1
  fi
  mode="${BASH_REMATCH[1]}"
  if [[ "${lines[1]}" != MSS_VALUE=* ]] ||
     [[ ! "${lines[2]}" =~ ^CLAMP_FORWARD=[01]$ ]] ||
     [[ ! "${lines[3]}" =~ ^CLAMP_OUTPUT=[01]$ ]]; then
    echo "Invalid ${CONFIG_FILE} format." >&2
    exit 1
  fi

  mss_value="${lines[1]#MSS_VALUE=}"
  if [[ "${mode}" == "clamp" ]]; then
    [[ -z "${mss_value}" ]] || { echo "MSS_VALUE must be empty in clamp mode." >&2; exit 1; }
  elif [[ ! "${mss_value}" =~ ^(0|[1-9][0-9]{0,3})$ ]] ||
       (( 10#${mss_value} < 536 || 10#${mss_value} > 1460 )); then
    echo "MSS_VALUE must be 536-1460 in fixed mode." >&2
    exit 1
  fi

  MSS_MODE="${mode}"
  MSS_VALUE="${mss_value}"
  CLAMP_FORWARD="${lines[2]#CLAMP_FORWARD=}"
  CLAMP_OUTPUT="${lines[3]#CLAMP_OUTPUT=}"
}

load_config

ipt() {
  local family="$1"
  shift
  if [[ "${family}" == "v6" ]]; then
    ip6tables -w 10 "$@"
  else
    iptables -w 10 "$@"
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
  while ipt "${family}" -t mangle -C "${base_chain}" -j "${target_chain}" 2>/dev/null; do
    ipt "${family}" -t mangle -D "${base_chain}" -j "${target_chain}"
  done
  ipt "${family}" -t mangle -I "${base_chain}" 1 -j "${target_chain}"
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

if ! table_available v4; then
  echo "IPv4 mangle table is unavailable." >&2
  exit 1
fi

if [[ "${CLAMP_FORWARD}" == "0" && "${CLAMP_OUTPUT}" == "0" ]]; then
  delete_family v4
else
  apply_family v4
fi
delete_family v6

if [[ "${CLAMP_FORWARD}" == "1" ]]; then
  ipt v4 -t mangle -C FORWARD -j "${CHAIN_FORWARD}"
fi
if [[ "${CLAMP_OUTPUT}" == "1" ]]; then
  ipt v4 -t mangle -C OUTPUT -j "${CHAIN_OUTPUT}"
fi
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
  green "iptables 后端："
  iptables --version 2>/dev/null || true

  green "配置文件：${CONFIG_FILE}"
  if [[ -r "${CONFIG_FILE}" ]]; then
    cat "${CONFIG_FILE}"
  else
    yellow "暂无配置。"
  fi

  green "IPv4 mangle 规则："
  iptables -w 10 -t mangle -S "${CHAIN_FORWARD}" 2>/dev/null || true
  iptables -w 10 -t mangle -S "${CHAIN_OUTPUT}" 2>/dev/null || true

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
    yellow "适用于 Debian 或 Ubuntu 的中转、NAT、VPN、落地机场景。"
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
need_supported_os
require_runtime_paths_safe

case "${1:-menu}" in
  enable|clamp) enable_rules clamp ;;
  fixed) enable_rules fixed "${2:?mss_value}" ;;
  disable|clear) disable_rules ;;
  status) status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|enable|fixed <mss>|disable|status]"; exit 1 ;;
esac
