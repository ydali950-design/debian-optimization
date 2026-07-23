#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "This script only supports Debian or Ubuntu."
  exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
  debian|ubuntu) ;;
  *) echo "This script only supports Debian or Ubuntu. Current system ID=${ID:-unknown}."; exit 1 ;;
esac
OS_PRETTY_NAME="${PRETTY_NAME:-${ID}}"

BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_MB="$((MEM_KB / 1024))"
CPU_COUNT="$(nproc 2>/dev/null || echo 1)"
SYSCTL_FILE="/etc/sysctl.d/99-network-optimization.conf"
LIMITS_FILE="/etc/security/limits.d/99-network-optimization.conf"
SYSCTL_APPLY_SCRIPT="/usr/local/sbin/network-optimization-sysctl.sh"
SYSCTL_SERVICE_FILE="/etc/systemd/system/network-optimization-sysctl.service"
SYSCTL_DEFAULT_FILE="/etc/default/network-optimization-sysctl"
NETWORK_TUNE_DEFAULT_FILE="/etc/default/network-max-tune"
NETWORK_TUNE_SCRIPT="/usr/local/sbin/network-max-tune.sh"
NETWORK_TUNE_SERVICE_FILE="/etc/systemd/system/network-max-tune.service"
PORT_RANGE_WAS_MANAGED=0
LEGACY_PORT_RANGE_REMOVED=0

if [[ -L "${SYSCTL_FILE}" ]]; then
  SYSCTL_LINK_TARGET="$(readlink -- "${SYSCTL_FILE}")"
  if [[ "${SYSCTL_LINK_TARGET}" != "/etc/sysctl.conf" ]]; then
    echo "Refusing to replace unexpected symlink ${SYSCTL_FILE} -> ${SYSCTL_LINK_TARGET}."
    exit 1
  fi
fi

max_int() {
  if (( "$1" > "$2" )); then
    echo "$1"
  else
    echo "$2"
  fi
}

min_int() {
  if (( "$1" < "$2" )); then
    echo "$1"
  else
    echo "$2"
  fi
}

require_positive_decimal() {
  local name="$1"
  local value="$2"
  if [[ ! "${value}" =~ ^[1-9][0-9]{0,9}$ ]]; then
    echo "${name} must be a positive decimal integer with at most 10 digits. Current value=${value}."
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

preflight_network_tune_paths() {
  if [[ ! -e "${NETWORK_TUNE_DEFAULT_FILE}" && ! -L "${NETWORK_TUNE_DEFAULT_FILE}" &&
        ! -e "${NETWORK_TUNE_SCRIPT}" && ! -L "${NETWORK_TUNE_SCRIPT}" &&
        ! -e "${NETWORK_TUNE_SERVICE_FILE}" && ! -L "${NETWORK_TUNE_SERVICE_FILE}" ]]; then
    return 0
  fi

  if [[ ( -e "${NETWORK_TUNE_DEFAULT_FILE}" || -L "${NETWORK_TUNE_DEFAULT_FILE}" ) &&
        ( ! -f "${NETWORK_TUNE_DEFAULT_FILE}" || -L "${NETWORK_TUNE_DEFAULT_FILE}" ) ]]; then
    echo "Refusing to replace non-regular file ${NETWORK_TUNE_DEFAULT_FILE}."
    exit 1
  fi

  if file_sha256_is "${NETWORK_TUNE_SCRIPT}" ff055ea655d1e0bb358668575cc177529b537e7aa79600e1bb177290a6d5930e &&
     file_sha256_is "${NETWORK_TUNE_SERVICE_FILE}" 95e083a80521a871fe467b3dc804ff28ab4f001269d8876a536234c7b60552a9; then
    return 0
  fi

  if { file_sha256_is "${NETWORK_TUNE_SCRIPT}" 81bfc014065899e0e32e77a0ae6a0c2abeabd0793c76d231429835205733edb0 ||
       file_sha256_is "${NETWORK_TUNE_SCRIPT}" 6f8ba0c035cacbf9d32ed309a866edccef5e0b40366cd0c754386a41f273f0c3; } &&
     file_sha256_is "${NETWORK_TUNE_SERVICE_FILE}" b6b1d82eb6e297618575dc25e75dc9a22b21df1c77fa9359b2631325dc81565a; then
    return 0
  fi

  echo "Refusing to replace network-max-tune files that are not owned by the legacy script or main2."
  exit 1
}

backup_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${path}.bak.${BACKUP_SUFFIX}"
  fi
}

