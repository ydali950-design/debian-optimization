#!/usr/bin/env bash
# Test cases use explicit subshell isolation and dynamically sourced libraries.
# shellcheck disable=SC2030,SC2031
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
MAIN2="${REPO_DIR}/main2.sh"
OPTIMIZER="${REPO_DIR}/sysctl_optimization_debian_overwrite_main2.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail_test() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] ||
    fail_test "${label}: expected=${expected} actual=${actual}"
}

assert_file() {
  [[ -f "$1" && ! -L "$1" ]] || fail_test "expected regular file: $1"
}

assert_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail_test "expected missing path: $1"
}

assert_contains() {
  local pattern="$1"
  local path="$2"
  grep -Fq -- "${pattern}" "${path}" ||
    fail_test "missing '${pattern}' in ${path}"
}

assert_not_contains() {
  local pattern="$1"
  local path="$2"
  if grep -Fq -- "${pattern}" "${path}"; then
    fail_test "unexpected '${pattern}' in ${path}"
  fi
}

line_count() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    wc -l < "${path}" | tr -d '[:space:]'
  else
    printf '%s' 0
  fi
}

build_main2_library() {
  local case_dir="$1"
  local root_dir="${case_dir}/rootfs"
  local library="${case_dir}/main2-library.sh"

  install -d "${root_dir}/etc/security" "${root_dir}/etc/systemd/system" \
    "${root_dir}/etc/sysctl.d" "${root_dir}/etc/default" \
    "${root_dir}/usr/local/sbin" "${root_dir}/usr/share/keyrings" \
    "${root_dir}/var/lib" "${root_dir}/root"
  sed \
    -e "s|/root|${root_dir}/root|g" \
    -e "s|/usr/local|${root_dir}/usr/local|g" \
    -e "s|/usr/share|${root_dir}/usr/share|g" \
    -e "s|/var/lib|${root_dir}/var/lib|g" \
    -e "s|/etc|${root_dir}/etc|g" \
    -e "s|/run/systemd|${root_dir}/run/systemd|g" \
    "${MAIN2}" > "${library}"
}

write_udp_validator() {
  local case_dir="$1"
  local rules_file="${case_dir}/rootfs/etc/udp-multinic/rules.conf"
  local validator="${case_dir}/udp-validator.sh"
  local log_file="${case_dir}/udp.log"

  cat > "${validator}" <<EOF
#!/usr/bin/env bash
set -euo pipefail
case "\${1:-}" in
  validate)
    printf '%s\n' validate >> "${log_file}"
    [[ -f "${rules_file}" ]] || exit 0
    awk '
      /^[[:space:]]*(#|$)/ { next }
      NF != 4 || \$1 != "v4" { exit 1 }
    ' "${rules_file}"
    ;;
  migrate)
    printf '%s\n' migrate >> "${log_file}"
    ;;
  *) exit 64 ;;
esac
EOF
  chmod 0755 "${validator}"
}

load_case() {
  local case_dir="$1"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  # Read by functions loaded from the extracted main2 library.
  # shellcheck disable=SC2034
  UDP_MULTINIC_SCRIPT="${case_dir}/udp-validator.sh"
  : > "${case_dir}/systemctl.log"

  # Invoked by functions loaded from the extracted main2 library.
  # shellcheck disable=SC2329
  systemctl() {
    printf '%s\n' "$*" >> "${case_dir}/systemctl.log"
    return 0
  }
  # shellcheck disable=SC2329
  iptables() { return 1; }
  # shellcheck disable=SC2329
  ip6tables() { return 1; }
  # shellcheck disable=SC2329
  file_sha256_is() {
    local path="$1"
    local expected="$2"
    local content
    [[ -f "${path}" && ! -L "${path}" ]] || return 1
    content="$(<"${path}")"
    case "${content}:${expected}" in
      legacy-mss-apply:f5ce5cf993b2093d96f2c11b7e67326219178b8aa05a5cf35df1ba4eeaec94b3|\
      legacy-mss-config:b78d8eb778d330047aeb041b3353edbe4dbb709672361e13387ba9d521bfcd14|\
      legacy-mss-service:5696d6de58dc07facf0aedc07f23937bee822090d1caf8fbbf69a980fe22b6b1|\
      legacy-network-apply:81bfc014065899e0e32e77a0ae6a0c2abeabd0793c76d231429835205733edb0|\
      legacy-network-service:b6b1d82eb6e297618575dc25e75dc9a22b21df1c77fa9359b2631325dc81565a|\
      current-udp-apply:4f094911fe1e2d4e0a528e17e0cc50e46045b76cb0e8bd563b0742d1ec7c054f|\
      current-udp-service:d4eaeadd2f155b831c44a65aba43297ad6eaa15c3b530be73afba65c823cc7a4|\
      current-udp-sysctl:eac3e15d92ea1b5c6b07ba242cba835d146d412832f920aa3d89f7e680c135db)
        return 0
        ;;
      *) return 1 ;;
    esac
  }
}

write_legacy_core_files() {
  local root_dir="$1"
  install -d "${root_dir}/etc/security" "${root_dir}/etc/default" \
    "${root_dir}/etc/systemd/system" "${root_dir}/usr/local/sbin"
  cat > "${root_dir}/etc/sysctl.conf" <<'EOF'
# Debian / Ubuntu relay / VPN landing host balanced-max network optimization.
net.ipv4.ip_forward = 1
net.ipv6.ip_nonlocal_bind = 1
EOF
  cat > "${root_dir}/etc/security/limits.conf" <<'EOF'
* soft nproc 1048576
* hard nproc 1048576
* soft nofile 1048576
* hard nofile 1048576
root soft nproc 1048576
root hard nproc 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF
  printf '%s\n' legacy-mss-apply > "${root_dir}/usr/local/sbin/mtu-mss-apply.sh"
  printf '%s\n' legacy-mss-config > "${root_dir}/etc/default/mtu-mss-fix"
  printf '%s\n' legacy-mss-service > "${root_dir}/etc/systemd/system/mtu-mss-fix.service"
  printf '%s\n' legacy-network-apply > "${root_dir}/usr/local/sbin/network-max-tune.sh"
  printf '%s\n' legacy-network-config > "${root_dir}/etc/default/network-max-tune"
  printf '%s\n' legacy-network-service > "${root_dir}/etc/systemd/system/network-max-tune.service"
}

write_test_os_release() {
  local root_dir="$1"
  local os_id="$2"
  local codename="$3"
  local version_id="$4"
  cat > "${root_dir}/etc/os-release" <<EOF
ID=${os_id}
VERSION_ID=${version_id}
VERSION_CODENAME=${codename}
PRETTY_NAME=${os_id}-${codename}
EOF
}

write_test_archive_keyring() {
  local root_dir="$1"
  local os_id="$2"
  local keyring
  case "${os_id}" in
    debian) keyring="${root_dir}/usr/share/keyrings/debian-archive-keyring.gpg" ;;
    ubuntu) keyring="${root_dir}/usr/share/keyrings/ubuntu-archive-keyring.gpg" ;;
    *) fail_test "unsupported test system id: ${os_id}" ;;
  esac
  printf '%s\n' "${os_id}-archive-keyring" > "${keyring}"
}

assert_no_source_transaction_files() {
  local apt_dir="$1"
  if find "${apt_dir}" -name '.main2-*-sources.*' -o -name '*.disabled.*' | grep -q .; then
    fail_test "source transaction files remain under ${apt_dir}"
  fi
}

test_debian_official_sources() (
  local case_dir="${TMP_DIR}/debian-official-sources"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local archive_keyring="${root_dir}/usr/share/keyrings/debian-archive-keyring.gpg"
  local old_main='deb http://ftp.debian.org/debian bookworm main'
  local old_dropin="Types: deb
URIs: http://deb.debian.org/debian
Suites: bookworm bookworm-updates
Components: main
Signed-By: ${archive_keyring}
Contact: https://support.example.com

Enabled: no
Types: deb
URIs: https://packages.example.com/debian
Suites: bookworm
Components: main"
  local third_party='deb https://download.docker.com/linux/debian bookworm stable'
  local expected="deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware"

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" debian bookworm 12
  write_test_archive_keyring "${root_dir}" debian
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
  printf '%s\n' "${old_dropin}" > "${source_dir}/debian.sources"
  printf '%s\n' "${third_party}" > "${source_dir}/docker.list"
  printf '%s\n' first-backup > "${apt_dir}/sources.list.bak.20260727010101"
  : > "${apt_update_log}"

  source_uri_belongs_to_system debian 'http://ftp.debian.org/debian' ||
    fail_test "ftp.debian.org was not recognized as a Debian system source"
  source_uri_belongs_to_system debian 'http://http.us.debian.org/debian' ||
    fail_test "http.us.debian.org was not recognized as a Debian system source"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  date() {
    [[ "${1:-}" == "+%Y%m%d%H%M%S" ]] || return 64
    printf '%s' 20260727010101
  }
  # shellcheck disable=SC2329
  apt_update() {
    printf '%s\n' update >> "${apt_update_log}"
    grep -Fq 'http://deb.debian.org/debian bookworm main' "${apt_dir}/sources.list"
  }

  set_system_sources > "${case_dir}/output" 2>&1
  assert_eq 1 "$(line_count "${apt_update_log}")" \
    "Debian official source apt update count"
  assert_eq "${expected}" "$(<"${apt_dir}/sources.list")" "Debian official sources"
  assert_eq first-backup "$(<"${apt_dir}/sources.list.bak.20260727010101")" \
    "existing Debian source backup preserved"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list.bak.20260727010101.1")" \
    "new Debian source backup content"
  assert_missing "${source_dir}/debian.sources"
  assert_eq "${old_dropin}" \
    "$(<"${source_dir}/debian.sources.disabled.20260727010101")" \
    "disabled Debian source content"
  assert_eq "${third_party}" "$(<"${source_dir}/docker.list")" \
    "Debian third-party source preserved"
  if find "${apt_dir}" -name '.main2-debian-sources.*' | grep -q .; then
    fail_test "Debian source staging file remains"
  fi

  set_system_sources > "${case_dir}/repeat-output" 2>&1
  assert_eq 2 "$(line_count "${apt_update_log}")" \
    "repeated Debian official source apt update count"
  assert_eq "${expected}" "$(<"${apt_dir}/sources.list")" \
    "repeated Debian official sources"
  assert_eq "${expected}" "$(<"${apt_dir}/sources.list.bak.20260727010101.2")" \
    "repeated Debian source backup content"
  assert_eq "${third_party}" "$(<"${source_dir}/docker.list")" \
    "repeated Debian third-party source preserved"
)

test_debian_official_source_matrix() (
  local case_dir="${TMP_DIR}/debian-source-matrix"
  local root_dir="${case_dir}/rootfs"
  local archive_keyring="${root_dir}/usr/share/keyrings/debian-archive-keyring.gpg"
  local codename expected output

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"

  for codename in buster bullseye bookworm trixie; do
    output="${case_dir}/${codename}.list"
    case "${codename}" in
      buster)
        expected="deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian buster main contrib non-free
deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian buster-updates main contrib non-free
deb [check-valid-until=no signed-by=${archive_keyring}] http://archive.debian.org/debian-security buster/updates main contrib non-free"
        ;;
      bullseye)
        expected="deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bullseye main contrib non-free
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bullseye-updates main contrib non-free
deb [signed-by=${archive_keyring}] http://security.debian.org/debian-security bullseye-security main contrib non-free"
        ;;
      bookworm)
        expected="deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware"
        ;;
      trixie)
        expected="deb [signed-by=${archive_keyring}] http://deb.debian.org/debian trixie main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://deb.debian.org/debian trixie-updates main contrib non-free non-free-firmware
