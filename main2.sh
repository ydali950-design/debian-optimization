#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/ydali950-design/debian-optimization/refs/heads/main}"
AUTO_UPDATE_SUPPORT="${AUTO_UPDATE_SUPPORT:-0}"
OPTIMIZER="${SCRIPT_DIR}/sysctl_optimization_debian_overwrite_main2.sh"
SWAP_SCRIPT="${SCRIPT_DIR}/scripts/swap.sh"
SSH_ROOT_SCRIPT="${SCRIPT_DIR}/scripts/ssh_root.sh"
UDP_MULTINIC_SCRIPT="${SCRIPT_DIR}/scripts/udp_multinic_main2.sh"
MTU_MSS_SCRIPT="${SCRIPT_DIR}/scripts/mtu_mss_main2.sh"
MARK_FILE="/root/.debian_optimization_main2_done"
LEGACY_MARK_FILE="/root/.debian_optimization_done"
LEGACY_BACKUP_SUFFIX="${LEGACY_BACKUP_SUFFIX:-}"
LEGACY_UDP_PENDING_FILE="/etc/udp-multinic/.main2-migration-pending"
LEGACY_RESTORE_STATE_DIR="/var/lib/debian-optimization-main2"
LEGACY_UDP_MIGRATION=0
LEGACY_SYSCTL_MIGRATION=0
LEGACY_SYSCTL_RESTORED=0
LEGACY_BACKUP_ALREADY_RESTORED=0

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

support_script_needs_refresh() {
  local path="$1"
  case "${path}" in
    sysctl_optimization_debian_overwrite_main2.sh)
      file_sha256_is \
        "${SCRIPT_DIR}/${path}" \
        de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181
      ;;
    *) return 1 ;;
  esac
}

ensure_support_scripts() {
  local path target url
  for path in \
    "sysctl_optimization_debian_overwrite_main2.sh" \
    "scripts/swap.sh" \
    "scripts/ssh_root.sh" \
    "scripts/udp_multinic_main2.sh" \
    "scripts/mtu_mss_main2.sh"; do
    target="${SCRIPT_DIR}/${path}"
    if [[ -e "${target}" || -L "${target}" ]] &&
       [[ ! -f "${target}" || -L "${target}" ]]; then
      fail "配套脚本路径不是普通文件，已停止同步：${target}"
      exit 1
    fi
    if [[ "${AUTO_UPDATE_SUPPORT}" == "1" || ! -e "${target}" ]] ||
       support_script_needs_refresh "${path}"; then
      url="${RAW_BASE_URL}/${path}"
      warn "正在同步 ${target} ..."
      download_file "${url}" "${target}"
      if support_script_needs_refresh "${path}"; then
        fail "同步后仍是已知故障版本，已停止执行：${target}"
        exit 1
      fi
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
  if [[ "$(system_id)" != "debian" ]]; then
    fail "设置 Debian 官方源仅支持 Debian 系统。"
    return 1
  fi
  local codename backup components
  codename="$(detect_codename)"
  backup="/etc/apt/sources.list.bak.$(date +%Y%m%d%H%M%S)"

  case "${codename}" in
    bookworm|trixie) components="main contrib non-free non-free-firmware" ;;
    buster|bullseye) components="main contrib non-free" ;;
    *) fail "不支持将 Debian ${codename} 重置为本脚本内置源。"; return 1 ;;
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
  apt_update
  ok "系统软件源已刷新，保留现有镜像与组件配置。"
}

is_legacy_sysctl_file() {
  local path="$1"
  local first_line=""
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  IFS= read -r first_line < "${path}" || true
  case "${first_line}" in
    "# Debian relay / VPN landing host balanced-max network optimization."|\
    "# Debian / Ubuntu relay / VPN landing host balanced-max network optimization.") return 0 ;;
    *) return 1 ;;
  esac
}

