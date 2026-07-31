#!/bin/bash
set -eu

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RUNNER="${REPO_ROOT}/bin/av-scan-scheduler-runner"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "${TEST_ROOT}"' EXIT INT TERM

BASE="${TEST_ROOT}/config"
STATE_DIR="${TEST_ROOT}/state"
LOG_DIR="${TEST_ROOT}/log"
FAKE_BIN="${TEST_ROOT}/bin"
FIXTURE_DIR="${TEST_ROOT}/fixtures"
QUICK_DIR="${FIXTURE_DIR}/Downloads Folder"

mkdir -p "${BASE}" "${STATE_DIR}" "${LOG_DIR}" "${FAKE_BIN}" "${QUICK_DIR}" "${TEST_ROOT}/db"

printf 'UPDATE_INTERVAL_SECONDS=86400\nQUICK_INTERVAL_SECONDS=259200\nFULL_INTERVAL_SECONDS=1814400\n' \
  > "${BASE}/settings.conf"
printf '%s\n' "${QUICK_DIR}" > "${BASE}/quick-paths"
printf '%s\n' "${FIXTURE_DIR}" > "${BASE}/full-paths"
printf '^%s/cache($|/)\n' "${FIXTURE_DIR}" > "${BASE}/full-excludes"
printf 'DatabaseDirectory %s\nDatabaseOwner %s\nDatabaseMirror database.clamav.net\n' \
  "${TEST_ROOT}/db" "$(id -un)" > "${BASE}/freshclam.conf"
: > "${BASE}/discord-webhook.url"
printf 'harmless fixture\n' > "${QUICK_DIR}/file.txt"
date '+%s' > "${STATE_DIR}/installed-at"

cat > "${FAKE_BIN}/freshclam" <<'EOF'
#!/bin/bash
printf 'fake freshclam update\n'
printf '%s\n' "$*" > "${FAKE_FRESHCLAM_ARGS}"
exit "${FAKE_FRESHCLAM_RC:-0}"
EOF

cat > "${FAKE_BIN}/clamscan" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  if [ "${arg}" = "--version" ]; then
    printf 'ClamAV test-engine/test-db\n'
    exit 0
  fi
done
printf '%s\n' "$@" > "${FAKE_CLAMSCAN_ARGS}"
if [ "${FAKE_CLAMSCAN_ACCESS_ERROR:-0}" = "1" ]; then
  printf 'ERROR: Operation not permitted\n'
fi
if [ "${FAKE_CLAMSCAN_RC:-0}" = "1" ]; then
  infected_files=1
else
  infected_files=0
fi
cat <<'SUMMARY'
----------- SCAN SUMMARY -----------
Known viruses: 42
Engine version: test
Scanned directories: 1
Scanned files: 1
SUMMARY
printf 'Infected files: %s\n' "${infected_files}"
printf 'Total errors: %s\n' "${FAKE_CLAMSCAN_TOTAL_ERRORS:-0}"
exit "${FAKE_CLAMSCAN_RC:-0}"
EOF

cat > "${FAKE_BIN}/jq" <<'EOF'
#!/bin/bash
content=""
username=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --arg)
      if [ "${2:-}" = "content" ]; then
        content="${3:-}"
      elif [ "${2:-}" = "username" ]; then
        username="${3:-}"
      fi
      shift 3
      ;;
    *)
      shift
      ;;
  esac
done
printf '%s\n' "${content}" > "${FAKE_JQ_CONTENT_MARKER}"
printf '%s\n' "${username}" > "${FAKE_JQ_USERNAME_MARKER}"
printf '{"content":"test","username":"AV Scan Scheduler","allowed_mentions":{"parse":[]}}\n'
exit "${FAKE_JQ_RC:-0}"
EOF

cat > "${FAKE_BIN}/curl" <<'EOF'
#!/bin/bash
while IFS= read -r ignored; do
  :
done
: > "${FAKE_CURL_MARKER}"
exit "${FAKE_CURL_RC:-0}"
EOF

cat > "${FAKE_BIN}/nice" <<'EOF'
#!/bin/bash
if [ "${1:-}" = "-n" ]; then
  shift 2
fi
exec "$@"
EOF

cat > "${FAKE_BIN}/ps" <<'EOF'
#!/bin/bash
for arg in "$@"; do
  case "${arg}" in
    uid=)
      printf '%s\n' "${FAKE_PS_UID}"
      exit 0
      ;;
    lstart=)
      printf '%s\n' "${FAKE_PS_START}"
      exit 0
      ;;
    command=)
      printf '%s\n' "${FAKE_PS_COMMAND}"
      exit 0
      ;;
  esac
done
exit 1
EOF

chmod +x \
  "${FAKE_BIN}/freshclam" \
  "${FAKE_BIN}/clamscan" \
  "${FAKE_BIN}/jq" \
  "${FAKE_BIN}/curl" \
  "${FAKE_BIN}/nice" \
  "${FAKE_BIN}/ps"