migrate_legacy_sysctl() {
  local legacy_file="/etc/sysctl.conf"
  local legacy_header
  local tmp

  [[ -f "${legacy_file}" ]] || return 0
  legacy_header="$(head -n 1 "${legacy_file}")"
  case "${legacy_header}" in
    "# Debian relay / VPN landing host balanced-max network optimization."|\
    "# Debian / Ubuntu relay / VPN landing host balanced-max network optimization.") ;;
    *) return 0 ;;
  esac

  if grep -Eq '^[[:space:]]*net\.ipv4\.ip_local_port_range[[:space:]]*=' "${legacy_file}"; then
    LEGACY_PORT_RANGE_REMOVED=1
  fi
  backup_file "${legacy_file}"
  tmp="$(mktemp)"
  awk '
    BEGIN {
      managed["net.ipv4.tcp_no_metrics_save"] = 1
      managed["net.ipv4.ipfrag_low_thresh"] = 1
      managed["net.ipv4.ip_local_port_range"] = 1
    }
    NR == FNR {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line !~ /^#/ && line ~ /^[[:alnum:]_.-]+[[:space:]]*=/) {
        split(line, fields, /[[:space:]=]+/)
        managed[fields[1]] = 1
      }
      next
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (FNR == 1 &&
          (line == "# Debian relay / VPN landing host balanced-max network optimization." ||
           line == "# Debian / Ubuntu relay / VPN landing host balanced-max network optimization.")) {
        next
      }
      split(line, fields, /[[:space:]=]+/)
      if (line !~ /^#/ && fields[1] in managed) {
        next
      }
      print
    }
  ' "${SYSCTL_FILE}" "${legacy_file}" > "${tmp}"
  install -m 0644 "${tmp}" "${legacy_file}"
  rm -f "${tmp}"
  echo "Migrated legacy managed sysctl keys from ${legacy_file}; backup suffix: .bak.${BACKUP_SUFFIX}"
}

auto_socket_buffer_max() {
  local value
  if (( MEM_MB < 1024 )); then
    value=16777216
  elif (( MEM_MB < 2048 )); then
    value=33554432
  elif (( MEM_MB < 4096 )); then
    value=67108864
  elif (( MEM_MB < 8192 )); then
    value=134217728
  else
    value=268435456
  fi

  if [[ "${PROFILE}" == "max" ]]; then
    value="$(min_int "$((value * 2))" 268435456)"
  fi
  echo "${value}"
}

auto_conntrack_max() {
  local per_mb minimum maximum
  if [[ "${PROFILE}" == "max" ]]; then
    per_mb=256
    minimum=131072
    maximum=2097152
  else
    per_mb=128
    minimum=65536
    maximum=2097152
  fi
  min_int "$(max_int "$((MEM_MB * per_mb))" "${minimum}")" "${maximum}"
}

auto_netdev_backlog() {
  local per_cpu minimum maximum
  if [[ "${PROFILE}" == "max" ]]; then
    per_cpu=8192
    minimum=16384
    maximum=65536
  else
    per_cpu=4096
    minimum=8192
    maximum=32768
  fi
  min_int "$(max_int "$((CPU_COUNT * per_cpu))" "${minimum}")" "${maximum}"
}

auto_rps_flow_entries() {
  local per_cpu maximum
  if [[ "${PROFILE}" == "max" ]]; then
    per_cpu=8192
    maximum=131072
  else
    per_cpu=4096
    maximum=65536
  fi
  min_int "$(max_int "$((CPU_COUNT * per_cpu))" 16384)" "${maximum}"
}

auto_tcp_max_tw_buckets() {
  local per_mb minimum maximum
  if [[ "${PROFILE}" == "max" ]]; then
    per_mb=512
    minimum=524288
    maximum=4194304
  else
    per_mb=256
    minimum=262144
    maximum=2097152
  fi
  min_int "$(max_int "$((MEM_MB * per_mb))" "${minimum}")" "${maximum}"
}

# balanced: high throughput, safer memory use for 1G-4G VPS.
# max: more aggressive buffers/queues for speed tests and 4G+ memory hosts.
PROFILE="${PROFILE:-balanced}"
case "${PROFILE}" in
  balanced|max) ;;
  *) echo "PROFILE must be balanced or max. Current value=${PROFILE}."; exit 1 ;;
esac

TIMEZONE="${TIMEZONE:-}"
VALIDATE_ONLY="${VALIDATE_ONLY:-0}"
FORMAT_XVDB="${FORMAT_XVDB:-0}"
ENABLE_NIC_TUNING="${ENABLE_NIC_TUNING:-1}"
MAXIMIZE_NIC_RING="${MAXIMIZE_NIC_RING:-0}"
case "${VALIDATE_ONLY}" in
  0|1) ;;
  *) echo "VALIDATE_ONLY must be 0 or 1. Current value=${VALIDATE_ONLY}."; exit 1 ;;