is_legacy_limits_file() {
  local path="$1"
  [[ -f "${path}" && ! -L "${path}" ]] || return 1
  awk '
    NR == 1 && NF == 4 && $1 == "*" && $2 == "soft" && $3 == "nproc" && $4 ~ /^[1-9][0-9]*$/ { limit = $4; next }
    NR == 2 && NF == 4 && $1 == "*" && $2 == "hard" && $3 == "nproc" && $4 == limit { next }
    NR == 3 && NF == 4 && $1 == "*" && $2 == "soft" && $3 == "nofile" && $4 == limit { next }
    NR == 4 && NF == 4 && $1 == "*" && $2 == "hard" && $3 == "nofile" && $4 == limit { next }
    NR == 5 && NF == 4 && $1 == "root" && $2 == "soft" && $3 == "nproc" && $4 == limit { next }
    NR == 6 && NF == 4 && $1 == "root" && $2 == "hard" && $3 == "nproc" && $4 == limit { next }
    NR == 7 && NF == 4 && $1 == "root" && $2 == "soft" && $3 == "nofile" && $4 == limit { next }
    NR == 8 && NF == 4 && $1 == "root" && $2 == "hard" && $3 == "nofile" && $4 == limit { next }
    { exit 1 }
    END { if (NR != 8 || limit == "") exit 1 }
  ' "${path}"
}

restore_legacy_sysctl() {
  local target="/etc/sysctl.conf"
  local backup saved
  if [[ -n "${LEGACY_BACKUP_SUFFIX}" ]]; then
    [[ "${LEGACY_BACKUP_ALREADY_RESTORED}" == "0" ]] || return 0
    backup="${target}.bak.${LEGACY_BACKUP_SUFFIX}"
    saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
    cp -a "${target}" "${saved}"
    cp -a "${backup}" "${target}"
    LEGACY_SYSCTL_RESTORED=1
    ok "已按明确指定的时间戳从 ${backup} 恢复 ${target}；原文件保存在 ${saved}。"
    return 0
  fi

  is_legacy_sysctl_file "${target}" || return 0
  LEGACY_SYSCTL_MIGRATION=1
  saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
  cp -a "${target}" "${saved}"
  warn "检测到旧版覆盖的 ${target}；新版优化器将移除旧版管理键并保留其他现有内容。当前文件已备份为 ${saved}。"
}

restore_legacy_limits() {
  local target="/etc/security/limits.conf"
  local backup saved
  if [[ -n "${LEGACY_BACKUP_SUFFIX}" ]]; then
    [[ "${LEGACY_BACKUP_ALREADY_RESTORED}" == "0" ]] || return 0
    backup="${target}.bak.${LEGACY_BACKUP_SUFFIX}"
    saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
    cp -a "${target}" "${saved}"
    cp -a "${backup}" "${target}"
    ok "已按明确指定的时间戳从 ${backup} 恢复 ${target}；原文件保存在 ${saved}。"
    return 0
  fi

  is_legacy_limits_file "${target}" || return 0
  saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
  cp -a "${target}" "${saved}"
  : > "${target}"
  chmod 0644 "${target}"
  warn "已移除精确匹配的旧版 8 行 limits 配置；未自动选择历史备份，旧版文件保存在 ${saved}。"
}

