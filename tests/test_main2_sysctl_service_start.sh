#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OPTIMIZER="${REPO_DIR}/sysctl_optimization_debian_overwrite_main2.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_count() {
  local expected="$1"
  local pattern="$2"
  local file="$3"
  local actual
  actual="$(grep -Fc -- "${pattern}" "${file}" || true)"
  [[ "${actual}" == "${expected}" ]] ||
    fail "expected ${expected} occurrences of '${pattern}', got ${actual}"
}

awk '
  $0 == "diagnose_network_sysctl_service_failure() {" { capture = 1 }
  capture && $0 == "if command -v systemctl >/dev/null 2>&1; then" { exit }
  capture { print }
' "${OPTIMIZER}" > "${TMP_DIR}/service-functions.sh"
[[ -s "${TMP_DIR}/service-functions.sh" ]] || fail "failed to extract service functions"

cat > "${TMP_DIR}/driver.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1090
. "${SERVICE_FUNCTIONS}"
restart_calls=0
active_calls=0

systemctl() {
  printf 'systemctl %s\n' "$*" >> "${SERVICE_LOG}"
  case "$1" in
    restart)
      restart_calls=$((restart_calls + 1))
      case "${SERVICE_SCENARIO}" in
        success|inactive_then_success|inactive_permanent) return 0 ;;
        retry_success) [[ "${restart_calls}" -ge 2 ]] ;;
        permanent_failure|reset_failure) return 1 ;;
        *) return 64 ;;
      esac
      ;;
    is-active)
      active_calls=$((active_calls + 1))
      case "${SERVICE_SCENARIO}" in
        inactive_then_success) [[ "${active_calls}" -ge 2 ]] ;;
        inactive_permanent) return 1 ;;
        *) return 0 ;;
      esac
      ;;
    reset-failed)
      [[ "${SERVICE_SCENARIO}" != "reset_failure" ]]
      ;;
    status) return 0 ;;
    *) return 64 ;;
  esac
}

journalctl() {
  printf 'journalctl %s\n' "$*" >> "${SERVICE_LOG}"
}

start_network_sysctl_service
EOF
chmod 0755 "${TMP_DIR}/driver.sh"

run_case() {
  local scenario="$1"
  local expect_success="$2"
  local log="${TMP_DIR}/${scenario}.log"
  : > "${log}"
  if SERVICE_FUNCTIONS="${TMP_DIR}/service-functions.sh" \
     SERVICE_SCENARIO="${scenario}" SERVICE_LOG="${log}" \
     bash "${TMP_DIR}/driver.sh" > "${TMP_DIR}/${scenario}.output" 2>&1; then
    [[ "${expect_success}" == "1" ]] || fail "${scenario} unexpectedly succeeded"
  else
    [[ "${expect_success}" == "0" ]] || fail "${scenario} unexpectedly failed"
  fi
}

run_case success 1
assert_count 1 'systemctl restart network-optimization-sysctl.service' "${TMP_DIR}/success.log"
assert_count 1 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/success.log"
assert_count 0 'systemctl reset-failed network-optimization-sysctl.service' "${TMP_DIR}/success.log"

run_case retry_success 1
assert_count 2 'systemctl restart network-optimization-sysctl.service' "${TMP_DIR}/retry_success.log"
assert_count 1 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/retry_success.log"
assert_count 1 'systemctl reset-failed network-optimization-sysctl.service' "${TMP_DIR}/retry_success.log"
assert_count 0 'systemctl status network-optimization-sysctl.service' "${TMP_DIR}/retry_success.log"

run_case inactive_then_success 1
assert_count 2 'systemctl restart network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_then_success.log"
assert_count 2 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_then_success.log"
assert_count 1 'systemctl reset-failed network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_then_success.log"
assert_count 0 'systemctl status network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_then_success.log"

run_case permanent_failure 0
assert_count 2 'systemctl restart network-optimization-sysctl.service' "${TMP_DIR}/permanent_failure.log"
assert_count 0 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/permanent_failure.log"
assert_count 1 'systemctl status network-optimization-sysctl.service --no-pager --full' \
  "${TMP_DIR}/permanent_failure.log"
assert_count 1 'journalctl -u network-optimization-sysctl.service -n 120 --no-pager' \
  "${TMP_DIR}/permanent_failure.log"

run_case inactive_permanent 0
assert_count 2 'systemctl restart network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_permanent.log"
assert_count 2 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_permanent.log"
assert_count 1 'systemctl reset-failed network-optimization-sysctl.service' \
  "${TMP_DIR}/inactive_permanent.log"
assert_count 1 'systemctl status network-optimization-sysctl.service --no-pager --full' \
  "${TMP_DIR}/inactive_permanent.log"
assert_count 1 'journalctl -u network-optimization-sysctl.service -n 120 --no-pager' \
  "${TMP_DIR}/inactive_permanent.log"

run_case reset_failure 0
assert_count 1 'systemctl restart network-optimization-sysctl.service' "${TMP_DIR}/reset_failure.log"
assert_count 0 'systemctl is-active --quiet network-optimization-sysctl.service' \
  "${TMP_DIR}/reset_failure.log"
assert_count 1 'systemctl reset-failed network-optimization-sysctl.service' "${TMP_DIR}/reset_failure.log"
assert_count 1 'systemctl status network-optimization-sysctl.service --no-pager --full' \
  "${TMP_DIR}/reset_failure.log"

echo "PASS: main2 network sysctl service controlled retry"
