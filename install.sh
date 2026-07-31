#!/bin/bash
set -eu
umask 077

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin

LABEL="io.github.tetsuroando.av-scan-scheduler"
SYSTEM_PARENT="/Library/Application Support"
SYSTEM_BASE="/Library/Application Support/AV Scan Scheduler"
RUNNER_DEST="${SYSTEM_BASE}/libexec/av-scan-scheduler"
CLI_DEST="${SYSTEM_BASE}/bin/av-scan-scheduler"
WEBHOOK_HELPER_DEST="${SYSTEM_BASE}/libexec/av-scan-scheduler-configure-webhook"
LAUNCHD_DIR="/Library/LaunchDaemons"
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"

# Exact identifiers from the only pre-rename release. Migration and cleanup use
# no wildcard paths or labels, so unrelated predecessor installations remain
# outside this installer's scope.
LEGACY_LABEL="io.github.tetsuroando.clamav-hook"
LEGACY_SYSTEM_BASE="/Library/Application Support/ClamAV-Hook"
LEGACY_RUNNER="${LEGACY_SYSTEM_BASE}/libexec/clamav-hook"
LEGACY_CLI="${LEGACY_SYSTEM_BASE}/bin/clamav-hook"
LEGACY_WEBHOOK_HELPER="${LEGACY_SYSTEM_BASE}/libexec/clamav-hook-configure-webhook"
LEGACY_PLIST="/Library/LaunchDaemons/${LEGACY_LABEL}.plist"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_USER=""
SKIP_UPDATE=0
SHOW_HELP=0
TARGET_UID=""
TARGET_HOME=""
BREW_PREFIX=""
CLI_LINK=""

STAGE_DIR=""
INSTALL_MUTATED=0
INSTALL_COMMITTED=0
ROLLBACK_BLOCKED=0
NEW_CLI_LINK_CREATED=0
OLD_JOB_LOADED=0
OLD_TARGET_USER=""
OLD_CLI_LINK=""

LEGACY_INSTALL_DETECTED=0
LEGACY_JOB_LOADED=0
LEGACY_LABEL_WAS_DISABLED=0
LEGACY_LABEL_DISABLE_ATTEMPTED=0
LEGACY_TARGET_USER=""
LEGACY_TARGET_UID=""
LEGACY_TARGET_HOME=""
LEGACY_CLI_LINK=""
LEGACY_CLI_QUARANTINE=""
LEGACY_CLI_QUARANTINED=0
LEGACY_USER_BASE=""
LEGACY_LOG_DIR=""
NEW_USER_BASE=""
NEW_LOG_DIR=""
USER_DATA_MIGRATED=0
USER_LOGS_MIGRATED=0
FRESHCLAM_BACKUP=""
FRESHCLAM_BACKED_UP=0

HAD_RUNNER=0
HAD_CLI=0
HAD_WEBHOOK_HELPER=0
HAD_PLIST=0
CREATED_SYSTEM_BASE=0
CREATED_BIN_DIR=0
CREATED_LIBEXEC_DIR=0

die() {
  printf '%s\n' "$1" >&2
  exit "${2:-70}"
}

valid_user_name() {
  case "$1" in
    ''|-*|*[!A-Za-z0-9._-]*) return 1 ;;
    *) return 0 ;;
  esac
}

path_has_symlink_component() {
  local path="$1"
  local remainder component current

  case "${path}" in
    /*) ;;
    *) return 0 ;;
  esac

  remainder="${path#/}"
  current=""
  while [ -n "${remainder}" ]; do
    component="${remainder%%/*}"
    if [ -z "${current}" ]; then
      current="/${component}"
    else
      current="${current}/${component}"
    fi
    if [ -L "${current}" ]; then
      return 0
    fi
    if [ "${remainder}" = "${component}" ]; then
      break
    fi
    remainder="${remainder#*/}"
  done
  return 1
}

assert_no_symlink_components() {
  if path_has_symlink_component "$1"; then
    die "Refusing system path with a symbolic-link component: $1" 73
  fi
}