esac
case "${FORMAT_XVDB}" in
  0|1) ;;
  *) echo "FORMAT_XVDB must be 0 or 1. Current value=${FORMAT_XVDB}."; exit 1 ;;
esac
if [[ "${FORMAT_XVDB}" == "1" && ! -b /dev/xvdb ]]; then
  echo "/dev/xvdb does not exist."
  exit 1
fi
case "${ENABLE_NIC_TUNING}" in
  0|1) ;;
  *) echo "ENABLE_NIC_TUNING must be 0 or 1. Current value=${ENABLE_NIC_TUNING}."; exit 1 ;;
esac
case "${MAXIMIZE_NIC_RING}" in
  0|1) ;;
  *) echo "MAXIMIZE_NIC_RING must be 0 or 1. Current value=${MAXIMIZE_NIC_RING}."; exit 1 ;;
esac

# 0 is best for VPN/tunnel/asymmetric routing compatibility. Use 2 for loose RPF.
RP_FILTER="${RP_FILTER:-0}"
case "${RP_FILTER}" in
  0|1|2) ;;
  *) echo "RP_FILTER must be 0, 1, or 2. Current value=${RP_FILTER}."; exit 1 ;;
esac
if [[ "${RP_FILTER}" != "0" && -s /etc/udp-multinic/rules.conf ]]; then
  echo "RP_FILTER must be 0 while /etc/udp-multinic/rules.conf contains active UDP mappings."
  exit 1
fi

if [[ "${PROFILE}" == "max" ]]; then
  SOCKET_BUFFER_DEFAULT="${SOCKET_BUFFER_DEFAULT:-524288}"
  SOCKET_BUFFER_MAX="${SOCKET_BUFFER_MAX:-$(auto_socket_buffer_max)}"
  NETDEV_MAX_BACKLOG="${NETDEV_MAX_BACKLOG:-$(auto_netdev_backlog)}"
  NETDEV_BUDGET="${NETDEV_BUDGET:-600}"
  NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-4000}"
  RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-$(auto_rps_flow_entries)}"
  TXQUEUELEN="${TXQUEUELEN:-5000}"
  TCP_MAX_TW_BUCKETS="${TCP_MAX_TW_BUCKETS:-$(auto_tcp_max_tw_buckets)}"
  TCP_MAX_SYN_BACKLOG="${TCP_MAX_SYN_BACKLOG:-131072}"
  IPFRAG_HIGH_THRESH="${IPFRAG_HIGH_THRESH:-67108864}"
else
  SOCKET_BUFFER_DEFAULT="${SOCKET_BUFFER_DEFAULT:-262144}"
  SOCKET_BUFFER_MAX="${SOCKET_BUFFER_MAX:-$(auto_socket_buffer_max)}"
  NETDEV_MAX_BACKLOG="${NETDEV_MAX_BACKLOG:-$(auto_netdev_backlog)}"
  NETDEV_BUDGET="${NETDEV_BUDGET:-300}"
  NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-2000}"
  RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-$(auto_rps_flow_entries)}"
  TXQUEUELEN="${TXQUEUELEN:-2000}"
  TCP_MAX_TW_BUCKETS="${TCP_MAX_TW_BUCKETS:-$(auto_tcp_max_tw_buckets)}"
  TCP_MAX_SYN_BACKLOG="${TCP_MAX_SYN_BACKLOG:-65536}"
  IPFRAG_HIGH_THRESH="${IPFRAG_HIGH_THRESH:-33554432}"
fi

NOFILE_LIMIT="${NOFILE_LIMIT:-1048576}"
FILE_MAX="${FILE_MAX:-4194304}"
NF_CONNTRACK_MAX="${NF_CONNTRACK_MAX:-$(auto_conntrack_max)}"
NF_CONNTRACK_HASH_SIZE="${NF_CONNTRACK_HASH_SIZE:-}"
for numeric_name in \
  SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
  NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
  TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX NF_CONNTRACK_MAX; do
  require_positive_decimal "${numeric_name}" "${!numeric_name}"
done
if [[ -z "${NF_CONNTRACK_HASH_SIZE}" ]]; then
  NF_CONNTRACK_HASH_SIZE="$((NF_CONNTRACK_MAX / 4))"
fi
require_positive_decimal NF_CONNTRACK_HASH_SIZE "${NF_CONNTRACK_HASH_SIZE}"