cleanup_owned_chain() {
  local tool="$1"
  local table="$2"
  local base_chain="$3"
  local owned_chain="$4"
  command -v "${tool}" >/dev/null 2>&1 || return 0
  "${tool}" -w 10 -t "${table}" -L >/dev/null 2>&1 || return 0
  while "${tool}" -w 10 -t "${table}" -C "${base_chain}" -j "${owned_chain}" 2>/dev/null; do
    "${tool}" -w 10 -t "${table}" -D "${base_chain}" -j "${owned_chain}" 2>/dev/null || break
  done
  "${tool}" -w 10 -t "${table}" -F "${owned_chain}" 2>/dev/null || true
  "${tool}" -w 10 -t "${table}" -X "${owned_chain}" 2>/dev/null || true
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

legacy_backup_state_file() {
  printf '%s/legacy-backup-%s.restored' "${LEGACY_RESTORE_STATE_DIR}" "${LEGACY_BACKUP_SUFFIX}"
}

mark_legacy_backup_restored() {
  local state_file
  if [[ -z "${LEGACY_BACKUP_SUFFIX}" || "${LEGACY_BACKUP_ALREADY_RESTORED}" == "1" ]]; then
    return 0
  fi
  install -d -m 0755 "${LEGACY_RESTORE_STATE_DIR}"
  state_file="$(legacy_backup_state_file)"
  touch "${state_file}"
  chmod 0644 "${state_file}"
  ok "已记录旧备份时间戳 ${LEGACY_BACKUP_SUFFIX} 的一次性恢复状态。"
}

cleanup_legacy_mss() {
  local apply_script="/usr/local/sbin/mtu-mss-apply.sh"
  local config_file="/etc/default/mtu-mss-fix"
  local service_file="/etc/systemd/system/mtu-mss-fix.service"
  local tool
  if [[ ! -f "${apply_script}" ]]; then
    if [[ -e "${LEGACY_MARK_FILE}" && ! -e "${config_file}" && ! -e "${service_file}" ]]; then
      for tool in iptables ip6tables; do
        cleanup_owned_chain "${tool}" mangle FORWARD MSS_FIX_FORWARD
        cleanup_owned_chain "${tool}" mangle OUTPUT MSS_FIX_OUTPUT
      done
    fi
    return 0
  fi
  if ! file_sha256_is "${apply_script}" f5ce5cf993b2093d96f2c11b7e67326219178b8aa05a5cf35df1ba4eeaec94b3 &&
     ! file_sha256_is "${apply_script}" 9b7efb88f963a36150a47feb680cfae0b088e3921368d4a07ba0bd94e40b6afd; then
    return 0
  fi
  if ! file_sha256_is "${config_file}" b78d8eb778d330047aeb041b3353edbe4dbb709672361e13387ba9d521bfcd14 ||
     ! file_sha256_is "${service_file}" 5696d6de58dc07facf0aedc07f23937bee822090d1caf8fbbf69a980fe22b6b1; then
    warn "检测到旧版自定义 MTU/MSS 配置，未自动删除；可通过 main2 菜单中的 MTU/MSS 管理确认后清理。"
    return 0
  fi

  systemctl disable --now mtu-mss-fix.service 2>/dev/null || true
  for tool in iptables ip6tables; do
    cleanup_owned_chain "${tool}" mangle FORWARD MSS_FIX_FORWARD
    cleanup_owned_chain "${tool}" mangle OUTPUT MSS_FIX_OUTPUT
  done
  rm -f \
    /etc/default/mtu-mss-fix \
    /usr/local/sbin/mtu-mss-apply.sh \
    /etc/systemd/system/mtu-mss-fix.service \
    /etc/systemd/system/multi-user.target.wants/mtu-mss-fix.service
  ok "已清理旧版 main.sh 默认启用的 MTU/MSS 服务和规则。"
}

cleanup_legacy_network_tune() {
  local service_file="/etc/systemd/system/network-max-tune.service"
  local apply_script="/usr/local/sbin/network-max-tune.sh"
  local config_file="/etc/default/network-max-tune"
  [[ -e "${service_file}" || -L "${service_file}" ||
     -e "${apply_script}" || -L "${apply_script}" ||
     -e "${config_file}" || -L "${config_file}" ]] || return 0
  if file_sha256_is "${apply_script}" ff055ea655d1e0bb358668575cc177529b537e7aa79600e1bb177290a6d5930e &&
     file_sha256_is "${service_file}" 95e083a80521a871fe467b3dc804ff28ab4f001269d8876a536234c7b60552a9; then
    return 0
  fi
  if { ! file_sha256_is "${apply_script}" 81bfc014065899e0e32e77a0ae6a0c2abeabd0793c76d231429835205733edb0 &&
       ! file_sha256_is "${apply_script}" 6f8ba0c035cacbf9d32ed309a866edccef5e0b40366cd0c754386a41f273f0c3; } ||
     ! file_sha256_is "${service_file}" b6b1d82eb6e297618575dc25e75dc9a22b21df1c77fa9359b2631325dc81565a; then
    fail "检测到同名但不属于旧版或 main2 的网卡调优文件，已停止接管。"
    return 1
  fi

  systemctl disable --now network-max-tune.service 2>/dev/null || true
  rm -f \
    /etc/default/network-max-tune \
    /usr/local/sbin/network-max-tune.sh \
    /etc/systemd/system/network-max-tune.service \
    /etc/systemd/system/multi-user.target.wants/network-max-tune.service
  ok "已停用旧版网卡调优服务，后续由 main2 新服务接管。"
}

detect_legacy_udp() {
  local apply_script="/usr/local/sbin/udp-multinic-apply.sh"
  local service_file="/etc/systemd/system/udp-multinic.service"

  if file_sha256_is "${apply_script}" b705ef4416d151e5269f238feda1a2a14fbf063afcb85c767244339380300a0d ||
     file_sha256_is "${apply_script}" ff294f60fff80d303727ba7e75a7fdf7227a4c327e08304f2667100acacc7162; then
    return 0
  fi
  if file_sha256_is "${service_file}" 18a15a9d7663de9779eee0cb6ad9b09c0f1f0407401c2d40f4e6cb66875a2611; then
    return 0
  fi
  return 1
}

preflight_udp_runtime_paths() {
  local apply_script="/usr/local/sbin/udp-multinic-apply.sh"
  local service_file="/etc/systemd/system/udp-multinic.service"
  local sysctl_file="/etc/sysctl.d/61-udp-multinic.conf"
  local legacy_runtime=0

  if [[ -e "${apply_script}" || -L "${apply_script}" ]]; then
    if file_sha256_is "${apply_script}" b705ef4416d151e5269f238feda1a2a14fbf063afcb85c767244339380300a0d ||
       file_sha256_is "${apply_script}" ff294f60fff80d303727ba7e75a7fdf7227a4c327e08304f2667100acacc7162; then
      legacy_runtime=1
    elif ! file_sha256_is "${apply_script}" 4f094911fe1e2d4e0a528e17e0cc50e46045b76cb0e8bd563b0742d1ec7c054f; then
      fail "检测到同名但不属于旧版或 main2 的 UDP 应用脚本，已停止接管：${apply_script}"
      return 1
    fi
  fi

  if [[ -e "${service_file}" || -L "${service_file}" ]]; then
    if file_sha256_is "${service_file}" 18a15a9d7663de9779eee0cb6ad9b09c0f1f0407401c2d40f4e6cb66875a2611; then
      legacy_runtime=1
    elif ! file_sha256_is "${service_file}" d4eaeadd2f155b831c44a65aba43297ad6eaa15c3b530be73afba65c823cc7a4; then
      fail "检测到同名但不属于旧版或 main2 的 UDP 服务文件，已停止接管：${service_file}"
      return 1
    fi
  fi

  if [[ "${legacy_runtime}" == "1" || -f "${LEGACY_UDP_PENDING_FILE}" ]]; then
    if [[ -e "${sysctl_file}" || -L "${sysctl_file}" ]]; then
      if ! file_sha256_is "${sysctl_file}" 1569eb1b5cdfcb20d405e167b52f6ea83ea3e6240366c6649b4d8d9f660d64d7 &&
         ! file_sha256_is "${sysctl_file}" c8c8cbd1560c9b5edf183bca4174734afca2d3e52a03922b0dc708fd43e1be15 &&
         ! file_sha256_is "${sysctl_file}" eac3e15d92ea1b5c6b07ba242cba835d146d412832f920aa3d89f7e680c135db; then
        fail "检测到同名但不属于旧版或 main2 的 UDP sysctl 文件，已停止接管：${sysctl_file}"
        return 1
      fi
    fi
  fi
}

preflight_legacy_main_deployment() {
  local backup link_target state_file
  if [[ -L /etc/udp-multinic || ( -e /etc/udp-multinic && ! -d /etc/udp-multinic ) ]]; then
    fail "UDP 配置路径不是安全的真实目录：/etc/udp-multinic"
    return 1
  fi
  if [[ ( -e "${LEGACY_UDP_PENDING_FILE}" || -L "${LEGACY_UDP_PENDING_FILE}" ) &&
        ( ! -f "${LEGACY_UDP_PENDING_FILE}" || -L "${LEGACY_UDP_PENDING_FILE}" ) ]]; then
    fail "UDP 迁移标记不是普通文件：${LEGACY_UDP_PENDING_FILE}"
    return 1
  fi
  if [[ -L /etc/sysctl.d/99-network-optimization.conf ]]; then
    link_target="$(readlink -- /etc/sysctl.d/99-network-optimization.conf)"
    if [[ "${link_target}" != "/etc/sysctl.conf" ]]; then
      fail "检测到未知符号链接：/etc/sysctl.d/99-network-optimization.conf -> ${link_target}，已停止接管。"
      return 1
    fi
  fi

  if [[ ( -e /etc/udp-multinic/rules.conf || -L /etc/udp-multinic/rules.conf ) &&
        ( ! -f /etc/udp-multinic/rules.conf || -L /etc/udp-multinic/rules.conf ) ]]; then
    fail "UDP 规则路径不是普通文件：/etc/udp-multinic/rules.conf"
    return 1
  fi
  preflight_udp_runtime_paths

  if [[ -z "${LEGACY_BACKUP_SUFFIX}" ]]; then
    return 0
  fi
  if [[ ! "${LEGACY_BACKUP_SUFFIX}" =~ ^[0-9]{14}$ ]]; then
    fail "LEGACY_BACKUP_SUFFIX 必须是旧脚本生成的 14 位时间戳。"
    return 1
  fi

  if [[ -L "${LEGACY_RESTORE_STATE_DIR}" ||
        ( -e "${LEGACY_RESTORE_STATE_DIR}" && ! -d "${LEGACY_RESTORE_STATE_DIR}" ) ]]; then
    fail "旧备份恢复状态路径不是安全的真实目录：${LEGACY_RESTORE_STATE_DIR}"
    return 1
  fi
  state_file="$(legacy_backup_state_file)"
  if [[ -e "${state_file}" || -L "${state_file}" ]]; then
    if [[ ! -f "${state_file}" || -L "${state_file}" ]]; then
      fail "旧备份恢复状态不是普通文件：${state_file}"
      return 1
    fi
    LEGACY_BACKUP_ALREADY_RESTORED=1
    warn "旧备份时间戳 ${LEGACY_BACKUP_SUFFIX} 已恢复过，本次不会重复覆盖系统配置。"
    return 0
  fi

  if [[ ! -f /etc/sysctl.conf || -L /etc/sysctl.conf ]]; then
    fail "当前 /etc/sysctl.conf 不是普通文件，不能执行指定备份恢复。"
    return 1
  fi
  backup="/etc/sysctl.conf.bak.${LEGACY_BACKUP_SUFFIX}"
  if [[ ! -f "${backup}" || -L "${backup}" ]]; then
    fail "指定的旧备份不是普通文件：${backup}"
    return 1
  fi
  if is_legacy_sysctl_file "${backup}"; then
    fail "指定的 ${backup} 仍是旧版生成配置，不能作为部署前备份恢复。"
    return 1
  fi

  if [[ ! -f /etc/security/limits.conf || -L /etc/security/limits.conf ]]; then
    fail "当前 /etc/security/limits.conf 不是普通文件，不能执行指定备份恢复。"
    return 1
  fi
  backup="/etc/security/limits.conf.bak.${LEGACY_BACKUP_SUFFIX}"
  if [[ ! -f "${backup}" || -L "${backup}" ]]; then
    fail "指定的旧备份不是普通文件：${backup}"
    return 1
  fi
  if is_legacy_limits_file "${backup}"; then
    fail "指定的 ${backup} 仍是旧版生成配置，不能作为部署前备份恢复。"
    return 1
  fi
}

prepare_legacy_main_deployment() {
  LEGACY_UDP_MIGRATION=0
  LEGACY_SYSCTL_MIGRATION=0
  LEGACY_SYSCTL_RESTORED=0
  LEGACY_BACKUP_ALREADY_RESTORED=0
  preflight_legacy_main_deployment
  restore_legacy_sysctl
  restore_legacy_limits
  mark_legacy_backup_restored
  cleanup_legacy_mss
  cleanup_legacy_network_tune

  if detect_legacy_udp; then
    chmod +x "${UDP_MULTINIC_SCRIPT}"
    bash "${UDP_MULTINIC_SCRIPT}" validate
    systemctl disable --now udp-multinic.service 2>/dev/null || true
    install -d -m 0755 "$(dirname "${LEGACY_UDP_PENDING_FILE}")"
    touch "${LEGACY_UDP_PENDING_FILE}"
    chmod 0644 "${LEGACY_UDP_PENDING_FILE}"
    ok "已停用旧版 UDP 映射服务，现有映射将在新网络配置应用后升级。"
  elif [[ -f "${LEGACY_UDP_PENDING_FILE}" && ! -L "${LEGACY_UDP_PENDING_FILE}" ]]; then
    chmod +x "${UDP_MULTINIC_SCRIPT}"
    bash "${UDP_MULTINIC_SCRIPT}" validate
  fi
  if [[ -f "${LEGACY_UDP_PENDING_FILE}" && ! -L "${LEGACY_UDP_PENDING_FILE}" ]]; then
    LEGACY_UDP_MIGRATION=1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    systemctl reset-failed network-max-tune.service mtu-mss-fix.service udp-multinic.service 2>/dev/null || true
  fi
}

migrate_legacy_udp() {
  if [[ "${LEGACY_UDP_MIGRATION}" != "1" && ! -f "${LEGACY_UDP_PENDING_FILE}" ]]; then
    return 0
  fi
  chmod +x "${UDP_MULTINIC_SCRIPT}"
  bash "${UDP_MULTINIC_SCRIPT}" migrate
  rm -f "${LEGACY_UDP_PENDING_FILE}"
  rmdir "$(dirname "${LEGACY_UDP_PENDING_FILE}")" 2>/dev/null || true
}

run_network_optimization() {
  local profile="$1"
  local port_range
  if [[ ! -f "${OPTIMIZER}" ]]; then
    fail "未找到 ${OPTIMIZER}"
    exit 1
  fi

  port_range="${IP_LOCAL_PORT_RANGE:-}"
  if [[ -n "${port_range}" ]]; then
    PROFILE="${profile}" IP_LOCAL_PORT_RANGE="${port_range}" VALIDATE_ONLY=1 bash "${OPTIMIZER}"
  else
    PROFILE="${profile}" VALIDATE_ONLY=1 bash "${OPTIMIZER}"
  fi

  prepare_legacy_main_deployment
  chmod +x "${OPTIMIZER}"
  if [[ -n "${port_range}" ]]; then
    PROFILE="${profile}" IP_LOCAL_PORT_RANGE="${port_range}" VALIDATE_ONLY=0 bash "${OPTIMIZER}"
  else
    PROFILE="${profile}" VALIDATE_ONLY=0 bash "${OPTIMIZER}"
  fi
  if [[ "${LEGACY_SYSCTL_MIGRATION}" == "1" && -z "${port_range}" ]]; then
    warn "旧版临时端口范围已停止持久化；当前运行值会持续到本次重启，main2 不会自行填入未知的部署前数值。"
  fi
  if [[ "${LEGACY_SYSCTL_RESTORED}" == "1" ]]; then
    warn "指定备份中的非 main2 运行参数将在重启后按系统加载顺序生效。"
  fi
  migrate_legacy_udp
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
  apt update
  apt install chrony -y
  systemctl enable chrony
  systemctl restart chrony
  chronyc makestep
  ok "Chrony 已安装、启用并完成立即校时。"
}

default_setup() {
  if [[ "${SKIP_INIT:-0}" == "1" ]]; then
    ok "已跳过默认初始化。"
    return 0
  fi

  warn "开始默认初始化：刷新系统软件源 -> 安装并校准 Chrony -> 关闭 IPv6 -> 执行用户态 TCP/UDP 代理优化 -> 安装并启用 irqbalance。"
  set_system_sources
  install_base_tools
  install_chrony
  run_network_optimization "${PROFILE:-balanced}"
  install_irqbalance
  touch "${MARK_FILE}"
  ok "默认初始化完成。"
}

install_warp_menu() {
  local url="https://gitlab.com/fscarmen/warp/-/raw/main/menu.sh"
  local target="/root/warp-menu.sh"
  local warp_status=0

  warn "即将下载并执行第三方 WARP 脚本：${url}"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target}"
  else
    wget -O "${target}" "${url}"
  fi

  chmod +x "${target}"
  bash "${target}" || warp_status=$?
  if systemctl cat network-optimization-sysctl.service >/dev/null 2>&1; then
    systemctl restart network-optimization-sysctl.service
    ok "已重新校验网络参数和 IPv6 关闭状态。"
  fi
  return "${warp_status}"
}