assert_root_owned_directory() {
  local path="$1"
  local mode

  assert_no_symlink_components "${path}"
  if [ ! -e "${path}" ]; then
    return 0
  fi
  if [ ! -d "${path}" ]; then
    die "Refusing non-directory system path: ${path}" 73
  fi
  if [ "$(stat -f '%Su' "${path}")" != "root" ]; then
    die "Refusing system directory not owned by root: ${path}" 73
  fi
  mode="$(stat -f '%Lp' "${path}")"
  if [ $((8#${mode} & 0022)) -ne 0 ]; then
    die "Refusing group/world-writable system directory: ${path}" 73
  fi
}

assert_root_owned_file_or_missing() {
  local path="$1"
  local mode

  assert_no_symlink_components "${path}"
  if [ ! -e "${path}" ]; then
    return 0
  fi
  if [ ! -f "${path}" ]; then
    die "Refusing non-regular system file: ${path}" 73
  fi
  if [ "$(stat -f '%Su' "${path}")" != "root" ]; then
    die "Refusing system file not owned by root: ${path}" 73
  fi
  mode="$(stat -f '%Lp' "${path}")"
  if [ $((8#${mode} & 0022)) -ne 0 ]; then
    die "Refusing group/world-writable system file: ${path}" 73
  fi
}

validate_system_paths() {
  assert_root_owned_directory "/Library"
  assert_root_owned_directory "${SYSTEM_PARENT}"
  assert_root_owned_directory "${LAUNCHD_DIR}"
  assert_root_owned_directory "${SYSTEM_BASE}"
  assert_root_owned_directory "${SYSTEM_BASE}/bin"
  assert_root_owned_directory "${SYSTEM_BASE}/libexec"
  assert_root_owned_file_or_missing "${RUNNER_DEST}"
  assert_root_owned_file_or_missing "${CLI_DEST}"
  assert_root_owned_file_or_missing "${WEBHOOK_HELPER_DEST}"
  assert_root_owned_file_or_missing "${PLIST_DEST}"
}

validate_legacy_system_paths() {
  assert_root_owned_directory "${LEGACY_SYSTEM_BASE}"
  assert_root_owned_directory "${LEGACY_SYSTEM_BASE}/bin"
  assert_root_owned_directory "${LEGACY_SYSTEM_BASE}/libexec"
  assert_root_owned_file_or_missing "${LEGACY_RUNNER}"
  assert_root_owned_file_or_missing "${LEGACY_CLI}"
  assert_root_owned_file_or_missing "${LEGACY_WEBHOOK_HELPER}"
  assert_root_owned_file_or_missing "${LEGACY_PLIST}"
}

job_is_loaded() {
  local label="$1"
  launchctl print "system/${label}" >/dev/null 2>&1
}

label_is_disabled() {
  local label="$1"

  launchctl print-disabled system 2>/dev/null |
    awk -v entry="\"${label}\"" '
      $1 == entry && $3 == "disabled" {
        disabled = 1
      }
      END {
        exit disabled ? 0 : 1
      }
    '
}

stop_job_and_verify() {
  local label="$1"
  local attempts=0

  if ! job_is_loaded "${label}"; then
    return 0
  fi

  if ! launchctl bootout "system/${label}" >/dev/null 2>&1; then
    if job_is_loaded "${label}"; then
      printf 'Could not stop the existing launchd job: %s\n' "${label}" >&2
      return 1
    fi
  fi

  while job_is_loaded "${label}" && [ "${attempts}" -lt 5 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done
  if job_is_loaded "${label}"; then
    printf 'The existing launchd job is still loaded: %s\n' "${label}" >&2
    return 1
  fi
}

verify_new_job_started() {
  local attempts=0
  local running_observations=0
  local output state runs last_exit

  while [ "${attempts}" -lt 10 ]; do
    output="$(launchctl print "system/${LABEL}" 2>/dev/null || true)"
    state="$(
      printf '%s\n' "${output}" |
        awk -F' = ' '/^\tstate = / { print $2; exit }'
    )"
    runs="$(
      printf '%s\n' "${output}" |
        awk -F' = ' '/^\truns = / { print $2; exit }'
    )"
    last_exit="$(
      printf '%s\n' "${output}" |
        awk -F' = ' '/^\tlast exit code = / { print $2; exit }'
    )"

    case "${runs}" in
      ''|*[!0-9]*) ;;
      *)
        if [ "${runs}" -gt 0 ] && [ "${state}" = "running" ]; then
          running_observations=$((running_observations + 1))
          if [ "${running_observations}" -ge 2 ]; then
            return 0
          fi
        elif [ "${runs}" -gt 0 ] &&
             [ "${state}" = "not running" ] &&
             [ "${last_exit}" = "0" ]; then
          return 0
        elif [ "${runs}" -gt 0 ] &&
             [ "${state}" = "not running" ] &&
             [ -n "${last_exit}" ]; then
          printf 'The new launchd job exited with status %s before commit.\n' \
            "${last_exit}" >&2
          return 1
        else
          running_observations=0
        fi
        ;;
    esac

    sleep 1
    attempts=$((attempts + 1))
  done

  printf 'Could not verify that the new launchd job started successfully.\n' >&2
  return 1
}

atomic_install_file() {
  local source="$1"
  local destination="$2"
  local mode="$3"
  local temporary

  temporary="$(mktemp "${destination}.install.XXXXXX")" || return 1
  if ! install -o root -g wheel -m "${mode}" "${source}" "${temporary}"; then
    rm -f "${temporary}"
    return 1
  fi
  if ! mv -f "${temporary}" "${destination}"; then
    rm -f "${temporary}"
    return 1
  fi
}

restore_or_remove() {
  local had_file="$1"
  local backup="$2"
  local destination="$3"
  local temporary

  if [ "${had_file}" -eq 1 ]; then
    temporary="$(mktemp "${destination}.rollback.XXXXXX")" || return 1
    if ! cp -p "${backup}" "${temporary}"; then
      rm -f "${temporary}"
      return 1
    fi
    if ! mv -f "${temporary}" "${destination}"; then
      rm -f "${temporary}"
      return 1
    fi
  else
    rm -f "${destination}"
  fi
}

remove_managed_cli_link() {
  local user="$1"
  local link_path="$2"
  local expected_target="$3"

  if ! valid_user_name "${user}" ||
     [ -z "${link_path}" ] ||
     [ -z "${expected_target}" ]; then
    return 1
  fi
  if ! id -u "${user}" >/dev/null 2>&1; then
    return 1
  fi
  if [ -L "${link_path}" ] &&
     [ "$(readlink "${link_path}")" = "${expected_target}" ]; then
    sudo -u "${user}" rm -f "${link_path}"
  fi
}

quarantine_legacy_cli_link() {
  if [ ! -L "${LEGACY_CLI_LINK}" ] ||
     [ "$(readlink "${LEGACY_CLI_LINK}")" != "${LEGACY_CLI}" ]; then
    return
  fi

  LEGACY_CLI_QUARANTINE="${LEGACY_CLI_LINK}.rename-backup.$$"
  if [ -e "${LEGACY_CLI_QUARANTINE}" ] ||
     [ -L "${LEGACY_CLI_QUARANTINE}" ]; then
    die "Refusing to replace an existing command-link backup: ${LEGACY_CLI_QUARANTINE}" 73
  fi

  LEGACY_CLI_QUARANTINED=1
  sudo -u "${LEGACY_TARGET_USER}" \
    mv "${LEGACY_CLI_LINK}" "${LEGACY_CLI_QUARANTINE}"
}

restore_legacy_cli_link() {
  if [ "${LEGACY_CLI_QUARANTINED}" -ne 1 ]; then
    return
  fi
  if [ -e "${LEGACY_CLI_LINK}" ] || [ -L "${LEGACY_CLI_LINK}" ]; then
    if [ -L "${LEGACY_CLI_LINK}" ] &&
       [ "$(readlink "${LEGACY_CLI_LINK}")" = "${LEGACY_CLI}" ] &&
       [ ! -e "${LEGACY_CLI_QUARANTINE}" ] &&
       [ ! -L "${LEGACY_CLI_QUARANTINE}" ]; then
      LEGACY_CLI_QUARANTINED=0
      return
    fi
    return 1
  fi
  if [ ! -L "${LEGACY_CLI_QUARANTINE}" ] ||
     [ "$(readlink "${LEGACY_CLI_QUARANTINE}")" != "${LEGACY_CLI}" ]; then
    return 1
  fi
  sudo -u "${LEGACY_TARGET_USER}" \
    mv "${LEGACY_CLI_QUARANTINE}" "${LEGACY_CLI_LINK}"
  LEGACY_CLI_QUARANTINED=0
}

validate_user_directory_or_missing() {
  local path="$1"

  if path_has_symlink_component "${path}"; then
    die "Refusing user path with a symbolic-link component: ${path}" 73
  fi
  if [ ! -e "${path}" ]; then
    return
  fi
  if [ ! -d "${path}" ]; then
    die "Refusing non-directory user path: ${path}" 73
  fi
  if [ "$(stat -f '%u' "${path}")" != "${TARGET_UID}" ]; then
    die "Refusing user data not owned by ${TARGET_USER}: ${path}" 73
  fi
}

assert_no_active_user_lock() {
  local base="$1"

  if [ -d "${base}/state/run.lock" ]; then
    die "Refusing migration while a task lock exists: ${base}/state/run.lock" 75
  fi
}

rewrite_migrated_freshclam_config() {
  local config="${NEW_USER_BASE}/freshclam.conf"
  local new_db="${NEW_USER_BASE}/db"

  if [ -L "${config}" ]; then
    die "Refusing symbolic-link freshclam configuration: ${config}" 73
  fi
  if [ ! -e "${config}" ]; then
    return
  fi
  if [ ! -f "${config}" ]; then
    die "Refusing non-regular freshclam configuration: ${config}" 73
  fi

  FRESHCLAM_BACKUP="${NEW_USER_BASE}/.freshclam.conf.rename-backup.$$"
  if [ -e "${FRESHCLAM_BACKUP}" ] || [ -L "${FRESHCLAM_BACKUP}" ]; then
    die "Refusing to replace an existing migration backup: ${FRESHCLAM_BACKUP}" 73
  fi

  FRESHCLAM_BACKED_UP=1
  if ! sudo -u "${TARGET_USER}" env \
      HOME="${TARGET_HOME}" \
      CONFIG_PATH="${config}" \
      NEW_DATABASE_DIRECTORY="${new_db}" \
      BACKUP_PATH="${FRESHCLAM_BACKUP}" \
      /bin/bash -c '
      set -eu
      umask 077
      temporary="${CONFIG_PATH}.rename.$$"
      cleanup() {
        rc=$?
        rm -f "${temporary}"
        exit "${rc}"
      }
      trap cleanup EXIT
      cp -p "${CONFIG_PATH}" "${BACKUP_PATH}"
      awk -v database_directory="${NEW_DATABASE_DIRECTORY}" '\''
        BEGIN { found = 0 }
        $1 == "DatabaseDirectory" {
          print "DatabaseDirectory " database_directory
          found = 1
          next
        }
        { print }
        END {
          if (!found) {
            print "DatabaseDirectory " database_directory
          }
        }
      '\'' "${CONFIG_PATH}" > "${temporary}"
      chmod 600 "${temporary}"
      mv -f "${temporary}" "${CONFIG_PATH}"
    '; then
    return 1
  fi
}

restore_migrated_freshclam_config() {
  local config="${NEW_USER_BASE}/freshclam.conf"

  if [ "${FRESHCLAM_BACKED_UP}" -ne 1 ]; then
    return
  fi
  if [ ! -f "${FRESHCLAM_BACKUP}" ]; then
    FRESHCLAM_BACKED_UP=0
    return
  fi
  sudo -u "${TARGET_USER}" mv -f "${FRESHCLAM_BACKUP}" "${config}"
  FRESHCLAM_BACKED_UP=0
}

discard_migration_backup() {
  if [ "${FRESHCLAM_BACKED_UP}" -eq 1 ]; then
    if ! sudo -u "${TARGET_USER}" rm -f "${FRESHCLAM_BACKUP}"; then
      return 1
    fi
    FRESHCLAM_BACKED_UP=0
  fi
}

migrate_legacy_user_data() {
  validate_user_directory_or_missing "${LEGACY_USER_BASE}"
  validate_user_directory_or_missing "${NEW_USER_BASE}"
  validate_user_directory_or_missing "${LEGACY_LOG_DIR}"
  validate_user_directory_or_missing "${NEW_LOG_DIR}"

  assert_no_active_user_lock "${LEGACY_USER_BASE}"
  assert_no_active_user_lock "${NEW_USER_BASE}"

  if [ -d "${LEGACY_USER_BASE}" ]; then
    if [ -e "${NEW_USER_BASE}" ] || [ -L "${NEW_USER_BASE}" ]; then
      die "Both legacy and renamed user data exist; refusing to merge them automatically." 73
    fi
    USER_DATA_MIGRATED=1
    sudo -u "${TARGET_USER}" mv "${LEGACY_USER_BASE}" "${NEW_USER_BASE}"
  fi

  # A previous process or power interruption may have happened after the
  # directory rename but before the configuration rewrite. Rewriting the exact
  # setting is idempotent and lets a subsequent installer resume safely.
  if [ "${LEGACY_INSTALL_DETECTED}" -eq 1 ] &&
     [ -d "${NEW_USER_BASE}" ]; then
    rewrite_migrated_freshclam_config
  fi

  if [ -d "${LEGACY_LOG_DIR}" ]; then
    if [ -e "${NEW_LOG_DIR}" ] || [ -L "${NEW_LOG_DIR}" ]; then
      die "Both legacy and renamed log directories exist; refusing to merge them automatically." 73
    fi
    USER_LOGS_MIGRATED=1
    sudo -u "${TARGET_USER}" mv "${LEGACY_LOG_DIR}" "${NEW_LOG_DIR}"
  fi
}

rollback_legacy_user_data() {
  local rollback_failed=0

  restore_migrated_freshclam_config || rollback_failed=1
  if [ "${USER_LOGS_MIGRATED}" -eq 1 ] &&
     [ -d "${NEW_LOG_DIR}" ] &&
     [ ! -e "${LEGACY_LOG_DIR}" ]; then
    sudo -u "${TARGET_USER}" mv "${NEW_LOG_DIR}" "${LEGACY_LOG_DIR}" ||
      rollback_failed=1
  fi
  if [ "${USER_DATA_MIGRATED}" -eq 1 ] &&
     [ -d "${NEW_USER_BASE}" ] &&
     [ ! -e "${LEGACY_USER_BASE}" ]; then
    sudo -u "${TARGET_USER}" mv "${NEW_USER_BASE}" "${LEGACY_USER_BASE}" ||
      rollback_failed=1
  fi

  return "${rollback_failed}"
}

cleanup_legacy_install() {
  local cleanup_failed=0

  launchctl disable "system/${LEGACY_LABEL}" >/dev/null 2>&1 || cleanup_failed=1
  if job_is_loaded "${LEGACY_LABEL}"; then
    printf 'Warning: legacy job unexpectedly remained loaded; its files were preserved.\n' >&2
    return 1
  fi

  if [ "${LEGACY_CLI_QUARANTINED}" -eq 1 ]; then
    if [ -L "${LEGACY_CLI_QUARANTINE}" ] &&
       [ "$(readlink "${LEGACY_CLI_QUARANTINE}")" = "${LEGACY_CLI}" ]; then
      if sudo -u "${LEGACY_TARGET_USER}" rm -f "${LEGACY_CLI_QUARANTINE}"; then
        LEGACY_CLI_QUARANTINED=0
      else
        cleanup_failed=1
      fi
    else
      cleanup_failed=1
    fi
  elif [ -n "${LEGACY_CLI_LINK}" ]; then
    if ! remove_managed_cli_link \
      "${LEGACY_TARGET_USER:-${TARGET_USER}}" \
      "${LEGACY_CLI_LINK}" \
      "${LEGACY_CLI}"; then
      cleanup_failed=1
    fi
  fi

  validate_legacy_system_paths
  rm -f \
    "${LEGACY_PLIST}" \
    "${LEGACY_CLI}" \
    "${LEGACY_RUNNER}" \
    "${LEGACY_WEBHOOK_HELPER}" ||
    cleanup_failed=1
  rmdir "${LEGACY_SYSTEM_BASE}/bin" 2>/dev/null || true
  rmdir "${LEGACY_SYSTEM_BASE}/libexec" 2>/dev/null || true
  rmdir "${LEGACY_SYSTEM_BASE}" 2>/dev/null || true

  return "${cleanup_failed}"
}

cleanup_stage() {
  if [ "${ROLLBACK_BLOCKED}" -eq 1 ]; then
    printf 'Rollback staging files were preserved for manual recovery: %s\n' \
      "${STAGE_DIR}" >&2
    return
  fi
  if [ -n "${STAGE_DIR}" ]; then
    case "${STAGE_DIR}" in
      /private/tmp/av-scan-scheduler.install.*)
        if [ -d "${STAGE_DIR}" ] && [ ! -L "${STAGE_DIR}" ]; then
          rm -rf "${STAGE_DIR}"
        fi
        ;;
    esac
  fi
}

rollback_install() {
  local rollback_failed=0

  set +e
  printf 'Installation failed; restoring the previous AV Scan Scheduler state.\n' >&2

  if job_is_loaded "${LABEL}"; then
    if ! stop_job_and_verify "${LABEL}"; then
      ROLLBACK_BLOCKED=1
      printf 'WARNING: rollback stopped because the new job could not be stopped.\n' >&2
      printf 'No runtime, plist, user data, or legacy job was changed further.\n' >&2
      return
    fi
  fi

  restore_or_remove "${HAD_RUNNER}" \
    "${STAGE_DIR}/backup/av-scan-scheduler-runner" "${RUNNER_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_CLI}" \
    "${STAGE_DIR}/backup/av-scan-scheduler-cli" "${CLI_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_WEBHOOK_HELPER}" \
    "${STAGE_DIR}/backup/av-scan-scheduler-configure-webhook" \
    "${WEBHOOK_HELPER_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_PLIST}" \
    "${STAGE_DIR}/backup/launchd.plist" "${PLIST_DEST}" ||
    rollback_failed=1

  if [ "${NEW_CLI_LINK_CREATED}" -eq 1 ]; then
    remove_managed_cli_link "${TARGET_USER}" "${CLI_LINK}" "${CLI_DEST}" || true
  fi

  if [ "${CREATED_BIN_DIR}" -eq 1 ]; then
    rmdir "${SYSTEM_BASE}/bin" 2>/dev/null || true
  fi
  if [ "${CREATED_LIBEXEC_DIR}" -eq 1 ]; then
    rmdir "${SYSTEM_BASE}/libexec" 2>/dev/null || true
  fi
  if [ "${CREATED_SYSTEM_BASE}" -eq 1 ]; then
    rmdir "${SYSTEM_BASE}" 2>/dev/null || true
  fi

  rollback_legacy_user_data || rollback_failed=1
  restore_legacy_cli_link || rollback_failed=1

  if [ "${OLD_JOB_LOADED}" -eq 1 ] && [ "${HAD_PLIST}" -eq 1 ]; then
    launchctl enable "system/${LABEL}" >/dev/null 2>&1 || rollback_failed=1
    if ! job_is_loaded "${LABEL}"; then
      launchctl bootstrap system "${PLIST_DEST}" >/dev/null 2>&1 ||
        rollback_failed=1
    fi
    job_is_loaded "${LABEL}" || rollback_failed=1
  else
    launchctl disable "system/${LABEL}" >/dev/null 2>&1 || true
  fi

  if [ "${LEGACY_JOB_LOADED}" -eq 1 ] && [ -f "${LEGACY_PLIST}" ]; then
    launchctl enable "system/${LEGACY_LABEL}" >/dev/null 2>&1 ||
      rollback_failed=1
    if ! job_is_loaded "${LEGACY_LABEL}"; then
      launchctl bootstrap system "${LEGACY_PLIST}" >/dev/null 2>&1 ||
        rollback_failed=1
    fi
    job_is_loaded "${LEGACY_LABEL}" || rollback_failed=1
  fi
  if [ "${LEGACY_LABEL_DISABLE_ATTEMPTED}" -eq 1 ]; then
    if [ "${LEGACY_LABEL_WAS_DISABLED}" -eq 1 ]; then
      launchctl disable "system/${LEGACY_LABEL}" >/dev/null 2>&1 ||
        rollback_failed=1
    else
      launchctl enable "system/${LEGACY_LABEL}" >/dev/null 2>&1 ||
        rollback_failed=1
    fi
  fi

  if [ "${rollback_failed}" -ne 0 ]; then
    ROLLBACK_BLOCKED=1
    printf 'WARNING: automatic rollback was incomplete; inspect %s, %s, and %s.\n' \
      "${SYSTEM_BASE}" "${PLIST_DEST}" "${LEGACY_PLIST}" >&2
  fi
}

on_exit() {
  local rc=$?
  trap - EXIT
  if [ "${INSTALL_MUTATED}" -eq 1 ] && [ "${INSTALL_COMMITTED}" -eq 0 ]; then
    rollback_install
  fi
  cleanup_stage
  exit "${rc}"
}

trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<'EOF'
Usage: ./install.sh [--user macOS-user] [--skip-update]

The installer uses root only to install immutable program files and register
the LaunchDaemon. ClamAV and Homebrew tools run as the selected user.

Options:
  --user USER    Local account whose files will be scanned
  --skip-update  Do not run the initial private signature update
  -h, --help     Show this help
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --user)
      [ "$#" -ge 2 ] || { printf 'Missing value for --user\n' >&2; exit 64; }
      TARGET_USER="$2"
      shift 2
      ;;
    --skip-update)
      SKIP_UPDATE=1
      shift
      ;;
    -h|--help)
      SHOW_HELP=1
      shift
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
done

