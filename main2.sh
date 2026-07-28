#!/usr/bin/env bash
set -euo pipefail
if [[ -z "${TERM:-}" || "${TERM}" == "dumb" ]]; then
  export TERM=xterm
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
RAW_BASE_URL="${RAW_BASE_URL:-https://raw.githubusercontent.com/ydali950-design/debian-optimization/refs/heads/main}"
AUTO_UPDATE_SUPPORT="${AUTO_UPDATE_SUPPORT:-0}"
MAIN2_BUNDLE_VERSION=2026072901
MAIN2_MANAGED_CONFIG_FORMAT=1
DEBIAN_ARCHIVE_KEYRING="/usr/share/keyrings/debian-archive-keyring.gpg"
DEBIAN_ARCHIVE_KEYRING_LINK_TARGET="debian-archive-keyring.pgp"
UBUNTU_ARCHIVE_KEYRING="/usr/share/keyrings/ubuntu-archive-keyring.gpg"
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
MAIN2_INSTALL_STATE_FILE="${LEGACY_RESTORE_STATE_DIR}/install-state"
MAIN2_LOCK_FILE="/run/debian-optimization-main2.lock"
LEGACY_UDP_MIGRATION=0
LEGACY_SYSCTL_MIGRATION=0
LEGACY_SYSCTL_RESTORED=0
LEGACY_BACKUP_ALREADY_RESTORED=0
MAIN2_STATE_LOADED=0
CURRENT_MAIN2_SHA256=""
INSTALLED_BUNDLE_VERSION=0
INSTALLED_BUNDLE_MAIN2_SHA256=""
APPLIED_MAIN2_VERSION=0
APPLIED_MAIN2_SHA256=""
PENDING_MAIN2_VERSION=0
PENDING_MAIN2_SHA256=""
PENDING_REQUIRES_MANAGED_OVERWRITE=0
PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=1
STORED_MANAGED_CONFIG_FORMAT=""
STORED_MANAGED_CONFIG_SHA256=""
STORED_PROFILE=""
STORED_ENABLE_NIC_TUNING=""
STORED_RP_FILTER=""
STORED_MAXIMIZE_NIC_RING=""
STORED_IP_LOCAL_PORT_RANGE=""
STORED_SOCKET_BUFFER_DEFAULT=""
STORED_SOCKET_BUFFER_MAX=""
STORED_NETDEV_MAX_BACKLOG=""
STORED_NETDEV_BUDGET=""
STORED_NETDEV_BUDGET_USECS=""
STORED_RPS_FLOW_ENTRIES=""
STORED_TXQUEUELEN=""
STORED_TCP_MAX_TW_BUCKETS=""
STORED_TCP_MAX_SYN_BACKLOG=""
STORED_IPFRAG_HIGH_THRESH=""
STORED_NOFILE_LIMIT=""
STORED_FILE_MAX=""
STORED_NF_CONNTRACK_MAX=""
STORED_NF_CONNTRACK_HASH_SIZE=""
PROFILE_WAS_EXPLICIT=0
ENABLE_NIC_TUNING_WAS_EXPLICIT=0
RP_FILTER_WAS_EXPLICIT=0
MAXIMIZE_NIC_RING_WAS_EXPLICIT=0
IP_LOCAL_PORT_RANGE_WAS_EXPLICIT=0
SOCKET_BUFFER_DEFAULT_WAS_EXPLICIT=0
SOCKET_BUFFER_MAX_WAS_EXPLICIT=0
NETDEV_MAX_BACKLOG_WAS_EXPLICIT=0
NETDEV_BUDGET_WAS_EXPLICIT=0
NETDEV_BUDGET_USECS_WAS_EXPLICIT=0
RPS_FLOW_ENTRIES_WAS_EXPLICIT=0
TXQUEUELEN_WAS_EXPLICIT=0
TCP_MAX_TW_BUCKETS_WAS_EXPLICIT=0
TCP_MAX_SYN_BACKLOG_WAS_EXPLICIT=0
IPFRAG_HIGH_THRESH_WAS_EXPLICIT=0
NOFILE_LIMIT_WAS_EXPLICIT=0
FILE_MAX_WAS_EXPLICIT=0
NF_CONNTRACK_MAX_WAS_EXPLICIT=0
NF_CONNTRACK_HASH_SIZE_WAS_EXPLICIT=0
[[ -n "${PROFILE+x}" ]] && PROFILE_WAS_EXPLICIT=1
[[ -n "${ENABLE_NIC_TUNING+x}" ]] && ENABLE_NIC_TUNING_WAS_EXPLICIT=1
[[ -n "${RP_FILTER+x}" ]] && RP_FILTER_WAS_EXPLICIT=1
[[ -n "${MAXIMIZE_NIC_RING+x}" ]] && MAXIMIZE_NIC_RING_WAS_EXPLICIT=1
[[ -n "${IP_LOCAL_PORT_RANGE+x}" ]] && IP_LOCAL_PORT_RANGE_WAS_EXPLICIT=1
[[ -n "${SOCKET_BUFFER_DEFAULT+x}" ]] && SOCKET_BUFFER_DEFAULT_WAS_EXPLICIT=1
[[ -n "${SOCKET_BUFFER_MAX+x}" ]] && SOCKET_BUFFER_MAX_WAS_EXPLICIT=1
[[ -n "${NETDEV_MAX_BACKLOG+x}" ]] && NETDEV_MAX_BACKLOG_WAS_EXPLICIT=1
[[ -n "${NETDEV_BUDGET+x}" ]] && NETDEV_BUDGET_WAS_EXPLICIT=1
[[ -n "${NETDEV_BUDGET_USECS+x}" ]] && NETDEV_BUDGET_USECS_WAS_EXPLICIT=1
[[ -n "${RPS_FLOW_ENTRIES+x}" ]] && RPS_FLOW_ENTRIES_WAS_EXPLICIT=1
[[ -n "${TXQUEUELEN+x}" ]] && TXQUEUELEN_WAS_EXPLICIT=1
[[ -n "${TCP_MAX_TW_BUCKETS+x}" ]] && TCP_MAX_TW_BUCKETS_WAS_EXPLICIT=1
[[ -n "${TCP_MAX_SYN_BACKLOG+x}" ]] && TCP_MAX_SYN_BACKLOG_WAS_EXPLICIT=1
[[ -n "${IPFRAG_HIGH_THRESH+x}" ]] && IPFRAG_HIGH_THRESH_WAS_EXPLICIT=1
[[ -n "${NOFILE_LIMIT+x}" ]] && NOFILE_LIMIT_WAS_EXPLICIT=1
[[ -n "${FILE_MAX+x}" ]] && FILE_MAX_WAS_EXPLICIT=1
[[ -n "${NF_CONNTRACK_MAX+x}" ]] && NF_CONNTRACK_MAX_WAS_EXPLICIT=1
[[ -n "${NF_CONNTRACK_HASH_SIZE+x}" ]] && NF_CONNTRACK_HASH_SIZE_WAS_EXPLICIT=1

RED='\033[31;1m'
GREEN='\033[32;1m'
YELLOW='\033[33;1m'
BLUE='\033[34;1m'
NC='\033[0m'

info() { printf "${BLUE}%s${NC}\n" "$*"; }
ok() { printf "${GREEN}%s${NC}\n" "$*"; }
warn() { printf "${YELLOW}%s${NC}\n" "$*"; }
fail() { printf "${RED}%s${NC}\n" "$*"; }

prepare_main2_lock_file() {
  local create_status=0 lock_parent

  if ! lock_parent="$(dirname -- "${MAIN2_LOCK_FILE}")"; then
    fail "无法解析 main2 进程锁目录：${MAIN2_LOCK_FILE}"
    return 1
  fi
  if [[ ! -d "${lock_parent}" || -L "${lock_parent}" ]]; then
    fail "main2 进程锁目录不是安全的真实目录：${lock_parent}"
    return 1
  fi
  if [[ ! -e "${MAIN2_LOCK_FILE}" && ! -L "${MAIN2_LOCK_FILE}" ]]; then
    (umask 077; set -o noclobber; : > "${MAIN2_LOCK_FILE}") 2>/dev/null || create_status=$?
    if [[ "${create_status}" != "0" &&
          ! -e "${MAIN2_LOCK_FILE}" && ! -L "${MAIN2_LOCK_FILE}" ]]; then
      fail "无法创建 main2 进程锁：${MAIN2_LOCK_FILE}"
      return 1
    fi
  fi
  if [[ -L "${MAIN2_LOCK_FILE}" || ! -f "${MAIN2_LOCK_FILE}" ]]; then
    fail "main2 锁路径不是安全的普通文件：${MAIN2_LOCK_FILE}"
    return 1
  fi
  if ! chmod 0600 "${MAIN2_LOCK_FILE}"; then
    fail "无法设置 main2 进程锁权限：${MAIN2_LOCK_FILE}"
    return 1
  fi
}

run_main2_with_lock() {
  local lock_status=0
  if ! command -v flock >/dev/null 2>&1; then
    fail "未找到 flock；请先安装 Debian/Ubuntu 基础包 util-linux。"
    return 1
  fi
  prepare_main2_lock_file || return 1

  # The quoted command is expanded by the supervised child Bash.
  # shellcheck disable=SC2016
  flock --exclusive --nonblock --close --conflict-exit-code 200 \
    "${MAIN2_LOCK_FILE}" \
    bash -c '
      _main2_supervisor_exit() {
        child_status=$?
        trap - EXIT
        if [[ "${child_status}" == "200" ]]; then
          exit 199
        fi
        exit "${child_status}"
      }
      trap _main2_supervisor_exit EXIT
      main2_script="$1"
      shift
      . "${main2_script}"
      main2_locked_main "$@"
    ' main2-lock "${BASH_SOURCE[0]}" "$@" || lock_status=$?
  if [[ "${lock_status}" == "200" ]]; then
    fail "检测到另一份 main2.sh 正在运行，本次执行未修改系统。"
    return 1
  fi
  return "${lock_status}"
}

download_file() {
  local url="$1"
  local target="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${target}"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "${target}" "${url}"
  else
    fail "未找到 curl 或 wget，无法下载配套脚本。"
    return 1
  fi
}

support_script_expected_sha256() {
  local path="$1"
  case "${path}" in
    sysctl_optimization_debian_overwrite_main2.sh) printf '%s' 832b9060a9d7153c74814ded4cbc4b35cc738998b1c2ac43f70de793736ee3ba ;;
    scripts/swap.sh) printf '%s' 41c053c9a310fdb5de36832a5ee58fabee7e4e39e7ab5e60747b40e09f8bc28e ;;
    scripts/ssh_root.sh) printf '%s' 8835074f48a8d5ebe50d7a723dccfd03245f245f44ea0fc73be2313d4440f9ae ;;
    scripts/udp_multinic_main2.sh) printf '%s' 374d98155e6a26415418274663a291369017302693246101aa89eaf402d88b44 ;;
    scripts/mtu_mss_main2.sh) printf '%s' b1b3b3e93aa4353572e1c1d4c20835a243884978f76aeca4eb6b5b7d0b5c14f6 ;;
    *) return 1 ;;
  esac
}

support_script_is_repository_version() {
  local path="$1"
  local actual="$2"
  if [[ "${actual}" == "$(support_script_expected_sha256 "${path}")" ]]; then
    return 0
  fi
  case "${path}:${actual}" in
    sysctl_optimization_debian_overwrite_main2.sh:faaaf61b4756dd76548bdcd067653d3aed7a15f812680d13be8777e5f51dcfb9|\
    sysctl_optimization_debian_overwrite_main2.sh:3c182e7aaf39971bb56d00a4e6625ee2e00c3e9d35235fea4f0e9f0488749d4e|\
    sysctl_optimization_debian_overwrite_main2.sh:55171030719d1f3ca2a213d57425b1b35d62e6eb9754917335b3469895ba4c3f|\
    sysctl_optimization_debian_overwrite_main2.sh:14ec6ab107edf0bae40cfb527fb598b59377f45352ed2f1f4a09e6e2901659cb|\
    sysctl_optimization_debian_overwrite_main2.sh:c3603bfa2e2a8acacd9d03023136d3c74431fcc6ca872db400c817e50340bce3|\
    sysctl_optimization_debian_overwrite_main2.sh:de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181|\
    scripts/swap.sh:c66cb47b309abb443710d473b66380d14f9526ae1cd0d4e720a32a0dcbd49d60|\
    scripts/swap.sh:f40e4ba1b881a3d6a44c4b1a68de515dd183a2a73e887e1eb399def9762fab65|\
    scripts/swap.sh:bfab5c1ad70b404f6779f442cc4f953eade15979e337b28422ee2d806b1858d3|\
    scripts/swap.sh:f431b364f3e9a7bbca7e8858575d2ced85fe3d98000313f5d2ae6a20312de131|\
    scripts/ssh_root.sh:3cc5428c9cc4efe0ff2359375e96e9c36884e86c5fbf2469325f157b0618e553|\
    scripts/ssh_root.sh:5a4ec0c5f6c1907c0f92af96a69a0a62473f32bb1667da1d5ceee0b01afd6aed|\
    scripts/ssh_root.sh:f5e9f13a94acb111464995009996f17f00f356faeee12165835bf1a2f70be643|\
    scripts/ssh_root.sh:5a92bdc5a47947fc573e282c2d7967a5ec5a352ed59b1d0c0685e19f411b1c3e)
      return 0
      ;;
    *) return 1 ;;
  esac
}

