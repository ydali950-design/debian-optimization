#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Please run as root."
  exit 1
fi

BACKUP_SUFFIX="$(date +%Y%m%d%H%M%S)"
MEM_KB="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
MEM_MB="$((MEM_KB / 1024))"

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

backup_file() {
  local path="$1"
  if [[ -e "${path}" ]]; then
    cp -a "${path}" "${path}.bak.${BACKUP_SUFFIX}"
  fi
}

auto_socket_buffer_max() {
  if (( MEM_MB < 1024 )); then
    echo 33554432
  elif (( MEM_MB < 2048 )); then
    echo 67108864
  elif (( MEM_MB < 4096 )); then
    echo 134217728
  else
    echo 134217728
  fi
}

auto_conntrack_max() {
  local per_mb minimum maximum
  if [[ "${PROFILE}" == "max" ]]; then
    per_mb=768
    minimum=524288
    maximum=8388608
  else
    per_mb=384
    minimum=262144
    maximum=4194304
  fi
  min_int "$(max_int "$((MEM_MB * per_mb))" "${minimum}")" "${maximum}"
}

# Config overwrite is reversible; mkfs is not. Keep disk formatting opt-in.
if [[ "${FORMAT_XVDB:-0}" == "1" ]]; then
  [[ -b /dev/xvdb ]] || { echo "/dev/xvdb does not exist."; exit 1; }
  mkfs.ext4 -F /dev/xvdb -N 5359296
fi

# balanced: high throughput, safer memory use for 1G-4G VPS.
# max: more aggressive buffers/queues for speed tests and 4G+ memory hosts.
PROFILE="${PROFILE:-balanced}"
TIMEZONE="${TIMEZONE:-Asia/Hong_Kong}"
ENABLE_IPV6="${ENABLE_IPV6:-1}"
ENABLE_NIC_TUNING="${ENABLE_NIC_TUNING:-1}"

# 0 is best for VPN/tunnel/asymmetric routing compatibility. Use 2 for loose RPF.
RP_FILTER="${RP_FILTER:-0}"

if [[ "${PROFILE}" == "max" ]]; then
  SOCKET_BUFFER_DEFAULT="${SOCKET_BUFFER_DEFAULT:-1048576}"
  SOCKET_BUFFER_MAX="${SOCKET_BUFFER_MAX:-268435456}"
  NETDEV_MAX_BACKLOG="${NETDEV_MAX_BACKLOG:-524288}"
  NETDEV_BUDGET="${NETDEV_BUDGET:-600}"
  NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-8000}"
  RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-32768}"
  TXQUEUELEN="${TXQUEUELEN:-10000}"
  TCP_MAX_TW_BUCKETS="${TCP_MAX_TW_BUCKETS:-4000000}"
  IPFRAG_HIGH_THRESH="${IPFRAG_HIGH_THRESH:-134217728}"
  IPFRAG_LOW_THRESH="${IPFRAG_LOW_THRESH:-100663296}"
else
  SOCKET_BUFFER_DEFAULT="${SOCKET_BUFFER_DEFAULT:-262144}"
  SOCKET_BUFFER_MAX="${SOCKET_BUFFER_MAX:-$(auto_socket_buffer_max)}"
  NETDEV_MAX_BACKLOG="${NETDEV_MAX_BACKLOG:-131072}"
  NETDEV_BUDGET="${NETDEV_BUDGET:-300}"
  NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-6000}"
  RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-16384}"
  TXQUEUELEN="${TXQUEUELEN:-5000}"
  TCP_MAX_TW_BUCKETS="${TCP_MAX_TW_BUCKETS:-2000000}"
  IPFRAG_HIGH_THRESH="${IPFRAG_HIGH_THRESH:-67108864}"
  IPFRAG_LOW_THRESH="${IPFRAG_LOW_THRESH:-50331648}"
fi

NOFILE_LIMIT="${NOFILE_LIMIT:-1048576}"
FILE_MAX="${FILE_MAX:-4194304}"
NF_CONNTRACK_MAX="${NF_CONNTRACK_MAX:-$(auto_conntrack_max)}"
NF_CONNTRACK_HASH_SIZE="${NF_CONNTRACK_HASH_SIZE:-$((NF_CONNTRACK_MAX / 4))}"

if [[ -n "${TIMEZONE}" ]]; then
  timedatectl set-timezone "${TIMEZONE}"
