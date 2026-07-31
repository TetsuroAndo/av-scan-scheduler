#!/bin/bash
set -eu
umask 077

PATH=/usr/bin:/bin:/usr/sbin:/sbin

LABEL="io.github.tetsuroando.av-scan-scheduler"
SYSTEM_PARENT="/Library/Application Support"
SYSTEM_BASE="/Library/Application Support/AV Scan Scheduler"
RUNNER="${SYSTEM_BASE}/libexec/av-scan-scheduler"
CLI="${SYSTEM_BASE}/bin/av-scan-scheduler"
WEBHOOK_HELPER="${SYSTEM_BASE}/libexec/av-scan-scheduler-configure-webhook"
LAUNCHD_DIR="/Library/LaunchDaemons"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
PURGE=0
SHOW_HELP=0

target_home=""
target_user=""
target_uid=""
cli_link=""

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
    die "Refusing path with a symbolic-link component: $1" 73
  fi
}

assert_root_owned_directory() {
  local path="$1"
  local required="${2:-0}"
  local mode

  assert_no_symlink_components "${path}"
  if [ ! -e "${path}" ]; then
    if [ "${required}" -eq 1 ]; then
      die "Required system directory is missing: ${path}" 73
    fi
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
  assert_root_owned_directory "/Library" 1
  assert_root_owned_directory "${SYSTEM_PARENT}" 1
  assert_root_owned_directory "${LAUNCHD_DIR}" 1
  assert_root_owned_directory "${SYSTEM_BASE}"
  assert_root_owned_directory "${SYSTEM_BASE}/bin"
  assert_root_owned_directory "${SYSTEM_BASE}/libexec"
  assert_root_owned_file_or_missing "${RUNNER}"
  assert_root_owned_file_or_missing "${CLI}"
  assert_root_owned_file_or_missing "${WEBHOOK_HELPER}"
  assert_root_owned_file_or_missing "${PLIST}"
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
      printf 'Could not stop the launchd job: %s\n' "${LABEL}" >&2
      return 1
    fi
  fi

  while job_is_loaded && [ "${attempts}" -lt 5 ]; do
    sleep 1
    attempts=$((attempts + 1))
  done
  if job_is_loaded; then
    printf 'The launchd job is still loaded: %s\n' "${LABEL}" >&2
    return 1
  fi
}

usage() {
  cat <<'EOF'
Usage: ./uninstall.sh [--purge]

By default, user-owned configuration, signatures, logs, and run history are
preserved. Use --purge to remove those data directories as well.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --purge)
      if [ "${PURGE}" -eq 1 ]; then
        die 'Duplicate option: --purge' 64
      fi
      PURGE=1
      ;;
    -h|--help)
      SHOW_HELP=1
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 64
      ;;
  esac
  shift
done

if [ "${SHOW_HELP}" -eq 1 ]; then
  usage
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  if [ "${PURGE}" -eq 1 ]; then
    exec sudo "$0" --purge
  else
    exec sudo "$0"
  fi
fi

validate_system_paths

if [ -f "${PLIST}" ]; then
  target_home="$(plutil -extract EnvironmentVariables.AV_SCAN_SCHEDULER_HOME raw -o - "${PLIST}" 2>/dev/null || true)"
  target_user="$(plutil -extract UserName raw -o - "${PLIST}" 2>/dev/null || true)"
  target_uid="$(plutil -extract EnvironmentVariables.AV_SCAN_SCHEDULER_UID raw -o - "${PLIST}" 2>/dev/null || true)"
  cli_link="$(plutil -extract EnvironmentVariables.AV_SCAN_SCHEDULER_CLI_LINK raw -o - "${PLIST}" 2>/dev/null || true)"
fi

