#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

CONFIG_DIR="/etc/udp-multinic"
CONFIG_FILE="${CONFIG_DIR}/rules.conf"
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
      if (( octet < 0 || octet > 255 )); then
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

  if [[ "${src_family}" != "${dst_family}" ]]; then
    red "iptables NAT 不适合直接做 IPv4/IPv6 跨协议 UDP 地址转换。"
    red "请使用同协议地址：IPv4->IPv4 或 IPv6->IPv6。"
    exit 1
  fi

  if [[ "${port}" != "all" && ! "${port}" =~ ^[0-9]+$ ]]; then
    red "端口必须是数字，留空表示全部 UDP 端口。"
    exit 1
  fi

  if [[ "${port}" =~ ^[0-9]+$ ]] && (( port < 1 || port > 65535 )); then
    red "端口范围必须是 1-65535。"
    exit 1
  fi
}

write_sysctl() {
  cat > /etc/sysctl.d/61-udp-multinic.conf <<'EOF'
# UDP multi-NIC address mapping needs asymmetric routing tolerance.
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
EOF
  sysctl --system
}

write_apply_script() {
  install -d "${CONFIG_DIR}" "$(dirname "${APPLY_SCRIPT}")"
  touch "${CONFIG_FILE}"
  chmod 0644 "${CONFIG_FILE}"

  cat > "${APPLY_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/udp-multinic/rules.conf"

detect_family() {
  local ip="$1"
  if [[ "${ip}" == *:* ]]; then
    echo v6
  else
    echo v4
  fi
}

ipt() {
  local family="$1"
  shift
  if [[ "${family}" == "v6" ]]; then
    ip6tables "$@"
  else
    iptables "$@"
  fi
}

ensure_chain() {
  local family="$1"
  ipt "${family}" -t nat -L >/dev/null 2>&1 || return 0
  ipt "${family}" -t nat -N UDP_MNIC_PRE 2>/dev/null || true
  ipt "${family}" -t nat -N UDP_MNIC_POST 2>/dev/null || true
  ipt "${family}" -t nat -C PREROUTING -j UDP_MNIC_PRE 2>/dev/null || ipt "${family}" -t nat -A PREROUTING -j UDP_MNIC_PRE
  ipt "${family}" -t nat -C POSTROUTING -j UDP_MNIC_POST 2>/dev/null || ipt "${family}" -t nat -A POSTROUTING -j UDP_MNIC_POST
}

flush_chains() {
  for family in v4 v6; do
    ensure_chain "${family}"
    ipt "${family}" -t nat -F UDP_MNIC_PRE 2>/dev/null || true
    ipt "${family}" -t nat -F UDP_MNIC_POST 2>/dev/null || true
  done
}

add_rule() {
  local family="$1"
  local src_ip="$2"
  local dst_ip="$3"
  local port="$4"

  ensure_chain "${family}"

  if [[ "${port}" == "all" ]]; then
    ipt "${family}" -t nat -A UDP_MNIC_PRE -p udp -d "${src_ip}" -j DNAT --to-destination "${dst_ip}"
    ipt "${family}" -t nat -A UDP_MNIC_POST -p udp -s "${dst_ip}" -j SNAT --to-source "${src_ip}"
  else
    ipt "${family}" -t nat -A UDP_MNIC_PRE -p udp -d "${src_ip}" --dport "${port}" -j DNAT --to-destination "${dst_ip}"
    ipt "${family}" -t nat -A UDP_MNIC_POST -p udp -s "${dst_ip}" --sport "${port}" -j SNAT --to-source "${src_ip}"
  fi
}

modprobe nf_conntrack 2>/dev/null || true
modprobe nf_nat 2>/dev/null || true
modprobe nf_nat_ipv6 2>/dev/null || true

flush_chains

[[ -f "${CONFIG_FILE}" ]] || exit 0
while read -r family src_ip dst_ip port; do
  [[ -z "${family:-}" || "${family}" == \#* ]] && continue
  add_rule "${family}" "${src_ip}" "${dst_ip}" "${port:-all}"
done < "${CONFIG_FILE}"
EOF

  chmod 0755 "${APPLY_SCRIPT}"
}

write_service() {
  cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=UDP multi-NIC iptables address mapping
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
  systemctl enable udp-multinic.service
}

install_base() {
  install_packages
  write_sysctl
  write_apply_script
  write_service
}

add_rule() {
  local src_ip="$1"
  local dst_ip="$2"
  local port="${3:-all}"
  local family line

  [[ -n "${port}" ]] || port="all"
  validate_rule "${src_ip}" "${dst_ip}" "${port}"
  family="$(detect_family "${src_ip}")"
  line="${family} ${src_ip} ${dst_ip} ${port}"

  install_base

  if grep -Fxq "${line}" "${CONFIG_FILE}"; then
    yellow "规则已存在：${line}"
  else
    printf '%s\n' "${line}" >> "${CONFIG_FILE}"
    green "已写入规则：${line}"
  fi

  "${APPLY_SCRIPT}"
  green "UDP 多网卡映射已应用。"
}

clear_rules() {
  install_base
  : > "${CONFIG_FILE}"
  "${APPLY_SCRIPT}"
  green "UDP 多网卡映射规则已清空。"
}

status() {
  green "持久化规则："
  if [[ -s "${CONFIG_FILE}" ]]; then
    cat "${CONFIG_FILE}"
  else
    yellow "暂无规则。"
  fi

  green "IPv4 UDP_MNIC_PRE："
  iptables -t nat -S UDP_MNIC_PRE 2>/dev/null || true
  green "IPv4 UDP_MNIC_POST："
  iptables -t nat -S UDP_MNIC_POST 2>/dev/null || true
  green "IPv6 UDP_MNIC_PRE："
  ip6tables -t nat -S UDP_MNIC_PRE 2>/dev/null || true
  green "IPv6 UDP_MNIC_POST："
  ip6tables -t nat -S UDP_MNIC_POST 2>/dev/null || true
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
    yellow "说明：源 IP 和目标 IP 必须同为 IPv4 或同为 IPv6。"
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
need_debian

case "${1:-menu}" in
  add) add_rule "${2:?src_ip}" "${3:?dst_ip}" "${4:-all}" ;;
  clear) clear_rules ;;
  status) status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|add <src_ip> <dst_ip> [udp_port]|clear|status]"; exit 1 ;;
esac