remove_support_temporary_files() {
  local temporary_file
  for temporary_file in "$@"; do
    [[ -n "${temporary_file}" ]] || continue
    rm -f -- "${temporary_file}" || true
  done
}

ensure_support_scripts() {
  local path attempted_path target parent base expected actual url stage backup
  local rollback_failed=0
  local -a paths=(
    "sysctl_optimization_debian_overwrite_main2.sh"
    "scripts/swap.sh"
    "scripts/ssh_root.sh"
    "scripts/udp_multinic_main2.sh"
    "scripts/mtu_mss_main2.sh"
  )
  local -a update_paths=()
  local -A original_hash=()
  local -A staged_file=()
  local -A backup_file=()
  local -A existed=()
  local -a attempted_paths=()
  local -a temporary_files=()

  case "${AUTO_UPDATE_SUPPORT}" in
    0|1) ;;
    *) fail "AUTO_UPDATE_SUPPORT 必须是 0 或 1。"; return 1 ;;
  esac
  command -v sha256sum >/dev/null 2>&1 || {
    fail "未找到 sha256sum，无法校验配套脚本。"
    return 1
  }

  # Check every destination before downloading or replacing any file.
  for path in "${paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    parent="$(dirname "${target}")"
    if [[ -L "${parent}" || ( -e "${parent}" && ! -d "${parent}" ) ]]; then
      fail "配套脚本目录不是安全的真实目录，已停止同步：${parent}"
      return 1
    fi
    if [[ -e "${target}" || -L "${target}" ]] &&
       [[ ! -f "${target}" || -L "${target}" ]]; then
      fail "配套脚本路径不是普通文件，已停止同步：${target}"
      return 1
    fi
    expected="$(support_script_expected_sha256 "${path}")"
    if [[ ! -e "${target}" ]]; then
      original_hash["${path}"]="missing"
      update_paths+=("${path}")
      continue
    fi
    actual="$(sha256sum -- "${target}" | awk '{print $1}')"
    original_hash["${path}"]="${actual}"
    if ! support_script_is_repository_version "${path}" "${actual}"; then
      fail "检测到不属于本仓库历史版本的配套脚本，已停止全部同步：${target}"
      return 1
    fi
    if [[ "${AUTO_UPDATE_SUPPORT}" == "1" || "${actual}" != "${expected}" ]]; then
      update_paths+=("${path}")
    fi
  done

  (( ${#update_paths[@]} > 0 )) || return 0

  # Every staged file is created beside its target so the final rename stays
  # atomic even when scripts/ is a separate mount point.
  for path in "${update_paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    parent="$(dirname "${target}")"
    if ! install -d "${parent}" || [[ -L "${parent}" || ! -d "${parent}" ]]; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "无法创建安全的配套脚本目录，原文件均未修改：${parent}"
      return 1
    fi
  done

  for path in "${update_paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    parent="$(dirname "${target}")"
    base="$(basename "${target}")"
    expected="$(support_script_expected_sha256 "${path}")"
    url="${RAW_BASE_URL}/${path}"
    if ! stage="$(mktemp "${parent}/.main2-support-new-${base}.XXXXXX")"; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "无法创建配套脚本临时文件，原文件均未修改：${parent}"
      return 1
    fi
    temporary_files+=("${stage}")
    warn "正在下载并校验 ${path} ..."
    if ! download_file "${url}" "${stage}"; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "下载配套脚本失败，原文件均未修改：${url}"
      return 1
    fi
    actual="$(sha256sum -- "${stage}" | awk '{print $1}')"
    if [[ "${actual}" != "${expected}" ]] || ! bash -n "${stage}"; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "配套脚本校验失败，原文件均未修改：${path}"
      return 1
    fi
    if ! chmod 0755 "${stage}"; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "无法设置配套脚本权限，原文件均未修改：${path}"
      return 1
    fi
    staged_file["${path}"]="${stage}"
  done

  # Recheck destinations to prevent replacing a file changed during download.
  for path in "${update_paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    if [[ "${original_hash[${path}]}" == "missing" ]]; then
      if [[ -e "${target}" || -L "${target}" ]]; then
        remove_support_temporary_files "${temporary_files[@]}"
        fail "同步期间目标路径发生变化，原文件均未修改：${target}"
        return 1
      fi
    elif [[ ! -f "${target}" || -L "${target}" ]] ||
         [[ "$(sha256sum -- "${target}" | awk '{print $1}')" != "${original_hash[${path}]}" ]]; then
      remove_support_temporary_files "${temporary_files[@]}"
      fail "同步期间目标文件发生变化，原文件均未修改：${target}"
      return 1
    fi
  done

  for path in "${update_paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    parent="$(dirname "${target}")"
    base="$(basename "${target}")"
    if [[ -e "${target}" ]]; then
      if ! backup="$(mktemp "${parent}/.main2-support-backup-${base}.XXXXXX")"; then
        remove_support_temporary_files "${temporary_files[@]}"
        fail "无法创建配套脚本备份文件，原文件均未修改：${parent}"
        return 1
      fi
      temporary_files+=("${backup}")
      if ! cp -a -- "${target}" "${backup}"; then
        remove_support_temporary_files "${temporary_files[@]}"
        fail "无法备份配套脚本，原文件均未修改：${target}"
        return 1
      fi
      if [[ ! -f "${target}" || -L "${target}" ]] ||
         [[ "$(sha256sum -- "${target}" | awk '{print $1}')" != "${original_hash[${path}]}" ]] ||
         [[ "$(sha256sum -- "${backup}" | awk '{print $1}')" != "${original_hash[${path}]}" ]]; then
        remove_support_temporary_files "${temporary_files[@]}"
        fail "备份期间目标文件发生变化，原文件均未修改：${target}"
        return 1
      fi
      existed["${path}"]=1
      backup_file["${path}"]="${backup}"
    else
      existed["${path}"]=0
    fi
  done

  for path in "${update_paths[@]}"; do
    target="${SCRIPT_DIR}/${path}"
    attempted_paths+=("${path}")
    if mv -f -- "${staged_file[${path}]}" "${target}"; then
      continue
    fi

    for attempted_path in "${attempted_paths[@]}"; do
      target="${SCRIPT_DIR}/${attempted_path}"
      actual=""
      if [[ -f "${target}" && ! -L "${target}" ]]; then
        actual="$(sha256sum -- "${target}" | awk '{print $1}')"
      fi
      if [[ "${existed[${attempted_path}]}" == "1" ]]; then
        if [[ "${actual}" == "${original_hash[${attempted_path}]}" ]]; then
          continue
        fi
        if [[ ( -e "${target}" || -L "${target}" ) &&
              ( ! -f "${target}" || -L "${target}" ) ]]; then
          rollback_failed=1
        elif ! mv -f -- "${backup_file[${attempted_path}]}" "${target}"; then
          rollback_failed=1
        fi
      else
        if [[ ! -e "${target}" && ! -L "${target}" ]]; then
          continue
        fi
        if [[ ! -f "${target}" || -L "${target}" ]]; then
          rollback_failed=1
        else
          rm -f -- "${target}" || rollback_failed=1
        fi
      fi
    done
    remove_support_temporary_files "${temporary_files[@]}"
    if [[ "${rollback_failed}" == "1" ]]; then
      fail "配套脚本替换失败，且回滚未完整完成；请检查 ${SCRIPT_DIR}。"
    else
      fail "配套脚本替换失败，已恢复原文件。"
    fi
    return 1
  done

  remove_support_temporary_files "${temporary_files[@]}"
  ok "main2 配套脚本已覆盖更新到版本 ${MAIN2_BUNDLE_VERSION}。"
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

require_systemd() {
  if [[ ! -d /run/systemd/system ]] ||
     ! systemctl show --property=Version --value >/dev/null 2>&1; then
    fail "main2 需要由 systemd 作为 PID 1 运行；不支持容器、chroot 或未启动 systemd 的环境。"
    exit 1
  fi
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
  local codename="" os_id="" version_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
    version_id="${VERSION_ID:-}"
    codename="${VERSION_CODENAME:-}"
  fi

  if [[ -z "${codename}" ]]; then
    if [[ "${os_id}" != "debian" || ! -r /etc/debian_version ]]; then
      fail "无法从 /etc/os-release 精确读取 ${os_id:-当前系统} 的 VERSION_CODENAME。"
      return 1
    fi
    case "$(cat /etc/debian_version)" in
      13*) codename="trixie" ;;
      12*) codename="bookworm" ;;
      11*) codename="bullseye" ;;
      10*) codename="buster" ;;
      *) fail "无法识别 Debian 版本。"; return 1 ;;
    esac
  fi
  [[ "${codename}" =~ ^[a-z][a-z0-9]*$ ]] || {
    fail "系统版本代号格式无效：${codename}"
    return 1
  }
  if [[ "${os_id}" == "debian" ]]; then
    case "${version_id}:${codename}" in
      10:buster|11:bullseye|12:bookworm|13:trixie) ;;
      *)
        fail "Debian VERSION_ID=${version_id:-缺失} 与 VERSION_CODENAME=${codename} 不匹配。"
        return 1
        ;;
    esac
  fi

  printf "%s" "${codename}"
}

detect_deb_architecture() {
  local architecture
  command -v dpkg >/dev/null 2>&1 || {
    fail "未找到 dpkg，无法识别 Ubuntu 软件源架构。"
    return 1
  }
  architecture="$(dpkg --print-architecture)" || return 1
  [[ "${architecture}" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    fail "dpkg 返回的软件包架构格式无效：${architecture}"
    return 1
  }
  printf '%s' "${architecture}"
}

apt_update() {
  apt-get \
    -o Acquire::AllowReleaseInfoChange::Suite=true \
    -o Acquire::AllowReleaseInfoChange::Version=true \
    -o Acquire::AllowReleaseInfoChange::Codename=true \
    update
}

ensure_download_tool() {
  if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 || {
    fail "未找到 curl、wget 或 apt-get，无法自举下载配套脚本。"
    exit 1
  }

  warn "未找到 curl/wget，正在安装 ca-certificates 和 curl ..."
  export DEBIAN_FRONTEND=noninteractive
  apt_update
  apt-get install -y --no-install-recommends ca-certificates curl
  command -v curl >/dev/null 2>&1 || {
    fail "curl 安装完成后仍不可用，已停止执行。"
    exit 1
  }
}

source_uri_belongs_to_system() {
  local os_id="$1"
  local uri="${2%/}"
  case "${os_id}" in
    debian)
      [[ "${uri}" =~ ^https?://(deb\.debian\.org/debian|deb\.debian\.org/debian-security|security\.debian\.org/debian-security|ftp\.debian\.org/debian|ftp\.[^/]+\.debian\.org/debian|http\.us\.debian\.org/debian|httpredir\.debian\.org/debian|archive\.debian\.org/debian|archive\.debian\.org/debian-security)$ ]]
      ;;
    ubuntu)
      [[ "${uri}" =~ ^https?://(([[:alnum:]-]+\.)*archive\.ubuntu\.com/ubuntu|security\.ubuntu\.com/ubuntu|ports\.ubuntu\.com/ubuntu-ports|old-releases\.ubuntu\.com/ubuntu)$ ]]
      ;;
    *) return 1 ;;
  esac
}

active_source_uris() {
  local file="$1"
  case "${file}" in
    *.list)
      awk '
        /^[[:space:]]*(#|$)/ { next }
        {
          line = $0
          sub(/#.*/, "", line)
          sub(/^[[:space:]]+/, "", line)
          count = split(line, fields, /[[:space:]]+/)
          if (fields[1] != "deb" && fields[1] != "deb-src") next
          field_index = 2
          if (fields[field_index] ~ /^\[/) {
            while (field_index <= count && fields[field_index] !~ /\]$/) field_index++
            field_index++
          }
          if (field_index <= count) print fields[field_index]
        }
      ' "${file}"
      ;;
    *.sources)
      awk '
        function reset_stanza() {
          types = ""
          uris = ""
          enabled = "yes"
          current = ""
        }
        function emit_stanza(    count, item_index, values) {
          if (tolower(enabled) == "no" || types !~ /(^|[[:space:]])deb(-src)?([[:space:]]|$)/) return
          count = split(uris, values, /[[:space:]]+/)
          for (item_index = 1; item_index <= count; item_index++) {
            if (values[item_index] != "") print values[item_index]
          }
        }
        BEGIN { reset_stanza() }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { emit_stanza(); reset_stanza(); next }
        /^[[:space:]]/ {
          value = $0
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          if (current == "types") types = types " " value
          if (current == "uris") uris = uris " " value
          if (current == "enabled") enabled = enabled " " value
          next
        }
        {
          separator = index($0, ":")
          if (separator == 0) { current = ""; next }
          field = tolower(substr($0, 1, separator - 1))
          value = substr($0, separator + 1)
          sub(/^[[:space:]]+/, "", value)
          sub(/[[:space:]]+$/, "", value)
          current = field
          if (field == "types") types = value
          else if (field == "uris") uris = value
          else if (field == "enabled") enabled = value
        }
        END { emit_stanza() }
      ' "${file}"
      ;;
    *) return 1 ;;
  esac
}

archive_keyring_for_os() {
  case "$1" in
    debian) printf '%s' "${DEBIAN_ARCHIVE_KEYRING}" ;;
    ubuntu) printf '%s' "${UBUNTU_ARCHIVE_KEYRING}" ;;
    *) fail "不支持的软件源系统 ID：$1"; return 1 ;;
  esac
}

