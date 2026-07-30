#!/bin/bash
set -eu
umask 077

PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin

LABEL="io.github.tetsuroando.clamav-hook"
SYSTEM_PARENT="/Library/Application Support"
SYSTEM_BASE="/Library/Application Support/ClamAV-Hook"
RUNNER_DEST="${SYSTEM_BASE}/libexec/clamav-hook"
CLI_DEST="${SYSTEM_BASE}/bin/clamav-hook"
WEBHOOK_HELPER_DEST="${SYSTEM_BASE}/libexec/clamav-hook-configure-webhook"
LAUNCHD_DIR="/Library/LaunchDaemons"
PLIST_DEST="/Library/LaunchDaemons/${LABEL}.plist"

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
NEW_CLI_LINK_CREATED=0
OLD_JOB_LOADED=0
OLD_TARGET_USER=""
OLD_CLI_LINK=""

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

job_is_loaded() {
  launchctl print "system/${LABEL}" >/dev/null 2>&1
}

stop_job_and_verify() {
  local attempts=0

  if ! job_is_loaded; then
    return 0
  fi

  if ! launchctl bootout "system/${LABEL}" >/dev/null 2>&1; then
    if job_is_loaded; then
      printf 'Could not stop the existing launchd job: %s\n' "${LABEL}" >&2
      return 1
    fi
  fi

  while job_is_loaded && [ "${attempts}" -lt 5 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done
  if job_is_loaded; then
    printf 'The existing launchd job is still loaded: %s\n' "${LABEL}" >&2
    return 1
  fi
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

  if ! valid_user_name "${user}" || [ -z "${link_path}" ]; then
    return 1
  fi
  if ! id -u "${user}" >/dev/null 2>&1; then
    return 1
  fi
  if [ -L "${link_path}" ] &&
     [ "$(readlink "${link_path}")" = "${CLI_DEST}" ]; then
    sudo -u "${user}" rm -f "${link_path}"
  fi
}

cleanup_stage() {
  if [ -n "${STAGE_DIR}" ]; then
    case "${STAGE_DIR}" in
      /private/tmp/clamav-hook.install.*)
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
  printf 'Installation failed; restoring the previous ClamAV-Hook state.\n' >&2

  if job_is_loaded; then
    stop_job_and_verify || rollback_failed=1
  fi

  restore_or_remove "${HAD_RUNNER}" \
    "${STAGE_DIR}/backup/clamav-hook-runner" "${RUNNER_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_CLI}" \
    "${STAGE_DIR}/backup/clamav-hook-cli" "${CLI_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_WEBHOOK_HELPER}" \
    "${STAGE_DIR}/backup/clamav-hook-configure-webhook" "${WEBHOOK_HELPER_DEST}" ||
    rollback_failed=1
  restore_or_remove "${HAD_PLIST}" \
    "${STAGE_DIR}/backup/launchd.plist" "${PLIST_DEST}" ||
    rollback_failed=1

  if [ "${NEW_CLI_LINK_CREATED}" -eq 1 ]; then
    remove_managed_cli_link "${TARGET_USER}" "${CLI_LINK}" || true
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

  if [ "${OLD_JOB_LOADED}" -eq 1 ] && [ "${HAD_PLIST}" -eq 1 ]; then
    launchctl enable "system/${LABEL}" >/dev/null 2>&1 || rollback_failed=1
    launchctl bootstrap system "${PLIST_DEST}" >/dev/null 2>&1 || rollback_failed=1
    job_is_loaded || rollback_failed=1
  fi

  if [ "${rollback_failed}" -ne 0 ]; then
    printf 'WARNING: automatic rollback was incomplete; inspect %s and %s.\n' \
      "${SYSTEM_BASE}" "${PLIST_DEST}" >&2
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
  printf 'ClamAV-Hook supports macOS only.\n' >&2
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
CLI_LINK="${BREW_PREFIX}/bin/clamav-hook"
if ! sudo -u "${TARGET_USER}" test -w "${BREW_PREFIX}/bin"; then
  printf 'Homebrew bin directory is not writable by %s: %s\n' \
    "${TARGET_USER}" "${BREW_PREFIX}/bin" >&2
  exit 73
fi

if [ ! -f "${SCRIPT_DIR}/bin/clamav-hook-runner" ] ||
   [ ! -f "${SCRIPT_DIR}/bin/clamav-hook" ] ||
   [ ! -f "${SCRIPT_DIR}/bin/clamav-hook-configure-webhook" ] ||
   [ ! -f "${SCRIPT_DIR}/launchd/${LABEL}.plist" ]; then
  printf 'Run install.sh from a complete ClamAV-Hook checkout.\n' >&2
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

if [ -f "${PLIST_DEST}" ]; then
  OLD_TARGET_USER="$(
    plutil -extract UserName raw -o - "${PLIST_DEST}" 2>/dev/null || true
  )"
  OLD_CLI_LINK="$(
    plutil -extract EnvironmentVariables.CLAMAV_HOOK_CLI_LINK raw -o - \
      "${PLIST_DEST}" 2>/dev/null || true
  )"
fi
if job_is_loaded; then
  OLD_JOB_LOADED=1
fi