fi

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
if [[ -w /sys/module/nf_conntrack/parameters/hashsize ]]; then
  echo "${NF_CONNTRACK_HASH_SIZE}" > /sys/module/nf_conntrack/parameters/hashsize || true
fi

TCP_CC="bbr"
if [[ -r /proc/sys/net/ipv4/tcp_available_congestion_control ]] &&
   ! grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
  TCP_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo cubic)"
fi

backup_file /etc/security/limits.conf
cat > /etc/security/limits.conf <<EOF
*    soft    nproc     ${NOFILE_LIMIT}
*    hard    nproc     ${NOFILE_LIMIT}
*    soft    nofile    ${NOFILE_LIMIT}
*    hard    nofile    ${NOFILE_LIMIT}
root soft    nproc     ${NOFILE_LIMIT}
root hard    nproc     ${NOFILE_LIMIT}
root soft    nofile    ${NOFILE_LIMIT}
root hard    nofile    ${NOFILE_LIMIT}
EOF

install -d /etc/systemd/system.conf.d /etc/systemd/user.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
DefaultLimitNPROC=${NOFILE_LIMIT}
EOF

cat > /etc/systemd/user.conf.d/99-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE_LIMIT}
DefaultLimitNPROC=${NOFILE_LIMIT}
EOF

cat > /etc/profile.d/99-ulimit.sh <<EOF
ulimit -SHn ${NOFILE_LIMIT} 2>/dev/null || true
EOF
chmod 0644 /etc/profile.d/99-ulimit.sh

backup_file /etc/sysctl.conf
cat > /etc/sysctl.conf <<EOF
# Debian relay / VPN landing host balanced-max network optimization.

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
net.ipv4.tcp_max_syn_backlog = 262144
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
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_max_tw_buckets = ${TCP_MAX_TW_BUCKETS}
net.ipv4.tcp_syn_retries = 3
net.ipv4.tcp_synack_retries = 3
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_ecn_fallback = 1

# Local ports for high-rate NAT/proxy egress
net.ipv4.ip_local_port_range = 1024 65535

# Socket buffers. Moderate defaults, high autotuning ceilings.
net.core.rmem_default = ${SOCKET_BUFFER_DEFAULT}
net.core.wmem_default = ${SOCKET_BUFFER_DEFAULT}
net.core.rmem_max = ${SOCKET_BUFFER_MAX}
net.core.wmem_max = ${SOCKET_BUFFER_MAX}
net.core.optmem_max = 33554432
net.ipv4.tcp_rmem = 4096 262144 ${SOCKET_BUFFER_MAX}
net.ipv4.tcp_wmem = 4096 262144 ${SOCKET_BUFFER_MAX}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384

# Fragment queues. Correct tunnel MTU/MSS is still better than fragmentation.
net.ipv4.ipfrag_high_thresh = ${IPFRAG_HIGH_THRESH}
net.ipv4.ipfrag_low_thresh = ${IPFRAG_LOW_THRESH}
net.ipv4.ipfrag_time = 30

# Neighbor cache for many clients/peers
net.ipv4.neigh.default.gc_thresh1 = 8192
net.ipv4.neigh.default.gc_thresh2 = 32768
net.ipv4.neigh.default.gc_thresh3 = 65536

# Netfilter conntrack for NAT/VPN gateways
net.netfilter.nf_conntrack_max = ${NF_CONNTRACK_MAX}
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
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

if [[ "${ENABLE_IPV6}" == "1" ]]; then
  cat >> /etc/sysctl.conf <<EOF

# IPv6 forwarding and hardening
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1
net.ipv6.ip_nonlocal_bind = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.ip6frag_high_thresh = ${IPFRAG_HIGH_THRESH}
net.ipv6.ip6frag_low_thresh = ${IPFRAG_LOW_THRESH}
net.ipv6.ip6frag_time = 30
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
EOF
fi

if [[ "${ENABLE_NIC_TUNING}" == "1" ]]; then
  install -d /usr/local/sbin /etc/default
  cat > /etc/default/network-max-tune <<EOF
TXQUEUELEN=${TXQUEUELEN}
RPS_FLOW_ENTRIES=${RPS_FLOW_ENTRIES}
EOF

  cat > /usr/local/sbin/network-max-tune.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