softnet_drop_total() {
  local _processed dropped _rest total=0
  while read -r _processed dropped _rest; do
    total="$((total + 16#${dropped}))"
  done < /proc/net/softnet_stat
  printf "%s" "${total}"
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
  printf "CPUs: %s\n" "$(nproc)"
  printf "Memory: %s\n" "$(awk '/MemTotal:/ {printf "%.0f MB", $2/1024}' /proc/meminfo)"

  info "网络参数"
  printf "tcp_congestion_control: %s\n" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
  printf "default_qdisc: %s\n" "$(sysctl -n net.core.default_qdisc 2>/dev/null || echo unknown)"
  printf "ipv4_forward: %s\n" "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo unknown)"
  printf "ipv6_disabled: %s\n" "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo unknown)"
  printf "ipv4_precedence: %s\n" "${ipv4_precedence:-missing}"
  printf "nf_conntrack_max: %s\n" "$(sysctl -n net.netfilter.nf_conntrack_max 2>/dev/null || echo unknown)"
  printf "nf_conntrack_count: %s\n" "$(sysctl -n net.netfilter.nf_conntrack_count 2>/dev/null || echo unknown)"
  printf "nf_conntrack_buckets: %s\n" "$(sysctl -n net.netfilter.nf_conntrack_buckets 2>/dev/null || echo unknown)"
  printf "ip_local_port_range: %s\n" "$(sysctl -n net.ipv4.ip_local_port_range 2>/dev/null || echo unknown)"
  printf "rmem_max: %s\n" "$(sysctl -n net.core.rmem_max 2>/dev/null || echo unknown)"
  printf "wmem_max: %s\n" "$(sysctl -n net.core.wmem_max 2>/dev/null || echo unknown)"
  printf "netdev_max_backlog: %s\n" "$(sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo unknown)"
  printf "netdev_budget_usecs: %s\n" "$(sysctl -n net.core.netdev_budget_usecs 2>/dev/null || echo unavailable)"
  printf "mptcp_enabled: %s\n" "$(sysctl -n net.mptcp.enabled 2>/dev/null || echo unavailable)"
  printf "softnet_dropped: %s\n" "$(softnet_drop_total)"

  info "全局 IPv4 地址"
  ip -4 -o addr show scope global | awk '{print $2 ": " $4}' || true

  info "时间同步"
  chronyc tracking 2>/dev/null || warn "Chrony 当前不可用。"

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
    ok " 用户态 TCP/UDP 中转 / 代理落地优化"
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
    if [[ "$(system_id)" == "debian" ]]; then
      printf "12. 重置 Debian 官方源\n"
    fi
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
      12)
        if confirm "此操作会备份并覆盖 Debian 软件源配置，确认继续吗？"; then
          set_debian_sources
        fi
        pause
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