require_archive_keyring() {
  local os_id="$1"
  local keyring link_target link_target_path
  keyring="$(archive_keyring_for_os "${os_id}")" || return 1

  if [[ ! -e "${keyring}" && ! -L "${keyring}" ]]; then
    fail "发行版 APT 密钥环不存在：${keyring}"
    return 1
  fi
  if [[ -L "${keyring}" ]]; then
    if [[ "${os_id}" != "debian" ]]; then
      fail "Ubuntu APT 密钥环不允许使用符号链接：${keyring}"
      return 1
    fi
    link_target="$(readlink -- "${keyring}")" || {
      fail "无法读取 Debian APT 密钥环符号链接：${keyring}"
      return 1
    }
    if [[ "${link_target}" != "${DEBIAN_ARCHIVE_KEYRING_LINK_TARGET}" ]]; then
      fail "Debian APT 密钥环不是官方包定义的符号链接：${keyring}"
      return 1
    fi
    link_target_path="${keyring%/*}/${DEBIAN_ARCHIVE_KEYRING_LINK_TARGET}"
    if [[ ! -f "${link_target_path}" || -L "${link_target_path}" ]]; then
      fail "Debian APT 密钥环链接目标不是普通文件：${link_target_path}"
      return 1
    fi
    if [[ ! -r "${link_target_path}" ]]; then
      fail "Debian APT 密钥环链接目标不可读：${link_target_path}"
      return 1
    fi
    return 0
  fi
  if [[ ! -f "${keyring}" ]]; then
    fail "发行版 APT 密钥环不是普通文件：${keyring}"
    return 1
  fi
  if [[ ! -r "${keyring}" ]]; then
    fail "发行版 APT 密钥环不可读：${keyring}"
    return 1
  fi
}

deb822_file_distribution_match() {
  local os_id="$1"
  local file="$2"
  local codename="$3"
  local keyring="$4"
  local match_mode="$5"

  [[ "${file}" == *.sources ]] || return 1
  awk -v os_id="${os_id}" -v codename="${codename}" \
      -v keyring="${keyring}" -v match_mode="${match_mode}" '
    function reset_stanza() {
      types = ""
      suites = ""
      signed_by = ""
      enabled = "yes"
      current = ""
    }
    function suite_is_valid(suite) {
      if (suite == codename || suite == codename "-updates" ||
          suite == codename "-backports" || suite == codename "-security") return 1
      if (os_id == "ubuntu" && suite == codename "-proposed") return 1
      if (os_id == "debian" && codename == "buster" && suite == codename "/updates") return 1
      return 0
    }
    function validate_stanza(    count, item_index, stanza_valid, values) {
      if (tolower(enabled) == "no" || types !~ /(^|[[:space:]])deb(-src)?([[:space:]]|$)/) return
      active_stanzas++
      stanza_valid = signed_by == keyring
      count = split(suites, values, /[[:space:]]+/)
      if (count == 0) stanza_valid = 0
      for (item_index = 1; item_index <= count; item_index++) {
        if (values[item_index] != "" && !suite_is_valid(values[item_index])) stanza_valid = 0
      }
      if (stanza_valid) matched_stanzas++
      else invalid = 1
    }
    BEGIN { reset_stanza() }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { validate_stanza(); reset_stanza(); next }
    /^[[:space:]]/ {
      value = $0
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (current == "types") types = types " " value
      else if (current == "suites") suites = suites " " value
      else if (current == "signed-by") signed_by = signed_by " " value
      else if (current == "enabled") enabled = enabled " " value
      next
    }
    {
      separator = index($0, ":")
      if (separator == 0) { current = ""; next }
      field = tolower(substr($0, 1, separator - 1))
      value = substr($0, separator + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      current = field
      if (field == "types") types = value
      else if (field == "suites") suites = value
      else if (field == "signed-by") signed_by = value
      else if (field == "enabled") enabled = value
    }
    END {
      validate_stanza()
      if (match_mode == "any") exit(matched_stanzas > 0 ? 0 : 1)
      exit(active_stanzas > 0 && invalid == 0 ? 0 : 1)
    }
  ' "${file}"
}

list_file_distribution_match() {
  local os_id="$1"
  local file="$2"
  local codename="$3"
  local keyring="$4"
  local match_mode="$5"

  [[ "${file}" == *.list ]] || return 1
  awk -v os_id="${os_id}" -v codename="${codename}" \
      -v keyring="${keyring}" -v match_mode="${match_mode}" '
    function suite_is_valid(suite) {
      if (suite == codename || suite == codename "-updates" ||
          suite == codename "-backports" || suite == codename "-security") return 1
      if (os_id == "ubuntu" && suite == codename "-proposed") return 1
      if (os_id == "debian" && codename == "buster" && suite == codename "/updates") return 1
      return 0
    }
    /^[[:space:]]*(#|$)/ { next }
    {
      line = $0
      sub(/#.*/, "", line)
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      count = split(line, fields, /[[:space:]]+/)
      if (fields[1] != "deb" && fields[1] != "deb-src") next
      active_entries++
      field_index = 2
      signed_by = ""
      if (fields[field_index] ~ /^\[/) {
        while (field_index <= count) {
          option = fields[field_index]
          sub(/^\[/, "", option)
          sub(/\]$/, "", option)
          if (option ~ /^signed-by=/) signed_by = substr(option, 11)
          if (fields[field_index] ~ /\]$/) {
            field_index++
            break
          }
          field_index++
        }
      }
      suite_index = field_index + 1
      entry_valid = signed_by == keyring && suite_index <= count &&
                    suite_is_valid(fields[suite_index])
      if (entry_valid) matched_entries++
      else invalid = 1
    }
    END {
      if (match_mode == "any") exit(matched_entries > 0 ? 0 : 1)
      exit(active_entries > 0 && invalid == 0 ? 0 : 1)
    }
  ' "${file}"
}

source_file_is_distribution_source() {
  local os_id="$1"
  local file="$2"
  local codename="$3"
  local keyring="$4"
  case "${file}" in
    *.list) list_file_distribution_match "${os_id}" "${file}" "${codename}" "${keyring}" all ;;
    *.sources) deb822_file_distribution_match "${os_id}" "${file}" "${codename}" "${keyring}" all ;;
    *) return 1 ;;
  esac
}

source_file_has_distribution_source() {
  local os_id="$1"
  local file="$2"
  local codename="$3"
  local keyring="$4"
  case "${file}" in
    *.list) list_file_distribution_match "${os_id}" "${file}" "${codename}" "${keyring}" any ;;
    *.sources) deb822_file_distribution_match "${os_id}" "${file}" "${codename}" "${keyring}" any ;;
    *) return 1 ;;
  esac
}

source_file_has_active_uri() {
  local file="$1"
  local uri
  while IFS= read -r uri; do
    [[ -n "${uri}" ]] && return 0
  done < <(active_source_uris "${file}")
  return 1
}

source_file_belongs_to_system() {
  local os_id="$1"
  local file="$2"
  local uri

  while IFS= read -r uri; do
    if source_uri_belongs_to_system "${os_id}" "${uri}"; then
      return 0
    fi
  done < <(active_source_uris "${file}")
  return 1
}

source_file_has_non_system_uri() {
  local os_id="$1"
  local file="$2"
  local uri

  while IFS= read -r uri; do
    if ! source_uri_belongs_to_system "${os_id}" "${uri}"; then
      return 0
    fi
  done < <(active_source_uris "${file}")
  return 1
}

unique_source_backup_path() {
  local path="$1"
  local suffix="$2"
  local result="${path}.${suffix}"
  local index=0

  while [[ -e "${result}" || -L "${result}" ]]; do
    index=$((index + 1))
    result="${path}.${suffix}.${index}"
  done
  printf '%s' "${result}"
}

prepare_apt_source_directories() {
  local source_dir="/etc/apt/sources.list.d"
  [[ -d /etc/apt && ! -L /etc/apt ]] || {
    fail "APT 配置目录不是安全的真实目录：/etc/apt"
    return 1
  }
  if [[ ( -e "${source_dir}" || -L "${source_dir}" ) &&
        ( ! -d "${source_dir}" || -L "${source_dir}" ) ]]; then
    fail "APT 扩展源目录不是安全的真实目录：${source_dir}"
    return 1
  fi
  if [[ ! -e "${source_dir}" && ! -L "${source_dir}" ]]; then
    install -d -m 0755 "${source_dir}" || return 1
  fi
  [[ -d "${source_dir}" && ! -L "${source_dir}" ]] || {
    fail "APT 扩展源目录不是安全的真实目录：${source_dir}"
    return 1
  }
}

