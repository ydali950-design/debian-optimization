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
  value="${3#net.core.netdev_budget_usecs=}"
  if [[ "${MOCK_SYSCTL_WRITE}" == "accept" ]]; then
    printf '%s\n' "${value}" > "${MOCK_NETDEV_BUDGET_FILE}"
    exit 0
  fi
  echo 'sysctl: setting key "net.core.netdev_budget_usecs": Invalid argument' >&2
  exit 1
fi

echo "unexpected mock sysctl arguments: $*" >&2
exit 64
EOF
  chmod 0755 "${TMP_DIR}/bin/sysctl"
}

extract_main2_library() {
  install -d "${TMP_DIR}/refresh"
  awk '
    $0 == "require_root" {
      found = 1
      exit
    }
    { print }
    END { if (!found) exit 1 }
  ' "${MAIN2}" > "${TMP_DIR}/refresh/main2-library.sh"
  [[ -s "${TMP_DIR}/refresh/main2-library.sh" ]] || fail "failed to extract main2 functions"
}

write_refresh_driver() {
  cat > "${TMP_DIR}/refresh/driver.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

export AUTO_UPDATE_SUPPORT=0
# shellcheck disable=SC1090
. "${MAIN2_TEST_LIBRARY}"

file_sha256_is() {
  local path="$1"
  local expected="$2"
  [[ "${path}" == "${SCRIPT_DIR}/sysctl_optimization_debian_overwrite_main2.sh" &&
     "${expected}" == "de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181" &&
     "$(<"${path}")" == "known-outdated" ]]
}

download_file() {
  local _url="$1"
  local target="$2"
  install -d "$(dirname "${target}")"
  printf '%s\n' "${MAIN2_TEST_DOWNLOAD_CONTENT:-refreshed}" > "${target}"
  printf '%s\n' "${target}" >> "${MAIN2_TEST_LOG}"
}

ensure_support_scripts
EOF
  chmod 0755 "${TMP_DIR}/refresh/driver.sh"
}

run_refresh_driver() {
  local download_content="${1:-refreshed}"
  MAIN2_TEST_LIBRARY="${TMP_DIR}/refresh/main2-library.sh" \
    MAIN2_TEST_LOG="${TMP_DIR}/refresh/downloads" \
    MAIN2_TEST_DOWNLOAD_CONTENT="${download_content}" \
    bash "${TMP_DIR}/refresh/driver.sh"
}