if [ "${SHOW_HELP}" -eq 1 ]; then
  usage
  exit 0
fi

if [ "$(uname -s)" != "Darwin" ]; then
  printf 'AV Scan Scheduler supports macOS only.\n' >&2
  exit 69
fi

if [ "$(id -u)" -ne 0 ]; then
  if [ -z "${TARGET_USER}" ]; then
    TARGET_USER="$(id -un)"
  fi
  args=(--user "${TARGET_USER}")
  if [ "${SKIP_UPDATE}" -eq 1 ]; then
    args+=(--skip-update)
  fi
  exec sudo "$0" "${args[@]}"
fi

if [ -z "${TARGET_USER}" ]; then
  if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
    TARGET_USER="${SUDO_USER}"
  else
    printf 'Specify the local account to scan with --user USER.\n' >&2
    exit 64
  fi
fi

valid_user_name "${TARGET_USER}" ||
  die "Invalid local user name: ${TARGET_USER}" 64

TARGET_UID="$(id -u "${TARGET_USER}" 2>/dev/null || true)"
TARGET_HOME="$(
  dscacheutil -q user -a name "${TARGET_USER}" |
    awk -F': ' '$1 == "dir" { print $2; exit }'
)"

if [ -z "${TARGET_UID}" ] || [ -z "${TARGET_HOME}" ] || [ ! -d "${TARGET_HOME}" ]; then
  die "Could not resolve account details for ${TARGET_USER}." 67