IP_LOCAL_PORT_RANGE="${IP_LOCAL_PORT_RANGE:-}"
if [[ -n "${IP_LOCAL_PORT_RANGE}" ]]; then
  read -r IP_LOCAL_PORT_START IP_LOCAL_PORT_END IP_LOCAL_PORT_EXTRA <<< "${IP_LOCAL_PORT_RANGE}"
  if [[ -n "${IP_LOCAL_PORT_EXTRA:-}" ]] ||
     ! [[ "${IP_LOCAL_PORT_START:-}" =~ ^(0|[1-9][0-9]{0,4})$ && "${IP_LOCAL_PORT_END:-}" =~ ^(0|[1-9][0-9]{0,4})$ ]] ||
     (( 10#${IP_LOCAL_PORT_START} < 1 || 10#${IP_LOCAL_PORT_END} > 65535 || 10#${IP_LOCAL_PORT_START} >= 10#${IP_LOCAL_PORT_END} )); then
    echo "IP_LOCAL_PORT_RANGE must contain two integers within 1-65535. Current value=${IP_LOCAL_PORT_RANGE}."
    exit 1
  fi
fi

if [[ -n "${TIMEZONE}" ]]; then
  command -v timedatectl >/dev/null 2>&1 || {
    echo "TIMEZONE requires timedatectl."
    exit 1
  }
  if ! timedatectl list-timezones | awk -v timezone="${TIMEZONE}" '$0 == timezone { found = 1 } END { exit !found }'; then
    echo "TIMEZONE is not present in timedatectl list-timezones. Current value=${TIMEZONE}."
    exit 1
  fi
fi

if [[ -f "${SYSCTL_FILE}" && ! -L "${SYSCTL_FILE}" ]]; then
  IFS= read -r SYSCTL_FIRST_LINE < "${SYSCTL_FILE}" || true
  if [[ "${SYSCTL_FIRST_LINE:-}" == "# Debian / Ubuntu userspace TCP/UDP relay and proxy endpoint optimization." ]] &&
     grep -Eq '^[[:space:]]*net\.ipv4\.ip_local_port_range[[:space:]]*=' "${SYSCTL_FILE}"; then
    PORT_RANGE_WAS_MANAGED=1
  fi
fi

preflight_network_tune_paths

if [[ "${VALIDATE_ONLY}" == "1" ]]; then
  echo "Validation passed. No system changes were made."
  exit 0
fi

# Config overwrite is reversible; mkfs is not. Keep disk formatting opt-in.
if [[ "${FORMAT_XVDB}" == "1" ]]; then
  mkfs.ext4 -F /dev/xvdb -N 5359296
fi

if [[ -n "${TIMEZONE}" ]]; then
  timedatectl set-timezone "${TIMEZONE}"
fi

backup_file /etc/gai.conf
touch /etc/gai.conf
sed -i '/^[[:space:]#]*precedence[[:space:]]\+::ffff:0:0\/96[[:space:]]/d' /etc/gai.conf
cat >> /etc/gai.conf <<'EOF'

# Prefer IPv4-mapped addresses for relay/VPN landing hosts.
precedence ::ffff:0:0/96 100
EOF

cleanup_ip6_chain() {
  local table="$1"
  local base_chain="$2"
  local custom_chain="$3"
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -w 10 -t "${table}" -L >/dev/null 2>&1 || return 0
  while ip6tables -w 10 -t "${table}" -C "${base_chain}" -j "${custom_chain}" 2>/dev/null; do
    ip6tables -w 10 -t "${table}" -D "${base_chain}" -j "${custom_chain}" 2>/dev/null || break
  done
  ip6tables -w 10 -t "${table}" -F "${custom_chain}" 2>/dev/null || true
  ip6tables -w 10 -t "${table}" -X "${custom_chain}" 2>/dev/null || true
}

cleanup_ip6_chain mangle FORWARD MSS_FIX_FORWARD
cleanup_ip6_chain mangle OUTPUT MSS_FIX_OUTPUT
cleanup_ip6_chain nat PREROUTING UDP_MNIC_PRE
cleanup_ip6_chain nat POSTROUTING UDP_MNIC_POST

install -d /etc/modprobe.d /etc/modules-load.d
cat > /etc/modprobe.d/99-network-optimization.conf <<EOF
options nf_conntrack hashsize=${NF_CONNTRACK_HASH_SIZE}
EOF

cat > /etc/modules-load.d/99-network-optimization.conf <<'EOF'
tcp_bbr
sch_fq
nf_conntrack
EOF

modprobe tcp_bbr || true
modprobe sch_fq || true
modprobe nf_conntrack || true

TCP_CC="bbr"
if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
   ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
fi

install -d /etc/security/limits.d
backup_file "${LIMITS_FILE}"
cat > "${LIMITS_FILE}" <<EOF
*    soft    nofile    ${NOFILE_LIMIT}
*    hard    nofile    ${NOFILE_LIMIT}
root soft    nofile    ${NOFILE_LIMIT}
root hard    nofile    ${NOFILE_LIMIT}
EOF

install -d /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
EOF

cat > /etc/systemd/user.conf.d/99-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
EOF

cat > /etc/profile.d/99-ulimit.sh <<EOF
ulimit -SHn ${NOFILE_LIMIT} 2>/dev/null || true
EOF
chmod 0644 /etc/profile.d/99-ulimit.sh

if [[ -L "${SYSCTL_FILE}" ]]; then
  SYSCTL_LINK_TARGET="$(readlink -- "${SYSCTL_FILE}")"
  if [[ "${SYSCTL_LINK_TARGET}" != "/etc/sysctl.conf" ]]; then
    echo "Refusing to replace unexpected symlink ${SYSCTL_FILE} -> ${SYSCTL_LINK_TARGET}."
    exit 1
  fi
  backup_file "${SYSCTL_FILE}"
  rm -f "${SYSCTL_FILE}"
fi
backup_file "${SYSCTL_FILE}"
cat > "${SYSCTL_FILE}" <<EOF
# Debian / Ubuntu userspace TCP/UDP relay and proxy endpoint optimization.

# Routing and forwarding
net.ipv4.ip_forward = 1
net.ipv4.ip_nonlocal_bind = 1
net.ipv4.conf.all.forwarding = 1
net.ipv4.conf.default.forwarding = 1

# Forwarding host hardening
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.rp_filter = ${RP_FILTER}
net.ipv4.conf.default.rp_filter = ${RP_FILTER}
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.default.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.all.promote_secondaries = 1
net.ipv4.conf.default.promote_secondaries = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Queueing and congestion control
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = ${TCP_CC}
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_window_scaling = 1

# Packet processing budget
net.core.netdev_max_backlog = ${NETDEV_MAX_BACKLOG}
net.core.netdev_budget = ${NETDEV_BUDGET}
net.core.netdev_budget_usecs = ${NETDEV_BUDGET_USECS}
net.core.dev_weight = 64
net.core.rps_sock_flow_entries = ${RPS_FLOW_ENTRIES}

# Connection queues
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = ${TCP_MAX_SYN_BACKLOG}
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_abort_on_overflow = 0

# TCP behavior for relay/proxy workloads
net.ipv4.tcp_fin_timeout = 20
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 15
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW_BUCKETS}
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# Socket buffers. Moderate defaults, high autotuning ceilings.
net.core.rmem_default = ${SOCKET_BUFFER_DEFAULT}
net.core.wmem_default = ${SOCKET_BUFFER_DEFAULT}
net.core.rmem_max = ${SOCKET_BUFFER_MAX}
net.core.wmem_max = ${SOCKET_BUFFER_MAX}
net.core.optmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 ${SOCKET_BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 65536 ${SOCKET_BUFFER_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Fragment queues. Correct tunnel MTU/MSS is still better than fragmentation.
net.ipv4.ipfrag_high_thresh = ${IPFRAG_HIGH_THRESH}
net.ipv4.ipfrag_time = 30

# Neighbor cache for many clients/peers
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536

# Netfilter conntrack for NAT/VPN gateways
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 300
net.netfilter.nf_conntrack_generic_timeout = 120

# File handles
fs.file-max = ${FILE_MAX}
fs.nr_open = ${NOFILE_LIMIT}

# VM
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
EOF

if [[ -n "${IP_LOCAL_PORT_RANGE}" ]]; then
  cat >> "${SYSCTL_FILE}" <<EOF

# Explicit local port range. Keep it separate from relay listening port segments.
net.ipv4.ip_local_port_range = ${IP_LOCAL_PORT_START} ${IP_LOCAL_PORT_END}
EOF
fi

cat >> "${SYSCTL_FILE}" <<EOF

# IPv6 disabled. This profile is IPv4-first for relay/VPN landing hosts.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.default.forwarding = 0
EOF

if [[ -e /proc/sys/net/mptcp/enabled ]]; then
  cat >> "${SYSCTL_FILE}" <<'EOF'

# Enable MPTCP for userspace relays that explicitly request MPTCP sockets.
net.mptcp.enabled = 1
EOF
fi

migrate_legacy_sysctl

install -d "$(dirname "${SYSCTL_APPLY_SCRIPT}")" "$(dirname "${SYSCTL_SERVICE_FILE}")" "$(dirname "${SYSCTL_DEFAULT_FILE}")"
cat > "${SYSCTL_DEFAULT_FILE}" <<EOF
NF_CONNTRACK_HASH_SIZE=${NF_CONNTRACK_HASH_SIZE}
EOF
chmod 0644 "${SYSCTL_DEFAULT_FILE}"

cat > "${SYSCTL_APPLY_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SYSCTL_FILE="/etc/sysctl.d/99-network-optimization.conf"
SYSCTL_DEFAULT_FILE="/etc/default/network-optimization-sysctl"

if [[ -r "${SYSCTL_DEFAULT_FILE}" ]]; then
  # shellcheck disable=SC1090
  . "${SYSCTL_DEFAULT_FILE}"
fi
: "${NF_CONNTRACK_HASH_SIZE:?Missing NF_CONNTRACK_HASH_SIZE in ${SYSCTL_DEFAULT_FILE}}"

verify_sysctl_value() {
  local key="$1"
  local expected="$2"
  local actual
  actual="$(sysctl -n "${key}" 2>/dev/null || true)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "Failed to apply ${key}: expected=${expected} actual=${actual:-unavailable}." >&2
    exit 1
  fi
}

sysctl -e -p "${SYSCTL_FILE}"
verify_sysctl_value net.ipv4.ip_forward 1

modprobe nf_conntrack 2>/dev/null || true
if [[ -e /sys/module/nf_conntrack/parameters/hashsize ]]; then
  if [[ ! -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
    echo "Cannot write /sys/module/nf_conntrack/parameters/hashsize." >&2
    exit 1
  fi
  echo "${NF_CONNTRACK_HASH_SIZE}" > /sys/module/nf_conntrack/parameters/hashsize
  NF_CONNTRACK_HASH_SIZE_ACTUAL="$(</sys/module/nf_conntrack/parameters/hashsize)"
  if [[ ! "${NF_CONNTRACK_HASH_SIZE_ACTUAL}" =~ ^[1-9][0-9]*$ ]] ||
     (( 10#${NF_CONNTRACK_HASH_SIZE_ACTUAL} < 10#${NF_CONNTRACK_HASH_SIZE} )); then
    echo "Failed to apply nf_conntrack hashsize at least ${NF_CONNTRACK_HASH_SIZE}; actual=${NF_CONNTRACK_HASH_SIZE_ACTUAL}." >&2
    exit 1
  fi
fi

RP_FILTER="$(sysctl -n net.ipv4.conf.all.rp_filter)"
for rp_filter_file in /proc/sys/net/ipv4/conf/*/rp_filter; do
  [[ -e "${rp_filter_file}" ]] || continue
  echo "${RP_FILTER}" > "${rp_filter_file}"
  if [[ "$(<"${rp_filter_file}")" != "${RP_FILTER}" ]]; then
    echo "Failed to apply RP_FILTER=${RP_FILTER} to ${rp_filter_file}." >&2
    exit 1
  fi
done

for promote_secondaries_file in /proc/sys/net/ipv4/conf/*/promote_secondaries; do
  [[ -e "${promote_secondaries_file}" ]] || continue
  echo 1 > "${promote_secondaries_file}"
  if [[ "$(<"${promote_secondaries_file}")" != "1" ]]; then
    echo "Failed to enable ${promote_secondaries_file}." >&2
    exit 1
  fi
done

if [[ -d /proc/sys/net/ipv6/conf ]]; then
  for disable_ipv6_file in /proc/sys/net/ipv6/conf/*/disable_ipv6; do
    [[ -e "${disable_ipv6_file}" ]] || continue
    echo 1 > "${disable_ipv6_file}"
    if [[ "$(<"${disable_ipv6_file}")" != "1" ]]; then
      echo "Failed to disable IPv6 through ${disable_ipv6_file}." >&2
      exit 1
    fi
  done
  verify_sysctl_value net.ipv6.conf.all.disable_ipv6 1
  verify_sysctl_value net.ipv6.conf.default.disable_ipv6 1
  verify_sysctl_value net.ipv6.conf.lo.disable_ipv6 1
fi
EOF
chmod 0755 "${SYSCTL_APPLY_SCRIPT}"

cat > "${SYSCTL_SERVICE_FILE}" <<EOF
[Unit]
Description=Apply userspace relay/proxy network sysctls after distribution defaults
After=systemd-sysctl.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=${SYSCTL_APPLY_SCRIPT}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

if [[ "${ENABLE_NIC_TUNING}" == "1" ]]; then
  install -d /usr/local/sbin /etc/default
  backup_file "${NETWORK_TUNE_DEFAULT_FILE}"
  cat > "${NETWORK_TUNE_DEFAULT_FILE}" <<EOF
TXQUEUELEN=${TXQUEUELEN}
RPS_FLOW_ENTRIES=${RPS_FLOW_ENTRIES}
RP_FILTER=${RP_FILTER}
MAXIMIZE_NIC_RING=${MAXIMIZE_NIC_RING}
EOF

  cat > "${NETWORK_TUNE_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TXQUEUELEN="${TXQUEUELEN:-5000}"
RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-16384}"
RP_FILTER="${RP_FILTER:-0}"
MAXIMIZE_NIC_RING="${MAXIMIZE_NIC_RING:-0}"

expand_cpu_list() {
  local cpu_list="$1"
  local part first last cpu
  local IFS=','
  for part in ${cpu_list}; do
    if [[ "${part}" == *-* ]]; then
      first="${part%-*}"
      last="${part#*-}"
      for (( cpu=first; cpu<=last; cpu++ )); do
        echo "${cpu}"
      done
    else
      echo "${part}"
    fi
  done
}

CPU_ALLOWED_LIST="$(awk '/^Cpus_allowed_list:/ {print $2}' /proc/self/status)"
mapfile -t CPU_IDS < <(expand_cpu_list "${CPU_ALLOWED_LIST}")
CPU_COUNT="${#CPU_IDS[@]}"
if (( CPU_COUNT == 0 )); then
  CPU_IDS=(0)
  CPU_COUNT=1
fi
MAX_CPU_ID="${CPU_IDS[$((CPU_COUNT - 1))]}"

cpu_group_mask() {
  local group_index="$1"
  local group_count="$2"
  local chunks_count cpu chunk bit position i out="" formatted
  local -a chunks=()

  chunks_count="$(( (MAX_CPU_ID + 32) / 32 ))"
  for (( i=0; i<chunks_count; i++ )); do
    chunks[$i]=0
  done

  for (( position=group_index; position<CPU_COUNT; position+=group_count )); do
    cpu="${CPU_IDS[$position]}"
    chunk="$((cpu / 32))"
    bit="$((cpu % 32))"
    chunks[$chunk]="$(( chunks[$chunk] | (1 << bit) ))"
  done

  for (( i=chunks_count-1; i>=0; i-- )); do
    printf -v formatted '%08x' "${chunks[$i]}"
    if [[ -z "${out}" ]]; then
      out="${formatted}"
    else
      out="${out},${formatted}"
    fi
  done
  echo "${out:-00000000}"
}

floor_power_of_two() {
  local value="$1"
  local result=1
  if (( value < 1 )); then
    echo 0
    return 0
  fi
  while (( result <= value / 2 )); do
    result="$((result * 2))"
  done
  echo "${result}"
}

for devpath in /sys/class/net/*; do
  [[ -e "${devpath}" ]] || continue
  [[ -e "${devpath}/device" ]] || continue
  dev="$(basename "${devpath}")"
  [[ "${dev}" == "lo" ]] && continue

  ip link set dev "${dev}" txqueuelen "${TXQUEUELEN}" 2>/dev/null || true
  if [[ -w "/proc/sys/net/ipv4/conf/${dev}/rp_filter" ]]; then
    echo "${RP_FILTER}" > "/proc/sys/net/ipv4/conf/${dev}/rp_filter"
  fi
  if [[ -w "/proc/sys/net/ipv4/conf/${dev}/promote_secondaries" ]]; then
    echo 1 > "/proc/sys/net/ipv4/conf/${dev}/promote_secondaries"
  fi

  mapfile -t rx_queues < <(find "${devpath}/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | sort -V)
  rx_count="${#rx_queues[@]}"
  if (( rx_count > 0 )); then
    per_queue_flow="$(floor_power_of_two "$((RPS_FLOW_ENTRIES / rx_count))")"
    rx_index=0
    for queue in "${rx_queues[@]}"; do
      if (( CPU_COUNT > 1 && rx_count < CPU_COUNT )); then
        queue_mask="$(cpu_group_mask "${rx_index}" "${rx_count}")"
        queue_flow="${per_queue_flow}"
      else
        queue_mask="00000000"
        queue_flow=0
      fi
      if [[ -e "${queue}/rps_cpus" && -w "${queue}/rps_cpus" ]]; then
        { echo "${queue_mask}" > "${queue}/rps_cpus"; } 2>/dev/null || true
      fi
      if [[ -e "${queue}/rps_flow_cnt" && -w "${queue}/rps_flow_cnt" ]]; then
        { echo "${queue_flow}" > "${queue}/rps_flow_cnt"; } 2>/dev/null || true
      fi
      rx_index="$((rx_index + 1))"
    done
  fi

  mapfile -t tx_queues < <(find "${devpath}/queues" -maxdepth 1 -type d -name 'tx-*' 2>/dev/null | sort -V)
  tx_count="${#tx_queues[@]}"
  tx_index=0
  for queue in "${tx_queues[@]}"; do
    if (( tx_count > 1 )); then
      if (( tx_count < CPU_COUNT )); then
        xps_group_count="${tx_count}"
      else
        xps_group_count="${CPU_COUNT}"
      fi
      queue_mask="$(cpu_group_mask "$((tx_index % xps_group_count))" "${xps_group_count}")"
    else
      queue_mask="00000000"
    fi
    if [[ -e "${queue}/xps_cpus" && -w "${queue}/xps_cpus" ]]; then
      { echo "${queue_mask}" > "${queue}/xps_cpus"; } 2>/dev/null || true
    fi
    tx_index="$((tx_index + 1))"
  done

  if command -v ethtool >/dev/null 2>&1; then
    for feature in rx tx sg tso gso gro; do
      if ! ethtool -K "${dev}" "${feature}" on 2>/dev/null; then
        echo "${dev}: unable to enable offload ${feature}" >&2
      fi
    done

    if [[ "${MAXIMIZE_NIC_RING}" == "1" ]]; then
      ring="$(ethtool -g "${dev}" 2>/dev/null || true)"
      rx_max="$(printf '%s\n' "${ring}" | awk '/Pre-set maximums:/ {p=1; next} p && /RX:/ {print $2; exit}')"
      tx_max="$(printf '%s\n' "${ring}" | awk '/Pre-set maximums:/ {p=1; next} p && /TX:/ {print $2; exit}')"
      if [[ "${rx_max:-0}" =~ ^[0-9]+$ && "${tx_max:-0}" =~ ^[0-9]+$ ]]; then
        ethtool -G "${dev}" rx "${rx_max}" tx "${tx_max}" 2>/dev/null ||
          echo "${dev}: unable to maximize NIC ring buffers" >&2
      fi
    fi
  fi
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now irqbalance.service 2>/dev/null || true
fi

for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  if [[ -e "${governor}" && -w "${governor}" ]]; then
    { echo performance > "${governor}"; } 2>/dev/null || true
  fi
done
EOF
  chmod 0755 "${NETWORK_TUNE_SCRIPT}"

  cat > "${NETWORK_TUNE_SERVICE_FILE}" <<'EOF'
[Unit]
Description=High-throughput userspace TCP/UDP network tuning
Requires=network-optimization-sysctl.service
After=network-optimization-sysctl.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/network-max-tune
ExecStart=/usr/local/sbin/network-max-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload
  systemctl daemon-reexec
  systemctl enable network-optimization-sysctl.service
  systemctl restart network-optimization-sysctl.service
  systemctl is-active --quiet network-optimization-sysctl.service
  if [[ "${ENABLE_NIC_TUNING}" == "1" ]]; then
    systemctl enable network-max-tune.service
    systemctl restart network-max-tune.service
    systemctl is-active --quiet network-max-tune.service
  else
    systemctl disable --now network-max-tune.service 2>/dev/null || true
  fi
else
  "${SYSCTL_APPLY_SCRIPT}"
fi

echo "Done. ${OS_PRETTY_NAME} userspace TCP/UDP relay/proxy ${PROFILE} profile applied."
echo "Backups use suffix: .bak.${BACKUP_SUFFIX}"
echo "memory=${MEM_MB}MB cpus=${CPU_COUNT} tcp_cc=${TCP_CC} nf_conntrack_max=${NF_CONNTRACK_MAX} hashsize=${NF_CONNTRACK_HASH_SIZE}"
echo "socket_buffer_max=${SOCKET_BUFFER_MAX} netdev_backlog=${NETDEV_MAX_BACKLOG} rps_flow_entries=${RPS_FLOW_ENTRIES}"
echo "ipv4_preferred=1 disable_ipv6=1"
if [[ -z "${IP_LOCAL_PORT_RANGE}" &&
      ( "${PORT_RANGE_WAS_MANAGED}" == "1" || "${LEGACY_PORT_RANGE_REMOVED}" == "1" ) ]]; then
  echo "Warning: ip_local_port_range is no longer persisted by main2; its current live value remains until reboot or an explicit sysctl change."
fi
if [[ "${ENABLE_NIC_TUNING}" == "0" ]]; then
  echo "Warning: NIC tuning persistence is disabled, but current txqueuelen, RPS/XPS, offload, ring, and CPU governor values remain until reboot or manual reset."
fi