STAGE_DIR="$(mktemp -d /private/tmp/clamav-hook.install.XXXXXX)"
chmod 700 "${STAGE_DIR}"
mkdir "${STAGE_DIR}/runtime" "${STAGE_DIR}/backup"
chmod 700 "${STAGE_DIR}/runtime" "${STAGE_DIR}/backup"

install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/clamav-hook-runner" "${STAGE_DIR}/runtime/clamav-hook-runner"
install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/clamav-hook" "${STAGE_DIR}/runtime/clamav-hook-cli"
install -o root -g wheel -m 755 \
  "${SCRIPT_DIR}/bin/clamav-hook-configure-webhook" \
  "${STAGE_DIR}/runtime/clamav-hook-configure-webhook"
install -o root -g wheel -m 644 \
  "${SCRIPT_DIR}/launchd/${LABEL}.plist" "${STAGE_DIR}/runtime/launchd.plist"

plutil -replace UserName -string "${TARGET_USER}" "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.HOME -string "${TARGET_HOME}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.CLAMAV_HOOK_HOME -string "${TARGET_HOME}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.CLAMAV_HOOK_UID -string "${TARGET_UID}" \
  "${STAGE_DIR}/runtime/launchd.plist"
plutil -replace EnvironmentVariables.CLAMAV_HOOK_CLI_LINK -string "${CLI_LINK}" \
  "${STAGE_DIR}/runtime/launchd.plist"

bash -n \
  "${STAGE_DIR}/runtime/clamav-hook-runner" \
  "${STAGE_DIR}/runtime/clamav-hook-cli" \
  "${STAGE_DIR}/runtime/clamav-hook-configure-webhook"
plutil -lint "${STAGE_DIR}/runtime/launchd.plist" >/dev/null

if [ -f "${RUNNER_DEST}" ]; then
  HAD_RUNNER=1
  cp -p "${RUNNER_DEST}" "${STAGE_DIR}/backup/clamav-hook-runner"
fi
if [ -f "${CLI_DEST}" ]; then
  HAD_CLI=1
  cp -p "${CLI_DEST}" "${STAGE_DIR}/backup/clamav-hook-cli"
fi
if [ -f "${WEBHOOK_HELPER_DEST}" ]; then
  HAD_WEBHOOK_HELPER=1
  cp -p "${WEBHOOK_HELPER_DEST}" \
    "${STAGE_DIR}/backup/clamav-hook-configure-webhook"
fi
if [ -f "${PLIST_DEST}" ]; then
  HAD_PLIST=1
  cp -p "${PLIST_DEST}" "${STAGE_DIR}/backup/launchd.plist"
fi

stop_job_and_verify ||
  die "Refusing to modify files while ${LABEL} may still be running." 70
INSTALL_MUTATED=1
validate_system_paths

if [ ! -d "${SYSTEM_BASE}" ]; then
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}"
  CREATED_SYSTEM_BASE=1
fi
if [ ! -d "${SYSTEM_BASE}/bin" ]; then
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}/bin"
  CREATED_BIN_DIR=1
fi
if [ ! -d "${SYSTEM_BASE}/libexec" ]; then
  install -d -o root -g wheel -m 755 "${SYSTEM_BASE}/libexec"
  CREATED_LIBEXEC_DIR=1
fi

atomic_install_file "${STAGE_DIR}/runtime/clamav-hook-runner" "${RUNNER_DEST}" 755
atomic_install_file "${STAGE_DIR}/runtime/clamav-hook-cli" "${CLI_DEST}" 755
atomic_install_file "${STAGE_DIR}/runtime/clamav-hook-configure-webhook" \
  "${WEBHOOK_HELPER_DEST}" 755
atomic_install_file "${STAGE_DIR}/runtime/launchd.plist" "${PLIST_DEST}" 644
validate_system_paths

sudo -u "${TARGET_USER}" env \
  HOME="${TARGET_HOME}" \
  CLAMAV_HOOK_HOME="${TARGET_HOME}" \
  "${RUNNER_DEST}" init

if [ ! -L "${CLI_LINK}" ]; then
  sudo -u "${TARGET_USER}" ln -s "${CLI_DEST}" "${CLI_LINK}"
  NEW_CLI_LINK_CREATED=1
fi

if [ "${SKIP_UPDATE}" -eq 0 ]; then
  if ! sudo -u "${TARGET_USER}" env \
    HOME="${TARGET_HOME}" \
    CLAMAV_HOOK_HOME="${TARGET_HOME}" \
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

INSTALL_COMMITTED=1

if [ -n "${OLD_CLI_LINK}" ] &&
   [ "${OLD_CLI_LINK}" != "${CLI_LINK}" ]; then
  if ! remove_managed_cli_link "${OLD_TARGET_USER}" "${OLD_CLI_LINK}"; then
    printf 'Warning: could not remove the previous command link: %s\n' \
      "${OLD_CLI_LINK}" >&2
  fi
fi

printf '\nClamAV-Hook installed for %s (%s).\n' "${TARGET_USER}" "${TARGET_HOME}"
printf 'Runtime privilege:  %s (never root)\n' "${TARGET_USER}"
printf 'Configure Discord:  clamav-hook configure-webhook\n'
printf 'Check status:       clamav-hook status\n'