fi

case "${TARGET_HOME}" in
  /Users/*) ;;
  *)
    printf 'Refusing unexpected home directory: %s\n' "${TARGET_HOME}" >&2
    exit 67
    ;;
esac

case "${TARGET_UID}" in
  ''|*[!0-9]*) die "Invalid UID for ${TARGET_USER}: ${TARGET_UID}" 67 ;;
esac

CANONICAL_HOME="$(cd "${TARGET_HOME}" 2>/dev/null && pwd -P)"
if [ "${CANONICAL_HOME}" != "${TARGET_HOME}" ]; then
  die "Refusing non-canonical or symbolic-link home directory: ${TARGET_HOME}" 67
fi

NEW_USER_BASE="${TARGET_HOME}/Library/Application Support/AV Scan Scheduler"
NEW_LOG_DIR="${TARGET_HOME}/Library/Logs/AV Scan Scheduler"
LEGACY_USER_BASE="${TARGET_HOME}/Library/Application Support/ClamAV-Hook"
LEGACY_LOG_DIR="${TARGET_HOME}/Library/Logs/ClamAV-Hook"

for tool in brew freshclam clamscan jq curl; do
  if ! sudo -u "${TARGET_USER}" env \
    HOME="${TARGET_HOME}" \
    PATH="${PATH}" \
    sh -c 'command -v "$1" >/dev/null 2>&1' sh "${tool}"; then
    printf 'Missing dependency for %s: %s\n' "${TARGET_USER}" "${tool}" >&2
    printf 'Install dependencies with: brew install clamav jq\n' >&2
    exit 69
  fi
done

BREW_PREFIX="$(
  sudo -u "${TARGET_USER}" env HOME="${TARGET_HOME}" PATH="${PATH}" brew --prefix
)"
case "${BREW_PREFIX}" in
  /*) ;;
  *)
    printf 'Refusing non-absolute Homebrew prefix: %s\n' "${BREW_PREFIX}" >&2
    exit 67
    ;;
esac
CLI_LINK="${BREW_PREFIX}/bin/av-scan-scheduler"
if ! sudo -u "${TARGET_USER}" test -w "${BREW_PREFIX}/bin"; then
  printf 'Homebrew bin directory is not writable by %s: %s\n' \
    "${TARGET_USER}" "${BREW_PREFIX}/bin" >&2
  exit 73
fi

if [ ! -f "${SCRIPT_DIR}/bin/av-scan-scheduler-runner" ] ||
   [ ! -f "${SCRIPT_DIR}/bin/av-scan-scheduler" ] ||
   [ ! -f "${SCRIPT_DIR}/bin/av-scan-scheduler-configure-webhook" ] ||
   [ ! -f "${SCRIPT_DIR}/launchd/${LABEL}.plist" ]; then
  printf 'Run install.sh from a complete AV Scan Scheduler checkout.\n' >&2
  exit 66
fi

if [ -L "${CLI_LINK}" ]; then
  if [ "$(readlink "${CLI_LINK}")" != "${CLI_DEST}" ]; then
    die "Refusing to replace an unmanaged command symlink: ${CLI_LINK}" 73
  fi
elif [ -e "${CLI_LINK}" ]; then
  die "Refusing to replace an existing command: ${CLI_LINK}" 73
fi

validate_system_paths
validate_legacy_system_paths

if [ -e "${LEGACY_SYSTEM_BASE}" ] ||
   [ -e "${LEGACY_PLIST}" ] ||
   [ -d "${LEGACY_USER_BASE}" ] ||
   [ -d "${LEGACY_LOG_DIR}" ] ||
   job_is_loaded "${LEGACY_LABEL}"; then
  LEGACY_INSTALL_DETECTED=1
  if label_is_disabled "${LEGACY_LABEL}"; then
    LEGACY_LABEL_WAS_DISABLED=1
  fi
fi

if [ -f "${PLIST_DEST}" ]; then
  OLD_TARGET_USER="$(
    plutil -extract UserName raw -o - "${PLIST_DEST}" 2>/dev/null || true
  )"
  OLD_CLI_LINK="$(
    plutil -extract EnvironmentVariables.AV_SCAN_SCHEDULER_CLI_LINK raw -o - \
      "${PLIST_DEST}" 2>/dev/null || true
  )"
fi
if job_is_loaded "${LABEL}"; then
  OLD_JOB_LOADED=1
fi

if [ -f "${LEGACY_PLIST}" ]; then
  LEGACY_TARGET_USER="$(
    plutil -extract UserName raw -o - "${LEGACY_PLIST}" 2>/dev/null || true
  )"
  LEGACY_TARGET_HOME="$(
    plutil -extract EnvironmentVariables.CLAMAV_HOOK_HOME raw -o - \
      "${LEGACY_PLIST}" 2>/dev/null || true
  )"
  LEGACY_TARGET_UID="$(
    plutil -extract EnvironmentVariables.CLAMAV_HOOK_UID raw -o - \
      "${LEGACY_PLIST}" 2>/dev/null || true
  )"
  LEGACY_CLI_LINK="$(
    plutil -extract EnvironmentVariables.CLAMAV_HOOK_CLI_LINK raw -o - \
      "${LEGACY_PLIST}" 2>/dev/null || true
  )"

  if [ "${LEGACY_TARGET_USER}" != "${TARGET_USER}" ] ||
     [ "${LEGACY_TARGET_HOME}" != "${TARGET_HOME}" ] ||
     [ "${LEGACY_TARGET_UID}" != "${TARGET_UID}" ]; then
    die "The legacy installation belongs to a different local account; refusing automatic migration." 73
  fi
else
  LEGACY_TARGET_USER="${TARGET_USER}"
  LEGACY_TARGET_HOME="${TARGET_HOME}"
  LEGACY_TARGET_UID="${TARGET_UID}"
fi

if [ -z "${LEGACY_CLI_LINK}" ]; then
  LEGACY_CLI_LINK="${BREW_PREFIX}/bin/clamav-hook"
fi
case "${LEGACY_CLI_LINK}" in
  /*) ;;
  *) die "Refusing non-absolute legacy command link: ${LEGACY_CLI_LINK}" 73 ;;
esac

if job_is_loaded "${LEGACY_LABEL}"; then
  [ -f "${LEGACY_PLIST}" ] ||
    die "The legacy launchd job is loaded but its plist is missing." 70
  LEGACY_JOB_LOADED=1
fi

STAGE_DIR="$(mktemp -d /private/tmp/av-scan-scheduler.install.XXXXXX)"
chmod 700 "${STAGE_DIR}"
mkdir "${STAGE_DIR}/runtime" "${STAGE_DIR}/backup"
chmod 700 "${STAGE_DIR}/runtime" "${STAGE_DIR}/backup"

install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/av-scan-scheduler-runner" \
  "${STAGE_DIR}/runtime/av-scan-scheduler-runner"
install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/av-scan-scheduler" \
  "${STAGE_DIR}/runtime/av-scan-scheduler-cli"
install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/av-scan-scheduler-configure-webhook" \
  "${STAGE_DIR}/runtime/av-scan-scheduler-configure-webhook"
install -o root -g wheel -m 644 \
  "${SCRIPT_DIR}/launchd/${LABEL}.plist" "${STAGE_DIR}/runtime/launchd.plist"

plutil -replace UserName -string "${TARGET_USER}" "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.HOME -string "${TARGET_HOME}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.AV_SCAN_SCHEDULER_HOME -string "${TARGET_HOME}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.AV_SCAN_SCHEDULER_UID -string "${TARGET_UID}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.AV_SCAN_SCHEDULER_CLI_LINK -string "${CLI_LINK}" \
  "${STAGE_DIR}/runtime/launchd.plist"

bash -n \
  "${STAGE_DIR}/runtime/av-scan-scheduler-runner" \
  "${STAGE_DIR}/runtime/av-scan-scheduler-cli" \
  "${STAGE_DIR}/runtime/av-scan-scheduler-configure-webhook"
plutil -lint "${STAGE_DIR}/runtime/launchd.plist" >/dev/null

if [ -f "${RUNNER_DEST}" ]; then
  HAD_RUNNER=1
  cp -p "${RUNNER_DEST}" "${STAGE_DIR}/backup/av-scan-scheduler-runner"
fi
if [ -f "${CLI_DEST}" ]; then
  HAD_CLI=1
  cp -p "${CLI_DEST}" "${STAGE_DIR}/backup/av-scan-scheduler-cli"
fi
if [ -f "${WEBHOOK_HELPER_DEST}" ]; then
  HAD_WEBHOOK_HELPER=1
  cp -p "${WEBHOOK_HELPER_DEST}" \
    "${STAGE_DIR}/backup/av-scan-scheduler-configure-webhook"
fi
if [ -f "${PLIST_DEST}" ]; then
  HAD_PLIST=1
  cp -p "${PLIST_DEST}" "${STAGE_DIR}/backup/launchd.plist"
fi

INSTALL_MUTATED=1
stop_job_and_verify "${LABEL}" ||
  die "Refusing to modify files while ${LABEL} may still be running." 70
stop_job_and_verify "${LEGACY_LABEL}" ||
  die "Refusing to migrate while ${LEGACY_LABEL} may still be running." 70
validate_system_paths
validate_legacy_system_paths

if [ "${LEGACY_INSTALL_DETECTED}" -eq 1 ]; then
  LEGACY_LABEL_DISABLE_ATTEMPTED=1
  if ! launchctl disable "system/${LEGACY_LABEL}"; then
    die "Could not disable the legacy launchd label; rollback will restore the previous installation." 70
  fi
  if ! label_is_disabled "${LEGACY_LABEL}"; then
    die "The legacy launchd label remained enabled; rollback will restore the previous installation." 70
  fi
fi

quarantine_legacy_cli_link
migrate_legacy_user_data

if [ ! -d "${SYSTEM_BASE}" ]; then
  CREATED_SYSTEM_BASE=1
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}"
fi
if [ ! -d "${SYSTEM_BASE}/bin" ]; then
  CREATED_BIN_DIR=1
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}/bin"
fi
if [ ! -d "${SYSTEM_BASE}/libexec" ]; then
  CREATED_LIBEXEC_DIR=1
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}/libexec"
fi

atomic_install_file \
  "${STAGE_DIR}/runtime/av-scan-scheduler-runner" "${RUNNER_DEST}" 755
atomic_install_file \
  "${STAGE_DIR}/runtime/av-scan-scheduler-cli" "${CLI_DEST}" 755
atomic_install_file "${STAGE_DIR}/runtime/av-scan-scheduler-configure-webhook" \
  "${WEBHOOK_HELPER_DEST}" 755
atomic_install_file "${STAGE_DIR}/runtime/launchd.plist" "${PLIST_DEST}" 644
validate_system_paths

sudo -u "${TARGET_USER}" env \
  HOME="${TARGET_HOME}" \
  AV_SCAN_SCHEDULER_HOME="${TARGET_HOME}" \
  "${RUNNER_DEST}" init

if [ ! -L "${CLI_LINK}" ]; then
  NEW_CLI_LINK_CREATED=1
  sudo -u "${TARGET_USER}" ln -s "${CLI_DEST}" "${CLI_LINK}"
fi

if [ "${SKIP_UPDATE}" -eq 0 ]; then
  if ! sudo -u "${TARGET_USER}" env \
    HOME="${TARGET_HOME}" \
    AV_SCAN_SCHEDULER_HOME="${TARGET_HOME}" \
    "${RUNNER_DEST}" update; then
    printf 'Initial database update failed. The daily scheduler will retry.\n' >&2
  fi
fi

launchctl enable "system/${LABEL}"
if ! launchctl bootstrap system "${PLIST_DEST}"; then
  die "launchd could not bootstrap ${LABEL}; rollback will restore the previous installation." 70
fi
if ! launchctl print "system/${LABEL}" >/dev/null 2>&1; then
  die "launchd did not accept ${LABEL}; rollback will restore the previous installation." 70
fi
if ! verify_new_job_started; then
  die "The new launchd job did not start cleanly; rollback will restore the previous installation." 70
fi

INSTALL_COMMITTED=1
if ! discard_migration_backup; then
  printf 'Warning: a user-private migration backup could not be removed: %s\n' \
    "${FRESHCLAM_BACKUP}" >&2
fi

if [ -n "${OLD_CLI_LINK}" ] &&
   [ "${OLD_CLI_LINK}" != "${CLI_LINK}" ]; then
  if ! remove_managed_cli_link \
    "${OLD_TARGET_USER}" "${OLD_CLI_LINK}" "${CLI_DEST}"; then
    printf 'Warning: could not remove the previous command link: %s\n' \
      "${OLD_CLI_LINK}" >&2
  fi
fi

if [ "${LEGACY_INSTALL_DETECTED}" -eq 1 ]; then
  if ! cleanup_legacy_install; then
    printf 'Warning: some stopped legacy files remain; the renamed job is active.\n' >&2
  fi
fi

printf '\nAV Scan Scheduler installed for %s (%s).\n' "${TARGET_USER}" "${TARGET_HOME}"
printf 'Runtime privilege:  %s (never root)\n' "${TARGET_USER}"
printf 'Configure Discord:  av-scan-scheduler configure-webhook\n'
printf 'Check status:       av-scan-scheduler status\n'