test_support_script_refresh() {
  local path download_count

  install -d "${TMP_DIR}/refresh/scripts"
  for path in \
    sysctl_optimization_debian_overwrite_main2.sh \
    scripts/swap.sh \
    scripts/ssh_root.sh \
    scripts/udp_multinic_main2.sh \
    scripts/mtu_mss_main2.sh; do
    printf '%s\n' current > "${TMP_DIR}/refresh/${path}"
  done
  printf '%s\n' known-outdated > "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  : > "${TMP_DIR}/refresh/downloads"

  run_refresh_driver > "${TMP_DIR}/refresh/output-first" 2>&1
  assert_eq refreshed "$(<"${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh")" 'known old optimizer is refreshed'
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 1 "${download_count}" 'only known old optimizer is refreshed'

  run_refresh_driver > "${TMP_DIR}/refresh/output-second" 2>&1
  download_count="$(wc -l < "${TMP_DIR}/refresh/downloads" | tr -d '[:space:]')"
  assert_eq 1 "${download_count}" 'refreshed optimizer is not downloaded again'

  printf '%s\n' custom > "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  run_refresh_driver > "${TMP_DIR}/refresh/output-custom" 2>&1
  assert_eq custom "$(<"${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh")" 'unknown regular optimizer is preserved'

  rm -f "${TMP_DIR}/refresh/scripts/swap.sh"
  run_refresh_driver > "${TMP_DIR}/refresh/output-missing" 2>&1
  assert_eq refreshed "$(<"${TMP_DIR}/refresh/scripts/swap.sh")" 'missing support script is downloaded'

  rm -f "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  mkdir "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  if run_refresh_driver > "${TMP_DIR}/refresh/output-nonregular" 2>&1; then
    fail 'non-regular support path unexpectedly succeeded'
  fi
  assert_contains '配套脚本路径不是普通文件，已停止同步' "${TMP_DIR}/refresh/output-nonregular"

  rmdir "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  printf '%s\n' known-outdated > "${TMP_DIR}/refresh/sysctl_optimization_debian_overwrite_main2.sh"
  if run_refresh_driver known-outdated > "${TMP_DIR}/refresh/output-stale-download" 2>&1; then
    fail 'known old optimizer remained after download without stopping'
  fi
  assert_contains '同步后仍是已知故障版本，已停止执行' "${TMP_DIR}/refresh/output-stale-download"
}

build_apply_case() {
  local case_dir="$1"
  local state_file="${case_dir}/netdev_budget_usecs"
  local sysctl_file="${case_dir}/99-network-optimization.conf"
  local default_file="${case_dir}/network-optimization-sysctl"

  printf '%s\n' '# test sysctl file' > "${sysctl_file}"
  awk \
    -v sysctl_file="${sysctl_file}" \
    -v default_file="${default_file}" \
    -v state_file="${state_file}" '
      /^SYSCTL_FILE=/ {
        print "SYSCTL_FILE=\"" sysctl_file "\""
        next
      }
      /^SYSCTL_DEFAULT_FILE=/ {
        print "SYSCTL_DEFAULT_FILE=\"" default_file "\""
        next
      }
      /local proc_file="\/proc\/sys\/net\/core\/netdev_budget_usecs"/ {
        print "  local proc_file=\"" state_file "\""
        next
      }
      { print }
      $0 == "apply_netdev_budget_usecs" { print "exit 0" }
    ' "${TMP_DIR}/apply-base.sh" > "${case_dir}/apply.sh"
  chmod 0755 "${case_dir}/apply.sh"
}

run_apply_case() {
  local name="$1"
  local current="$2"
  local requested="$3"
  local write_mode="$4"
  local case_dir="${TMP_DIR}/${name}"

  install -d "${case_dir}"
  build_apply_case "${case_dir}"
  printf '%s\n' \
    'NF_CONNTRACK_HASH_SIZE=65536' \
    "NETDEV_BUDGET_USECS=${requested}" > "${case_dir}/network-optimization-sysctl"
  if [[ "${current}" != "missing" ]]; then
    printf '%s\n' "${current}" > "${case_dir}/netdev_budget_usecs"
  fi

  PATH="${TMP_DIR}/bin:${PATH}" \
    MOCK_SYSCTL_WRITE="${write_mode}" \
    MOCK_NETDEV_BUDGET_FILE="${case_dir}/netdev_budget_usecs" \
    bash "${case_dir}/apply.sh" > "${case_dir}/output" 2>&1
}

extract_apply_script
write_mock_sysctl
extract_main2_library
write_refresh_driver
test_support_script_refresh

awk '
  $0 == "cat > \"${SYSCTL_FILE}\" <<EOF" { capture = 1; next }
  capture && $0 == "EOF" { exit }
  capture { print }
' "${OPTIMIZER}" > "${TMP_DIR}/persistent-sysctl"
assert_not_contains 'net.core.netdev_budget_usecs =' "${TMP_DIR}/persistent-sysctl"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS=${NETDEV_BUDGET_USECS}' "${OPTIMIZER}"
assert_contains 'managed["net.core.netdev_budget_usecs"] = 1' "${OPTIMIZER}"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-2000}"' "${OPTIMIZER}"
# shellcheck disable=SC2016
assert_contains 'NETDEV_BUDGET_USECS="${NETDEV_BUDGET_USECS:-4000}"' "${OPTIMIZER}"
assert_contains 'de2c23dde96fffba81210c58b8533bae6ad195a7f46a745e6f99078da19dd181' "${MAIN2}"

run_apply_case rejected 8000 2000 reject
assert_eq 8000 "$(<"${TMP_DIR}/rejected/netdev_budget_usecs")" 'rejected target preserves current value'
assert_contains 'Warning: failed to apply net.core.netdev_budget_usecs=2000; keeping current=8000.' "${TMP_DIR}/rejected/output"
assert_contains 'Invalid argument' "${TMP_DIR}/rejected/output"

run_apply_case accepted 2000 4000 accept
assert_eq 4000 "$(<"${TMP_DIR}/accepted/netdev_budget_usecs")" 'accepted target is applied'

PATH="${TMP_DIR}/bin:${PATH}" \
  MOCK_SYSCTL_WRITE=reject \
  MOCK_NETDEV_BUDGET_FILE="${TMP_DIR}/accepted/netdev_budget_usecs" \
  bash "${TMP_DIR}/accepted/apply.sh" > "${TMP_DIR}/accepted/output-second" 2>&1
assert_eq 4000 "$(<"${TMP_DIR}/accepted/netdev_budget_usecs")" 'second apply remains idempotent'
assert_not_contains 'failed to apply net.core.netdev_budget_usecs' "${TMP_DIR}/accepted/output-second"

run_apply_case unavailable missing 2000 reject
assert_contains 'Warning: net.core.netdev_budget_usecs is unavailable; keeping the running kernel defaults.' "${TMP_DIR}/unavailable/output"
assert_not_contains 'Invalid argument' "${TMP_DIR}/unavailable/output"

install -d "${TMP_DIR}/invalid"
build_apply_case "${TMP_DIR}/invalid"
printf '%s\n' \
  'NF_CONNTRACK_HASH_SIZE=65536' \
  'NETDEV_BUDGET_USECS=2147483648' > "${TMP_DIR}/invalid/network-optimization-sysctl"
printf '%s\n' 8000 > "${TMP_DIR}/invalid/netdev_budget_usecs"
if PATH="${TMP_DIR}/bin:${PATH}" \
   MOCK_SYSCTL_WRITE=accept \
   MOCK_NETDEV_BUDGET_FILE="${TMP_DIR}/invalid/netdev_budget_usecs" \
   bash "${TMP_DIR}/invalid/apply.sh" > "${TMP_DIR}/invalid/output" 2>&1; then
  fail 'out-of-range NETDEV_BUDGET_USECS unexpectedly succeeded'
fi
assert_contains 'Invalid NETDEV_BUDGET_USECS=2147483648' "${TMP_DIR}/invalid/output"

echo 'PASS: main2 netdev_budget_usecs runtime fallback'