run_hook() {
  env \
    AV_SCAN_SCHEDULER_BASE="${BASE}" \
    AV_SCAN_SCHEDULER_STATE_DIR="${STATE_DIR}" \
    AV_SCAN_SCHEDULER_LOG_DIR="${LOG_DIR}" \
    AV_SCAN_SCHEDULER_DB_DIR="${TEST_ROOT}/db" \
    AV_SCAN_SCHEDULER_FRESHCLAM="${FAKE_BIN}/freshclam" \
    AV_SCAN_SCHEDULER_CLAMSCAN="${FAKE_BIN}/clamscan" \
    AV_SCAN_SCHEDULER_JQ="${FAKE_BIN}/jq" \
    AV_SCAN_SCHEDULER_CURL="${FAKE_BIN}/curl" \
    AV_SCAN_SCHEDULER_NICE="${FAKE_BIN}/nice" \
    AV_SCAN_SCHEDULER_TASKPOLICY="${TEST_ROOT}/taskpolicy-not-present" \
    AV_SCAN_SCHEDULER_PS="${FAKE_BIN}/ps" \
    FAKE_CURL_MARKER="${TEST_ROOT}/curl-called" \
    FAKE_JQ_CONTENT_MARKER="${TEST_ROOT}/jq-content" \
    FAKE_JQ_USERNAME_MARKER="${TEST_ROOT}/jq-username" \
    FAKE_FRESHCLAM_ARGS="${TEST_ROOT}/freshclam-args" \
    FAKE_CLAMSCAN_ARGS="${TEST_ROOT}/clamscan-args" \
    FAKE_PS_UID="$(id -u)" \
    FAKE_PS_START="Thu Jul 31 04:00:00 2026" \
    FAKE_PS_COMMAND="av-scan-scheduler-test-process" \
    "${RUNNER}" "$@"
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

expected_version="$(cat "${REPO_ROOT}/VERSION")"
[ "$("${REPO_ROOT}/bin/av-scan-scheduler" --version)" = "AV Scan Scheduler ${expected_version}" ] ||
  fail "CLI version does not match VERSION"
if "${REPO_ROOT}/install.sh" --help unexpected >/dev/null 2>&1; then
  fail "installer accepted an unknown argument after --help"
fi
if "${REPO_ROOT}/uninstall.sh" --help unexpected >/dev/null 2>&1; then
  fail "uninstaller accepted an unknown argument after --help"
fi

if grep -q 'AV_SCAN_SCHEDULER_ALLOW_ROOT' "${RUNNER}"; then
  fail "runner still contains an environment bypass for root refusal"
fi

SCHEDULE_PLIST="${REPO_ROOT}/launchd/io.github.tetsuroando.av-scan-scheduler.plist"
schedule_index=0
for schedule_hour in 0 6 12 18; do
  actual_hour="$(
    plutil -extract "StartCalendarInterval.${schedule_index}.Hour" raw -o - \
      "${SCHEDULE_PLIST}"
  )"
  actual_minute="$(
    plutil -extract "StartCalendarInterval.${schedule_index}.Minute" raw -o - \
      "${SCHEDULE_PLIST}"
  )"
  [ "${actual_hour}" = "${schedule_hour}" ] ||
    fail "calendar trigger ${schedule_index} has hour ${actual_hour}, expected ${schedule_hour}"
  [ "${actual_minute}" = "17" ] ||
    fail "calendar trigger ${schedule_index} has minute ${actual_minute}, expected 17"
  schedule_index=$((schedule_index + 1))
done
if plutil -extract "StartCalendarInterval.${schedule_index}.Hour" raw -o - \
  "${SCHEDULE_PLIST}" >/dev/null 2>&1; then
  fail "calendar trigger list contains an unexpected fifth entry"
fi

run_hook scheduled
[ ! -f "${STATE_DIR}/update.last-success" ] || fail "fresh install should not be immediately due"

run_hook update
[ -s "${STATE_DIR}/update.last-success" ] || fail "update success was not recorded"
grep -q -- "--datadir=${TEST_ROOT}/db" "${TEST_ROOT}/freshclam-args" ||
  fail "freshclam did not receive the private database directory"

run_hook quick
[ -s "${STATE_DIR}/quick.last-success" ] || fail "quick success was not recorded"
grep -q -- "--database=${TEST_ROOT}/db" "${TEST_ROOT}/clamscan-args" ||
  fail "clamscan did not receive the private database directory"
grep -q -- '--official-db-only=yes' "${TEST_ROOT}/clamscan-args" ||
  fail "official database enforcement was missing"
grep -Fxq "${QUICK_DIR}" "${TEST_ROOT}/clamscan-args" ||
  fail "scan path containing spaces was not passed as one argument"

if FAKE_CLAMSCAN_RC=1 run_hook full; then
  fail "infected scan should return exit 1"
else
  rc=$?
  [ "${rc}" -eq 1 ] || fail "infected scan returned ${rc}, expected 1"