rollback_official_sources() {
  local target="$1"
  local target_existed="$2"
  local target_backup="$3"
  shift 3
  local rollback_failed=0 original disabled

  if [[ "${target_existed}" == "1" ]]; then
    if [[ -f "${target_backup}" && ! -L "${target_backup}" ]]; then
      if [[ -e "${target}" || -L "${target}" ]]; then
        if [[ ! -f "${target}" || -L "${target}" ]] ||
           ! rm -f -- "${target}"; then
          rollback_failed=1
        fi
      fi
      if [[ ! -e "${target}" && ! -L "${target}" ]] &&
         ! mv -f -- "${target_backup}" "${target}"; then
        rollback_failed=1
      fi
    elif [[ -e "${target_backup}" || -L "${target_backup}" ]]; then
      rollback_failed=1
    elif [[ ! -f "${target}" || -L "${target}" ]]; then
      rollback_failed=1
    fi
  elif [[ -e "${target}" || -L "${target}" ]]; then
    if [[ ! -f "${target}" || -L "${target}" ]] || ! rm -f -- "${target}"; then
      rollback_failed=1
    fi
  fi

  while (( $# >= 2 )); do
    original="$1"
    disabled="$2"
    shift 2
    if [[ -f "${disabled}" && ! -L "${disabled}" &&
          ! -e "${original}" && ! -L "${original}" ]]; then
      if ! mv -f -- "${disabled}" "${original}"; then
        rollback_failed=1
      fi
    elif [[ ! -f "${original}" || -L "${original}" ||
            -e "${disabled}" || -L "${disabled}" ]]; then
      rollback_failed=1
    fi
  done
  [[ "${rollback_failed}" == "0" ]]
}

rollback_source_transaction_on_exit() {
  local exit_status=$?
  trap - EXIT
  trap '' INT TERM
  if [[ "${source_transaction_active:-0}" == "1" ]]; then
    if rollback_official_sources \
        "${target}" "${target_existed}" "${target_backup}" "${moved_pairs[@]}"; then
      fail "官方源切换被中断，已恢复执行前的软件源。"
    else
      fail "官方源切换被中断，且原软件源未完整恢复；请立即检查 /etc/apt。"
    fi
  fi
  exit "${exit_status}"
}

exit_if_source_transaction_interrupted() {
  if [[ "${source_transaction_interrupted:-0}" == "1" ]]; then
    exit "${source_transaction_signal_status:-1}"
  fi
}

activate_official_sources() (
  local os_id="$1"
  local staged_source_file="$2"
  local codename="$3"
  local archive_keyring="$4"
  local target="/etc/apt/sources.list"
  local source_dir="/etc/apt/sources.list.d"
  local standard_source_file stamp target_backup="" file disabled
  local target_existed=0 rollback_failed=0 source_move_completed=0 apt_update_status=0
  local source_transaction_active=0
  local source_transaction_interrupted=0 source_transaction_signal_status=0
  local -a source_files=()
  local -a moved_pairs=()

  case "${os_id}" in
    debian) standard_source_file="${source_dir}/debian.sources" ;;
    ubuntu) standard_source_file="${source_dir}/ubuntu.sources" ;;
    *) fail "不支持的软件源系统 ID：${os_id}"; return 1 ;;
  esac
  prepare_apt_source_directories || return 1
  [[ -f "${staged_source_file}" && ! -L "${staged_source_file}" ]] || {
    fail "官方源暂存文件不是安全的普通文件：${staged_source_file}"
    return 1
  }
  if [[ ( -e "${target}" || -L "${target}" ) &&
        ( ! -f "${target}" || -L "${target}" ) ]]; then
    fail "APT 主源文件不是安全的普通文件：${target}"
    return 1
  fi
  if [[ -f "${target}" ]] && source_file_has_active_uri "${target}"; then
    if source_file_is_distribution_source \
        "${os_id}" "${target}" "${codename}" "${archive_keyring}"; then
      :
    elif source_file_has_distribution_source \
        "${os_id}" "${target}" "${codename}" "${archive_keyring}" ||
         source_file_has_non_system_uri "${os_id}" "${target}"; then
      fail "APT 主源包含无法确认归属的活动仓库：${target}"
      fail "请先把第三方仓库拆分到独立文件，或移除旧的非官方系统镜像。"
      return 1
    fi
  fi
  if [[ ( -e "${standard_source_file}" || -L "${standard_source_file}" ) &&
        ( ! -f "${standard_source_file}" || -L "${standard_source_file}" ) ]]; then
    fail "APT 系统源文件不是安全的普通文件：${standard_source_file}"
    return 1
  fi

  shopt -s nullglob
  for file in "${source_dir}"/*.list "${source_dir}"/*.sources; do
    if [[ -L "${file}" || ! -f "${file}" ]]; then
      fail "APT 源路径不是安全的普通文件：${file}"
      shopt -u nullglob
      return 1
    fi
    if ! source_file_has_active_uri "${file}"; then
      continue
    fi
    if source_file_is_distribution_source \
        "${os_id}" "${file}" "${codename}" "${archive_keyring}"; then
      source_files+=("${file}")
    elif source_file_has_distribution_source \
        "${os_id}" "${file}" "${codename}" "${archive_keyring}"; then
      fail "检测到系统源与第三方源混合在同一文件，未自动移动：${file}"
      fail "请先把第三方仓库拆分到独立的 .list 或 .sources 文件。"
      shopt -u nullglob
      return 1
    elif source_file_belongs_to_system "${os_id}" "${file}"; then
      if source_file_has_non_system_uri "${os_id}" "${file}"; then
        fail "检测到系统源与第三方源混合在同一文件，未自动移动：${file}"
        fail "请先把第三方仓库拆分到独立的 .list 或 .sources 文件。"
        shopt -u nullglob
        return 1
      fi
      source_files+=("${file}")
    elif [[ "${file}" == "${standard_source_file}" ]]; then
      fail "无法确认标准系统源文件只包含 ${os_id} 仓库：${file}"
      fail "请先把第三方仓库拆分到独立的 .list 或 .sources 文件。"
      shopt -u nullglob
      return 1
    fi
  done
  shopt -u nullglob

  stamp="$(date +%Y%m%d%H%M%S)" || return 1
  if [[ -e "${target}" ]]; then
    target_existed=1
    target_backup="$(unique_source_backup_path "${target}" "bak.${stamp}")" || return 1
  fi

  trap 'source_transaction_interrupted=1; source_transaction_signal_status=130' INT
  trap 'source_transaction_interrupted=1; source_transaction_signal_status=143' TERM
  trap rollback_source_transaction_on_exit EXIT

  if [[ "${target_existed}" == "1" ]]; then
    if ! mv -- "${target}" "${target_backup}"; then
      if [[ -f "${target_backup}" && ! -L "${target_backup}" &&
            ! -e "${target}" && ! -L "${target}" ]]; then
        source_transaction_active=1
      else
        trap - EXIT INT TERM
        if [[ "${source_transaction_interrupted}" == "1" ]]; then
          return "${source_transaction_signal_status}"
        fi
        fail "无法备份 APT 主源文件：${target}"
        return 1
      fi
    else
      source_transaction_active=1
    fi
  else
    source_transaction_active=1
  fi
  exit_if_source_transaction_interrupted

  for file in "${source_files[@]}"; do
    exit_if_source_transaction_interrupted
    disabled="$(unique_source_backup_path "${file}" "disabled.${stamp}")" || {
      rollback_failed=1
      break
    }
    source_move_completed=0
    if ! mv -- "${file}" "${disabled}"; then
      rollback_failed=1
      if [[ -f "${disabled}" && ! -L "${disabled}" &&
            ! -e "${file}" && ! -L "${file}" ]]; then
        source_move_completed=1
      fi
    else
      source_move_completed=1
    fi
    if [[ "${source_move_completed}" == "1" ]]; then
      moved_pairs+=("${file}" "${disabled}")
    fi
    exit_if_source_transaction_interrupted
    [[ "${rollback_failed}" == "0" ]] || break
    warn "已停用旧 ${os_id} 系统源：${file} -> ${disabled}"
  done

  exit_if_source_transaction_interrupted
  if [[ "${rollback_failed}" == "0" ]]; then
    if ! mv -- "${staged_source_file}" "${target}"; then
      rollback_failed=1
    fi
    exit_if_source_transaction_interrupted
  fi
  if [[ "${rollback_failed}" == "1" ]]; then
    trap '' INT TERM
    if rollback_official_sources "${target}" "${target_existed}" "${target_backup}" \
      "${moved_pairs[@]}"; then
      source_transaction_active=0
      trap - EXIT INT TERM
      fail "官方源写入失败，已恢复原软件源。"
    else
      source_transaction_active=0
      trap - EXIT INT TERM
      fail "官方源写入失败，且原软件源未完整恢复；请立即检查 /etc/apt。"
    fi
    return 1
  fi

  exit_if_source_transaction_interrupted
  apt_update || apt_update_status=$?
  exit_if_source_transaction_interrupted
  if [[ "${apt_update_status}" != "0" ]]; then
    trap '' INT TERM
    if rollback_official_sources "${target}" "${target_existed}" "${target_backup}" \
      "${moved_pairs[@]}"; then
      source_transaction_active=0
      trap - EXIT INT TERM
      if apt_update; then
        fail "官方源刷新失败，已恢复并重新刷新执行前的软件源。"
      else
        fail "官方源刷新失败；原软件源已恢复，但原软件源也刷新失败。"
      fi
    else
      source_transaction_active=0
      trap - EXIT INT TERM
      fail "官方源刷新失败，且原软件源未完整恢复；请立即检查 /etc/apt。"
    fi
    return 1
  fi

  source_transaction_active=0
  trap - EXIT INT TERM
  if [[ "${target_existed}" == "1" ]]; then
    ok "原 APT 主源已备份为 ${target_backup}"
  fi
)

write_debian_official_sources() {
  local target="$1"
  local codename="$2"
  local archive_keyring="$3"
  local components

  case "${codename}" in
    bookworm|trixie) components="main contrib non-free non-free-firmware" ;;
    buster|bullseye) components="main contrib non-free" ;;
    *) fail "不支持将 Debian ${codename} 设置为本脚本内置官方源。"; return 1 ;;
  esac

  if [[ "${codename}" == "buster" ]]; then
    cat > "${target}" <<EOF
deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian ${codename} ${components}
deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian ${codename}-updates ${components}
deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian-security ${codename}/updates ${components}
EOF
  else
    cat > "${target}" <<EOF
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian ${codename} ${components}
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian ${codename}-updates ${components}
deb [signed-by=${archive_keyring}] http://security.debian.org/debian-security ${codename}-security ${components}
EOF
  fi
}

write_ubuntu_official_sources() {
  local target="$1"
  local codename="$2"
  local architecture="$3"
  local archive_keyring="$4"
  local archive_uri security_uri
  local components="main restricted universe multiverse"

  case "${architecture}" in
    amd64|i386)
      archive_uri="http://archive.ubuntu.com/ubuntu"
      security_uri="http://security.ubuntu.com/ubuntu"
      ;;
    arm64|armhf|ppc64el|riscv64|s390x)
      archive_uri="http://ports.ubuntu.com/ubuntu-ports"
      security_uri="${archive_uri}"
      ;;
    *) fail "本脚本未配置 Ubuntu ${architecture} 的官方仓库地址。"; return 1 ;;
  esac

  cat > "${target}" <<EOF
deb [arch=${architecture} signed-by=${archive_keyring}] ${archive_uri} ${codename} ${components}
deb [arch=${architecture} signed-by=${archive_keyring}] ${archive_uri} ${codename}-updates ${components}
deb [arch=${architecture} signed-by=${archive_keyring}] ${archive_uri} ${codename}-backports ${components}
deb [arch=${architecture} signed-by=${archive_keyring}] ${security_uri} ${codename}-security ${components}
EOF
}

set_debian_sources() {
  local codename archive_keyring staged_source_file
  require_supported_os
  if [[ "$(system_id)" != "debian" ]]; then
    fail "设置 Debian 官方源仅支持 Debian 系统。"
    return 1
  fi
  codename="$(detect_codename)" || return 1
  require_archive_keyring debian || return 1
  archive_keyring="$(archive_keyring_for_os debian)" || return 1
  prepare_apt_source_directories || return 1
  staged_source_file="$(mktemp /etc/apt/.main2-debian-sources.XXXXXX)" || return 1
  if ! write_debian_official_sources \
       "${staged_source_file}" "${codename}" "${archive_keyring}" ||
     ! chmod 0644 "${staged_source_file}" ||
     ! activate_official_sources \
       debian "${staged_source_file}" "${codename}" "${archive_keyring}"; then
    rm -f -- "${staged_source_file}" || true
    return 1
  fi
  ok "Debian ${codename} 官方源已设置并刷新。"
}

set_ubuntu_sources() {
  local codename architecture archive_keyring staged_source_file
  require_supported_os
  if [[ "$(system_id)" != "ubuntu" ]]; then
    fail "设置 Ubuntu 官方源仅支持 Ubuntu 系统。"
    return 1
  fi
  codename="$(detect_codename)" || return 1
  architecture="$(detect_deb_architecture)" || return 1
  require_archive_keyring ubuntu || return 1
  archive_keyring="$(archive_keyring_for_os ubuntu)" || return 1
  prepare_apt_source_directories || return 1
  staged_source_file="$(mktemp /etc/apt/.main2-ubuntu-sources.XXXXXX)" || return 1
  if ! write_ubuntu_official_sources \
       "${staged_source_file}" "${codename}" "${architecture}" "${archive_keyring}" ||
     ! chmod 0644 "${staged_source_file}" ||
     ! activate_official_sources \
       ubuntu "${staged_source_file}" "${codename}" "${archive_keyring}"; then
    rm -f -- "${staged_source_file}" || true
    return 1
  fi
  ok "Ubuntu ${codename} ${architecture} 官方源已设置并刷新。"
}

install_base_tools() {
  require_supported_os || return 1
  export DEBIAN_FRONTEND=noninteractive
  apt_update || return 1
  apt-get install -y --no-install-recommends \
    ca-certificates curl wget gnupg lsb-release iproute2 ethtool procps gawk || return 1
  ok "基础组件安装完成。"
}

set_system_sources() {
  case "$(system_id)" in
    debian) set_debian_sources ;;
    ubuntu) set_ubuntu_sources ;;
    *) fail "仅支持设置 Debian 或 Ubuntu 官方源。"; return 1 ;;
  esac
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

has_legacy_limits_prefix() {
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
    NR == 8 && NF == 4 && $1 == "root" && $2 == "hard" && $3 == "nofile" && $4 == limit { valid = 1; next }
    NR > 8 { next }
    { exit 1 }
    END { if (NR < 8 || limit == "" || !valid) exit 1 }
  ' "${path}"
}

restore_legacy_sysctl() {
  local target="/etc/sysctl.conf"
  local backup saved
  if [[ -n "${LEGACY_BACKUP_SUFFIX}" ]]; then
    [[ "${LEGACY_BACKUP_ALREADY_RESTORED}" == "0" ]] || return 0
    backup="${target}.bak.${LEGACY_BACKUP_SUFFIX}"
    saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
    cp -a "${target}" "${saved}" || return 1
    cp -a "${backup}" "${target}" || return 1
    LEGACY_SYSCTL_RESTORED=1
    ok "已按明确指定的时间戳从 ${backup} 恢复 ${target}；原文件保存在 ${saved}。"
    return 0
  fi

  is_legacy_sysctl_file "${target}" || return 0
  LEGACY_SYSCTL_MIGRATION=1
  saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
  cp -a "${target}" "${saved}" || return 1
  warn "检测到旧版覆盖的 ${target}；新版优化器将移除旧版管理键并保留其他现有内容。当前文件已备份为 ${saved}。"
}

restore_legacy_limits() {
  local target="/etc/security/limits.conf"
  local backup saved tmp
  if [[ -n "${LEGACY_BACKUP_SUFFIX}" ]]; then
    [[ "${LEGACY_BACKUP_ALREADY_RESTORED}" == "0" ]] || return 0
    backup="${target}.bak.${LEGACY_BACKUP_SUFFIX}"
    saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
    cp -a "${target}" "${saved}" || return 1
    cp -a "${backup}" "${target}" || return 1
    ok "已按明确指定的时间戳从 ${backup} 恢复 ${target}；原文件保存在 ${saved}。"
    return 0
  fi

  if ! is_legacy_limits_file "${target}"; then
    [[ -f "${LEGACY_MARK_FILE}" && ! -L "${LEGACY_MARK_FILE}" ]] || return 0
    has_legacy_limits_prefix "${target}" || return 0
  fi
  saved="${target}.pre-main2.$(date +%Y%m%d%H%M%S)"
  cp -a "${target}" "${saved}" || return 1
  tmp="$(mktemp)" || return 1
  if ! awk 'NR > 8 { print }' "${target}" > "${tmp}"; then
    rm -f -- "${tmp}" || true
    return 1
  fi
  if ! install -m 0644 "${tmp}" "${target}"; then
    rm -f -- "${tmp}" || true
    return 1
  fi
  rm -f -- "${tmp}" || return 1
  warn "已移除精确匹配的旧版 8 行 limits 配置并保留后续自定义内容；未自动选择历史备份，旧版文件保存在 ${saved}。"
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

validate_stored_port_range() {
  local value="$1"
  local start end extra
  [[ -n "${value}" ]] || return 0
  read -r start end extra <<< "${value}"
  [[ -z "${extra:-}" &&
     "${start:-}" =~ ^(0|[1-9][0-9]{0,4})$ &&
     "${end:-}" =~ ^(0|[1-9][0-9]{0,4})$ ]] || return 1
  (( 10#${start} >= 1 && 10#${end} <= 65535 && 10#${start} < 10#${end} ))
}

validate_optional_positive_decimal() {
  local value="$1"
  [[ -z "${value}" || "${value}" =~ ^[1-9][0-9]{0,9}$ ]]
}

managed_network_fingerprint() {
  local format="${1:-${MAIN2_MANAGED_CONFIG_FORMAT}}"
  local path actual
  local -a managed_paths=()
  case "${format}" in
    1)
      managed_paths=(
        /etc/modprobe.d/99-network-optimization.conf
        /etc/modules-load.d/99-network-optimization.conf
        /etc/security/limits.d/99-network-optimization.conf
        /etc/systemd/system.conf.d/99-limits.conf
        /etc/systemd/user.conf.d/99-limits.conf
        /etc/profile.d/99-ulimit.sh
        /etc/sysctl.d/99-network-optimization.conf
        /etc/default/network-optimization-sysctl
        /usr/local/sbin/network-optimization-sysctl.sh
        /etc/systemd/system/network-optimization-sysctl.service
        /etc/default/network-max-tune
        /usr/local/sbin/network-max-tune.sh
        /etc/systemd/system/network-max-tune.service
      )
      ;;
    *) return 1 ;;
  esac

  {
    for path in "${managed_paths[@]}"; do
      printf '%s\0' "${path}"
      if [[ ! -e "${path}" && ! -L "${path}" ]]; then
        printf 'missing\0'
      elif [[ -f "${path}" && ! -L "${path}" ]]; then
        actual="$(sha256sum -- "${path}" | awk '{print $1}')" || return 1
        [[ "${actual}" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf 'file\0%s\0' "${actual}"
      else
        return 1
      fi
    done
  } | sha256sum | awk '{print $1}'
}

validate_install_state_values() {
  local value
  local -a performance_values=(
    "${STORED_SOCKET_BUFFER_DEFAULT}"
    "${STORED_SOCKET_BUFFER_MAX}"
    "${STORED_NETDEV_MAX_BACKLOG}"
    "${STORED_NETDEV_BUDGET}"
    "${STORED_NETDEV_BUDGET_USECS}"
    "${STORED_RPS_FLOW_ENTRIES}"
    "${STORED_TXQUEUELEN}"
    "${STORED_TCP_MAX_TW_BUCKETS}"
    "${STORED_TCP_MAX_SYN_BACKLOG}"
    "${STORED_IPFRAG_HIGH_THRESH}"
    "${STORED_NOFILE_LIMIT}"
    "${STORED_FILE_MAX}"
    "${STORED_NF_CONNTRACK_MAX}"
    "${STORED_NF_CONNTRACK_HASH_SIZE}"
  )
  [[ "${INSTALLED_BUNDLE_VERSION}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  [[ "${INSTALLED_BUNDLE_MAIN2_SHA256}" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "${APPLIED_MAIN2_VERSION}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  [[ "${PENDING_MAIN2_VERSION}" =~ ^(0|[1-9][0-9]{0,9})$ ]] || return 1
  case "${PENDING_REQUIRES_MANAGED_OVERWRITE}" in 0|1) ;; *) return 1 ;; esac
  if [[ "${PENDING_MAIN2_VERSION}" == "0" ]]; then
    [[ -z "${PENDING_MAIN2_SHA256}" &&
       "${PENDING_REQUIRES_MANAGED_OVERWRITE}" == "0" ]] || return 1
  else
    [[ "${PENDING_MAIN2_SHA256}" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  if [[ "${APPLIED_MAIN2_VERSION}" == "0" ]]; then
    [[ -z "${APPLIED_MAIN2_SHA256}" &&
       -z "${STORED_MANAGED_CONFIG_FORMAT}" &&
       -z "${STORED_MANAGED_CONFIG_SHA256}" ]] || return 1
    if [[ "${PENDING_MAIN2_VERSION}" == "0" ]]; then
      [[ -z "${STORED_PROFILE}" &&
         -z "${STORED_ENABLE_NIC_TUNING}" && -z "${STORED_RP_FILTER}" &&
         -z "${STORED_MAXIMIZE_NIC_RING}" && -z "${STORED_IP_LOCAL_PORT_RANGE}" ]] || return 1
      for value in "${performance_values[@]}"; do
        [[ -z "${value}" ]] || return 1
      done
      return
    fi
  else
    [[ "${APPLIED_MAIN2_SHA256}" =~ ^[0-9a-f]{64}$ ]] || return 1
    case "${STORED_MANAGED_CONFIG_FORMAT}" in 1) ;; *) return 1 ;; esac
    [[ "${STORED_MANAGED_CONFIG_SHA256}" =~ ^[0-9a-f]{64}$ ]] || return 1
  fi
  case "${STORED_PROFILE}" in balanced|max) ;; *) return 1 ;; esac
  case "${STORED_ENABLE_NIC_TUNING}" in 0|1) ;; *) return 1 ;; esac
  case "${STORED_RP_FILTER}" in 0|1|2) ;; *) return 1 ;; esac
  case "${STORED_MAXIMIZE_NIC_RING}" in 0|1) ;; *) return 1 ;; esac
  validate_stored_port_range "${STORED_IP_LOCAL_PORT_RANGE}" || return 1
  for value in "${performance_values[@]}"; do
    validate_optional_positive_decimal "${value}" || return 1
  done
  if [[ -n "${STORED_NETDEV_BUDGET_USECS}" ]] &&
     (( 10#${STORED_NETDEV_BUDGET_USECS} > 2147483647 )); then
    return 1
  fi
}

write_install_state() {
  local state_dir tmp
  state_dir="$(dirname "${MAIN2_INSTALL_STATE_FILE}")"
  if [[ -L "${state_dir}" || ( -e "${state_dir}" && ! -d "${state_dir}" ) ]]; then
    fail "main2 状态目录不是安全的真实目录：${state_dir}"
    return 1
  fi
  if [[ ( -e "${MAIN2_INSTALL_STATE_FILE}" || -L "${MAIN2_INSTALL_STATE_FILE}" ) &&
        ( ! -f "${MAIN2_INSTALL_STATE_FILE}" || -L "${MAIN2_INSTALL_STATE_FILE}" ) ]]; then
    fail "main2 安装状态不是普通文件：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  fi
  validate_install_state_values || {
    fail "拒绝写入无效的 main2 安装状态。"
    return 1
  }

  if ! install -d -m 0755 "${state_dir}"; then
    fail "无法创建 main2 状态目录：${state_dir}"
    return 1
  fi
  if ! tmp="$(mktemp "${state_dir}/.install-state.XXXXXX")"; then
    fail "无法创建 main2 安装状态临时文件：${state_dir}"
    return 1
  fi
  if ! cat > "${tmp}" <<EOF
STATE_FORMAT=2
BUNDLE_VERSION=${INSTALLED_BUNDLE_VERSION}
BUNDLE_MAIN2_SHA256=${INSTALLED_BUNDLE_MAIN2_SHA256}
APPLIED_VERSION=${APPLIED_MAIN2_VERSION}
APPLIED_MAIN2_SHA256=${APPLIED_MAIN2_SHA256}
PENDING_VERSION=${PENDING_MAIN2_VERSION}
PENDING_MAIN2_SHA256=${PENDING_MAIN2_SHA256}
PENDING_REQUIRES_MANAGED_OVERWRITE=${PENDING_REQUIRES_MANAGED_OVERWRITE}
MANAGED_CONFIG_FORMAT=${STORED_MANAGED_CONFIG_FORMAT}
MANAGED_CONFIG_SHA256=${STORED_MANAGED_CONFIG_SHA256}
PROFILE=${STORED_PROFILE}
ENABLE_NIC_TUNING=${STORED_ENABLE_NIC_TUNING}
RP_FILTER=${STORED_RP_FILTER}
MAXIMIZE_NIC_RING=${STORED_MAXIMIZE_NIC_RING}
IP_LOCAL_PORT_RANGE=${STORED_IP_LOCAL_PORT_RANGE}
SOCKET_BUFFER_DEFAULT=${STORED_SOCKET_BUFFER_DEFAULT}
SOCKET_BUFFER_MAX=${STORED_SOCKET_BUFFER_MAX}
NETDEV_MAX_BACKLOG=${STORED_NETDEV_MAX_BACKLOG}
NETDEV_BUDGET=${STORED_NETDEV_BUDGET}
NETDEV_BUDGET_USECS=${STORED_NETDEV_BUDGET_USECS}
RPS_FLOW_ENTRIES=${STORED_RPS_FLOW_ENTRIES}
TXQUEUELEN=${STORED_TXQUEUELEN}
TCP_MAX_TW_BUCKETS=${STORED_TCP_MAX_TW_BUCKETS}
TCP_MAX_SYN_BACKLOG=${STORED_TCP_MAX_SYN_BACKLOG}
IPFRAG_HIGH_THRESH=${STORED_IPFRAG_HIGH_THRESH}
NOFILE_LIMIT=${STORED_NOFILE_LIMIT}
FILE_MAX=${STORED_FILE_MAX}
NF_CONNTRACK_MAX=${STORED_NF_CONNTRACK_MAX}
NF_CONNTRACK_HASH_SIZE=${STORED_NF_CONNTRACK_HASH_SIZE}
EOF
  then
    rm -f -- "${tmp}" || true
    fail "无法完整写入 main2 安装状态临时文件。"
    return 1
  fi
  if ! chmod 0644 "${tmp}"; then
    rm -f -- "${tmp}" || true
    fail "无法设置 main2 安装状态临时文件权限。"
    return 1
  fi
  if ! mv -f -- "${tmp}" "${MAIN2_INSTALL_STATE_FILE}"; then
    rm -f -- "${tmp}" || true
    fail "无法原子替换 main2 安装状态：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  fi
}

restore_stored_settings() {
  local mode="${1:-if-unset}"
  case "${mode}" in
    if-unset|force) ;;
    *) fail "main2 状态恢复模式无效：${mode}"; return 1 ;;
  esac
  [[ "${mode}" != "force" && "${PROFILE_WAS_EXPLICIT}" == "1" ]] || PROFILE="${STORED_PROFILE}"
  [[ "${mode}" != "force" && "${ENABLE_NIC_TUNING_WAS_EXPLICIT}" == "1" ]] || ENABLE_NIC_TUNING="${STORED_ENABLE_NIC_TUNING}"
  [[ "${mode}" != "force" && "${RP_FILTER_WAS_EXPLICIT}" == "1" ]] || RP_FILTER="${STORED_RP_FILTER}"
  [[ "${mode}" != "force" && "${MAXIMIZE_NIC_RING_WAS_EXPLICIT}" == "1" ]] || MAXIMIZE_NIC_RING="${STORED_MAXIMIZE_NIC_RING}"
  [[ "${mode}" != "force" && "${IP_LOCAL_PORT_RANGE_WAS_EXPLICIT}" == "1" ]] || IP_LOCAL_PORT_RANGE="${STORED_IP_LOCAL_PORT_RANGE}"
  [[ "${mode}" != "force" && "${SOCKET_BUFFER_DEFAULT_WAS_EXPLICIT}" == "1" ]] || SOCKET_BUFFER_DEFAULT="${STORED_SOCKET_BUFFER_DEFAULT}"
  [[ "${mode}" != "force" && "${SOCKET_BUFFER_MAX_WAS_EXPLICIT}" == "1" ]] || SOCKET_BUFFER_MAX="${STORED_SOCKET_BUFFER_MAX}"
  [[ "${mode}" != "force" && "${NETDEV_MAX_BACKLOG_WAS_EXPLICIT}" == "1" ]] || NETDEV_MAX_BACKLOG="${STORED_NETDEV_MAX_BACKLOG}"
  [[ "${mode}" != "force" && "${NETDEV_BUDGET_WAS_EXPLICIT}" == "1" ]] || NETDEV_BUDGET="${STORED_NETDEV_BUDGET}"
  [[ "${mode}" != "force" && "${NETDEV_BUDGET_USECS_WAS_EXPLICIT}" == "1" ]] || NETDEV_BUDGET_USECS="${STORED_NETDEV_BUDGET_USECS}"
  [[ "${mode}" != "force" && "${RPS_FLOW_ENTRIES_WAS_EXPLICIT}" == "1" ]] || RPS_FLOW_ENTRIES="${STORED_RPS_FLOW_ENTRIES}"
  [[ "${mode}" != "force" && "${TXQUEUELEN_WAS_EXPLICIT}" == "1" ]] || TXQUEUELEN="${STORED_TXQUEUELEN}"
  [[ "${mode}" != "force" && "${TCP_MAX_TW_BUCKETS_WAS_EXPLICIT}" == "1" ]] || TCP_MAX_TW_BUCKETS="${STORED_TCP_MAX_TW_BUCKETS}"
  [[ "${mode}" != "force" && "${TCP_MAX_SYN_BACKLOG_WAS_EXPLICIT}" == "1" ]] || TCP_MAX_SYN_BACKLOG="${STORED_TCP_MAX_SYN_BACKLOG}"
  [[ "${mode}" != "force" && "${IPFRAG_HIGH_THRESH_WAS_EXPLICIT}" == "1" ]] || IPFRAG_HIGH_THRESH="${STORED_IPFRAG_HIGH_THRESH}"
  [[ "${mode}" != "force" && "${NOFILE_LIMIT_WAS_EXPLICIT}" == "1" ]] || NOFILE_LIMIT="${STORED_NOFILE_LIMIT}"
  [[ "${mode}" != "force" && "${FILE_MAX_WAS_EXPLICIT}" == "1" ]] || FILE_MAX="${STORED_FILE_MAX}"
  [[ "${mode}" != "force" && "${NF_CONNTRACK_MAX_WAS_EXPLICIT}" == "1" ]] || NF_CONNTRACK_MAX="${STORED_NF_CONNTRACK_MAX}"
  [[ "${mode}" != "force" && "${NF_CONNTRACK_HASH_SIZE_WAS_EXPLICIT}" == "1" ]] || NF_CONNTRACK_HASH_SIZE="${STORED_NF_CONNTRACK_HASH_SIZE}"
}

initialize_main2_state() {
  local state_dir
  local -a lines=()
  [[ "${MAIN2_STATE_LOADED}" == "0" ]] || return 0
  command -v sha256sum >/dev/null 2>&1 || {
    fail "未找到 sha256sum，无法识别 main2 版本。"
    return 1
  }
  CURRENT_MAIN2_SHA256="$(sha256sum -- "${BASH_SOURCE[0]}" | awk '{print $1}')"
  [[ "${CURRENT_MAIN2_SHA256}" =~ ^[0-9a-f]{64}$ ]] || {
    fail "无法读取当前 main2.sh 的 SHA256。"
    return 1
  }

  state_dir="$(dirname "${MAIN2_INSTALL_STATE_FILE}")"
  if [[ -L "${state_dir}" || ( -e "${state_dir}" && ! -d "${state_dir}" ) ]]; then
    fail "main2 状态目录不是安全的真实目录：${state_dir}"
    return 1
  fi
  if [[ ! -e "${MAIN2_INSTALL_STATE_FILE}" && ! -L "${MAIN2_INSTALL_STATE_FILE}" ]]; then
    MAIN2_STATE_LOADED=1
    return 0
  fi
  if [[ ! -f "${MAIN2_INSTALL_STATE_FILE}" || -L "${MAIN2_INSTALL_STATE_FILE}" ]]; then
    fail "main2 安装状态不是普通文件：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  fi

  mapfile -t lines < "${MAIN2_INSTALL_STATE_FILE}"
  if (( ${#lines[@]} < 7 )); then
    fail "main2 安装状态格式无效：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  fi
  [[ "${lines[1]}" == BUNDLE_VERSION=* &&
     "${lines[2]}" == BUNDLE_MAIN2_SHA256=* &&
     "${lines[3]}" == APPLIED_VERSION=* &&
     "${lines[4]}" == APPLIED_MAIN2_SHA256=* &&
     "${lines[5]}" == PENDING_VERSION=* &&
     "${lines[6]}" == PENDING_MAIN2_SHA256=* ]] || {
    fail "main2 安装状态字段无效：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  }
  INSTALLED_BUNDLE_VERSION="${lines[1]#BUNDLE_VERSION=}"
  INSTALLED_BUNDLE_MAIN2_SHA256="${lines[2]#BUNDLE_MAIN2_SHA256=}"
  APPLIED_MAIN2_VERSION="${lines[3]#APPLIED_VERSION=}"
  APPLIED_MAIN2_SHA256="${lines[4]#APPLIED_MAIN2_SHA256=}"
  PENDING_MAIN2_VERSION="${lines[5]#PENDING_VERSION=}"
  PENDING_MAIN2_SHA256="${lines[6]#PENDING_MAIN2_SHA256=}"
  case "${lines[0]}" in
    STATE_FORMAT=1)
      if (( ${#lines[@]} != 28 )) ||
         [[ "${lines[7]}" != MANAGED_CONFIG_FORMAT=* ||
            "${lines[8]}" != MANAGED_CONFIG_SHA256=* ||
            "${lines[9]}" != PROFILE=* ||
            "${lines[10]}" != ENABLE_NIC_TUNING=* ||
            "${lines[11]}" != RP_FILTER=* ||
            "${lines[12]}" != MAXIMIZE_NIC_RING=* ||
            "${lines[13]}" != IP_LOCAL_PORT_RANGE=* ||
            "${lines[14]}" != SOCKET_BUFFER_DEFAULT=* ||
            "${lines[15]}" != SOCKET_BUFFER_MAX=* ||
            "${lines[16]}" != NETDEV_MAX_BACKLOG=* ||
            "${lines[17]}" != NETDEV_BUDGET=* ||
            "${lines[18]}" != NETDEV_BUDGET_USECS=* ||
            "${lines[19]}" != RPS_FLOW_ENTRIES=* ||
            "${lines[20]}" != TXQUEUELEN=* ||
            "${lines[21]}" != TCP_MAX_TW_BUCKETS=* ||
            "${lines[22]}" != TCP_MAX_SYN_BACKLOG=* ||
            "${lines[23]}" != IPFRAG_HIGH_THRESH=* ||
            "${lines[24]}" != NOFILE_LIMIT=* ||
            "${lines[25]}" != FILE_MAX=* ||
            "${lines[26]}" != NF_CONNTRACK_MAX=* ||
            "${lines[27]}" != NF_CONNTRACK_HASH_SIZE=* ]]; then
        fail "main2 安装状态字段无效：${MAIN2_INSTALL_STATE_FILE}"
        return 1
      fi
      PENDING_REQUIRES_MANAGED_OVERWRITE=0
      if [[ "${PENDING_MAIN2_VERSION}" == "0" ]]; then
        PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=1
      else
        PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=0
      fi
      STORED_MANAGED_CONFIG_FORMAT="${lines[7]#MANAGED_CONFIG_FORMAT=}"
      STORED_MANAGED_CONFIG_SHA256="${lines[8]#MANAGED_CONFIG_SHA256=}"
      STORED_PROFILE="${lines[9]#PROFILE=}"
      STORED_ENABLE_NIC_TUNING="${lines[10]#ENABLE_NIC_TUNING=}"
      STORED_RP_FILTER="${lines[11]#RP_FILTER=}"
      STORED_MAXIMIZE_NIC_RING="${lines[12]#MAXIMIZE_NIC_RING=}"
      STORED_IP_LOCAL_PORT_RANGE="${lines[13]#IP_LOCAL_PORT_RANGE=}"
      STORED_SOCKET_BUFFER_DEFAULT="${lines[14]#SOCKET_BUFFER_DEFAULT=}"
      STORED_SOCKET_BUFFER_MAX="${lines[15]#SOCKET_BUFFER_MAX=}"
      STORED_NETDEV_MAX_BACKLOG="${lines[16]#NETDEV_MAX_BACKLOG=}"
      STORED_NETDEV_BUDGET="${lines[17]#NETDEV_BUDGET=}"
      STORED_NETDEV_BUDGET_USECS="${lines[18]#NETDEV_BUDGET_USECS=}"
      STORED_RPS_FLOW_ENTRIES="${lines[19]#RPS_FLOW_ENTRIES=}"
      STORED_TXQUEUELEN="${lines[20]#TXQUEUELEN=}"
      STORED_TCP_MAX_TW_BUCKETS="${lines[21]#TCP_MAX_TW_BUCKETS=}"
      STORED_TCP_MAX_SYN_BACKLOG="${lines[22]#TCP_MAX_SYN_BACKLOG=}"
      STORED_IPFRAG_HIGH_THRESH="${lines[23]#IPFRAG_HIGH_THRESH=}"
      STORED_NOFILE_LIMIT="${lines[24]#NOFILE_LIMIT=}"
      STORED_FILE_MAX="${lines[25]#FILE_MAX=}"
      STORED_NF_CONNTRACK_MAX="${lines[26]#NF_CONNTRACK_MAX=}"
      STORED_NF_CONNTRACK_HASH_SIZE="${lines[27]#NF_CONNTRACK_HASH_SIZE=}"
      ;;
    STATE_FORMAT=2)
      if (( ${#lines[@]} != 29 )) ||
         [[ "${lines[7]}" != PENDING_REQUIRES_MANAGED_OVERWRITE=* ||
            "${lines[8]}" != MANAGED_CONFIG_FORMAT=* ||
            "${lines[9]}" != MANAGED_CONFIG_SHA256=* ||
            "${lines[10]}" != PROFILE=* ||
            "${lines[11]}" != ENABLE_NIC_TUNING=* ||
            "${lines[12]}" != RP_FILTER=* ||
            "${lines[13]}" != MAXIMIZE_NIC_RING=* ||
            "${lines[14]}" != IP_LOCAL_PORT_RANGE=* ||
            "${lines[15]}" != SOCKET_BUFFER_DEFAULT=* ||
            "${lines[16]}" != SOCKET_BUFFER_MAX=* ||
            "${lines[17]}" != NETDEV_MAX_BACKLOG=* ||
            "${lines[18]}" != NETDEV_BUDGET=* ||
            "${lines[19]}" != NETDEV_BUDGET_USECS=* ||
            "${lines[20]}" != RPS_FLOW_ENTRIES=* ||
            "${lines[21]}" != TXQUEUELEN=* ||
            "${lines[22]}" != TCP_MAX_TW_BUCKETS=* ||
            "${lines[23]}" != TCP_MAX_SYN_BACKLOG=* ||
            "${lines[24]}" != IPFRAG_HIGH_THRESH=* ||
            "${lines[25]}" != NOFILE_LIMIT=* ||
            "${lines[26]}" != FILE_MAX=* ||
            "${lines[27]}" != NF_CONNTRACK_MAX=* ||
            "${lines[28]}" != NF_CONNTRACK_HASH_SIZE=* ]]; then
        fail "main2 安装状态字段无效：${MAIN2_INSTALL_STATE_FILE}"
        return 1
      fi
      PENDING_REQUIRES_MANAGED_OVERWRITE="${lines[7]#PENDING_REQUIRES_MANAGED_OVERWRITE=}"
      PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=1
      STORED_MANAGED_CONFIG_FORMAT="${lines[8]#MANAGED_CONFIG_FORMAT=}"
      STORED_MANAGED_CONFIG_SHA256="${lines[9]#MANAGED_CONFIG_SHA256=}"
      STORED_PROFILE="${lines[10]#PROFILE=}"
      STORED_ENABLE_NIC_TUNING="${lines[11]#ENABLE_NIC_TUNING=}"
      STORED_RP_FILTER="${lines[12]#RP_FILTER=}"
      STORED_MAXIMIZE_NIC_RING="${lines[13]#MAXIMIZE_NIC_RING=}"
      STORED_IP_LOCAL_PORT_RANGE="${lines[14]#IP_LOCAL_PORT_RANGE=}"
      STORED_SOCKET_BUFFER_DEFAULT="${lines[15]#SOCKET_BUFFER_DEFAULT=}"
      STORED_SOCKET_BUFFER_MAX="${lines[16]#SOCKET_BUFFER_MAX=}"
      STORED_NETDEV_MAX_BACKLOG="${lines[17]#NETDEV_MAX_BACKLOG=}"
      STORED_NETDEV_BUDGET="${lines[18]#NETDEV_BUDGET=}"
      STORED_NETDEV_BUDGET_USECS="${lines[19]#NETDEV_BUDGET_USECS=}"
      STORED_RPS_FLOW_ENTRIES="${lines[20]#RPS_FLOW_ENTRIES=}"
      STORED_TXQUEUELEN="${lines[21]#TXQUEUELEN=}"
      STORED_TCP_MAX_TW_BUCKETS="${lines[22]#TCP_MAX_TW_BUCKETS=}"
      STORED_TCP_MAX_SYN_BACKLOG="${lines[23]#TCP_MAX_SYN_BACKLOG=}"
      STORED_IPFRAG_HIGH_THRESH="${lines[24]#IPFRAG_HIGH_THRESH=}"
      STORED_NOFILE_LIMIT="${lines[25]#NOFILE_LIMIT=}"
      STORED_FILE_MAX="${lines[26]#FILE_MAX=}"
      STORED_NF_CONNTRACK_MAX="${lines[27]#NF_CONNTRACK_MAX=}"
      STORED_NF_CONNTRACK_HASH_SIZE="${lines[28]#NF_CONNTRACK_HASH_SIZE=}"
      ;;
    *)
      fail "main2 安装状态格式无效：${MAIN2_INSTALL_STATE_FILE}"
      return 1
      ;;
  esac
  validate_install_state_values || {
    fail "main2 安装状态内容无效：${MAIN2_INSTALL_STATE_FILE}"
    return 1
  }
  if (( 10#${INSTALLED_BUNDLE_VERSION} > MAIN2_BUNDLE_VERSION ||
        10#${APPLIED_MAIN2_VERSION} > MAIN2_BUNDLE_VERSION ||
        10#${PENDING_MAIN2_VERSION} > MAIN2_BUNDLE_VERSION )); then
    fail "当前 main2.sh 版本低于机器已记录版本，拒绝自动降级。"
    return 1
  fi

  if [[ "${APPLIED_MAIN2_VERSION}" != "0" || "${PENDING_MAIN2_VERSION}" != "0" ]]; then
    restore_stored_settings if-unset || return 1
  fi
  MAIN2_STATE_LOADED=1
}

record_bundle_state() {
  initialize_main2_state || return 1
  if [[ "${PENDING_MAIN2_VERSION}" != "0" &&
        "${PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN}" != "1" ]]; then
    return 0
  fi
  INSTALLED_BUNDLE_VERSION="${MAIN2_BUNDLE_VERSION}"
  INSTALLED_BUNDLE_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  write_install_state
}

store_requested_settings() {
  local profile="$1"
  STORED_PROFILE="${profile}"
  STORED_ENABLE_NIC_TUNING="${ENABLE_NIC_TUNING:-1}"
  STORED_RP_FILTER="${RP_FILTER:-0}"
  STORED_MAXIMIZE_NIC_RING="${MAXIMIZE_NIC_RING:-0}"
  STORED_IP_LOCAL_PORT_RANGE="${IP_LOCAL_PORT_RANGE:-}"
  STORED_SOCKET_BUFFER_DEFAULT="${SOCKET_BUFFER_DEFAULT:-}"
  STORED_SOCKET_BUFFER_MAX="${SOCKET_BUFFER_MAX:-}"
  STORED_NETDEV_MAX_BACKLOG="${NETDEV_MAX_BACKLOG:-}"
  STORED_NETDEV_BUDGET="${NETDEV_BUDGET:-}"
  STORED_NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-}"
  STORED_RPS_FLOW_ENTRIES="${RPS_FLOW_ENTRIES:-}"
  STORED_TXQUEUELEN="${TXQUEUELEN:-}"
  STORED_TCP_MAX_TW_BUCKETS="${TCP_MAX_TW_BUCKETS:-}"
  STORED_TCP_MAX_SYN_BACKLOG="${TCP_MAX_SYN_BACKLOG:-}"
  STORED_IPFRAG_HIGH_THRESH="${IPFRAG_HIGH_THRESH:-}"
  STORED_NOFILE_LIMIT="${NOFILE_LIMIT:-}"
  STORED_FILE_MAX="${FILE_MAX:-}"
  STORED_NF_CONNTRACK_MAX="${NF_CONNTRACK_MAX:-}"
  STORED_NF_CONNTRACK_HASH_SIZE="${NF_CONNTRACK_HASH_SIZE:-}"
}

begin_applied_update() {
  local profile="$1"
  local requires_managed_overwrite="$2"
  case "${requires_managed_overwrite}" in
    0|1) ;;
    *) fail "受管文件覆盖事务参数必须是 0 或 1。"; return 1 ;;
  esac
  initialize_main2_state || return 1
  INSTALLED_BUNDLE_VERSION="${MAIN2_BUNDLE_VERSION}"
  INSTALLED_BUNDLE_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  PENDING_MAIN2_VERSION="${MAIN2_BUNDLE_VERSION}"
  PENDING_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  PENDING_REQUIRES_MANAGED_OVERWRITE="${requires_managed_overwrite}"
  PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=1
  store_requested_settings "${profile}"
  write_install_state
}

record_applied_state() {
  local profile="$1"
  local managed_config_sha256
  initialize_main2_state || return 1
  managed_config_sha256="$(managed_network_fingerprint "${MAIN2_MANAGED_CONFIG_FORMAT}")" || {
    fail "无法计算 main2 管理配置的 SHA256，安装状态未更新。"
    return 1
  }
  [[ "${managed_config_sha256}" =~ ^[0-9a-f]{64}$ ]] || {
    fail "main2 管理配置 SHA256 无效，安装状态未更新。"
    return 1
  }
  INSTALLED_BUNDLE_VERSION="${MAIN2_BUNDLE_VERSION}"
  INSTALLED_BUNDLE_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  APPLIED_MAIN2_VERSION="${MAIN2_BUNDLE_VERSION}"
  APPLIED_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  PENDING_MAIN2_VERSION=0
  PENDING_MAIN2_SHA256=""
  PENDING_REQUIRES_MANAGED_OVERWRITE=0
  PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN=1
  STORED_MANAGED_CONFIG_FORMAT="${MAIN2_MANAGED_CONFIG_FORMAT}"
  STORED_MANAGED_CONFIG_SHA256="${managed_config_sha256}"
  store_requested_settings "${profile}"
  write_install_state
}

legacy_backup_state_file() {
  printf '%s/legacy-backup-%s.restored' "${LEGACY_RESTORE_STATE_DIR}" "${LEGACY_BACKUP_SUFFIX}"
}

mark_legacy_backup_restored() {
  local state_file
  if [[ -z "${LEGACY_BACKUP_SUFFIX}" || "${LEGACY_BACKUP_ALREADY_RESTORED}" == "1" ]]; then
    return 0
  fi
  install -d -m 0755 "${LEGACY_RESTORE_STATE_DIR}" || return 1
  state_file="$(legacy_backup_state_file)"
  touch "${state_file}" || return 1
  chmod 0644 "${state_file}" || return 1
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
    /etc/systemd/system/multi-user.target.wants/mtu-mss-fix.service || return 1
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
    /etc/systemd/system/multi-user.target.wants/network-max-tune.service || return 1
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

udp_runtime_is_current_main2() {
  file_sha256_is /usr/local/sbin/udp-multinic-apply.sh 4f094911fe1e2d4e0a528e17e0cc50e46045b76cb0e8bd563b0742d1ec7c054f &&
    file_sha256_is /etc/systemd/system/udp-multinic.service d4eaeadd2f155b831c44a65aba43297ad6eaa15c3b530be73afba65c823cc7a4 &&
    file_sha256_is /etc/sysctl.d/61-udp-multinic.conf eac3e15d92ea1b5c6b07ba242cba835d146d412832f920aa3d89f7e680c135db
}

udp_rules_need_runtime_recovery() {
  [[ -s /etc/udp-multinic/rules.conf && ! -L /etc/udp-multinic/rules.conf ]] || return 1
  ! udp_runtime_is_current_main2
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
  if [[ ( -e "${LEGACY_MARK_FILE}" || -L "${LEGACY_MARK_FILE}" ) &&
        ( ! -f "${LEGACY_MARK_FILE}" || -L "${LEGACY_MARK_FILE}" ) ]]; then
    fail "旧版 main.sh 初始化标记不是普通文件：${LEGACY_MARK_FILE}"
    return 1
  fi
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
  preflight_udp_runtime_paths || return 1
  if [[ -f /etc/udp-multinic/rules.conf ]]; then
    if ! bash "${UDP_MULTINIC_SCRIPT}" validate; then
      fail "UDP 规则未通过 main2 IPv4 迁移校验，系统配置尚未修改。"
      return 1
    fi
  fi

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
  preflight_legacy_main_deployment || return 1
  restore_legacy_sysctl || return 1
  restore_legacy_limits || return 1
  mark_legacy_backup_restored || return 1
  cleanup_legacy_mss || return 1
  cleanup_legacy_network_tune || return 1

  if detect_legacy_udp || udp_rules_need_runtime_recovery; then
    chmod +x "${UDP_MULTINIC_SCRIPT}" || return 1
    systemctl disable --now udp-multinic.service 2>/dev/null || true
    install -d -m 0755 "$(dirname "${LEGACY_UDP_PENDING_FILE}")" || return 1
    touch "${LEGACY_UDP_PENDING_FILE}" || return 1
    chmod 0644 "${LEGACY_UDP_PENDING_FILE}" || return 1
    ok "已停用旧版或残缺的 UDP 映射服务，现有 IPv4 规则将在新网络配置应用后升级。"
  elif [[ -f "${LEGACY_UDP_PENDING_FILE}" && ! -L "${LEGACY_UDP_PENDING_FILE}" ]]; then
    bash "${UDP_MULTINIC_SCRIPT}" validate || return 1
  fi
  if [[ -f "${LEGACY_UDP_PENDING_FILE}" && ! -L "${LEGACY_UDP_PENDING_FILE}" ]]; then
    LEGACY_UDP_MIGRATION=1
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || return 1
    systemctl reset-failed network-max-tune.service mtu-mss-fix.service udp-multinic.service 2>/dev/null || true
  fi
}

migrate_legacy_udp() {
  if [[ "${LEGACY_UDP_MIGRATION}" != "1" && ! -f "${LEGACY_UDP_PENDING_FILE}" ]]; then
    return 0
  fi
  chmod +x "${UDP_MULTINIC_SCRIPT}" || return 1
  bash "${UDP_MULTINIC_SCRIPT}" migrate || return 1
  rm -f "${LEGACY_UDP_PENDING_FILE}" || return 1
  rmdir "$(dirname "${LEGACY_UDP_PENDING_FILE}")" 2>/dev/null || true
}

run_network_optimization() {
  local profile="$1"
  local save_applied_state="${2:-1}"
  local allow_managed_overwrite="${3:-${ALLOW_MANAGED_CONFIG_OVERWRITE:-0}}"
  local port_range enable_nic_tuning rp_filter maximize_nic_ring
  local -a optimizer_env
  case "${save_applied_state}" in
    0|1) ;;
    *) fail "run_network_optimization 的状态记录参数必须是 0 或 1。"; return 1 ;;
  esac
  case "${allow_managed_overwrite}" in
    0|1) ;;
    *) fail "ALLOW_MANAGED_CONFIG_OVERWRITE 必须是 0 或 1。"; return 1 ;;
  esac
  if [[ ! -f "${OPTIMIZER}" ]]; then
    fail "未找到 ${OPTIMIZER}"
    exit 1
  fi

  port_range="${IP_LOCAL_PORT_RANGE:-}"
  enable_nic_tuning="${ENABLE_NIC_TUNING:-1}"
  rp_filter="${RP_FILTER:-0}"
  maximize_nic_ring="${MAXIMIZE_NIC_RING:-0}"
  optimizer_env=(
    "PROFILE=${profile}"
    "IP_LOCAL_PORT_RANGE=${port_range}"
    "ENABLE_NIC_TUNING=${enable_nic_tuning}"
    "RP_FILTER=${rp_filter}"
    "MAXIMIZE_NIC_RING=${maximize_nic_ring}"
    "ALLOW_MANAGED_CONFIG_OVERWRITE=${allow_managed_overwrite}"
    "SOCKET_BUFFER_DEFAULT=${SOCKET_BUFFER_DEFAULT:-}"
    "SOCKET_BUFFER_MAX=${SOCKET_BUFFER_MAX:-}"
    "NETDEV_MAX_BACKLOG=${NETDEV_MAX_BACKLOG:-}"
    "NETDEV_BUDGET=${NETDEV_BUDGET:-}"
    "NETDEV_BUDGET_USECS=${NETDEV_BUDGET_USECS:-}"
    "RPS_FLOW_ENTRIES=${RPS_FLOW_ENTRIES:-}"
    "TXQUEUELEN=${TXQUEUELEN:-}"
    "TCP_MAX_TW_BUCKETS=${TCP_MAX_TW_BUCKETS:-}"
    "TCP_MAX_SYN_BACKLOG=${TCP_MAX_SYN_BACKLOG:-}"
    "IPFRAG_HIGH_THRESH=${IPFRAG_HIGH_THRESH:-}"
    "NOFILE_LIMIT=${NOFILE_LIMIT:-}"
    "FILE_MAX=${FILE_MAX:-}"
    "NF_CONNTRACK_MAX=${NF_CONNTRACK_MAX:-}"
    "NF_CONNTRACK_HASH_SIZE=${NF_CONNTRACK_HASH_SIZE:-}"
  )
  if ! env "${optimizer_env[@]}" VALIDATE_ONLY=1 bash "${OPTIMIZER}"; then
    fail "网络优化参数或受管文件校验失败，系统配置尚未应用。"
    return 1
  fi
  begin_applied_update "${profile}" "${allow_managed_overwrite}" || return 1

  prepare_legacy_main_deployment || return 1
  chmod +x "${OPTIMIZER}" || return 1
  if ! env "${optimizer_env[@]}" VALIDATE_ONLY=0 bash "${OPTIMIZER}"; then
    if [[ "${PENDING_REQUIRES_MANAGED_OVERWRITE}" == "1" ]]; then
      fail "网络优化应用失败；已保留进行中状态。重试时必须再次明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh。"
    else
      fail "网络优化应用失败；已保留进行中状态，下次运行将按上次记录参数继续重试。"
    fi
    return 1
  fi
  if [[ "${LEGACY_SYSCTL_MIGRATION}" == "1" && -z "${port_range}" ]]; then
    warn "旧版临时端口范围已停止持久化；当前运行值会持续到本次重启，main2 不会自行填入未知的部署前数值。"
  fi
  if [[ "${LEGACY_SYSCTL_RESTORED}" == "1" ]]; then
    warn "指定备份中的非 main2 运行参数将在重启后按系统加载顺序生效。"
  fi
  migrate_legacy_udp || return 1
  ENABLE_NIC_TUNING="${enable_nic_tuning}"
  RP_FILTER="${rp_filter}"
  MAXIMIZE_NIC_RING="${maximize_nic_ring}"
  if [[ "${save_applied_state}" == "1" ]]; then
    record_applied_state "${profile}" || return 1
  fi
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
  local install_attempt
  export DEBIAN_FRONTEND=noninteractive

  for install_attempt in 1 2; do
    if apt-get \
         -o Acquire::Retries=3 \
         -o DPkg::Lock::Timeout=60 \
         install -y irqbalance; then
      break
    fi
    if [[ "${install_attempt}" == "2" ]]; then
      fail "irqbalance 软件包连续两次安装失败。"
      return 1
    fi
    warn "irqbalance 软件包首次安装未完成，正在自动重试一次。"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed irqbalance.service >/dev/null 2>&1 || true
  done

  if ! systemctl daemon-reload; then
    fail "irqbalance 安装完成，但 systemd 配置刷新失败。"
    return 1
  fi
  if ! systemctl enable irqbalance.service; then
    fail "irqbalance 安装完成，但设置开机启用失败。"
    return 1
  fi
  if ! systemctl restart irqbalance.service; then
    warn "irqbalance 首次启动未完成，正在清除失败计数并重试一次。"
    if ! systemctl reset-failed irqbalance.service; then
      fail "irqbalance 首次启动失败，且无法清除 systemd 失败计数。"
      return 1
    fi
    if ! systemctl restart irqbalance.service; then
      fail "irqbalance 连续两次启动失败，以下为服务状态和最近日志。"
      systemctl status irqbalance.service --no-pager --full || true
      journalctl -u irqbalance.service -n 40 --no-pager || true
      return 1
    fi
  fi
  ok "irqbalance 已安装并启用。"
}

install_chrony() {
  export DEBIAN_FRONTEND=noninteractive
  apt update || return 1
  apt install chrony -y || return 1
  systemctl enable chrony || return 1
  systemctl restart chrony || return 1
  chronyc makestep || return 1
  ok "Chrony 已安装、启用并完成立即校时。"
}

default_setup() {
  local skip_init="${SKIP_INIT:-0}"
  local reapply_init="${REAPPLY_INIT:-0}"
  local allow_managed_overwrite="${ALLOW_MANAGED_CONFIG_OVERWRITE:-0}"
  local profile current_managed_config_sha256
  local resume_pending=0

  initialize_main2_state || return 1

  case "${skip_init}" in
    0|1) ;;
    *) fail "SKIP_INIT 必须是 0 或 1。"; return 1 ;;
  esac
  case "${reapply_init}" in
    0|1) ;;
    *) fail "REAPPLY_INIT 必须是 0 或 1。"; return 1 ;;
  esac
  case "${allow_managed_overwrite}" in
    0|1) ;;
    *) fail "ALLOW_MANAGED_CONFIG_OVERWRITE 必须是 0 或 1。"; return 1 ;;
  esac
  if [[ ( -e "${MARK_FILE}" || -L "${MARK_FILE}" ) &&
        ( ! -f "${MARK_FILE}" || -L "${MARK_FILE}" ) ]]; then
    fail "main2 初始化标记不是普通文件：${MARK_FILE}"
    return 1
  fi
  if [[ "${skip_init}" == "1" ]]; then
    ok "已跳过默认初始化。"
    return 0
  fi
  if [[ "${PROFILE_WAS_EXPLICIT}" == "1" ]]; then
    case "${PROFILE}" in
      balanced|max) ;;
      *) fail "PROFILE 已明确设置时必须精确为 balanced 或 max。"; return 1 ;;
    esac
  fi
  if [[ "${PENDING_MAIN2_VERSION}" != "0" && "${allow_managed_overwrite}" != "1" ]]; then
    if [[ "${PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN}" != "1" ]]; then
      warn "旧状态未记录上次未完成事务的人工文件覆盖条件，本次未获得重新覆盖授权。"
      warn "处理该事务时，请明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=${STORED_PROFILE} bash main2.sh。"
      return 0
    fi
    if [[ "${PENDING_REQUIRES_MANAGED_OVERWRITE}" == "1" ]]; then
      warn "上次未完成事务包含人工同名普通文件覆盖，本次尚未重新获得覆盖授权。"
      warn "继续或重开该事务时，必须再次执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh。"
      return 0
    fi
  fi
  if [[ -f "${MARK_FILE}" && "${APPLIED_MAIN2_VERSION}" == "0" &&
        "${PENDING_MAIN2_VERSION}" == "0" ]]; then
    if [[ "${PROFILE_WAS_EXPLICIT}" == "0" && "${reapply_init}" == "0" ]]; then
      warn "已覆盖更新 main2 脚本包；旧 main2 没有记录 balanced/max，现有系统参数保持不变。"
      warn "请在菜单明确执行 balanced 或 max，之后的 main2 更新将按该档位自动覆盖应用。"
      return 0
    fi
    case "${PROFILE:-}" in
      balanced|max) ;;
      *) fail "旧 main2 没有档位记录；重应用时必须同时明确 PROFILE=balanced 或 PROFILE=max。"; return 1 ;;
    esac
  fi
  if [[ -f "${MARK_FILE}" && "${reapply_init}" == "0" &&
        "${PENDING_MAIN2_VERSION}" == "0" &&
        "${APPLIED_MAIN2_VERSION}" == "${MAIN2_BUNDLE_VERSION}" &&
        "${APPLIED_MAIN2_SHA256}" == "${CURRENT_MAIN2_SHA256}" ]]; then
    ok "当前 main2 版本已应用，本次保留现有配置并直接进入菜单。"
    return 0
  fi
  if [[ "${PENDING_MAIN2_VERSION}" != "0" && "${reapply_init}" == "0" ]]; then
    if [[ "${PENDING_MAIN2_VERSION}" == "${MAIN2_BUNDLE_VERSION}" &&
          "${PENDING_MAIN2_SHA256}" == "${CURRENT_MAIN2_SHA256}" ]]; then
      if [[ "${PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN}" != "1" ]]; then
        warn "旧状态无法确认上次未完成应用是否获得过人工文件覆盖授权，本次未自动续跑。"
        warn "确认覆盖后，请明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=${STORED_PROFILE} bash main2.sh。"
        return 0
      fi
      restore_stored_settings force || return 1
      if [[ "${PENDING_REQUIRES_MANAGED_OVERWRITE}" == "1" &&
            "${allow_managed_overwrite}" != "1" ]]; then
        warn "上次未完成应用包含人工同名普通文件覆盖，本次尚未重新获得覆盖授权。"
        warn "继续同一事务时，请明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh。"
        return 0
      fi
      resume_pending=1
      warn "检测到同一 main2 版本上次应用未完成，将按上次记录参数继续重试。"
    else
      warn "检测到其他 main2 版本留下的未完成应用，现有系统配置未自动覆盖。"
      if [[ "${PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN}" != "1" ||
            "${PENDING_REQUIRES_MANAGED_OVERWRITE}" == "1" ]]; then
        warn "确认覆盖后，请明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=${STORED_PROFILE} bash main2.sh。"
      else
        warn "确认继续后，请明确执行 REAPPLY_INIT=1 PROFILE=${STORED_PROFILE} bash main2.sh。"
      fi
      return 0
    fi
  fi
  if [[ "${APPLIED_MAIN2_VERSION}" != "0" && "${reapply_init}" == "0" &&
        "${resume_pending}" == "0" ]]; then
    if ! current_managed_config_sha256="$(managed_network_fingerprint "${STORED_MANAGED_CONFIG_FORMAT}")" ||
       [[ "${current_managed_config_sha256}" != "${STORED_MANAGED_CONFIG_SHA256}" ]]; then
      warn "检测到 main2 管理配置已被修改，脚本包已更新，但现有系统配置未覆盖。"
      warn "确认允许覆盖普通文件后，请明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=balanced bash main2.sh 或对应的 PROFILE=max 命令。"
      return 0
    fi
  fi
  if [[ "${resume_pending}" == "1" ]]; then
    :
  elif [[ -f "${MARK_FILE}" && "${reapply_init}" == "0" ]]; then
    warn "检测到 main2 新版本，将按已记录配置覆盖更新系统优化。"
  elif [[ "${APPLIED_MAIN2_VERSION}" != "0" && "${reapply_init}" == "0" ]]; then
    warn "检测到网络优化已记录但默认初始化未完成，将按已记录配置补齐默认初始化。"
  fi

  profile="${PROFILE:-balanced}"
  warn "开始默认初始化：设置 Debian/Ubuntu 官方源 -> 安装并校准 Chrony -> 关闭 IPv6 -> 执行用户态 TCP/UDP 代理优化 -> 安装并启用 irqbalance。"
  set_system_sources || return 1
  install_base_tools || return 1
  install_chrony || return 1
  if ! install_irqbalance; then
    fail "irqbalance 安装或启用失败，本次 main2 版本尚未标记为已完成。"
    return 1
  fi
  run_network_optimization "${profile}" 0 "${allow_managed_overwrite}" || return 1
  record_applied_state "${profile}" || return 1
  if ! touch "${MARK_FILE}"; then
    fail "无法写入 main2 初始化标记：${MARK_FILE}"
    return 1
  fi
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
    printf " 2. 设置官方源并刷新\n"
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

main2_locked_main() {
  ensure_download_tool
  initialize_main2_state
  ensure_support_scripts
  record_bundle_state
  default_setup
  main_menu
}

main2_main() {
  require_root
  require_supported_os
  require_systemd
  run_main2_with_lock "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main2_main "$@"
fi
