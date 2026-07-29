#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OPTIMIZER="${REPO_DIR}/sysctl_optimization_debian_overwrite_main2.sh"
MAIN2="${REPO_DIR}/main2.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local label="$3"
  [[ "${actual}" == "${expected}" ]] || fail "${label}: expected=${expected} actual=${actual}"
}

assert_contains() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "${pattern}" "${file}" || fail "missing '${pattern}' in ${file}"
}

assert_not_contains() {
  local pattern="$1"
  local file="$2"
  if grep -Fq -- "${pattern}" "${file}"; then
    fail "unexpected '${pattern}' in ${file}"
  fi
}

assert_missing() {
  [[ ! -e "$1" && ! -L "$1" ]] || fail "expected missing path: $1"
}

extract_apply_script() {
  awk '
    $0 == "cat > \"${SYSCTL_APPLY_SCRIPT}\" <<\047EOF\047" {
      capture = 1
      next
    }
    capture && $0 == "EOF" { exit }
    capture { print }
  ' "${OPTIMIZER}" > "${TMP_DIR}/apply-base.sh"
  [[ -s "${TMP_DIR}/apply-base.sh" ]] || fail "failed to extract generated sysctl apply script"
}

write_mock_sysctl() {
  install -d "${TMP_DIR}/bin"
  cat > "${TMP_DIR}/bin/sysctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "$1" == "-e" && "$2" == "-p" ]]; then
  exit 0
fi

if [[ "$1" == "-q" && "$2" == "-w" ]]; then
  assignment="$3"
  key="${assignment%%=*}"
  value="${assignment#*=}"
  state_file="${MOCK_PROC_SYS_ROOT}/${key//./_}"
  case "${key}" in
    net.core.netdev_budget_usecs) write_mode="${MOCK_NETDEV_WRITE}" ;;
    net.ipv4.ipfrag_high_thresh) write_mode="${MOCK_IPFRAG_WRITE}" ;;
    *) echo "unexpected mock sysctl key: ${key}" >&2; exit 64 ;;
  esac
  if [[ "${write_mode}" == "accept" ]]; then
    printf '%s\n' "${value}" > "${state_file}"
    exit 0
  fi
  printf 'sysctl: setting key "%s": Invalid argument\n' "${key}" >&2
  exit 1
fi

echo "unexpected mock sysctl arguments: $*" >&2
exit 64
EOF
  chmod 0755 "${TMP_DIR}/bin/sysctl"
}

extract_main2_library() {
  install -d "${TMP_DIR}/refresh"
  cp "${MAIN2}" "${TMP_DIR}/refresh/main2-library.sh"
  [[ -s "${TMP_DIR}/refresh/main2-library.sh" ]] || fail "failed to extract main2 functions"
}

write_refresh_driver() {
  cat > "${TMP_DIR}/refresh/driver.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090
. "${MAIN2_TEST_LIBRARY}"
AUTO_UPDATE_SUPPORT="${MAIN2_TEST_AUTO_UPDATE:-0}"

render_support() {
  local kind="$1"
  local path="$2"
  printf '%s\n' '#!/usr/bin/env bash' "# ${kind}:${path}"
}

support_hash() {
  render_support "$1" "$2" | sha256sum | awk '{print $1}'
}

support_script_expected_sha256() {
  support_hash current "$1"
}

support_script_is_repository_version() {
  local path="$1"
  local actual="$2"
  [[ "${actual}" == "$(support_hash current "${path}")" ||
     "${actual}" == "$(support_hash old "${path}")" ]]
}

download_file() {
  local url="$1"
  local target="$2"
  local path="${url#${RAW_BASE_URL}/}"
  printf '%s\n' "${path}" >> "${MAIN2_TEST_LOG}"
  case "${MAIN2_TEST_DOWNLOAD_MODE:-valid}" in
    valid) render_support current "${path}" > "${target}" ;;
    invalid)
      if [[ "${path}" == "scripts/ssh_root.sh" ]]; then
        render_support corrupt "${path}" > "${target}"
      else
        render_support current "${path}" > "${target}"
      fi
      ;;
    failure) return 1 ;;
    *) return 64 ;;
  esac
}