if [ "${PURGE}" -eq 1 ]; then
  valid_user_name "${target_user}" ||
    die "Purge refused because the installed user is invalid: ${target_user:-unknown}" 70
  case "${target_uid}" in
    ''|*[!0-9]*)
      die "Purge refused because the installed UID is invalid: ${target_uid:-unknown}" 70
      ;;
  esac
  case "${target_home}" in
    /Users/*) ;;
    *)
      die "Purge refused because the installed home is unexpected: ${target_home:-unknown}" 70
      ;;
  esac

  resolved_uid="$(id -u "${target_user}" 2>/dev/null || true)"
  resolved_home="$(
    dscacheutil -q user -a name "${target_user}" |
      awk -F': ' '$1 == "dir" { print $2; exit }'
  )"
  if [ "${resolved_uid}" != "${target_uid}" ]; then
    die "Purge refused: UID for ${target_user} no longer matches the installed UID." 70
  fi
  if [ "${resolved_home}" != "${target_home}" ]; then
    die "Purge refused: home for ${target_user} no longer matches the installed home." 70
  fi
  if [ ! -d "${target_home}" ]; then
    die "Purge refused because the installed home is missing: ${target_home}" 70
  fi

  canonical_home="$(cd "${target_home}" 2>/dev/null && pwd -P)"
  if [ "${canonical_home}" != "${target_home}" ]; then
    die "Purge refused for non-canonical or symbolic-link home: ${target_home}" 70
  fi

  data_dir="${target_home}/Library/Application Support/AV Scan Scheduler"
  log_dir="${target_home}/Library/Logs/AV Scan Scheduler"
  for purge_path in \
    "${target_home}" \
    "${target_home}/Library" \
    "${target_home}/Library/Application Support" \
    "${target_home}/Library/Logs" \
    "${data_dir}" \
    "${log_dir}"; do
    if path_has_symlink_component "${purge_path}"; then
      die "Purge refused for path with a symbolic-link component: ${purge_path}" 70
    fi
  done

  for purge_dir in "${data_dir}" "${log_dir}"; do
    if [ -e "${purge_dir}" ]; then
      if [ ! -d "${purge_dir}" ]; then
        die "Purge refused for non-directory data path: ${purge_dir}" 70
      fi
      if [ "$(stat -f '%u' "${purge_dir}")" != "${target_uid}" ]; then
        die "Purge refused for data not owned by ${target_user}: ${purge_dir}" 70
      fi
    fi
  done
fi

stop_job_and_verify ||
  die "Refusing to remove files while ${LABEL} may still be running." 70
launchctl disable "system/${LABEL}" >/dev/null 2>&1 || true

if valid_user_name "${target_user}" &&
   id -u "${target_user}" >/dev/null 2>&1 &&
   [ -L "${cli_link}" ] &&
   [ "$(readlink "${cli_link}")" = "${CLI}" ]; then
  sudo -u "${target_user}" rm -f "${cli_link}"
fi

validate_system_paths
rm -f \
  "${PLIST}" \
  "${CLI}" \
  "${RUNNER}" \
  "${WEBHOOK_HELPER}"
rmdir "${SYSTEM_BASE}/bin" 2>/dev/null || true
rmdir "${SYSTEM_BASE}/libexec" 2>/dev/null || true
rmdir "${SYSTEM_BASE}" 2>/dev/null || true

if [ "${PURGE}" -eq 1 ]; then
  # Recheck immediately before deletion. The removal itself runs with the
  # configured user's privileges, never root privileges.
  for purge_path in "${data_dir}" "${log_dir}"; do
    if path_has_symlink_component "${purge_path}"; then
      die "Purge refused after path changed: ${purge_path}" 70
    fi
  done
  sudo -u "${target_user}" env HOME="${target_home}" \
    rm -rf "${data_dir}" "${log_dir}"
  printf 'AV Scan Scheduler and its local data were removed.\n'
else
  printf 'AV Scan Scheduler was removed. User configuration, signatures, and logs were preserved.\n'
  printf 'Run ./uninstall.sh --purge to remove preserved local data.\n'
fi

printf 'Homebrew and ClamAV were not uninstalled.\n'