deb [signed-by=${archive_keyring}] http://security.debian.org/debian-security trixie-security main contrib non-free non-free-firmware"
        ;;
    esac
    write_debian_official_sources "${output}" "${codename}" "${archive_keyring}"
    assert_eq "${expected}" "$(<"${output}")" "Debian ${codename} source matrix"
  done
)

test_ubuntu_official_sources() (
  local architecture expected archive_marker forbidden_marker
  for architecture in amd64 i386 arm64 armhf ppc64el riscv64 s390x; do
    (
      local test_architecture="${architecture}"
      local case_dir="${TMP_DIR}/ubuntu-official-${architecture}"
      local root_dir="${case_dir}/rootfs"
      local apt_dir="${root_dir}/etc/apt"
      local source_dir="${apt_dir}/sources.list.d"
      local apt_update_log="${case_dir}/apt-update.log"
      local archive_keyring="${root_dir}/usr/share/keyrings/ubuntu-archive-keyring.gpg"
      local old_main='deb http://archive.ubuntu.com/ubuntu noble main'
      local old_dropin="Types: deb
URIs: https://mirror.example.com/ubuntu
Suites: noble noble-updates noble-security
Components: main restricted universe multiverse
Signed-By: ${archive_keyring}"
      local regional_source="Types: deb
URIs: https://regional.example.com/ubuntu
Suites: noble-backports
Components: main restricted universe multiverse
Signed-By: ${archive_keyring}"
      local regional_list="deb [signed-by=${archive_keyring}] https://regional-list.example.com/ubuntu noble main"
      local third_party='deb https://ppa.launchpadcontent.net/example/repo/ubuntu noble main'

      install -d "${case_dir}"
      build_main2_library "${case_dir}"
      # shellcheck disable=SC1090,SC1091
      . "${case_dir}/main2-library.sh"
      install -d "${source_dir}"
      write_test_os_release "${root_dir}" ubuntu noble 24.04
      write_test_archive_keyring "${root_dir}" ubuntu
      printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
      printf '%s\n' "${old_dropin}" > "${source_dir}/ubuntu.sources"
      printf '%s\n' "${regional_source}" > "${source_dir}/regional.sources"
      printf '%s\n' "${regional_list}" > "${source_dir}/regional.list"
      printf '%s\n' "${third_party}" > "${source_dir}/ppa.list"
      : > "${apt_update_log}"

      if [[ "${architecture}" == "amd64" || "${architecture}" == "i386" ]]; then
        expected="deb [arch=${architecture} signed-by=${archive_keyring}] http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse"
        archive_marker='http://archive.ubuntu.com/ubuntu'
        forbidden_marker='ports.ubuntu.com'
      else
        expected="deb [arch=${architecture} signed-by=${archive_keyring}] http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://ports.ubuntu.com/ubuntu-ports noble-backports main restricted universe multiverse
deb [arch=${architecture} signed-by=${archive_keyring}] http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse"
        archive_marker='http://ports.ubuntu.com/ubuntu-ports'
        forbidden_marker='archive.ubuntu.com'
      fi

      # Invoked by source transaction functions from the extracted main2 library.
      # shellcheck disable=SC2329
      date() {
        [[ "${1:-}" == "+%Y%m%d%H%M%S" ]] || return 64
        printf '%s' 20260727020202
      }
      # shellcheck disable=SC2329
      dpkg() {
        [[ "${1:-}" == "--print-architecture" ]] || return 64
        printf '%s' "${test_architecture}"
      }
      # shellcheck disable=SC2329
      apt_update() {
        printf '%s\n' update >> "${apt_update_log}"
        grep -Fq "${archive_marker}" "${apt_dir}/sources.list"
      }

      set_system_sources > "${case_dir}/output" 2>&1
      assert_eq 1 "$(line_count "${apt_update_log}")" \
        "Ubuntu ${architecture} apt update count"
      assert_eq "${expected}" "$(<"${apt_dir}/sources.list")" \
        "Ubuntu ${architecture} official sources"
      assert_not_contains "${forbidden_marker}" "${apt_dir}/sources.list"
      assert_eq "${old_main}" "$(<"${apt_dir}/sources.list.bak.20260727020202")" \
        "Ubuntu ${architecture} source backup"
      assert_missing "${source_dir}/ubuntu.sources"
      assert_eq "${old_dropin}" \
        "$(<"${source_dir}/ubuntu.sources.disabled.20260727020202")" \
        "Ubuntu ${architecture} disabled system source"
      assert_missing "${source_dir}/regional.sources"
      assert_eq "${regional_source}" \
        "$(<"${source_dir}/regional.sources.disabled.20260727020202")" \
        "Ubuntu ${architecture} disabled nonstandard system source"
      assert_missing "${source_dir}/regional.list"
      assert_eq "${regional_list}" \
        "$(<"${source_dir}/regional.list.disabled.20260727020202")" \
        "Ubuntu ${architecture} disabled nonstandard list source"
      assert_eq "${third_party}" "$(<"${source_dir}/ppa.list")" \
        "Ubuntu ${architecture} third-party source preserved"
      if find "${apt_dir}" -name '.main2-ubuntu-sources.*' | grep -q .; then
        fail_test "Ubuntu ${architecture} source staging file remains"
      fi
    )
  done
)

test_official_source_failure_rollback() (
  local spec os_id codename architecture standard_file standard_content
  for spec in 'debian:bookworm:amd64' 'ubuntu:noble:amd64'; do
    IFS=: read -r os_id codename architecture <<< "${spec}"
    (
      local test_architecture="${architecture}"
      local case_dir="${TMP_DIR}/source-rollback-${os_id}"
      local root_dir="${case_dir}/rootfs"
      local apt_dir="${root_dir}/etc/apt"
      local source_dir="${apt_dir}/sources.list.d"
      local apt_update_log="${case_dir}/apt-update.log"
      local old_main
      local third_party="deb https://download.docker.com/linux/${os_id} ${codename} stable"

      if [[ "${os_id}" == "debian" ]]; then
        old_main="deb http://deb.debian.org/debian ${codename} main"
      else
        old_main="deb http://archive.ubuntu.com/ubuntu ${codename} main"
      fi

      install -d "${case_dir}"
      build_main2_library "${case_dir}"
      # shellcheck disable=SC1090,SC1091
      . "${case_dir}/main2-library.sh"
      install -d "${source_dir}"
      if [[ "${os_id}" == "debian" ]]; then
        write_test_os_release "${root_dir}" "${os_id}" "${codename}" 12
      else
        write_test_os_release "${root_dir}" "${os_id}" "${codename}" 24.04
      fi
      write_test_archive_keyring "${root_dir}" "${os_id}"
      printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
      printf '%s\n' "${third_party}" > "${source_dir}/third-party.list"
      if [[ "${os_id}" == "debian" ]]; then
        standard_file="${source_dir}/debian.sources"
        standard_content=$'Types: deb\nURIs: http://deb.debian.org/debian\nSuites: bookworm\nComponents: main'
      else
        standard_file="${source_dir}/ubuntu.sources"
        standard_content=$'Types: deb\nURIs: http://archive.ubuntu.com/ubuntu\nSuites: noble\nComponents: main restricted'
      fi
      printf '%s\n' "${standard_content}" > "${standard_file}"
      : > "${apt_update_log}"

      # Invoked by source transaction functions from the extracted main2 library.
      # shellcheck disable=SC2329
      date() { printf '%s' 20260727030303; }
      # shellcheck disable=SC2329
      dpkg() {
        [[ "${1:-}" == "--print-architecture" ]] || return 64
        printf '%s' "${test_architecture}"
      }
      # shellcheck disable=SC2329
      apt_update() {
        printf '%s\n' update >> "${apt_update_log}"
        [[ "$(line_count "${apt_update_log}")" -gt 1 ]]
      }

      if set_system_sources > "${case_dir}/output" 2>&1; then
        fail_test "${os_id} source update failure unexpectedly succeeded"
      fi
      assert_eq 2 "$(line_count "${apt_update_log}")" \
        "${os_id} rollback apt update count"
      assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
        "${os_id} main source restored"
      assert_eq "${standard_content}" "$(<"${standard_file}")" \
        "${os_id} standard source restored"
      assert_eq "${third_party}" "$(<"${source_dir}/third-party.list")" \
        "${os_id} third-party source preserved after rollback"
      assert_no_source_transaction_files "${apt_dir}"
      assert_contains "已恢复并重新刷新执行前的软件源" "${case_dir}/output"
    )
  done
)

test_official_source_preflight_guards() (
  local case_dir="${TMP_DIR}/source-preflight"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local old_main='deb http://archive.ubuntu.com/ubuntu noble main'
  local mixed_content=$'  deb http://archive.ubuntu.com/ubuntu noble main\n\tdeb https://ppa.launchpadcontent.net/example/repo/ubuntu noble main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" ubuntu noble 24.04
  write_test_archive_keyring "${root_dir}" ubuntu
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
  printf '%s\n' "${mixed_content}" > "${source_dir}/mixed.list"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  dpkg() {
    [[ "${1:-}" == "--print-architecture" ]] || return 64
    printf '%s' amd64
  }
  # shellcheck disable=SC2329
  apt_update() {
    printf '%s\n' update >> "${apt_update_log}"
  }

  if set_system_sources > "${case_dir}/mixed-output" 2>&1; then
    fail_test "mixed Ubuntu system and third-party source unexpectedly succeeded"
  fi
  assert_eq 0 "$(line_count "${apt_update_log}")" "mixed source apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" "mixed source main file unchanged"
  assert_eq "${mixed_content}" "$(<"${source_dir}/mixed.list")" \
    "mixed source file unchanged"
  assert_contains "系统源与第三方源混合" "${case_dir}/mixed-output"
  assert_no_source_transaction_files "${apt_dir}"

  rm -f -- "${source_dir}/mixed.list"
  mkdir "${source_dir}/ubuntu.sources"
  if set_system_sources > "${case_dir}/unsafe-output" 2>&1; then
    fail_test "non-regular Ubuntu source path unexpectedly succeeded"
  fi
  assert_eq 0 "$(line_count "${apt_update_log}")" \
    "non-regular source apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "non-regular source main file unchanged"
  assert_contains "APT 系统源文件不是安全的普通文件" "${case_dir}/unsafe-output"
)

test_official_source_early_guards() (
  local case_dir="${TMP_DIR}/source-early-guards"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_calls=0
  local old_main='deb http://archive.ubuntu.com/ubuntu noble main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" ubuntu noble 24.04
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  dpkg() {
    [[ "${1:-}" == "--print-architecture" ]] || return 64
    printf '%s' amd64
  }
  # shellcheck disable=SC2329
  apt_update() {
    apt_update_calls=$((apt_update_calls + 1))
  }

  if set_system_sources > "${case_dir}/keyring-output" 2>&1; then
    fail_test "missing Ubuntu archive keyring unexpectedly succeeded"
  fi
  assert_eq 0 "${apt_update_calls}" "missing keyring apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "missing keyring source unchanged"
  assert_contains "发行版 APT 密钥环不是可读的普通文件" \
    "${case_dir}/keyring-output"
  assert_no_source_transaction_files "${apt_dir}"

  write_test_archive_keyring "${root_dir}" ubuntu
  # shellcheck disable=SC2329
  dpkg() {
    [[ "${1:-}" == "--print-architecture" ]] || return 64
    printf '%s' mips64el
  }
  if set_system_sources > "${case_dir}/architecture-output" 2>&1; then
    fail_test "unsupported Ubuntu architecture unexpectedly succeeded"
  fi
  assert_eq 0 "${apt_update_calls}" "unsupported architecture apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "unsupported architecture source unchanged"
  assert_contains "未配置 Ubuntu mips64el 的官方仓库地址" \
    "${case_dir}/architecture-output"
  assert_no_source_transaction_files "${apt_dir}"
)