MOVE_FAILURE_TRIGGERED=0
mv() {
  local source_index source target
  target="${!#}"
  if [[ "${MAIN2_TEST_MOVE_FAILURE:-0}" == "1" &&
        "${MOVE_FAILURE_TRIGGERED}" == "0" &&
        "${target}" == "${SCRIPT_DIR}/scripts/ssh_root.sh" ]]; then
    MOVE_FAILURE_TRIGGERED=1
    source_index=$(( $# - 1 ))
    source="${!source_index}"
    cp -- "${source}" "${target}"
    return 1
  fi
  command mv "$@"
}

ensure_support_scripts
EOF
  chmod 0755 "${TMP_DIR}/refresh/driver.sh"
}

run_refresh_driver() {
  local auto_update="${1:-0}"
  local download_mode="${2:-valid}"
  local move_failure="${3:-0}"
  MAIN2_TEST_LIBRARY="${TMP_DIR}/refresh/main2-library.sh" \
    MAIN2_TEST_LOG="${TMP_DIR}/refresh/downloads" \
    MAIN2_TEST_AUTO_UPDATE="${auto_update}" \
    MAIN2_TEST_DOWNLOAD_MODE="${download_mode}" \
    MAIN2_TEST_MOVE_FAILURE="${move_failure}" \
    bash "${TMP_DIR}/refresh/driver.sh"
}

render_test_support() {
  local kind="$1"
  local path="$2"
  printf '%s\n' '#!/usr/bin/env bash' "# ${kind}:${path}"
}

write_support_set() {
  local kind="$1"
  local path
  install -d "${TMP_DIR}/refresh/scripts"
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh \
    scripts/mtu_mss_main2.sh; do
    render_test_support "${kind}" "${path}" > "${TMP_DIR}/refresh/${path}"
    chmod 0755 "${TMP_DIR}/refresh/${path}"
  done
}

assert_support_set() {
  local kind="$1"
  local path
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh \
    scripts/mtu_mss_main2.sh; do
    assert_support_file "${kind}" "${path}"
  done
}

assert_support_file() {
  local kind="$1"
  local path="$2"
  cmp -s <(render_test_support "${kind}" "${path}") "${TMP_DIR}/refresh/${path}" ||
    fail "support file is not ${kind}: ${path}"
  [[ -x "${TMP_DIR}/refresh/${path}" ]] || fail "support file is not executable: ${path}"
}

test_support_manifest() (
  local path actual expected entry historical_path historical_hash
  # shellcheck disable=SC1090,SC1091
  . "${TMP_DIR}/refresh/main2-library.sh"
  # Read by production manifest functions from the extracted main2 library.
  # shellcheck disable=SC2034
  SCRIPT_DIR="${REPO_DIR}"

  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh \
    scripts/mtu_mss_main2.sh; do
    actual="$(sha256sum "${REPO_DIR}/${path}" | awk '{print $1}')"
    expected="$(support_script_expected_sha256 "${path}")"
    assert_eq "${actual}" "${expected}" "production manifest hash for ${path}"
    support_script_is_repository_version "${path}" "${actual}" ||
      fail "current repository hash is not owned: ${path}"
  done

  for entry in \
    sysctl_optimization_debian_overwrite_main2.sh:faaaf61b4756dd76548bdcd067653d3aed7a15f812680d13be8777e5f51dcfb9 \
    sysctl_optimization_debian_overwrite_main2.sh:832b9060a9d7153c74814ded4cbc4b35cc738998b1c2ac43f70de793736ee3ba \
    sysctl_optimization_debian_overwrite_main2.sh:3c182e7aaf39971bb56d00a4e6625ee2e00c3e9d35235fea4f0e9f0488749d4e \
    sysctl_optimization_debian_overwrite_main2.sh:55171030719d1f3ca2a213d57425b1b35d62e6eb9754917335b3469895ba4c3f \
    sysctl_optimization_debian_overwrite_main2.sh:14ec6ab107edf0bae40cfb527fb598b59377f45352ed2f1f4a09e6e2901659cb \
    sysctl_optimization_debian_overwrite_main2.sh:c3603bfa2e2a8acacd9d03023136d3c74431fcc6ca872db400c817e50340bce3 \
    sysctl_optimization_debian_overwrite_main2.sh:de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181 \
    scripts/swap.sh:c66cb47b309abb443710d473b66380d14f9526ae1cd0d4e720a32a0dcbd49d60 \
    scripts/swap.sh:f40e4ba1b881a3d6a44c4b1a68de515dd183a2a73e887e1eb399def9762fab65 \
    scripts/swap.sh:bfab5c1ad70b404f6779f442cc4f953eade15979e337b28422ee2d806b1858d3 \
    scripts/swap.sh:f431b364f3e9a7bbca7e8858575d2ced85fe3d98000313f5d2ae6a20312de131 \
    scripts/ssh_root.sh:3cc5428c9cc4efe0ff2359375e96e9c36884e86c5fbf2469325f157b0618e553 \
    scripts/ssh_root.sh:5a4ec0c5f6c1907c0f92af96a69a0a62473f32bb1667da1d5ceee0b01afd6aed \
    scripts/ssh_root.sh:f5e9f13a94acb111464995009996f17f00f356faeee12165835bf1a2f70be643 \
    scripts/ssh_root.sh:5a92bdc5a47947fc573e282c2d7967a5ec5a352ed59b1d0c0685e19f411b1c3e; do
    historical_path="${entry%%:*}"
    historical_hash="${entry#*:}"
    support_script_is_repository_version "${historical_path}" "${historical_hash}" ||
      fail "historical repository hash is not owned: ${entry}"
  done

  if support_script_is_repository_version \
    scripts/swap.sh \
    3cc5428c9cc4efe0ff2359375e96e9c36884e86c5fbf2469325f157b0618e553; then
    fail 'historical hash was accepted for the wrong path'
  fi
)

test_support_script_refresh() {
  local path download_count

  rm -rf "${TMP_DIR}/refresh/scripts"
  rm -f "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  : > "${TMP_DIR}/refresh/downloads"
  run_refresh_driver > "${TMP_DIR}/refresh/output-first" 2>&1
  assert_support_set current
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 5 "${download_count}" 'fresh support install downloads every file'

  : > "${TMP_DIR}/refresh/downloads"
  run_refresh_driver > "${TMP_DIR}/refresh/output-current" 2>&1
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 0 "${download_count}" 'current support bundle is not downloaded again'

  write_support_set old
  : > "${TMP_DIR}/refresh/downloads"
  run_refresh_driver > "${TMP_DIR}/refresh/output-old" 2>&1
  assert_support_set current
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 5 "${download_count}" 'known old support bundle is fully replaced'

  : > "${TMP_DIR}/refresh/downloads"
  run_refresh_driver 1 > "${TMP_DIR}/refresh/output-forced" 2>&1
  assert_support_set current
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 5 "${download_count}" 'explicit refresh redownloads the owned bundle'

  write_support_set current
  rm -f "${TMP_DIR}/refresh/scripts/swap.sh"
  : > "${TMP_DIR}/refresh/downloads"
  run_refresh_driver > "${TMP_DIR}/refresh/output-missing" 2>&1
  cmp -s <(render_test_support current scripts/swap.sh) "${TMP_DIR}/refresh/scripts/swap.sh" ||
    fail 'missing support script is not restored'
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 1 "${download_count}" 'only the missing support script is downloaded'

  write_support_set old
  printf '%s\n' '#!/usr/bin/env bash' '# custom:scripts/mtu_mss_main2.sh' > \
    "${TMP_DIR}/refresh/scripts/mtu_mss_main2.sh"
  : > "${TMP_DIR}/refresh/downloads"
  if run_refresh_driver > "${TMP_DIR}/refresh/output-custom" 2>&1; then
    fail 'unknown support file unexpectedly succeeded'
  fi
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh; do
    assert_support_file old "${path}"
  done
  assert_eq '# custom:scripts/mtu_mss_main2.sh' \
    "$(tail -n 1 "${TMP_DIR}/refresh/scripts/mtu_mss_main2.sh")" \
    'custom support file is preserved'
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 0 "${download_count}" 'custom preflight fails before every download'
  assert_contains '已停止全部同步' "${TMP_DIR}/refresh/output-custom"
  : > "${TMP_DIR}/refresh/downloads"
  if run_refresh_driver 1 > "${TMP_DIR}/refresh/output-custom-forced" 2>&1; then
    fail 'explicit refresh overwrote an unknown support file'
  fi
  assert_eq '# custom:scripts/mtu_mss_main2.sh' \
    "$(tail -n 1 "${TMP_DIR}/refresh/scripts/mtu_mss_main2.sh")" \
    'explicit refresh preserves custom support file'
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh; do
    assert_support_file old "${path}"
  done
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 0 "${download_count}" 'explicit refresh custom preflight downloads nothing'

  write_support_set old
  : > "${TMP_DIR}/refresh/downloads"
  if run_refresh_driver 0 invalid > "${TMP_DIR}/refresh/output-invalid-download" 2>&1; then
    fail 'wrong download hash unexpectedly succeeded'
  fi
  assert_support_set old
  assert_contains '配套脚本校验失败，原文件均未修改' "${TMP_DIR}/refresh/output-invalid-download"

  write_support_set old
  : > "${TMP_DIR}/refresh/downloads"
  if run_refresh_driver 0 valid 1 > "${TMP_DIR}/refresh/output-move-failure" 2>&1; then
    fail 'support replacement failure unexpectedly succeeded'
  fi
  assert_support_set old
  assert_contains '配套脚本替换失败，已恢复原文件' "${TMP_DIR}/refresh/output-move-failure"
  if find "${TMP_DIR}/refresh" -name '.main2-support-*' -print -quit | grep -q .; then
    fail 'support replacement failure left temporary files'
  fi

  rm -f \
    "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh" \
    "${TMP_DIR}/refresh/scripts/swap.sh" \
    "${TMP_DIR}/refresh/scripts/ssh_root.sh" \
    "${TMP_DIR}/refresh/scripts/udp_multinic_main2.sh" \
    "${TMP_DIR}/refresh/scripts/mtu_mss_main2.sh"
  : > "${TMP_DIR}/refresh/downloads"
  if run_refresh_driver 0 valid 1 > "${TMP_DIR}/refresh/output-fresh-move-failure" 2>&1; then
    fail 'fresh support replacement failure unexpectedly succeeded'
  fi
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh \
    scripts/mtu_mss_main2.sh; do
    assert_missing "${TMP_DIR}/refresh/${path}"
  done
  assert_contains '配套脚本替换失败，已恢复原文件' \
    "${TMP_DIR}/refresh/output-fresh-move-failure"
  if find "${TMP_DIR}/refresh" -name '.main2-support-*' -print -quit | grep -q .; then
    fail 'fresh support replacement failure left temporary files'
  fi

  write_support_set current
  rm -f "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  mkdir "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  if run_refresh_driver > "${TMP_DIR}/refresh/output-nonregular" 2>&1; then
    fail 'non-regular support path unexpectedly succeeded'
  fi
  assert_contains '配套脚本路径不是普通文件，已停止同步' "${TMP_DIR}/refresh/output-nonregular"
}

build_apply_case() {
  local case_dir="$1"
  local proc_root="${case_dir}/proc-sys"
  local sysctl_file="${case_dir}/99-network-optimization.conf"
  local default_file="${case_dir}/network-optimization-sysctl"

  install -d "${proc_root}"
  printf '%s\n' '# test sysctl file' > "${sysctl_file}"
  awk \
    -v sysctl_file="${sysctl_file}" \
    -v default_file="${default_file}" \
    -v proc_root="${proc_root}" '
      /^SYSCTL_FILE=/ {
        print "SYSCTL_FILE=\"" sysctl_file "\""
        next
      }
      /^SYSCTL_DEFAULT_FILE=/ {
        print "SYSCTL_DEFAULT_FILE=\"" default_file "\""
        next
      }
      /local proc_file="\/proc\/sys\// {
        print "  local proc_file=\"" proc_root "/${key//./_}\""
        next
      }
      { print }
      $0 == "apply_optional_numeric_sysctl net.ipv4.ipfrag_high_thresh \"${IPFRAG_HIGH_THRESH}\"" {
        print "exit 0"
      }
    ' "${TMP_DIR}/apply-base.sh" > "${case_dir}/apply.sh"
  chmod 0755 "${case_dir}/apply.sh"
}

