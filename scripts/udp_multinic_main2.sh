#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

CONFIG_DIR="/etc/udp-multinic"
CONFIG_FILE="${CONFIG_DIR}/rules.conf"
SYSCTL_FILE="/etc/sysctl.d/61-udp-multinic.conf"
APPLY_SCRIPT="/usr/local/sbin/udp-multinic-apply.sh"
SERVICE_FILE="/etc/systemd/system/udp-multinic.service"

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

require_config_paths_safe() {
  if [[ -L "${CONFIG_DIR}" || ( -e "${CONFIG_DIR}" && ! -d "${CONFIG_DIR}" ) ]]; then
    red "拒绝使用非真实目录：${CONFIG_DIR}"
    exit 1
  fi
  if [[ ( -e "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ) &&
        ( ! -f "${CONFIG_FILE}" || -L "${CONFIG_FILE}" ) ]]; then
    red "拒绝使用非普通规则文件：${CONFIG_FILE}"
    exit 1
  fi
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

require_runtime_paths_safe() {
  if [[ -e "${APPLY_SCRIPT}" || -L "${APPLY_SCRIPT}" ]]; then
    if ! file_sha256_is "${APPLY_SCRIPT}" b705ef4416d151e5269f238feda1a2a14fbf063afcb85c767244339380300a0d &&
       ! file_sha256_is "${APPLY_SCRIPT}" ff294f60fff80d303727ba7e75a7fdf7227a4c327e08304f2667100acacc7162 &&
       ! file_sha256_is "${APPLY_SCRIPT}" 4f094911fe1e2d4e0a528e17e0cc50e46045b76cb0e8bd563b0742d1ec7c054f; then
      red "拒绝覆盖不属于旧版或 main2 的同名文件：${APPLY_SCRIPT}"
      exit 1
    fi
  fi
  if [[ -e "${SERVICE_FILE}" || -L "${SERVICE_FILE}" ]]; then
    if ! file_sha256_is "${SERVICE_FILE}" 18a15a9d7663de9779eee0cb6ad9b09c0f1f0407401c2d40f4e6cb66875a2611 &&
       ! file_sha256_is "${SERVICE_FILE}" d4eaeadd2f155b831c44a65aba43297ad6eaa15c3b530be73afba65c823cc7a4; then
      red "拒绝覆盖不属于旧版或 main2 的同名文件：${SERVICE_FILE}"
      exit 1
    fi
  fi
  if [[ -e "${SYSCTL_FILE}" || -L "${SYSCTL_FILE}" ]]; then
    if ! file_sha256_is "${SYSCTL_FILE}" 1569eb1b5cdfcb20d405e167b52f6ea83ea3e6240366c6649b4d8d9f660d64d7 &&
       ! file_sha256_is "${SYSCTL_FILE}" c8c8cbd1560c9b5edf183bca4174734afca2d3e52a03922b0dc708fd43e1be15 &&
       ! file_sha256_is "${SYSCTL_FILE}" eac3e15d92ea1b5c6b07ba242cba835d146d412832f920aa3d89f7e680c135db; then
      red "拒绝覆盖不属于旧版或 main2 的同名文件：${SYSCTL_FILE}"
      exit 1
    fi
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends iptables iproute2 procps
}

detect_family() {
  local ip="$1"
  if [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    local IFS='.' octets octet
    read -r -a octets <<< "${ip}"
    for octet in "${octets[@]}"; do
      if [[ ! "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || (( 10#${octet} > 255 )); then
        echo invalid
        return 0
      fi
    done
    echo v4
    return 0
  fi

  if [[ "${ip}" == *:* ]]; then
    echo v6
    return 0
  fi

  echo invalid
}

validate_rule() {
  local src_ip="$1"
  local dst_ip="$2"
  local port="${3:-all}"
  local src_family dst_family

  src_family="$(detect_family "${src_ip}")"
  dst_family="$(detect_family "${dst_ip}")"

  if [[ "${src_family}" == "invalid" || "${dst_family}" == "invalid" ]]; then
    red "IP 地址格式无效。"
    exit 1
  fi

  if [[ "${src_family}" != "v4" || "${dst_family}" != "v4" ]]; then
    red "当前仓库强制关闭 IPv6。UDP 多网卡映射仅支持 IPv4->IPv4。"
    exit 1
  fi

  if [[ "${port}" != "all" && ! "${port}" =~ ^(0|[1-9][0-9]{0,4})$ ]]; then
    red "端口必须是数字，留空表示全部 UDP 端口。"
    exit 1
  fi

  if [[ "${port}" =~ ^(0|[1-9][0-9]{0,4})$ ]] && (( 10#${port} < 1 || 10#${port} > 65535 )); then
    red "端口范围必须是 1-65535。"
    exit 1
  fi
}

write_sysctl() {
  cat > "${SYSCTL_FILE}" <<'EOF'
# UDP multi-NIC address mapping needs asymmetric routing tolerance.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.promote_secondaries = 1
net.ipv4.conf.default.promote_secondaries = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF
  sysctl -e -p "${SYSCTL_FILE}"

  local rp_filter_file
  for rp_filter_file in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [[ -e "${rp_filter_file}" ]] || continue
    echo 0 > "${rp_filter_file}"
    if [[ "$(<"${rp_filter_file}")" != "0" ]]; then
      red "无法关闭 ${rp_filter_file}，UDP 多网卡映射不能安全启用。"
      exit 1
    fi
  done

  local promote_secondaries_file
  for promote_secondaries_file in /proc/sys/net/ipv4/conf/*/promote_secondaries; do
    [[ -e "${promote_secondaries_file}" ]] || continue
    echo 1 > "${promote_secondaries_file}"
    if [[ "$(<"${promote_secondaries_file}")" != "1" ]]; then
      red "无法启用 ${promote_secondaries_file}，不能安全替换同接口的主 IPv4。"
      exit 1
    fi
  done
}

write_apply_script() {
  install -d "${CONFIG_DIR}" "$(dirname "${APPLY_SCRIPT}")"
  touch "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"

  cat > "${APPLY_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/udp-multinic/rules.conf"

ipt() {
  local family="$1"
  shift
  if [[ "${family}" == "v6" ]]; then
    ip6tables -w 10 "$@"
  else
    iptables -w 10 "$@"
  fi
}

delete_prerouting_chain() {
  local family="$1"
  local chain="$2"
  ipt "${family}" -t nat -L >/dev/null 2>&1 || return 0
  while ipt "${family}" -t nat -C PREROUTING -j "${chain}" 2>/dev/null; do
    ipt "${family}" -t nat -D PREROUTING -j "${chain}" 2>/dev/null || break
  done
  ipt "${family}" -t nat -F "${chain}" 2>/dev/null || true
  ipt "${family}" -t nat -X "${chain}" 2>/dev/null || true
}

cleanup_legacy_post_chain() {
  local family="$1"
  ipt "${family}" -t nat -L >/dev/null 2>&1 || return 0
  while ipt "${family}" -t nat -C POSTROUTING -j UDP_MNIC_POST 2>/dev/null; do
    ipt "${family}" -t nat -D POSTROUTING -j UDP_MNIC_POST 2>/dev/null || break
  done
  ipt "${family}" -t nat -F UDP_MNIC_POST 2>/dev/null || true
  ipt "${family}" -t nat -X UDP_MNIC_POST 2>/dev/null || true
}

delete_chains() {
  local family="$1"
  delete_prerouting_chain "${family}" UDP_MNIC_PRE_NEW
  delete_prerouting_chain "${family}" UDP_MNIC_PRE
  cleanup_legacy_post_chain "${family}"
}

valid_ipv4() {
  local ip="$1"
  local IFS='.' octets octet
  [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  read -r -a octets <<< "${ip}"
  for octet in "${octets[@]}"; do
    [[ "${octet}" =~ ^(0|[1-9][0-9]{0,2})$ ]] || return 1
    (( 10#${octet} <= 255 )) || return 1
  done
}

valid_port() {
  local port="$1"
  [[ "${port}" == "all" ]] && return 0
  [[ "${port}" =~ ^(0|[1-9][0-9]{0,4})$ ]] || return 1
  (( 10#${port} >= 1 && 10#${port} <= 65535 ))
}

validate_config_rules() {
  local line family src_ip dst_ip port extra
  while IFS= read -r line || [[ -n "${line}" ]]; do
    read -r family src_ip dst_ip port extra <<< "${line}"
    [[ -z "${family:-}" || "${family}" == \#* ]] && continue
    port="${port:-all}"
    if [[ -n "${extra:-}" || "${family}" != "v4" || -z "${src_ip:-}" || -z "${dst_ip:-}" ]] ||
       ! valid_ipv4 "${src_ip}" || ! valid_ipv4 "${dst_ip}" || ! valid_port "${port}"; then
      echo "Invalid persisted UDP rule: ${line}" >&2
      exit 1
    fi
  done < "${CONFIG_FILE}"
}

prepare_staging_chain() {
  if ! ipt v4 -t nat -L >/dev/null 2>&1; then
    echo "IPv4 nat table is unavailable." >&2
    exit 1
  fi

  # A completed staging chain may remain active if the previous rename was interrupted.
  if ipt v4 -t nat -C PREROUTING -j UDP_MNIC_PRE_NEW 2>/dev/null; then
    while ipt v4 -t nat -C PREROUTING -j UDP_MNIC_PRE 2>/dev/null; do
      ipt v4 -t nat -D PREROUTING -j UDP_MNIC_PRE
    done
    ipt v4 -t nat -F UDP_MNIC_PRE 2>/dev/null || true
    ipt v4 -t nat -X UDP_MNIC_PRE 2>/dev/null || true
    if ! ipt v4 -t nat -E UDP_MNIC_PRE_NEW UDP_MNIC_PRE; then
      echo "Unable to finish the previous UDP chain switch; the complete staging chain remains active." >&2
      exit 1
    fi
  fi

  delete_prerouting_chain v4 UDP_MNIC_PRE_NEW
  ipt v4 -t nat -N UDP_MNIC_PRE_NEW
}

add_rule() {
  local chain="$1"
  local src_ip="$2"
  local dst_ip="$3"
  local port="$4"

  if [[ "${port}" == "all" ]]; then
    ipt v4 -t nat -A "${chain}" -p udp -d "${src_ip}" -j DNAT --to-destination "${dst_ip}"
  else
    ipt v4 -t nat -A "${chain}" -p udp -d "${src_ip}" --dport "${port}" -j DNAT --to-destination "${dst_ip}"
  fi
}

apply_config_rules() {
  local rule_kind="$1"
  local chain="$2"
  local line family src_ip dst_ip port extra
  while IFS= read -r line || [[ -n "${line}" ]]; do
    read -r family src_ip dst_ip port extra <<< "${line}"
    [[ -z "${family:-}" || "${family}" == \#* ]] && continue
    port="${port:-all}"
    if [[ "${rule_kind}" == "specific" && "${port}" == "all" ]]; then
      continue
    fi
    if [[ "${rule_kind}" == "all" && "${port}" != "all" ]]; then
      continue
    fi
    add_rule "${chain}" "${src_ip}" "${dst_ip}" "${port}"
  done < "${CONFIG_FILE}"
}

activate_staging_chain() {
  ipt v4 -t nat -I PREROUTING 1 -j UDP_MNIC_PRE_NEW
  while ipt v4 -t nat -C PREROUTING -j UDP_MNIC_PRE 2>/dev/null; do
    ipt v4 -t nat -D PREROUTING -j UDP_MNIC_PRE
  done
  ipt v4 -t nat -F UDP_MNIC_PRE 2>/dev/null || true
  ipt v4 -t nat -X UDP_MNIC_PRE 2>/dev/null || true
  ipt v4 -t nat -E UDP_MNIC_PRE_NEW UDP_MNIC_PRE
  cleanup_legacy_post_chain v4
}

if [[ ! -s "${CONFIG_FILE}" ]]; then
  delete_chains v4
  delete_chains v6
  exit 0
fi

validate_config_rules

modprobe nf_conntrack 2>/dev/null || true
modprobe nf_nat 2>/dev/null || true

delete_chains v6

for rp_filter_file in /proc/sys/net/ipv4/conf/*/rp_filter; do
  [[ -e "${rp_filter_file}" ]] || continue
  echo 0 > "${rp_filter_file}"
done

for promote_secondaries_file in /proc/sys/net/ipv4/conf/*/promote_secondaries; do
  [[ -e "${promote_secondaries_file}" ]] || continue
  echo 1 > "${promote_secondaries_file}"
  [[ "$(<"${promote_secondaries_file}")" == "1" ]]
done

if [[ -d /proc/sys/net/ipv6/conf ]]; then
  for disable_ipv6_file in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -e "${disable_ipv6_file}" ]] || continue
    echo 1 > "${disable_ipv6_file}"
    [[ "$(<"${disable_ipv6_file}")" == "1" ]]
  done
fi

prepare_staging_chain
apply_config_rules specific UDP_MNIC_PRE_NEW
apply_config_rules all UDP_MNIC_PRE_NEW
activate_staging_chain
EOF

  chmod 0755 "${APPLY_SCRIPT}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=UDP multi-NIC iptables address mapping
After=network-online.target network-optimization-sysctl.service network-max-tune.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable udp-multinic.service
}

install_base() {
  install_packages
  write_sysctl
  write_apply_script
  write_service
}

validate_config_rules() {
  local line family src_ip dst_ip port extra
  [[ -f "${CONFIG_FILE}" ]] || return 0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    read -r family src_ip dst_ip port extra <<< "${line}"
    [[ -z "${family:-}" || "${family}" == \#* ]] && continue
    if [[ -n "${extra:-}" || "${family}" != "v4" || -z "${src_ip:-}" || -z "${dst_ip:-}" ]]; then
      red "持久化 UDP 规则格式无效：${family:-} ${src_ip:-} ${dst_ip:-} ${port:-} ${extra:-}"
      exit 1
    fi
    validate_rule "${src_ip}" "${dst_ip}" "${port:-all}"
  done < "${CONFIG_FILE}"
}

migrate_rules() {
  if [[ ! -s "${CONFIG_FILE}" ]]; then
    clear_rules
    green "旧版 UDP 映射没有有效规则，旧服务和空链已清理。"
    return 0
  fi

  validate_config_rules
  install_base
  "${APPLY_SCRIPT}"
  systemctl restart udp-multinic.service
  systemctl is-active --quiet udp-multinic.service
  green "旧版 UDP 映射已保留规则并升级为 main2 实现。"
}

add_rule() {
  local src_ip="$1"
  local dst_ip="$2"
  local port="${3:-all}"
  local family line tmp replaced=0

  [[ -n "${port}" ]] || port="all"
  validate_rule "${src_ip}" "${dst_ip}" "${port}"
  family="$(detect_family "${src_ip}")"
  line="${family} ${src_ip} ${dst_ip} ${port}"

  install_base

  if grep -Fxq "${line}" "${CONFIG_FILE}"; then
    yellow "规则已存在：${line}"
  else
    tmp="$(mktemp)"
    awk -v rule_family="${family}" -v rule_src_ip="${src_ip}" -v rule_port="${port}" '
      !(NF >= 4 && $1 == rule_family && $2 == rule_src_ip && $4 == rule_port) { print }
    ' "${CONFIG_FILE}" > "${tmp}"
    if ! cmp -s "${tmp}" "${CONFIG_FILE}"; then
      replaced=1
    fi
    printf '%s\n' "${line}" >> "${tmp}"
    install -m 0644 "${tmp}" "${CONFIG_FILE}"
    rm -f "${tmp}"
    if [[ "${replaced}" == "1" ]]; then
      green "已替换相同入口 IPv4 和端口的旧规则：${line}"
    else
      green "已写入规则：${line}"
    fi
  fi

  "${APPLY_SCRIPT}"
  green "UDP 多网卡映射已应用。"
}

clear_rules() {
  if ! command -v iptables >/dev/null 2>&1; then
    install_packages
  fi
  install -d "${CONFIG_DIR}"
  touch "${CONFIG_FILE}"
  write_apply_script
  : > "${CONFIG_FILE}"
  "${APPLY_SCRIPT}"
  systemctl disable --now udp-multinic.service 2>/dev/null || true
  rm -f "${SYSCTL_FILE}" "${CONFIG_FILE}" "${APPLY_SCRIPT}" "${SERVICE_FILE}"
  systemctl daemon-reload
  if systemctl cat network-optimization-sysctl.service >/dev/null 2>&1; then
    systemctl restart network-optimization-sysctl.service
  fi
  green "UDP 多网卡映射规则、持久化配置和服务已清理。"
}

status() {
  green "iptables 后端："
  iptables --version 2>/dev/null || true

  green "持久化规则："
  if [[ -s "${CONFIG_FILE}" ]]; then
    cat "${CONFIG_FILE}"
  else
    yellow "暂无规则。"
  fi

  green "IPv4 UDP_MNIC_PRE："
  iptables -w 10 -t nat -S UDP_MNIC_PRE 2>/dev/null || true
  green "IPv6："
  yellow "默认关闭并清理，UDP 多网卡映射仅使用 IPv4。"
}

menu() {
  while true; do
    clear
    green "====================================="
    green " UDP 多网卡防丢包映射"
    green "====================================="
    printf " 1. 添加 UDP 地址映射\n"
    printf " 2. 查看规则\n"
    printf " 3. 清空本脚本创建的规则\n"
    printf " 0. 返回\n"
    printf "\n"
    yellow "说明：源 IP 和目标 IP 必须同为 IPv4；本仓库强制关闭 IPv6。"
    yellow "端口留空表示映射全部 UDP 端口。"
    printf "\n"
    if ! read -r -p "请输入数字: " num; then
      return 0
    fi
    case "${num}" in
      1)
        read -r -p "源 IP，本机入口/公网 IP: " src_ip
        read -r -p "目标 IP，本机另一网卡/落地 IP: " dst_ip
        read -r -p "UDP 端口，留空表示全部: " port
        add_rule "${src_ip}" "${dst_ip}" "${port:-all}"
        read -r -n 1 -s -p "按任意键继续..."
        printf "\n"
        ;;
      2) status; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      3) clear_rules; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      0) return 0 ;;
      *) red "请输入正确数字。"; sleep 1 ;;
    esac
  done
}

need_root
need_supported_os
require_config_paths_safe
require_runtime_paths_safe

case "${1:-menu}" in
  add) add_rule "${2:?src_ip}" "${3:?dst_ip}" "${4:-all}" ;;
  validate) validate_config_rules ;;
  migrate) migrate_rules ;;
  clear) clear_rules ;;
  status) status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|add <src_ip> <dst_ip> [udp_port]|validate|migrate|clear|status]"; exit 1 ;;
esac