test_main_source_mixed_guard() (
  local case_dir="${TMP_DIR}/mixed-main-source"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local mixed_main=$'deb http://archive.ubuntu.com/ubuntu noble main\ndeb https://download.docker.com/linux/ubuntu noble stable'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" ubuntu noble 24.04
  write_test_archive_keyring "${root_dir}" ubuntu
  printf '%s\n' "${mixed_main}" > "${apt_dir}/sources.list"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  dpkg() { printf '%s' amd64; }
  # shellcheck disable=SC2329
  apt_update() { printf '%s\n' update >> "${apt_update_log}"; }

  if set_system_sources > "${case_dir}/output" 2>&1; then
    fail_test "mixed APT main source unexpectedly succeeded"
  fi
  assert_eq "${mixed_main}" "$(<"${apt_dir}/sources.list")" \
    "mixed APT main source unchanged"
  assert_eq 0 "$(line_count "${apt_update_log}")" "mixed APT main update count"
  assert_contains "APT 主源包含无法确认归属的活动仓库" "${case_dir}/output"
  assert_no_source_transaction_files "${apt_dir}"
)

test_disabled_standard_source_is_ignored() (
  local case_dir="${TMP_DIR}/disabled-standard-source"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local disabled_source=$'Enabled: no   \nTypes: deb\nURIs: https://packages.example.com/ubuntu\nSuites: noble\nComponents: main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" ubuntu noble 24.04
  write_test_archive_keyring "${root_dir}" ubuntu
  printf '%s\n' 'deb http://archive.ubuntu.com/ubuntu noble main' > \
    "${apt_dir}/sources.list"
  printf '%s\n' "${disabled_source}" > "${source_dir}/ubuntu.sources"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  date() { printf '%s' 20260727050505; }
  # shellcheck disable=SC2329
  dpkg() { printf '%s' amd64; }
  # shellcheck disable=SC2329
  apt_update() { printf '%s\n' update >> "${apt_update_log}"; }

  set_system_sources > "${case_dir}/output" 2>&1
  assert_eq 1 "$(line_count "${apt_update_log}")" \
    "disabled standard source apt update count"
  assert_eq "${disabled_source}" "$(<"${source_dir}/ubuntu.sources")" \
    "disabled standard source preserved"
  assert_contains 'deb [arch=amd64 signed-by=' "${apt_dir}/sources.list"
  assert_no_source_transaction_files "${apt_dir}"
)

test_source_transaction_interrupt_rollback() (
  local case_dir="${TMP_DIR}/source-interrupt"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local old_main='deb http://deb.debian.org/debian bookworm main'
  local old_dropin=$'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: bookworm-security\nComponents: main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" debian bookworm 12
  write_test_archive_keyring "${root_dir}" debian
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
  printf '%s\n' "${old_dropin}" > "${source_dir}/debian.sources"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  date() { printf '%s' 20260727060606; }
  # shellcheck disable=SC2329
  apt_update() {
    printf '%s\n' update >> "${apt_update_log}"
    kill -TERM "${BASHPID}"
  }

  if set_system_sources > "${case_dir}/output" 2>&1; then
    fail_test "interrupted source transaction unexpectedly succeeded"
  fi
  assert_eq 1 "$(line_count "${apt_update_log}")" \
    "interrupted source transaction apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "interrupted main source restored"
  assert_eq "${old_dropin}" "$(<"${source_dir}/debian.sources")" \
    "interrupted drop-in source restored"
  assert_contains "官方源切换被中断，已恢复执行前的软件源" "${case_dir}/output"
  assert_no_source_transaction_files "${apt_dir}"
)

test_source_move_interrupt_rollback() (
  local case_dir="${TMP_DIR}/source-move-interrupt"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local target_backup="${apt_dir}/sources.list.bak.20260727060607"
  local old_main='deb http://deb.debian.org/debian bookworm main'
  local old_dropin=$'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: bookworm-security\nComponents: main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" debian bookworm 12
  write_test_archive_keyring "${root_dir}" debian
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
  printf '%s\n' "${old_dropin}" > "${source_dir}/debian.sources"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  date() { printf '%s' 20260727060607; }
  # shellcheck disable=SC2329
  mv() {
    local -a move_args=("$@")
    local argument_count="${#move_args[@]}"
    local source_path="${move_args[argument_count - 2]}"
    local destination_path="${move_args[argument_count - 1]}"
    command mv "$@" || return 1
    if [[ "${source_path}" == "${apt_dir}/sources.list" &&
          "${destination_path}" == "${target_backup}" ]]; then
      kill -TERM "${BASHPID}"
    fi
  }
  # shellcheck disable=SC2329
  apt_update() { printf '%s\n' update >> "${apt_update_log}"; }

  if set_system_sources > "${case_dir}/output" 2>&1; then
    fail_test "interrupted main source move unexpectedly succeeded"
  fi
  assert_eq 0 "$(line_count "${apt_update_log}")" \
    "interrupted main source move apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "interrupted main source move restored"
  assert_eq "${old_dropin}" "$(<"${source_dir}/debian.sources")" \
    "source drop-in unchanged after main source move interrupt"
  assert_contains "官方源切换被中断，已恢复执行前的软件源" "${case_dir}/output"
  assert_no_source_transaction_files "${apt_dir}"
)

test_source_rollback_ignores_second_signal() (
  local case_dir="${TMP_DIR}/source-rollback-signal"
  local root_dir="${case_dir}/rootfs"
  local apt_dir="${root_dir}/etc/apt"
  local source_dir="${apt_dir}/sources.list.d"
  local apt_update_log="${case_dir}/apt-update.log"
  local target_backup="${apt_dir}/sources.list.bak.20260727070707"
  local old_main='deb http://deb.debian.org/debian bookworm main'
  local old_dropin=$'Types: deb\nURIs: http://security.debian.org/debian-security\nSuites: bookworm-security\nComponents: main'

  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  install -d "${source_dir}"
  write_test_os_release "${root_dir}" debian bookworm 12
  write_test_archive_keyring "${root_dir}" debian
  printf '%s\n' "${old_main}" > "${apt_dir}/sources.list"
  printf '%s\n' "${old_dropin}" > "${source_dir}/debian.sources"
  : > "${apt_update_log}"

  # Invoked by source transaction functions from the extracted main2 library.
  # shellcheck disable=SC2329
  date() { printf '%s' 20260727070707; }
  # shellcheck disable=SC2329
  mv() {
    local -a move_args=("$@")
    local argument_count="${#move_args[@]}"
    local source_path="${move_args[argument_count - 2]}"
    local destination_path="${move_args[argument_count - 1]}"
    command mv "$@" || return 1
    if [[ "${source_path}" == "${target_backup}" &&
          "${destination_path}" == "${apt_dir}/sources.list" ]]; then
      kill -TERM "${BASHPID}"
    fi
  }
  # shellcheck disable=SC2329
  apt_update() {
    printf '%s\n' update >> "${apt_update_log}"
    [[ "$(line_count "${apt_update_log}")" -gt 1 ]]
  }

  if set_system_sources > "${case_dir}/output" 2>&1; then
    fail_test "failed official update unexpectedly reported success"
  fi
  assert_eq 2 "$(line_count "${apt_update_log}")" \
    "rollback signal apt update count"
  assert_eq "${old_main}" "$(<"${apt_dir}/sources.list")" \
    "rollback signal main source restored"
  assert_eq "${old_dropin}" "$(<"${source_dir}/debian.sources")" \
    "rollback signal drop-in restored"
  assert_contains "已恢复并重新刷新执行前的软件源" "${case_dir}/output"
  assert_no_source_transaction_files "${apt_dir}"
)

test_main2_lock_gate() (
  local case_dir="${TMP_DIR}/main2-lock"
  local flock_result=0
  local mapped_status=0
  local -a child_lines=()
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  cat >> "${case_dir}/main2-library.sh" <<EOF
main2_locked_main() {
  printf '%s\n' "\$#" "\${1:-}" "\${2:-}" >> "${case_dir}/child.log"
  return "\${MAIN2_LOCK_TEST_STATUS:-0}"
}
EOF
  # shellcheck disable=SC1090,SC1091
  . "${case_dir}/main2-library.sh"
  MAIN2_LOCK_FILE="${case_dir}/main2.lock"
  export MAIN2_LOCK_TEST_STATUS=0

  # Invoked by run_main2_with_lock from the extracted main2 library.
  # shellcheck disable=SC2329
  flock() {
    printf '%s\n' "$*" >> "${case_dir}/flock.log"
    if [[ "${flock_result}" != "0" ]]; then
      return "${flock_result}"
    fi
    shift 6
    "$@"
  }

  run_main2_with_lock alpha "two words"
  assert_file "${MAIN2_LOCK_FILE}"
  assert_contains "--exclusive --nonblock --close --conflict-exit-code 200 ${MAIN2_LOCK_FILE}" \
    "${case_dir}/flock.log"
  mapfile -t child_lines < "${case_dir}/child.log"
  assert_eq 3 "${#child_lines[@]}" "supervised main2 child log line count"
  assert_eq 2 "${child_lines[0]}" "supervised main2 argument count"
  assert_eq alpha "${child_lines[1]}" "supervised main2 first argument"
  assert_eq "two words" "${child_lines[2]}" "supervised main2 quoted argument"

  MAIN2_LOCK_TEST_STATUS=200
  : > "${case_dir}/child.log"
  if run_main2_with_lock > "${case_dir}/mapped-output" 2>&1; then
    fail_test "supervised main2 status 200 unexpectedly succeeded"
  else
    mapped_status=$?
  fi
  assert_eq 199 "${mapped_status}" "supervised main2 status 200 mapping"

  flock_result=200
  MAIN2_LOCK_TEST_STATUS=0
  : > "${case_dir}/child.log"
  if run_main2_with_lock > "${case_dir}/busy-output" 2>&1; then
    fail_test "busy main2 lock unexpectedly succeeded"
  fi
  assert_contains "另一份 main2.sh 正在运行" "${case_dir}/busy-output"
  assert_eq "" "$(<"${case_dir}/child.log")" "busy main2 lock child execution"

  rm -f -- "${MAIN2_LOCK_FILE}"
  mkdir "${MAIN2_LOCK_FILE}"
  if prepare_main2_lock_file > "${case_dir}/unsafe-output" 2>&1; then
    fail_test "non-regular main2 lock path unexpectedly succeeded"
  fi
  assert_contains "锁路径不是安全的普通文件" "${case_dir}/unsafe-output"
)