run_apply_case() {
  local name="$1"
  local netdev_current="$2"
  local netdev_requested="$3"
  local netdev_write="$4"
  local ipfrag_current="$5"
  local ipfrag_requested="$6"
  local ipfrag_write="$7"
  local case_dir="${TMP_DIR}/${name}"

  install -d "${case_dir}"
  build_apply_case "${case_dir}"
  printf '%s\n' \
    'NF_CONNTRACK_HASH_SIZE=65536' \
    "NETDEV_BUDGET_USECS=${netdev_requested}" \
    "IPFRAG_HIGH_THRESH=${ipfrag_requested}" > "${case_dir}/network-optimization-sysctl"
  if [[ "${netdev_current}" != "missing" ]]; then
    printf '%s\n' "${netdev_current}" > "${case_dir}/proc-sys/net_core_netdev_budget_usecs"
  fi
  if [[ "${ipfrag_current}" != "missing" ]]; then
    printf '%s\n' "${ipfrag_current}" > "${case_dir}/proc-sys/net_ipv4_ipfrag_high_thresh"
  fi

  PATH="${TMP_DIR}/bin:${PATH}" \
    MOCK_PROC_SYS_ROOT="${case_dir}/proc-sys" \
    MOCK_NETDEV_WRITE="${netdev_write}" \
    MOCK_IPFRAG_WRITE="${ipfrag_write}" \
    bash "${case_dir}/apply.sh" > "${case_dir}/output" 2>&1
}