fi
[ -s "${STATE_DIR}/full.last-success" ] || fail "completed infected scan was not recorded"
[ -s "${STATE_DIR}/quick.last-success" ] || fail "full scan did not also satisfy quick scan"

run_hook status | grep -q 'ClamAV test-engine/test-db' ||
  fail "status did not report the database version"

printf 'https://discord.com/api/webhooks/123456/test_token\n' > "${BASE}/discord-webhook.url"
run_hook notify-test
[ -f "${TEST_ROOT}/curl-called" ] || fail "notification transport was not called"
grep -Fxq 'AV Scan Scheduler' "${TEST_ROOT}/jq-username" ||
  fail "notification did not override the legacy Discord webhook name"
if grep -R 'test_token' "${STATE_DIR}" "${LOG_DIR}" >/dev/null 2>&1; then
  fail "webhook token leaked into state or logs"
fi

if FAKE_CURL_RC=22 run_hook notify-test; then
  fail "failed Discord transport should not report success"
else
  rc=$?
  [ "${rc}" -eq 69 ] || fail "failed Discord transport returned ${rc}, expected 69"
fi

rm -f "${STATE_DIR}/quick.last-success"
if FAKE_CLAMSCAN_ACCESS_ERROR=1 run_hook quick; then
  fail "incomplete scan coverage should not report clean"
else
  rc=$?
  [ "${rc}" -eq 2 ] || fail "coverage error returned ${rc}, expected 2"
fi
[ ! -f "${STATE_DIR}/quick.last-success" ] || fail "coverage failure was recorded as success"
unset FAKE_CLAMSCAN_ACCESS_ERROR

rm -f "${STATE_DIR}/full.last-success"
if FAKE_CLAMSCAN_RC=1 FAKE_CLAMSCAN_TOTAL_ERRORS=2 run_hook full; then
  fail "detected scan with incomplete coverage should return failure"
else
  rc=$?
  [ "${rc}" -eq 2 ] ||
    fail "detected scan with incomplete coverage returned ${rc}, expected 2"
fi
[ ! -f "${STATE_DIR}/full.last-success" ] ||
  fail "detected scan with incomplete coverage was recorded as success"
grep -q 'detected malware, but scan coverage was incomplete' "${TEST_ROOT}/jq-content" ||
  fail "incomplete detected scan notification lost the detection warning"

current_uid="$(id -u)"
current_start="Thu Jul 31 04:00:00 2026"
current_command="av-scan-scheduler-test-process"
mkdir "${STATE_DIR}/run.lock"
printf '%s\n' "$$" > "${STATE_DIR}/run.lock/pid"
printf '%s\n' "${current_uid}" > "${STATE_DIR}/run.lock/uid"
printf '%s\n' "${current_start}" > "${STATE_DIR}/run.lock/start"
printf '%s\n' "${current_command}" > "${STATE_DIR}/run.lock/command"
if run_hook quick; then
  fail "concurrent run should have been rejected"
else
  rc=$?
  [ "${rc}" -eq 75 ] || fail "concurrent run returned ${rc}, expected 75"
fi
rm \
  "${STATE_DIR}/run.lock/pid" \
  "${STATE_DIR}/run.lock/uid" \
  "${STATE_DIR}/run.lock/start" \
  "${STATE_DIR}/run.lock/command"
rmdir "${STATE_DIR}/run.lock"

mkdir "${STATE_DIR}/run.lock"
printf '99999999\n' > "${STATE_DIR}/run.lock/pid"
printf '%s\n' "${current_uid}" > "${STATE_DIR}/run.lock/uid"
printf 'Mon Jan  1 00:00:00 2001\n' > "${STATE_DIR}/run.lock/start"
printf 'stale-process\n' > "${STATE_DIR}/run.lock/command"
run_hook quick
[ ! -d "${STATE_DIR}/run.lock" ] || fail "stale lock was not recovered"

mkdir "${STATE_DIR}/run.lock"
printf '%s\n' "$$" > "${STATE_DIR}/run.lock/pid"
printf '%s\n' "${current_uid}" > "${STATE_DIR}/run.lock/uid"
printf 'Mon Jan  1 00:00:00 2001\n' > "${STATE_DIR}/run.lock/start"
printf '%s\n' "${current_command}" > "${STATE_DIR}/run.lock/command"
run_hook quick
[ ! -d "${STATE_DIR}/run.lock" ] ||
  fail "PID-reuse lock with a mismatched start token was not recovered"

printf 'not-an-epoch\n' > "${STATE_DIR}/quick.last-success"
run_hook status | grep -q 'Quick last success:  never' ||
  fail "malformed state timestamp was not rejected"

printf '%s\n' "$(( $(date '+%s') + 86400 ))" > "${STATE_DIR}/quick.last-success"
run_hook status | grep -q 'Quick last success:  never' ||
  fail "future state timestamp was not rejected"

printf 'All AV Scan Scheduler tests passed.\n'