test_main2_lock_call_order() (
  local main_line root_line os_line systemd_line lock_line
  local locked_line download_line direct_guard_line direct_call_line
  main_line="$(awk '$0 == "main2_main() {" { print NR; exit }' "${MAIN2}")"
  root_line="$(awk '$0 == "main2_main() {" { capture = 1; next } capture && $0 == "  require_root" { print NR; exit }' "${MAIN2}")"
  os_line="$(awk '$0 == "main2_main() {" { capture = 1; next } capture && $0 == "  require_supported_os" { print NR; exit }' "${MAIN2}")"
  systemd_line="$(awk '$0 == "main2_main() {" { capture = 1; next } capture && $0 == "  require_systemd" { print NR; exit }' "${MAIN2}")"
  lock_line="$(awk '$0 == "main2_main() {" { capture = 1; next } capture && $0 == "  run_main2_with_lock \"$@\"" { print NR; exit }' "${MAIN2}")"
  locked_line="$(awk '$0 == "main2_locked_main() {" { print NR; exit }' "${MAIN2}")"
  download_line="$(awk '$0 == "main2_locked_main() {" { capture = 1; next } capture && $0 == "  ensure_download_tool" { print NR; exit }' "${MAIN2}")"
  direct_guard_line="$(awk '$0 == "if [[ \"${BASH_SOURCE[0]}\" == \"$0\" ]]; then" { print NR; exit }' "${MAIN2}")"
  direct_call_line="$(awk '$0 == "  main2_main \"$@\"" { print NR; exit }' "${MAIN2}")"
  [[ "${main_line}" =~ ^[1-9][0-9]*$ &&
     "${root_line}" =~ ^[1-9][0-9]*$ &&
     "${os_line}" =~ ^[1-9][0-9]*$ &&
     "${systemd_line}" =~ ^[1-9][0-9]*$ &&
     "${lock_line}" =~ ^[1-9][0-9]*$ &&
     "${locked_line}" =~ ^[1-9][0-9]*$ &&
     "${download_line}" =~ ^[1-9][0-9]*$ &&
     "${direct_guard_line}" =~ ^[1-9][0-9]*$ &&
     "${direct_call_line}" =~ ^[1-9][0-9]*$ ]] ||
    fail_test "main2 entry lock ordering markers are incomplete"
  (( main_line < root_line && root_line < os_line && os_line < systemd_line &&
     systemd_line < lock_line && locked_line < download_line &&
     lock_line < direct_guard_line && direct_guard_line < direct_call_line )) ||
    fail_test "main2 lock must run before downloads and system writes"
  assert_contains 'flock --exclusive --nonblock --close --conflict-exit-code 200' "${MAIN2}"
  assert_contains "      . \"\${main2_script}\"" "${MAIN2}"
  assert_contains "      main2_locked_main \"\$@\"" "${MAIN2}"
)

test_fresh_prepare_is_noop() (
  local case_dir="${TMP_DIR}/fresh"
  local root_dir="${case_dir}/rootfs"
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"

  prepare_legacy_main_deployment
  assert_eq 0 "${LEGACY_SYSCTL_MIGRATION}" "fresh sysctl migration flag"
  assert_eq 0 "${LEGACY_UDP_MIGRATION}" "fresh UDP migration flag"
  assert_missing "${LEGACY_UDP_PENDING_FILE}"
  if find "${root_dir}" -name '*.pre-main2.*' -print -quit | grep -q .; then
    fail_test "fresh prepare created a migration backup"
  fi
)

test_legacy_and_incomplete_udp_migrate() (
  local case_dir="${TMP_DIR}/legacy"
  local root_dir="${case_dir}/rootfs"
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  write_legacy_core_files "${root_dir}"
  touch "${LEGACY_MARK_FILE}"
  printf '%s\n' '@vpn soft nofile 65536' >> "${root_dir}/etc/security/limits.conf"
  install -d "${root_dir}/etc/udp-multinic"
  printf '%s\n' 'v4 203.0.113.10 10.0.0.2 443' > \
    "${root_dir}/etc/udp-multinic/rules.conf"

  prepare_legacy_main_deployment
  assert_eq 1 "${LEGACY_SYSCTL_MIGRATION}" "legacy sysctl migration flag"
  assert_eq 1 "${LEGACY_UDP_MIGRATION}" "incomplete UDP recovery flag"
  assert_file "${LEGACY_UDP_PENDING_FILE}"
  assert_eq '@vpn soft nofile 65536' "$(<"${root_dir}/etc/security/limits.conf")" \
    "custom limits tail preserved"
  assert_missing "${root_dir}/usr/local/sbin/mtu-mss-apply.sh"
  assert_missing "${root_dir}/etc/systemd/system/mtu-mss-fix.service"
  assert_missing "${root_dir}/usr/local/sbin/network-max-tune.sh"
  assert_missing "${root_dir}/etc/systemd/system/network-max-tune.service"
  assert_eq 1 "$(find "${root_dir}/etc" -name 'sysctl.conf.pre-main2.*' | wc -l | tr -d '[:space:]')" \
    "legacy sysctl backup count"
  assert_eq 1 "$(find "${root_dir}/etc/security" -name 'limits.conf.pre-main2.*' | wc -l | tr -d '[:space:]')" \
    "legacy limits backup count"
  assert_contains validate "${case_dir}/udp.log"

  migrate_legacy_udp
  assert_missing "${LEGACY_UDP_PENDING_FILE}"
  assert_contains migrate "${case_dir}/udp.log"
)

test_invalid_udp_fails_before_writes() (
  local case_dir="${TMP_DIR}/invalid-udp"
  local root_dir="${case_dir}/rootfs"
  local sysctl_before limits_before
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  write_legacy_core_files "${root_dir}"
  install -d "${root_dir}/etc/udp-multinic"
  printf '%s\n' 'v6 2001:db8::10 2001:db8::20 443' > \
    "${root_dir}/etc/udp-multinic/rules.conf"
  sysctl_before="$(sha256sum "${root_dir}/etc/sysctl.conf" | awk '{print $1}')"
  limits_before="$(sha256sum "${root_dir}/etc/security/limits.conf" | awk '{print $1}')"

  if prepare_legacy_main_deployment > "${case_dir}/output" 2>&1; then
    fail_test "invalid legacy UDP rules unexpectedly migrated"
  fi
  assert_eq "${sysctl_before}" "$(sha256sum "${root_dir}/etc/sysctl.conf" | awk '{print $1}')" \
    "sysctl unchanged after UDP preflight failure"
  assert_eq "${limits_before}" "$(sha256sum "${root_dir}/etc/security/limits.conf" | awk '{print $1}')" \
    "limits unchanged after UDP preflight failure"
  assert_file "${root_dir}/usr/local/sbin/mtu-mss-apply.sh"
  assert_file "${root_dir}/usr/local/sbin/network-max-tune.sh"
  assert_missing "${LEGACY_UDP_PENDING_FILE}"
  assert_contains "系统配置尚未修改" "${case_dir}/output"
)

test_current_udp_is_not_restarted() (
  local case_dir="${TMP_DIR}/current-udp"
  local root_dir="${case_dir}/rootfs"
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "${root_dir}/etc/udp-multinic"
  printf '%s\n' 'v4 203.0.113.10 10.0.0.2 443' > \
    "${root_dir}/etc/udp-multinic/rules.conf"
  printf '%s\n' current-udp-apply > "${root_dir}/usr/local/sbin/udp-multinic-apply.sh"
  printf '%s\n' current-udp-service > "${root_dir}/etc/systemd/system/udp-multinic.service"
  printf '%s\n' current-udp-sysctl > "${root_dir}/etc/sysctl.d/61-udp-multinic.conf"

  prepare_legacy_main_deployment
  assert_eq 0 "${LEGACY_UDP_MIGRATION}" "current UDP migration flag"
  assert_missing "${LEGACY_UDP_PENDING_FILE}"
  assert_not_contains "disable --now udp-multinic.service" "${case_dir}/systemctl.log"
)

test_failed_udp_migration_keeps_pending_marker() (
  local case_dir="${TMP_DIR}/failed-udp-migration"
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "$(dirname "${LEGACY_UDP_PENDING_FILE}")"
  touch "${LEGACY_UDP_PENDING_FILE}"
  cat > "${case_dir}/udp-validator.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  validate) exit 0 ;;
  migrate) exit 42 ;;
  *) exit 64 ;;
esac
EOF
  chmod 0755 "${case_dir}/udp-validator.sh"
  LEGACY_UDP_MIGRATION=1
  if migrate_legacy_udp > "${case_dir}/output" 2>&1; then
    fail_test "failed UDP migration unexpectedly succeeded"
  fi
  assert_file "${LEGACY_UDP_PENDING_FILE}"
)

test_default_setup_marker_gate() (
  local case_dir="${TMP_DIR}/marker"
  local calls_file="${case_dir}/calls.log"
  local old_applied_sha
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  # These mocks are invoked by default_setup from the extracted main2 library.
  # shellcheck disable=SC2329
  set_system_sources() { echo sources >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_base_tools() { echo base >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${calls_file}"; }
  # shellcheck disable=SC2329
  run_network_optimization() { echo "network:$1:${2:-1}" >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${calls_file}"; }

  install -d "$(dirname "${MARK_FILE}")"
  touch "${MARK_FILE}"
  record_bundle_state
  assert_contains "BUNDLE_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "APPLIED_VERSION=0" "${MAIN2_INSTALL_STATE_FILE}"
  : > "${calls_file}"
  default_setup
  assert_eq "" "$(<"${calls_file}")" "legacy main2 without profile preserves current settings"

  # Read by default_setup from the extracted main2 library.
  # shellcheck disable=SC2034
  REAPPLY_INIT=1
  if default_setup > "${case_dir}/missing-profile-output" 2>&1; then
    fail_test "legacy main2 reapply without a profile unexpectedly succeeded"
  fi
  assert_contains "必须同时明确 PROFILE=balanced 或 PROFILE=max" \
    "${case_dir}/missing-profile-output"
  assert_eq "" "$(<"${calls_file}")" "missing legacy profile performs no setup"
  # shellcheck disable=SC2034
  # Read by default_setup from the extracted main2 library.
  # shellcheck disable=SC2034
  REAPPLY_INIT=0

  # Read by default_setup from the extracted main2 library.
  # shellcheck disable=SC2034
  PROFILE_WAS_EXPLICIT=1
  # shellcheck disable=SC2030,SC2034
  PROFILE=max
  default_setup
  assert_contains sources "${calls_file}"
  assert_contains base "${calls_file}"
  assert_contains chrony "${calls_file}"
  assert_contains network:max:0 "${calls_file}"
  assert_contains irqbalance "${calls_file}"
  assert_file "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "APPLIED_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PROFILE=max" "${MAIN2_INSTALL_STATE_FILE}"

  : > "${calls_file}"
  default_setup
  assert_eq "" "$(<"${calls_file}")" "same main2 version skips default setup"

  old_applied_sha="$(printf '%064d' 0)"
  # Read by write_install_state from the extracted main2 library.
  # shellcheck disable=SC2034
  APPLIED_MAIN2_SHA256="${old_applied_sha}"
  write_install_state
  # Read by initialize_main2_state from the extracted main2 library.
  # shellcheck disable=SC2034
  MAIN2_STATE_LOADED=0
  initialize_main2_state

  # shellcheck disable=SC2329
  install_chrony() {
    echo chrony-failed >> "${calls_file}"
    return 1
  }
  : > "${calls_file}"
  if default_setup > "${case_dir}/chrony-failure-output" 2>&1; then
    fail_test "default setup unexpectedly succeeded after Chrony failure"
  fi
  assert_not_contains irqbalance "${calls_file}"
  assert_not_contains network: "${calls_file}"
  assert_contains "APPLIED_MAIN2_SHA256=${old_applied_sha}" "${MAIN2_INSTALL_STATE_FILE}"

  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_irqbalance() {
    echo irqbalance-failed >> "${calls_file}"
    return 1
  }
  : > "${calls_file}"
  if default_setup > "${case_dir}/irqbalance-failure-output" 2>&1; then
    fail_test "default setup unexpectedly succeeded after irqbalance failure"
  fi
  assert_not_contains network: "${calls_file}"
  assert_contains "APPLIED_MAIN2_SHA256=${old_applied_sha}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "尚未标记为已完成" "${case_dir}/irqbalance-failure-output"

  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${calls_file}"; }
  : > "${calls_file}"
  default_setup
  assert_contains network:max:0 "${calls_file}"
  assert_contains "APPLIED_MAIN2_SHA256=${CURRENT_MAIN2_SHA256}" "${MAIN2_INSTALL_STATE_FILE}"
)

test_required_package_commands_fail_closed() (
  local case_dir="${TMP_DIR}/required-package-commands"
  local apt_update_status=1 apt_get_status=0 fail_command expected
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"

  # shellcheck disable=SC2329
  require_supported_os() { return 0; }
  # shellcheck disable=SC2329
  system_id() { printf '%s' debian; }
  # shellcheck disable=SC2329
  set_debian_sources() { apt_update; }
  # shellcheck disable=SC2329
  apt_update() {
    echo apt-update >> "${case_dir}/commands.log"
    return "${apt_update_status}"
  }
  # shellcheck disable=SC2329
  apt-get() {
    echo "apt-get $*" >> "${case_dir}/commands.log"
    return "${apt_get_status}"
  }

  : > "${case_dir}/commands.log"
  if set_system_sources > "${case_dir}/sources-failure-output" 2>&1; then
    fail_test "source refresh failure unexpectedly succeeded"
  fi
  assert_eq apt-update "$(<"${case_dir}/commands.log")" \
    "source refresh failure is returned"

  : > "${case_dir}/commands.log"
  if install_base_tools > "${case_dir}/base-update-failure-output" 2>&1; then
    fail_test "base tool apt update failure unexpectedly succeeded"
  fi
  assert_eq apt-update "$(<"${case_dir}/commands.log")" \
    "base tool install stops after apt update failure"

  apt_update_status=0
  apt_get_status=1
  : > "${case_dir}/commands.log"
  if install_base_tools > "${case_dir}/base-install-failure-output" 2>&1; then
    fail_test "base tool package install failure unexpectedly succeeded"
  fi
  assert_contains "apt-get install -y --no-install-recommends" "${case_dir}/commands.log"

  # shellcheck disable=SC2329
  apt() {
    local command="apt $*"
    echo "${command}" >> "${case_dir}/commands.log"
    [[ "${command}" != "${fail_command}" ]]
  }
  # shellcheck disable=SC2329
  systemctl() {
    local command="systemctl $*"
    echo "${command}" >> "${case_dir}/commands.log"
    [[ "${command}" != "${fail_command}" ]]
  }
  # shellcheck disable=SC2329
  chronyc() {
    local command="chronyc $*"
    echo "${command}" >> "${case_dir}/commands.log"
    [[ "${command}" != "${fail_command}" ]]
  }

  for fail_command in \
    "apt update" \
    "apt install chrony -y" \
    "systemctl enable chrony" \
    "systemctl restart chrony" \
    "chronyc makestep"; do
    case "${fail_command}" in
      "apt update") expected="apt update" ;;
      "apt install chrony -y") expected=$'apt update\napt install chrony -y' ;;
      "systemctl enable chrony") expected=$'apt update\napt install chrony -y\nsystemctl enable chrony' ;;
      "systemctl restart chrony") expected=$'apt update\napt install chrony -y\nsystemctl enable chrony\nsystemctl restart chrony' ;;
      "chronyc makestep") expected=$'apt update\napt install chrony -y\nsystemctl enable chrony\nsystemctl restart chrony\nchronyc makestep' ;;
    esac
    : > "${case_dir}/commands.log"
    if install_chrony > "${case_dir}/chrony-failure-output" 2>&1; then
      fail_test "required Chrony command failure unexpectedly succeeded: ${fail_command}"
    fi
    assert_eq "${expected}" "$(<"${case_dir}/commands.log")" \
      "Chrony stops at failed command ${fail_command}"
  done
)

test_install_state_validation() (
  local case_dir="${TMP_DIR}/install-state"
  local state_sha newer_version
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "$(dirname "${MAIN2_INSTALL_STATE_FILE}")"
  state_sha="$(printf '%064d' 1)"

  cat > "${MAIN2_INSTALL_STATE_FILE}" <<EOF
STATE_FORMAT=1
BUNDLE_VERSION=${MAIN2_BUNDLE_VERSION}
BUNDLE_MAIN2_SHA256=${state_sha}
APPLIED_VERSION=${MAIN2_BUNDLE_VERSION}
APPLIED_MAIN2_SHA256=${state_sha}
PENDING_VERSION=0
PENDING_MAIN2_SHA256=
MANAGED_CONFIG_FORMAT=1
MANAGED_CONFIG_SHA256=${state_sha}
PROFILE=invalid
ENABLE_NIC_TUNING=1
RP_FILTER=0
MAXIMIZE_NIC_RING=0
IP_LOCAL_PORT_RANGE=
SOCKET_BUFFER_DEFAULT=
SOCKET_BUFFER_MAX=
NETDEV_MAX_BACKLOG=
NETDEV_BUDGET=
NETDEV_BUDGET_USECS=
RPS_FLOW_ENTRIES=
TXQUEUELEN=
TCP_MAX_TW_BUCKETS=
TCP_MAX_SYN_BACKLOG=
IPFRAG_HIGH_THRESH=
NOFILE_LIMIT=
FILE_MAX=
NF_CONNTRACK_MAX=
NF_CONNTRACK_HASH_SIZE=
EOF
  if initialize_main2_state > "${case_dir}/invalid-output" 2>&1; then
    fail_test "invalid install state unexpectedly succeeded"
  fi
  assert_contains "main2 安装状态内容无效" "${case_dir}/invalid-output"

  cat > "${MAIN2_INSTALL_STATE_FILE}" <<EOF
STATE_FORMAT=2
BUNDLE_VERSION=${MAIN2_BUNDLE_VERSION}
EOF
  if initialize_main2_state > "${case_dir}/truncated-output" 2>&1; then
    fail_test "truncated install state unexpectedly succeeded"
  fi
  assert_contains "main2 安装状态格式无效" "${case_dir}/truncated-output"

  newer_version=$((MAIN2_BUNDLE_VERSION + 1))
  cat > "${MAIN2_INSTALL_STATE_FILE}" <<EOF
STATE_FORMAT=1
BUNDLE_VERSION=${newer_version}
BUNDLE_MAIN2_SHA256=${state_sha}
APPLIED_VERSION=0
APPLIED_MAIN2_SHA256=
PENDING_VERSION=0
PENDING_MAIN2_SHA256=
MANAGED_CONFIG_FORMAT=
MANAGED_CONFIG_SHA256=
PROFILE=
ENABLE_NIC_TUNING=
RP_FILTER=
MAXIMIZE_NIC_RING=
IP_LOCAL_PORT_RANGE=
SOCKET_BUFFER_DEFAULT=
SOCKET_BUFFER_MAX=
NETDEV_MAX_BACKLOG=
NETDEV_BUDGET=
NETDEV_BUDGET_USECS=
RPS_FLOW_ENTRIES=
TXQUEUELEN=
TCP_MAX_TW_BUCKETS=
TCP_MAX_SYN_BACKLOG=
IPFRAG_HIGH_THRESH=
NOFILE_LIMIT=
FILE_MAX=
NF_CONNTRACK_MAX=
NF_CONNTRACK_HASH_SIZE=
EOF
  if initialize_main2_state > "${case_dir}/downgrade-output" 2>&1; then
    fail_test "main2 downgrade unexpectedly succeeded"
  fi
  assert_contains "当前 main2.sh 版本低于机器已记录版本，拒绝自动降级" \
    "${case_dir}/downgrade-output"

  rm -f "${MAIN2_INSTALL_STATE_FILE}"
  mkdir "${MAIN2_INSTALL_STATE_FILE}"
  if initialize_main2_state > "${case_dir}/nonregular-output" 2>&1; then
    fail_test "non-regular install state unexpectedly succeeded"
  fi
  assert_contains "main2 安装状态不是普通文件" "${case_dir}/nonregular-output"
)

test_install_state_atomic_failure() (
  local case_dir="${TMP_DIR}/install-state-atomic"
  local state_dir
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  initialize_main2_state
  INSTALLED_BUNDLE_VERSION="${MAIN2_BUNDLE_VERSION}"
  INSTALLED_BUNDLE_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  state_dir="$(dirname "${MAIN2_INSTALL_STATE_FILE}")"
  install -d "${state_dir}"
  printf '%s\n' preserved-state > "${MAIN2_INSTALL_STATE_FILE}"
  : > "${case_dir}/mv.log"

  # Invoked by write_install_state while the here-document is redirected.
  # shellcheck disable=SC2329
  cat() { return 1; }
  # shellcheck disable=SC2329
  mv() {
    printf '%s\n' "$*" >> "${case_dir}/mv.log"
    command mv "$@"
  }
  if write_install_state > "${case_dir}/write-failure-output" 2>&1; then
    fail_test "install-state content write failure unexpectedly succeeded"
  fi
  unset -f cat
  assert_eq preserved-state "$(<"${MAIN2_INSTALL_STATE_FILE}")" \
    "content write failure preserves existing install state"
  assert_eq "" "$(<"${case_dir}/mv.log")" \
    "content write failure never attempts state replacement"
  if find "${state_dir}" -maxdepth 1 -name '.install-state.*' -print -quit | grep -q .; then
    fail_test "content write failure left an install-state temporary file"
  fi

  # shellcheck disable=SC2329
  chmod() {
    local target="${!#}"
    if [[ "${target}" == "${state_dir}"/.install-state.* ]]; then
      return 1
    fi
    command chmod "$@"
  }
  if write_install_state > "${case_dir}/chmod-failure-output" 2>&1; then
    fail_test "install-state chmod failure unexpectedly succeeded"
  fi
  assert_eq preserved-state "$(<"${MAIN2_INSTALL_STATE_FILE}")" \
    "chmod failure preserves existing install state"
  assert_eq "" "$(<"${case_dir}/mv.log")" \
    "chmod failure never attempts state replacement"
  if find "${state_dir}" -maxdepth 1 -name '.install-state.*' -print -quit | grep -q .; then
    fail_test "chmod failure left an install-state temporary file"
  fi
)

test_legacy_pending_state_requires_explicit_restart() (
  local case_dir="${TMP_DIR}/legacy-pending-state"
  local calls_file="${case_dir}/calls.log"
  local library_sha applied_sha managed_sha previous_version
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "$(dirname "${MAIN2_INSTALL_STATE_FILE}")" "$(dirname "${MARK_FILE}")"
  touch "${MARK_FILE}"
  library_sha="$(sha256sum "${case_dir}/main2-library.sh" | awk '{print $1}')"
  applied_sha="$(printf '%064d' 4)"
  managed_sha="$(managed_network_fingerprint 1)"
  previous_version=$((MAIN2_BUNDLE_VERSION - 1))

  cat > "${MAIN2_INSTALL_STATE_FILE}" <<EOF
STATE_FORMAT=1
BUNDLE_VERSION=${previous_version}
BUNDLE_MAIN2_SHA256=${applied_sha}
APPLIED_VERSION=${previous_version}
APPLIED_MAIN2_SHA256=${applied_sha}
PENDING_VERSION=${MAIN2_BUNDLE_VERSION}
PENDING_MAIN2_SHA256=${library_sha}
MANAGED_CONFIG_FORMAT=1
MANAGED_CONFIG_SHA256=${managed_sha}
PROFILE=max
ENABLE_NIC_TUNING=1
RP_FILTER=0
MAXIMIZE_NIC_RING=0
IP_LOCAL_PORT_RANGE=
SOCKET_BUFFER_DEFAULT=
SOCKET_BUFFER_MAX=
NETDEV_MAX_BACKLOG=
NETDEV_BUDGET=
NETDEV_BUDGET_USECS=
RPS_FLOW_ENTRIES=
TXQUEUELEN=
TCP_MAX_TW_BUCKETS=
TCP_MAX_SYN_BACKLOG=
IPFRAG_HIGH_THRESH=
NOFILE_LIMIT=
FILE_MAX=
NF_CONNTRACK_MAX=
NF_CONNTRACK_HASH_SIZE=
EOF

  initialize_main2_state
  assert_eq 0 "${PENDING_MANAGED_OVERWRITE_REQUIREMENT_KNOWN}" \
    "legacy pending state has no recorded overwrite requirement"
  record_bundle_state
  assert_contains "STATE_FORMAT=1" "${MAIN2_INSTALL_STATE_FILE}"
  assert_not_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=" "${MAIN2_INSTALL_STATE_FILE}"

  : > "${calls_file}"
  # These mocks remain unused because state format 1 did not record this requirement.
  # shellcheck disable=SC2329
  set_system_sources() { echo sources >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_base_tools() { echo base >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${calls_file}"; }
  default_setup > "${case_dir}/output" 2>&1
  assert_eq "" "$(<"${calls_file}")" \
    "legacy pending state stops before system changes"
  assert_contains "旧状态未记录上次未完成事务的人工文件覆盖条件" "${case_dir}/output"
  assert_contains "ALLOW_MANAGED_CONFIG_OVERWRITE=1 REAPPLY_INIT=1 PROFILE=max bash main2.sh" \
    "${case_dir}/output"

  REAPPLY_INIT=1
  PROFILE=max
  PROFILE_WAS_EXPLICIT=1
  : > "${calls_file}"
  default_setup > "${case_dir}/reapply-without-overwrite-output" 2>&1
  assert_eq "" "$(<"${calls_file}")" \
    "legacy pending state cannot bypass confirmation with reapply"
  assert_contains "本次未获得重新覆盖授权" \
    "${case_dir}/reapply-without-overwrite-output"
  assert_contains "STATE_FORMAT=1" "${MAIN2_INSTALL_STATE_FILE}"
)

test_saved_settings_restore_and_edit_guard() (
  local case_dir="${TMP_DIR}/saved-settings"
  local calls_file="${case_dir}/calls.log"
  local state_sha managed_sha previous_version network_count
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "$(dirname "${MAIN2_INSTALL_STATE_FILE}")" "$(dirname "${MARK_FILE}")"
  touch "${MARK_FILE}"
  state_sha="$(printf '%064d' 2)"
  managed_sha="$(managed_network_fingerprint)"
  previous_version=$((MAIN2_BUNDLE_VERSION - 1))

  cat > "${MAIN2_INSTALL_STATE_FILE}" <<EOF
STATE_FORMAT=1
BUNDLE_VERSION=${previous_version}
BUNDLE_MAIN2_SHA256=${state_sha}
APPLIED_VERSION=${previous_version}
APPLIED_MAIN2_SHA256=${state_sha}
PENDING_VERSION=0
PENDING_MAIN2_SHA256=
MANAGED_CONFIG_FORMAT=1
MANAGED_CONFIG_SHA256=${managed_sha}
PROFILE=max
ENABLE_NIC_TUNING=0
RP_FILTER=2
MAXIMIZE_NIC_RING=1
IP_LOCAL_PORT_RANGE=20000 60999
SOCKET_BUFFER_DEFAULT=300001
SOCKET_BUFFER_MAX=300002
NETDEV_MAX_BACKLOG=300003
NETDEV_BUDGET=304
NETDEV_BUDGET_USECS=300005
RPS_FLOW_ENTRIES=300006
TXQUEUELEN=300007
TCP_MAX_TW_BUCKETS=300008
TCP_MAX_SYN_BACKLOG=300009
IPFRAG_HIGH_THRESH=300010
NOFILE_LIMIT=300011
FILE_MAX=300012
NF_CONNTRACK_MAX=300013
NF_CONNTRACK_HASH_SIZE=300014
EOF

  initialize_main2_state
  # PROFILE is restored inside this independent upgrade-case subshell.
  # shellcheck disable=SC2031
  assert_eq max "${PROFILE}" "saved profile restored"
  assert_eq 0 "${ENABLE_NIC_TUNING}" "saved NIC tuning restored"
  assert_eq 2 "${RP_FILTER}" "saved rp_filter restored"
  assert_eq 1 "${MAXIMIZE_NIC_RING}" "saved ring setting restored"
  assert_eq "20000 60999" "${IP_LOCAL_PORT_RANGE}" "saved port range restored"
  assert_eq 300001 "${SOCKET_BUFFER_DEFAULT}" "saved socket default restored"
  assert_eq 300002 "${SOCKET_BUFFER_MAX}" "saved socket max restored"
  assert_eq 300003 "${NETDEV_MAX_BACKLOG}" "saved backlog restored"
  assert_eq 304 "${NETDEV_BUDGET}" "saved netdev budget restored"
  assert_eq 300005 "${NETDEV_BUDGET_USECS}" "saved budget usecs restored"
  assert_eq 300006 "${RPS_FLOW_ENTRIES}" "saved RPS entries restored"
  assert_eq 300007 "${TXQUEUELEN}" "saved txqueuelen restored"
  assert_eq 300008 "${TCP_MAX_TW_BUCKETS}" "saved TW buckets restored"
  assert_eq 300009 "${TCP_MAX_SYN_BACKLOG}" "saved SYN backlog restored"
  assert_eq 300010 "${IPFRAG_HIGH_THRESH}" "saved fragment threshold restored"
  assert_eq 300011 "${NOFILE_LIMIT}" "saved nofile restored"
  assert_eq 300012 "${FILE_MAX}" "saved file max restored"
  assert_eq 300013 "${NF_CONNTRACK_MAX}" "saved conntrack max restored"
  assert_eq 300014 "${NF_CONNTRACK_HASH_SIZE}" "saved conntrack hash restored"

  # These mocks are invoked by default_setup from the extracted main2 library.
  # shellcheck disable=SC2329
  set_system_sources() { echo sources >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_base_tools() { echo base >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${calls_file}"; }
  # shellcheck disable=SC2329
  run_network_optimization() { echo "network:$1:${2:-1}" >> "${calls_file}"; }
  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${calls_file}"; }

  record_bundle_state
  : > "${calls_file}"
  default_setup
  network_count="$(grep -c '^network:' "${calls_file}")"
  assert_eq 1 "${network_count}" "saved profile applied exactly once"
  assert_contains network:max:0 "${calls_file}"
  assert_contains "APPLIED_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PROFILE=max" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "ENABLE_NIC_TUNING=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "RP_FILTER=2" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "MAXIMIZE_NIC_RING=1" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "IP_LOCAL_PORT_RANGE=20000 60999" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "NF_CONNTRACK_HASH_SIZE=300014" "${MAIN2_INSTALL_STATE_FILE}"

  # Read by default_setup and write_install_state from the extracted library.
  # shellcheck disable=SC2034
  APPLIED_MAIN2_SHA256="$(printf '%064d' 0)"
  write_install_state
  install -d "${case_dir}/rootfs/etc/sysctl.d"
  printf '%s\n' '# manually changed managed file' > \
    "${case_dir}/rootfs/etc/sysctl.d/99-network-optimization.conf"
  : > "${calls_file}"
  default_setup > "${case_dir}/managed-edit-output" 2>&1
  assert_eq "" "$(<"${calls_file}")" "managed edit prevents automatic reapply"
  assert_contains "管理配置已被修改" "${case_dir}/managed-edit-output"
)

test_optimizer_environment_forwarding() (
  local case_dir="${TMP_DIR}/optimizer-env"
  local optimizer_log="${case_dir}/optimizer.log"
  local expected_values call_count
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE ALLOW_MANAGED_CONFIG_OVERWRITE
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  cat > "${case_dir}/optimizer.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
  "${VALIDATE_ONLY}|${PROFILE}|${IP_LOCAL_PORT_RANGE}|${ENABLE_NIC_TUNING}|${RP_FILTER}|${MAXIMIZE_NIC_RING}|${ALLOW_MANAGED_CONFIG_OVERWRITE}|${SOCKET_BUFFER_DEFAULT}|${SOCKET_BUFFER_MAX}|${NETDEV_MAX_BACKLOG}|${NETDEV_BUDGET}|${NETDEV_BUDGET_USECS}|${RPS_FLOW_ENTRIES}|${TXQUEUELEN}|${TCP_MAX_TW_BUCKETS}|${TCP_MAX_SYN_BACKLOG}|${IPFRAG_HIGH_THRESH}|${NOFILE_LIMIT}|${FILE_MAX}|${NF_CONNTRACK_MAX}|${NF_CONNTRACK_HASH_SIZE}" \
  >> "${FORWARD_LOG}"
if [[ "${VALIDATE_ONLY}" == "0" && "${FORWARD_FAIL:-0}" == "1" ]]; then
  exit 42
fi
EOF
  chmod 0755 "${case_dir}/optimizer.sh"
  export FORWARD_LOG="${optimizer_log}"
  export IP_LOCAL_PORT_RANGE="20000 60999"
  export ENABLE_NIC_TUNING=0 RP_FILTER=2 MAXIMIZE_NIC_RING=1
  export ALLOW_MANAGED_CONFIG_OVERWRITE=1
  export SOCKET_BUFFER_DEFAULT=300001 SOCKET_BUFFER_MAX=300002
  export NETDEV_MAX_BACKLOG=300003 NETDEV_BUDGET=304 NETDEV_BUDGET_USECS=300005
  export RPS_FLOW_ENTRIES=300006 TXQUEUELEN=300007 TCP_MAX_TW_BUCKETS=300008
  export TCP_MAX_SYN_BACKLOG=300009 IPFRAG_HIGH_THRESH=300010 NOFILE_LIMIT=300011
  export FILE_MAX=300012 NF_CONNTRACK_MAX=300013 NF_CONNTRACK_HASH_SIZE=300014
  # Read by run_network_optimization from the extracted main2 library.
  # shellcheck disable=SC2034
  OPTIMIZER="${case_dir}/optimizer.sh"
  # shellcheck disable=SC2329
  prepare_legacy_main_deployment() { return 0; }
  # shellcheck disable=SC2329
  migrate_legacy_udp() { return 0; }

  run_network_optimization max 0
  record_applied_state max
  expected_values='max|20000 60999|0|2|1|1|300001|300002|300003|304|300005|300006|300007|300008|300009|300010|300011|300012|300013|300014'
  assert_contains "1|${expected_values}" "${optimizer_log}"
  assert_contains "0|${expected_values}" "${optimizer_log}"
  call_count="$(wc -l < "${optimizer_log}" | tr -d '[:space:]')"
  assert_eq 2 "${call_count}" "optimizer receives one validation and one apply call"

  # shellcheck disable=SC2329
  prepare_legacy_main_deployment() { return 1; }
  if run_network_optimization max 0 > "${case_dir}/prepare-failure-output" 2>&1; then
    fail_test "legacy preparation failure unexpectedly succeeded"
  fi
  # shellcheck disable=SC2329
  prepare_legacy_main_deployment() { return 0; }

  # shellcheck disable=SC2329
  migrate_legacy_udp() { return 1; }
  if run_network_optimization max 0 > "${case_dir}/migrate-failure-output" 2>&1; then
    fail_test "legacy UDP migration failure unexpectedly succeeded"
  fi
  # shellcheck disable=SC2329
  migrate_legacy_udp() { return 0; }

  # shellcheck disable=SC2329
  record_applied_state() { return 1; }
  if run_network_optimization max 1 > "${case_dir}/state-failure-output" 2>&1; then
    fail_test "applied-state write failure unexpectedly succeeded"
  fi

  export FORWARD_FAIL=1
  if run_network_optimization max 0 > "${case_dir}/optimizer-failure-output" 2>&1; then
    fail_test "optimizer apply failure unexpectedly succeeded"
  fi
  assert_contains "重试时必须再次明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1" \
    "${case_dir}/optimizer-failure-output"
  assert_contains "PENDING_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
)

test_first_apply_pending_retry() (
  local case_dir="${TMP_DIR}/first-apply-pending"
  local root_dir="${case_dir}/rootfs"
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE ALLOW_MANAGED_CONFIG_OVERWRITE
  install -d "${case_dir}" "${root_dir}/etc/sysctl.d"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"

  cat > "${case_dir}/optimizer.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "optimizer:\${VALIDATE_ONLY}:\${PROFILE}:\${NETDEV_BUDGET:-}" \
  >> "${case_dir}/order.log"
if [[ "\${VALIDATE_ONLY}" == "0" ]]; then
  printf '%s\n' '# first apply output' > \
    "${root_dir}/etc/sysctl.d/99-network-optimization.conf"
  [[ ! -e "${case_dir}/fail-apply" ]] || exit 42
fi
EOF
  chmod 0755 "${case_dir}/optimizer.sh"
  # Read by run_network_optimization from the extracted main2 library.
  # shellcheck disable=SC2034
  OPTIMIZER="${case_dir}/optimizer.sh"
  # shellcheck disable=SC2329
  prepare_legacy_main_deployment() { return 0; }
  # shellcheck disable=SC2329
  migrate_legacy_udp() { return 0; }
  NETDEV_BUDGET=444
  touch "${case_dir}/fail-apply"
  if run_network_optimization max 0 > "${case_dir}/failure-output" 2>&1; then
    fail_test "first managed apply failure unexpectedly succeeded"
  fi
  assert_contains "APPLIED_VERSION=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PROFILE=max" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "NETDEV_BUDGET=444" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "按上次记录参数继续重试" "${case_dir}/failure-output"

  # Simulate a new process with no performance variables in its environment.
  # shellcheck disable=SC2034
  MAIN2_STATE_LOADED=0
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE ALLOW_MANAGED_CONFIG_OVERWRITE
  initialize_main2_state
  # shellcheck disable=SC2329
  set_system_sources() { echo sources >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_base_tools() { echo base >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${case_dir}/order.log"; }
  rm -f "${case_dir}/fail-apply"
  : > "${case_dir}/order.log"
  default_setup > "${case_dir}/retry-output" 2>&1
  assert_eq $'sources\nbase\nchrony\nirqbalance\noptimizer:1:max:444\noptimizer:0:max:444' \
    "$(<"${case_dir}/order.log")" "first apply pending retry order"
  assert_file "${MARK_FILE}"
  assert_contains "APPLIED_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_VERSION=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PROFILE=max" "${MAIN2_INSTALL_STATE_FILE}"
)

test_pending_update_retry() (
  local case_dir="${TMP_DIR}/pending-retry"
  local root_dir="${case_dir}/rootfs"
  local state_sha previous_version old_fingerprint
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE ALLOW_MANAGED_CONFIG_OVERWRITE
  install -d "${case_dir}"
  build_main2_library "${case_dir}"
  write_udp_validator "${case_dir}"
  load_case "${case_dir}"
  install -d "$(dirname "${MAIN2_INSTALL_STATE_FILE}")" "$(dirname "${MARK_FILE}")" \
    "${root_dir}/etc/sysctl.d"
  touch "${MARK_FILE}"
  state_sha="$(printf '%064d' 3)"
  previous_version=$((MAIN2_BUNDLE_VERSION - 1))
  old_fingerprint="$(managed_network_fingerprint 1)"
  initialize_main2_state
  export INSTALLED_BUNDLE_VERSION="${MAIN2_BUNDLE_VERSION}"
  export INSTALLED_BUNDLE_MAIN2_SHA256="${CURRENT_MAIN2_SHA256}"
  export APPLIED_MAIN2_VERSION="${previous_version}"
  export APPLIED_MAIN2_SHA256="${state_sha}"
  export PENDING_MAIN2_VERSION=0
  export PENDING_MAIN2_SHA256=""
  export PENDING_REQUIRES_MANAGED_OVERWRITE=0
  export STORED_MANAGED_CONFIG_FORMAT=1
  export STORED_MANAGED_CONFIG_SHA256="${old_fingerprint}"
  export ENABLE_NIC_TUNING=1 RP_FILTER=0 MAXIMIZE_NIC_RING=0
  store_requested_settings max
  write_install_state

cat > "${case_dir}/optimizer.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' \
  "optimizer:\${VALIDATE_ONLY}:\${PROFILE}:\${ALLOW_MANAGED_CONFIG_OVERWRITE}:\${NETDEV_BUDGET:-}" \
  >> "${case_dir}/order.log"
if [[ "\${VALIDATE_ONLY}" == "0" ]]; then
  printf '%s\n' '# generated during update' > \
    "${root_dir}/etc/sysctl.d/99-network-optimization.conf"
  [[ ! -e "${case_dir}/fail-apply" ]] || exit 42
fi
EOF
  chmod 0755 "${case_dir}/optimizer.sh"
  # Read by run_network_optimization from the extracted main2 library.
  # shellcheck disable=SC2034
  OPTIMIZER="${case_dir}/optimizer.sh"
  # shellcheck disable=SC2329
  prepare_legacy_main_deployment() { return 0; }
  # shellcheck disable=SC2329
  migrate_legacy_udp() { return 0; }
  ALLOW_MANAGED_CONFIG_OVERWRITE=1
  NETDEV_BUDGET=444
  touch "${case_dir}/fail-apply"
  if run_network_optimization max 0 > "${case_dir}/first-failure-output" 2>&1; then
    fail_test "interrupted network update unexpectedly succeeded"
  fi
  assert_contains "PENDING_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_MAIN2_SHA256=${CURRENT_MAIN2_SHA256}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=1" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "APPLIED_VERSION=${previous_version}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "重试时必须再次明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1" \
    "${case_dir}/first-failure-output"

  # Simulate a new main2 process loading the unfinished state.
  # shellcheck disable=SC2034
  MAIN2_STATE_LOADED=0
  unset PROFILE ENABLE_NIC_TUNING RP_FILTER MAXIMIZE_NIC_RING IP_LOCAL_PORT_RANGE \
    SOCKET_BUFFER_DEFAULT SOCKET_BUFFER_MAX NETDEV_MAX_BACKLOG NETDEV_BUDGET \
    NETDEV_BUDGET_USECS RPS_FLOW_ENTRIES TXQUEUELEN TCP_MAX_TW_BUCKETS \
    TCP_MAX_SYN_BACKLOG IPFRAG_HIGH_THRESH NOFILE_LIMIT FILE_MAX \
    NF_CONNTRACK_MAX NF_CONNTRACK_HASH_SIZE ALLOW_MANAGED_CONFIG_OVERWRITE
  initialize_main2_state
  # These mocks are invoked by default_setup from the extracted main2 library.
  # shellcheck disable=SC2329
  set_system_sources() { echo sources >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_base_tools() { echo base >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_chrony() { echo chrony >> "${case_dir}/order.log"; }
  # shellcheck disable=SC2329
  install_irqbalance() { echo irqbalance >> "${case_dir}/order.log"; }
  : > "${case_dir}/order.log"
  REAPPLY_INIT=1
  PROFILE=max
  PROFILE_WAS_EXPLICIT=1
  default_setup > "${case_dir}/reapply-without-overwrite-output" 2>&1
  assert_eq "" "$(<"${case_dir}/order.log")" \
    "reapply cannot bypass pending explicit overwrite confirmation"
  assert_contains "必须再次执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh" \
    "${case_dir}/reapply-without-overwrite-output"
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=1" "${MAIN2_INSTALL_STATE_FILE}"

  # Read by default_setup from the extracted main2 library.
  # shellcheck disable=SC2034
  REAPPLY_INIT=0
  : > "${case_dir}/order.log"
  default_setup > "${case_dir}/missing-overwrite-output" 2>&1
  assert_eq "" "$(<"${case_dir}/order.log")" \
    "pending explicit overwrite requires confirmation before system calls"
  assert_contains "ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh" \
    "${case_dir}/missing-overwrite-output"

  ALLOW_MANAGED_CONFIG_OVERWRITE=1
  PROFILE=balanced
  # Read by default_setup from the extracted main2 library.
  # shellcheck disable=SC2034
  PROFILE_WAS_EXPLICIT=1
  NETDEV_BUDGET=999
  # Read by restore_stored_settings from the extracted main2 library.
  # shellcheck disable=SC2034
  NETDEV_BUDGET_WAS_EXPLICIT=1
  if default_setup > "${case_dir}/second-failure-output" 2>&1; then
    fail_test "second explicit overwrite attempt unexpectedly succeeded"
  fi
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=1" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "重试时必须再次明确执行 ALLOW_MANAGED_CONFIG_OVERWRITE=1" \
    "${case_dir}/second-failure-output"

  # Simulate another process loading the still-incomplete transaction.
  # shellcheck disable=SC2034
  MAIN2_STATE_LOADED=0
  initialize_main2_state
  unset ALLOW_MANAGED_CONFIG_OVERWRITE
  : > "${case_dir}/order.log"
  default_setup > "${case_dir}/missing-overwrite-again-output" 2>&1
  assert_eq "" "$(<"${case_dir}/order.log")" \
    "each interrupted explicit overwrite requires confirmation"
  assert_contains "ALLOW_MANAGED_CONFIG_OVERWRITE=1 bash main2.sh" \
    "${case_dir}/missing-overwrite-again-output"

  rm -f "${case_dir}/fail-apply"
  ALLOW_MANAGED_CONFIG_OVERWRITE=1
  : > "${case_dir}/order.log"
  default_setup > "${case_dir}/retry-output" 2>&1
  assert_eq $'sources\nbase\nchrony\nirqbalance\noptimizer:1:max:1:444\noptimizer:0:max:1:444' \
    "$(<"${case_dir}/order.log")" "pending update retry order"
  assert_contains "同一 main2 版本上次应用未完成" "${case_dir}/retry-output"
  assert_contains "PENDING_VERSION=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_MAIN2_SHA256=" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "APPLIED_VERSION=${MAIN2_BUNDLE_VERSION}" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PROFILE=max" "${MAIN2_INSTALL_STATE_FILE}"

  touch "${case_dir}/fail-apply"
  : > "${case_dir}/order.log"
  if run_network_optimization max 0 0 > "${case_dir}/ordinary-failure-output" 2>&1; then
    fail_test "ordinary interrupted network update unexpectedly succeeded"
  fi
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "按上次记录参数继续重试" "${case_dir}/ordinary-failure-output"

  rm -f "${case_dir}/fail-apply"
  # Read by initialize_main2_state from the extracted main2 library.
  # shellcheck disable=SC2034
  MAIN2_STATE_LOADED=0
  unset ALLOW_MANAGED_CONFIG_OVERWRITE
  initialize_main2_state
  : > "${case_dir}/order.log"
  default_setup > "${case_dir}/ordinary-retry-output" 2>&1
  assert_eq $'sources\nbase\nchrony\nirqbalance\noptimizer:1:max:0:444\noptimizer:0:max:0:444' \
    "$(<"${case_dir}/order.log")" "ordinary pending update retry order"
  assert_contains "PENDING_VERSION=0" "${MAIN2_INSTALL_STATE_FILE}"
  assert_contains "PENDING_REQUIRES_MANAGED_OVERWRITE=0" "${MAIN2_INSTALL_STATE_FILE}"
)

test_legacy_ipv6_keys_are_removed() (
  local case_dir="${TMP_DIR}/legacy-ipv6"
  local legacy_file="${case_dir}/sysctl.conf"
  local managed_file="${case_dir}/99-network-optimization.conf"
  local raw_functions="${case_dir}/optimizer-functions.raw"
  local functions_file="${case_dir}/optimizer-functions.sh"
  install -d "${case_dir}"

  awk '
    $0 == "backup_file() {" { capture = 1 }
    $0 == "auto_socket_buffer_max() {" { exit }
    capture { print }
  ' "${OPTIMIZER}" > "${raw_functions}"
  sed "s|/etc/sysctl.conf|${legacy_file}|g" "${raw_functions}" > "${functions_file}"
  # Read by migrate_legacy_sysctl from the extracted optimizer functions.
  # shellcheck disable=SC2034
  BACKUP_SUFFIX=TESTSTAMP
  # shellcheck disable=SC2034
  LEGACY_PORT_RANGE_REMOVED=0
  # shellcheck disable=SC2034
  SYSCTL_FILE="${managed_file}"
  # shellcheck disable=SC1090
  . "${functions_file}"

  cat > "${managed_file}" <<'EOF'
# current main2 managed keys
net.ipv4.ip_forward = 1
EOF
  cat > "${legacy_file}" <<'EOF'
# Debian relay / VPN landing host balanced-max network optimization.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.ip_nonlocal_bind = 1
net.ipv6.ip6frag_high_thresh = 33554432
net.ipv6.ip6frag_low_thresh = 16777216
net.ipv6.ip6frag_time = 30
net.ipv6.neigh.default.gc_thresh1 = 8192
net.ipv6.neigh.default.gc_thresh2 = 32768
net.ipv6.neigh.default.gc_thresh3 = 65536
kernel.pid_max = 4194304
EOF

  migrate_legacy_sysctl
  assert_not_contains "net.ipv4.ip_forward" "${legacy_file}"
  assert_not_contains "net.ipv6." "${legacy_file}"
  assert_contains "kernel.pid_max = 4194304" "${legacy_file}"
  assert_file "${legacy_file}.bak.TESTSTAMP"
)

test_optimizer_owned_path_preflight() (
  local case_dir="${TMP_DIR}/owned-paths"
  local root_dir="${case_dir}/rootfs"
  local raw_functions="${case_dir}/preflight-functions.raw"
  local functions_file="${case_dir}/preflight-functions.sh"
  local path
  local -a managed_paths=()
  install -d "${root_dir}/etc/sysctl.d" "${root_dir}/etc/security/limits.d" \
    "${root_dir}/etc/default" "${root_dir}/etc/systemd/system" \
    "${root_dir}/etc/modprobe.d" "${root_dir}/etc/modules-load.d" \
    "${root_dir}/etc/systemd/system.conf.d" "${root_dir}/etc/systemd/user.conf.d" \
    "${root_dir}/etc/profile.d" "${root_dir}/usr/local/sbin"

  awk '
    $0 == "file_sha256_is() {" { capture = 1 }
    $0 == "migrate_legacy_sysctl() {" { exit }
    capture { print }
  ' "${OPTIMIZER}" > "${raw_functions}"
  sed \
    -e "s|/root|${root_dir}/root|g" \
    -e "s|/usr/local|${root_dir}/usr/local|g" \
    -e "s|/etc|${root_dir}/etc|g" \
    "${raw_functions}" > "${functions_file}"

  # These paths are read by functions from the extracted optimizer block.
  # shellcheck disable=SC2034
  LIMITS_FILE="${root_dir}/etc/security/limits.d/99-network-optimization.conf"
  SYSCTL_FILE="${root_dir}/etc/sysctl.d/99-network-optimization.conf"
  # shellcheck disable=SC2034
  SYSCTL_DEFAULT_FILE="${root_dir}/etc/default/network-optimization-sysctl"
  SYSCTL_APPLY_SCRIPT="${root_dir}/usr/local/sbin/network-optimization-sysctl.sh"
  SYSCTL_SERVICE_FILE="${root_dir}/etc/systemd/system/network-optimization-sysctl.service"
  # shellcheck disable=SC2034
  NETWORK_TUNE_DEFAULT_FILE="${root_dir}/etc/default/network-max-tune"
  # shellcheck disable=SC2034
  NETWORK_TUNE_SCRIPT="${root_dir}/usr/local/sbin/network-max-tune.sh"
  # shellcheck disable=SC2034
  NETWORK_TUNE_SERVICE_FILE="${root_dir}/etc/systemd/system/network-max-tune.service"
  # shellcheck disable=SC2034
  ALLOW_MANAGED_CONFIG_OVERWRITE=0
  # Read by backup_managed_paths_for_explicit_overwrite.
  # shellcheck disable=SC2034
  BACKUP_SUFFIX=TESTSTAMP
  # shellcheck disable=SC1090
  . "${functions_file}"

  printf '%s\n' custom-sysctl > "${SYSCTL_FILE}"
  if (preflight_managed_paths) > "${case_dir}/custom-output" 2>&1; then
    fail_test "custom same-name sysctl file unexpectedly passed preflight"
  fi
  assert_eq custom-sysctl "$(<"${SYSCTL_FILE}")" "custom sysctl remains unchanged"
  assert_contains "not generated by the legacy script or main2" "${case_dir}/custom-output"

  # Read by preflight_managed_paths from the extracted optimizer functions.
  # shellcheck disable=SC2034
  ALLOW_MANAGED_CONFIG_OVERWRITE=1
  preflight_managed_paths
  mkdir "${LIMITS_FILE}"
  if (preflight_managed_paths) > "${case_dir}/forced-nonregular-output" 2>&1; then
    fail_test "explicit managed overwrite accepted a non-regular path"
  fi
  rmdir "${LIMITS_FILE}"
  assert_contains "non-regular or symbolic-link managed path" \
    "${case_dir}/forced-nonregular-output"
  # shellcheck disable=SC2034
  ALLOW_MANAGED_CONFIG_OVERWRITE=0

  printf '%s\n' \
    '# Debian / Ubuntu userspace TCP/UDP relay and proxy endpoint optimization.' \
    > "${SYSCTL_FILE}"
  preflight_managed_paths

  awk '
    $0 == "cat > \"${SYSCTL_APPLY_SCRIPT}\" <<\047EOF\047" { capture = 1; next }
    capture && $0 == "EOF" { exit }
    capture { print }
  ' "${OPTIMIZER}" > "${SYSCTL_APPLY_SCRIPT}"
  assert_eq 999c4866911e98c7a61e6f7ba98d175d5224f4dcca93a251b8a0ced10ceb029b \
    "$(sha256sum "${SYSCTL_APPLY_SCRIPT}" | awk '{print $1}')" \
    "current generated sysctl apply script hash"

  # The literal variable reference is replaced inside the generated service.
  # shellcheck disable=SC2016
  awk '
    $0 == "cat > \"${SYSCTL_SERVICE_FILE}\" <<EOF" { capture = 1; next }
    capture && $0 == "EOF" { exit }
    capture { print }
  ' "${OPTIMIZER}" |
    sed 's|${SYSCTL_APPLY_SCRIPT}|/usr/local/sbin/network-optimization-sysctl.sh|g' \
      > "${SYSCTL_SERVICE_FILE}"
  assert_eq f79cd486003bd9352ed7653404c2277d2ce511c71e32bab571122969e948293d \
    "$(sha256sum "${SYSCTL_SERVICE_FILE}" | awk '{print $1}')" \
    "current generated sysctl service hash"
  preflight_managed_paths

  printf '%s\n' custom-apply > "${SYSCTL_APPLY_SCRIPT}"
  if (preflight_managed_paths) > "${case_dir}/custom-apply-output" 2>&1; then
    fail_test "custom same-name sysctl apply script unexpectedly passed preflight"
  fi
  assert_eq custom-apply "$(<"${SYSCTL_APPLY_SCRIPT}")" "custom apply remains unchanged"

  managed_paths=(
    "${root_dir}/etc/modprobe.d/99-network-optimization.conf"
    "${root_dir}/etc/modules-load.d/99-network-optimization.conf"
    "${LIMITS_FILE}"
    "${root_dir}/etc/systemd/system.conf.d/99-limits.conf"
    "${root_dir}/etc/systemd/user.conf.d/99-limits.conf"
    "${root_dir}/etc/profile.d/99-ulimit.sh"
    "${SYSCTL_FILE}"
    "${SYSCTL_DEFAULT_FILE}"
    "${SYSCTL_APPLY_SCRIPT}"
    "${SYSCTL_SERVICE_FILE}"
    "${NETWORK_TUNE_DEFAULT_FILE}"
    "${NETWORK_TUNE_SCRIPT}"
    "${NETWORK_TUNE_SERVICE_FILE}"
  )
  for path in "${managed_paths[@]}"; do
    printf '%s\n' "original:${path}" > "${path}"
  done
  ALLOW_MANAGED_CONFIG_OVERWRITE=1
  backup_managed_paths_for_explicit_overwrite
  for path in "${managed_paths[@]}"; do
    assert_file "${path}.bak.TESTSTAMP"
    assert_eq "original:${path}" "$(<"${path}.bak.TESTSTAMP")" \
      "explicit overwrite backup preserves ${path}"
    printf '%s\n' replaced > "${path}"
    assert_eq "original:${path}" "$(<"${path}.bak.TESTSTAMP")" \
      "explicit overwrite backup remains unchanged for ${path}"
  done
  backup_managed_paths_for_explicit_overwrite
  for path in "${managed_paths[@]}"; do
    assert_missing "${path}.bak.TESTSTAMP.1"
  done
  unset MAIN2_BACKED_UP_PATHS
  backup_managed_paths_for_explicit_overwrite
  for path in "${managed_paths[@]}"; do
    assert_eq replaced "$(<"${path}.bak.TESTSTAMP.1")" \
      "a later process uses a new backup name for ${path}"
    assert_eq "original:${path}" "$(<"${path}.bak.TESTSTAMP")" \
      "the earliest explicit overwrite backup remains intact for ${path}"
  done
  unset MAIN2_BACKED_UP_PATHS
  # shellcheck disable=SC2329
  cp() { return 1; }
  if backup_managed_paths_for_explicit_overwrite > "${case_dir}/backup-failure-output" 2>&1; then
    fail_test "managed-path backup copy failure unexpectedly succeeded"
  fi
  assert_contains "Failed to back up managed path before overwrite" \
    "${case_dir}/backup-failure-output"
)

test_optimizer_backup_call_order() (
  local validation_exit_line backup_call_line first_managed_write_line
  validation_exit_line="$(awk '
    $0 == "  echo \"Validation passed. No system changes were made.\"" {
      getline
      if ($0 != "  exit 0") exit 1
      print NR
      exit
    }
  ' "${OPTIMIZER}")"
  backup_call_line="$(awk '
    $0 == "backup_managed_paths_for_explicit_overwrite" { print NR; exit }
  ' "${OPTIMIZER}")"
  first_managed_write_line="$(awk '
    $0 == "cat > /etc/modprobe.d/99-network-optimization.conf <<EOF" { print NR; exit }
  ' "${OPTIMIZER}")"
  [[ "${validation_exit_line}" =~ ^[1-9][0-9]*$ &&
     "${backup_call_line}" =~ ^[1-9][0-9]*$ &&
     "${first_managed_write_line}" =~ ^[1-9][0-9]*$ ]] ||
    fail_test "optimizer explicit-overwrite backup call markers are incomplete"
  (( validation_exit_line < backup_call_line &&
     backup_call_line < first_managed_write_line )) ||
    fail_test "optimizer must back up managed paths after validation and before writes"
)

test_main2_lock_gate
test_main2_lock_call_order
test_debian_official_sources
test_debian_official_source_matrix
test_ubuntu_official_sources
test_official_source_failure_rollback
test_official_source_preflight_guards
test_official_source_early_guards
test_main_source_mixed_guard
test_disabled_standard_source_is_ignored
test_source_transaction_interrupt_rollback
test_source_move_interrupt_rollback
test_source_rollback_ignores_second_signal
test_fresh_prepare_is_noop
test_legacy_and_incomplete_udp_migrate
test_invalid_udp_fails_before_writes
test_current_udp_is_not_restarted
test_failed_udp_migration_keeps_pending_marker
test_default_setup_marker_gate
test_required_package_commands_fail_closed
test_install_state_validation
test_install_state_atomic_failure
test_legacy_pending_state_requires_explicit_restart
test_saved_settings_restore_and_edit_guard
test_optimizer_environment_forwarding
test_first_apply_pending_retry
test_pending_update_retry
test_legacy_ipv6_keys_are_removed
test_optimizer_owned_path_preflight
test_optimizer_backup_call_order

echo "PASS: main2 fresh install and legacy main compatibility"