run_invalid_config_case() {
  local name="$1"
  local netdev_requested="$2"
  local ipfrag_requested="$3"
  local expected_message="$4"
  local case_dir="${TMP_DIR}/${name}"

  install -d "${case_dir}"
  build_apply_case "${case_dir}"
  printf '%s\n' \
    'NF_CONNTRACK_HASH_SIZE=65536' \
    "NETDEV_BUDGET_USECS=${netdev_requested}" \
    "IPFRAG_HIGH_THRESH=${ipfrag_requested}" > "${case_dir}/network-optimization-sysctl"
  printf '%s\n' 8000 > "${case_dir}/proc-sys/net_core_netdev_budget_usecs"
  printf '%s\n' 4194304 > "${case_dir}/proc-sys/net_ipv4_ipfrag_high_thresh"
  if PATH="${TMP_DIR}/bin:${PATH}" \
     MOCK_PROC_SYS_ROOT="${case_dir}/proc-sys" \
     MOCK_NETDEV_WRITE=accept \
     MOCK_IPFRAG_WRITE=accept \
     bash "${case_dir}/apply.sh" > "${case_dir}/output" 2>&1; then
    fail "invalid optional sysctl config unexpectedly succeeded: ${name}"
  fi
  assert_contains "${expected_message}" "${case_dir}/output"
}