TXQUEUELEN="${TXQUEUELEN:-5000}"
RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-16384}"

cpu_mask() {
  local cpu_count remaining bits value chunks=()
  cpu_count="$(nproc 2>/dev/null || echo 1)"
  remaining="${cpu_count}"
  while (( remaining > 0 )); do
    if (( remaining >= 32 )); then
      bits=32
      value=4294967295
    else
      bits="${remaining}"
      value=$(( (1 << bits) - 1 ))
    fi
    chunks+=("$(printf '%08x' "${value}")")
    remaining=$((remaining - bits))
  done

  local out="" i
  for (( i=${#chunks[@]}-1; i>=0; i-- )); do
    if [[ -z "${out}" ]]; then
      out="${chunks[$i]}"
    else
      out="${out},${chunks[$i]}"
    fi
  done
  echo "${out:-00000001}"
}

MASK="$(cpu_mask)"

for devpath in /sys/class/net/*; do
  [[ -e "${devpath}" ]] || continue
  dev="$(basename "${devpath}")"
  [[ "${dev}" == "lo" ]] && continue

  ip link set dev "${dev}" txqueuelen "${TXQUEUELEN}" 2>/dev/null || true

  mapfile -t rx_queues < <(find "${devpath}/queues" -maxdepth 1 -type d -name 'rx-*' 2>/dev/null | sort)
  rx_count="${#rx_queues[@]}"
  if (( rx_count > 0 )); then
    per_queue_flow="$((RPS_FLOW_ENTRIES / rx_count))"
    (( per_queue_flow < 1024 )) && per_queue_flow=1024
    for queue in "${rx_queues[@]}"; do
      [[ -w "${queue}/rps_cpus" ]] && echo "${MASK}" > "${queue}/rps_cpus" || true
      [[ -w "${queue}/rps_flow_cnt" ]] && echo "${per_queue_flow}" > "${queue}/rps_flow_cnt" || true
    done
  fi

  for queue in "${devpath}"/queues/tx-*; do
    [[ -e "${queue}" ]] || continue
    [[ -w "${queue}/xps_cpus" ]] && echo "${MASK}" > "${queue}/xps_cpus" || true
  done

  if command -v ethtool >/dev/null 2>&1; then
    ethtool -K "${dev}" rx on tx on sg on tso on gso on gro on 2>/dev/null || true
    ring="$(ethtool -g "${dev}" 2>/dev/null || true)"
    rx_max="$(printf '%s\n' "${ring}" | awk '/Pre-set maximums:/ {p=1; next} p && /RX:/ {print $2; exit}')"
    tx_max="$(printf '%s\n' "${ring}" | awk '/Pre-set maximums:/ {p=1; next} p && /TX:/ {print $2; exit}')"
    if [[ "${rx_max:-0}" =~ ^[0-9]+$ && "${tx_max:-0}" =~ ^[0-9]+$ ]]; then
      ethtool -G "${dev}" rx "${rx_max}" tx "${tx_max}" 2>/dev/null || true
    fi
  fi
done

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now irqbalance.service 2>/dev/null || true
fi

for governor in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [[ -w "${governor}" ]] && echo performance > "${governor}" || true
done
EOF
  chmod 0755 /usr/local/sbin/network-max-tune.sh

  cat > /etc/systemd/system/network-max-tune.service <<'EOF'
[Unit]
Description=Balanced-max network interface tuning
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
EnvironmentFile=-/etc/default/network-max-tune
ExecStart=/usr/local/sbin/network-max-tune.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
fi

sysctl -e -p /etc/sysctl.conf

if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
  systemctl daemon-reexec || true
  if [[ "${ENABLE_NIC_TUNING}" == "1" ]]; then
    systemctl enable --now network-max-tune.service || true
  fi
fi

echo "Done. Debian relay/VPN ${PROFILE} network profile applied."
echo "Backups use suffix: .bak.${BACKUP_SUFFIX}"
echo "memory=${MEM_MB}MB tcp_cc=${TCP_CC} nf_conntrack_max=${NF_CONNTRACK_MAX} hashsize=${NF_CONNTRACK_HASH_SIZE}"
echo "socket_buffer_max=${SOCKET_BUFFER_MAX} netdev_backlog=${NETDEV_MAX_BACKLOG} rps_flow_entries=${RPS_FLOW_ENTRIES}"
