#!/usr/bin/env bash
set -euo pipefail
export TERM="${TERM:-xterm}"

SWAP_FILE="${SWAP_FILE:-/swapfile}"

green() { printf '\033[32;1m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33;1m%s\033[0m\n' "$*"; }
red() { printf '\033[31;1m%s\033[0m\n' "$*"; }

remove_fstab_entry() {
  local tmp
  tmp="$(mktemp)"
  awk -v swap_file="${SWAP_FILE}" '$1 != swap_file {print}' /etc/fstab > "${tmp}"
  cat "${tmp}" > /etc/fstab
  rm -f "${tmp}"
}

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

check_openvz() {
  if [[ -d /proc/vz && ! -d /proc/bc ]]; then
    red "检测到 OpenVZ/Virtuozzo 容器，通常不支持自行创建 swap。"
    exit 1
  fi
}

auto_swap_mb() {
  local mem_mb
  mem_mb="$(awk '/MemTotal:/ {printf "%d", $2/1024}' /proc/meminfo)"
  if (( mem_mb < 1024 )); then
    echo 2048
  elif (( mem_mb < 4096 )); then
    echo 2048
  elif (( mem_mb < 8192 )); then
    echo 4096
  else
    echo 4096
  fi
}

swap_status() {
  green "当前 swap："
  swapon --show || true
  awk '/MemTotal|SwapTotal|SwapFree/ {print}' /proc/meminfo
}

ensure_space() {
  local size_mb="$1"
  local mount_dir available_mb
  mount_dir="$(dirname "${SWAP_FILE}")"
  available_mb="$(df -Pm "${mount_dir}" | awk 'NR==2 {print $4}')"
  if (( available_mb < size_mb + 256 )); then
    red "磁盘空间不足：需要约 $((size_mb + 256)) MB，可用 ${available_mb} MB。"
    exit 1
  fi
}

add_swap() {
  local size_mb="${1:-}"

  if swapon --show=NAME | grep -qx "${SWAP_FILE}"; then
    yellow "${SWAP_FILE} 已经启用。"
    swap_status
    return 0
  fi

  if [[ -z "${size_mb}" ]]; then
    size_mb="$(auto_swap_mb)"
    read -r -p "请输入 swap 大小，单位 MB，默认 ${size_mb}: " input
    size_mb="${input:-${size_mb}}"
  fi

  if ! [[ "${size_mb}" =~ ^[1-9][0-9]*$ ]]; then
    red "swap 大小必须是正整数 MB。"
    exit 1
  fi

  ensure_space "${size_mb}"

  if [[ -e "${SWAP_FILE}" ]]; then
    yellow "${SWAP_FILE} 已存在，将重新初始化为 swap。"
  elif command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${size_mb}M" "${SWAP_FILE}" || dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${size_mb}" status=progress
  else
    dd if=/dev/zero of="${SWAP_FILE}" bs=1M count="${size_mb}" status=progress
  fi

  chmod 600 "${SWAP_FILE}"
  mkswap -f "${SWAP_FILE}"
  swapon "${SWAP_FILE}"

  remove_fstab_entry
  printf '%s\n' "${SWAP_FILE} none swap sw 0 0" >> /etc/fstab

  green "swap 已创建并持久化：${SWAP_FILE} ${size_mb} MB"
  swap_status
}

remove_swap() {
  if swapon --show=NAME | grep -qx "${SWAP_FILE}"; then
    swapoff "${SWAP_FILE}"
  fi

  remove_fstab_entry
  rm -f "${SWAP_FILE}"
  green "swap 已删除：${SWAP_FILE}"
}

menu() {
  while true; do
    clear
    green "=============================="
    green " Swap 管理"
    green "=============================="
    printf " 1. 自动创建/启用 swap\n"
    printf " 2. 指定大小创建/启用 swap\n"
    printf " 3. 删除 swap\n"
    printf " 4. 查看 swap 状态\n"
    printf " 0. 返回\n"
    if ! read -r -p "请输入数字: " num; then
      return 0
    fi
    case "${num}" in
      1) add_swap; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      2)
        read -r -p "请输入 swap 大小，单位 MB: " size_mb
        add_swap "${size_mb}"
        read -r -n 1 -s -p "按任意键继续..."
        printf "\n"
        ;;
      3) remove_swap; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      4) swap_status; read -r -n 1 -s -p "按任意键继续..."; printf "\n" ;;
      0) return 0 ;;
      *) red "请输入正确数字。"; sleep 1 ;;
    esac
  done
}

need_root
need_debian
check_openvz

case "${1:-menu}" in
  add) add_swap "${2:-}" ;;
  remove|del|delete) remove_swap ;;
  status) swap_status ;;
  menu) menu ;;
  *) red "用法: $0 [menu|add [MB]|remove|status]"; exit 1 ;;
esac