extract_apply_script
write_mock_sysctl
extract_main2_library
test_support_manifest
write_refresh_driver
test_support_script_refresh

awk '
  $0 == "cat > \"${SYSCTL_FILE}\" <<EOF" { capture = 1; next }
  capture && $0 == "EOF" { exit }
  capture { print }
' "${OPTIMIZER}" > "${TMP_DIR}/persistent-sysctl"
assert_not_contains 'net.core.netdev_budget_usecs =' "${TMP_DIR}/persistent-sysctl"
assert_not_contains 'net.ipv4.ipfrag_high_thresh =' "${TMP_DIR}/persistent-sysctl"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS=${NETDEV_BUDGET_USECS}' "${OPTIMIZER}"
# shellcheck disable=SC2016
assert_contains 'IPFRAG_HIGH_THRESH=${IPFRAG_HIGH_THRESH}' "${OPTIMIZER}"
assert_contains 'managed["net.core.netdev_budget_usecs"] = 1' "${OPTIMIZER}"
assert_contains 'managed["net.ipv4.ipfrag_high_thresh"] = 1' "${OPTIMIZER}"
assert_contains 'systemctl status network-optimization-sysctl.service --no-pager --full' "${OPTIMIZER}"
assert_contains 'journalctl -u network-optimization-sysctl.service -n 120 --no-pager' "${OPTIMIZER}"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-2000}"' "${OPTIMIZER}"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-4000}"' "${OPTIMIZER}"
assert_contains 'de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181' "${MAIN2}"
assert_contains 'c3603bfa2e2a8acacd9d03023136d3c74431fcc6ca872db400c817e50340bce3' "${MAIN2}"
assert_contains '14ec6ab107edf0bae40cfb527fb598b59377f45352ed2f1f4a09e6e2901659cb' "${MAIN2}"
assert_contains '55171030719d1f3ca2a213d57425b1b35d62e6eb9754917335b3469895ba4c3f' "${MAIN2}"
assert_contains '3c182e7aaf39971bb56d00a4e6625ee2e00c3e9d35235fea4f0e9f0488749d4e' "${MAIN2}"
assert_contains 'faaaf61b4756dd76548bdcd067653d3aed7a15f812680d13be8777e5f51dcfb9' "${MAIN2}"
assert_eq e17483af3315ae46b308075923e404f7c1698c1e4014779f27451a393136688d \
  "$(sha256sum "${REPO_DIR}/sysctl_optimization_debian_overwrite_main2.sh" | awk '{print $1}')" \
  'optimizer manifest hash'
assert_eq 41c053c9a310fdb5de36832a5ee58fabee7e4e39e7ab5e60747b40e09f8bc28e \
  "$(sha256sum "${REPO_DIR}/scripts/swap.sh" | awk '{print $1}')" \
  'swap manifest hash'
assert_eq 8835074f48a8d5ebe50d7a723dccfd03245f245f44ea0fc73be2313d4440f9ae \
  "$(sha256sum "${REPO_DIR}/scripts/ssh_root.sh" | awk '{print $1}')" \
  'ssh manifest hash'
assert_eq 374d98155e6a26415418274663a291369017302693246101aa89eaf402d88b44 \
  "$(sha256sum "${REPO_DIR}/scripts/udp_multinic_main2.sh" | awk '{print $1}')" \
  'UDP manifest hash'
assert_eq b1b3b3e93aa4353572e1c1d4c20835a243884978f76aeca4eb6b5b7d0b5c14f6 \
  "$(sha256sum "${REPO_DIR}/scripts/mtu_mss_main2.sh" | awk '{print $1}')" \
  'MTU/MSS manifest hash'

run_apply_case rejected 8000 2000 reject 4194304 67108864 reject
assert_eq 8000 "$(<"${TMP_DIR}/rejected/proc-sys/net_core_netdev_budget_usecs")" \
  'rejected netdev target preserves current value'
assert_contains 'Warning: failed to apply net.core.netdev_budget_usecs=2000; keeping current=8000.' "${TMP_DIR}/rejected/output"
assert_eq 4194304 "$(<"${TMP_DIR}/rejected/proc-sys/net_ipv4_ipfrag_high_thresh")" \
  'rejected ipfrag target preserves current value'
assert_contains 'Warning: failed to apply net.ipv4.ipfrag_high_thresh=67108864; keeping current=4194304.' \
  "${TMP_DIR}/rejected/output"
assert_contains 'Invalid argument' "${TMP_DIR}/rejected/output"

run_apply_case accepted 2000 4000 accept 4194304 33554432 accept
assert_eq 4000 "$(<"${TMP_DIR}/accepted/proc-sys/net_core_netdev_budget_usecs")" \
  'accepted netdev target is applied'
assert_eq 33554432 "$(<"${TMP_DIR}/accepted/proc-sys/net_ipv4_ipfrag_high_thresh")" \
  'accepted ipfrag target is applied'

PATH="${TMP_DIR}/bin:${PATH}" \
  MOCK_PROC_SYS_ROOT="${TMP_DIR}/accepted/proc-sys" \
  MOCK_NETDEV_WRITE=reject \
  MOCK_IPFRAG_WRITE=reject \
  bash "${TMP_DIR}/accepted/apply.sh" > "${TMP_DIR}/accepted/output-second" 2>&1
assert_eq 4000 "$(<"${TMP_DIR}/accepted/proc-sys/net_core_netdev_budget_usecs")" \
  'second netdev apply remains idempotent'
assert_eq 33554432 "$(<"${TMP_DIR}/accepted/proc-sys/net_ipv4_ipfrag_high_thresh")" \
  'second ipfrag apply remains idempotent'
assert_not_contains 'failed to apply net.core.netdev_budget_usecs' "${TMP_DIR}/accepted/output-second"
assert_not_contains 'failed to apply net.ipv4.ipfrag_high_thresh' "${TMP_DIR}/accepted/output-second"

run_apply_case unavailable missing 2000 reject missing 33554432 reject
assert_contains 'Warning: net.core.netdev_budget_usecs is unavailable; keeping the running kernel defaults.' "${TMP_DIR}/unavailable/output"
assert_contains 'Warning: net.ipv4.ipfrag_high_thresh is unavailable; keeping the running kernel defaults.' \
  "${TMP_DIR}/unavailable/output"
assert_not_contains 'Invalid argument' "${TMP_DIR}/unavailable/output"

run_invalid_config_case invalid-netdev-range 2147483648 33554432 \
  'Invalid NETDEV_BUDGET_USECS=2147483648'
run_invalid_config_case invalid-ipfrag-text 2000 not-a-number \
  'Invalid IPFRAG_HIGH_THRESH=not-a-number'
run_invalid_config_case invalid-ipfrag-range 2000 2147483648 \
  'Invalid IPFRAG_HIGH_THRESH=2147483648'

echo 'PASS: main2 optional numeric sysctl runtime fallback'
