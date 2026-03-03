#!/usr/bin/env bash
set -euo pipefail

readonly CONTAINER_NAME="bravebox"
readonly BROWSER_BINARYS=("brave-browser-beta" "brave-browser")
readonly LAUNCHER_SCRIPT="${HOME}/.local/bin/scripts/chrome_with_flags.py"
readonly NOTIFICATION_APP_NAME="bravebox-wrapper"

in_container() {
  [[ -n "${CONTAINER_ID:-}" ]] && return 0
  [[ -f /run/.containerenv ]] && return 0
  [[ -f /.dockerenv ]] && return 0
  grep -q container /proc/1/cgroup 2>/dev/null && return 0
  return 1
}

detect_browser() {
  local binary
  for binary in "${BROWSER_BINARYS[@]}"; do
    if command -v "${binary}" &>/dev/null; then
      printf '%s\n' "${binary}"
      return 0
    fi
  done
  return 1
}

is_process_running() {
  local process_name="$1"
  pgrep -x "${process_name}" &>/dev/null
}

send_notification() {
  local title="$1"
  local message="$2"

  if command -v notify-send &>/dev/null; then
    notify-send -a "${NOTIFICATION_APP_NAME}" "${title}" "${message}" 2>/dev/null && return 0
  fi

  gdbus call --session \
    --dest org.freedesktop.Notifications \
    --object-path /org/freedesktop/Notifications \
    --method org.freedesktop.Notifications.Notify \
    "${NOTIFICATION_APP_NAME}" \
    uint32:0 \
    string:"" \
    string:"${title}" \
    string:"${message}" \
    array:{} \
    array:{} \
    int32:-1 \
    &>/dev/null
}

upgrade_package() {
  local package="$1"
  local output
  output="$(sudo dnf upgrade -y "${package}" 2>&1)"
  local exit_code=$?

  # Check if any packages were actually upgraded
  if echo "${output}" | grep -qE "^(Upgrading|Installing|Removing): "; then
    echo "${output}"
    return 0 # Packages were upgraded
  elif echo "${output}" | grep -qE "^Nothing to do\.$|No packages marked for update"; then
    echo "${output}"
    return 2 # No upgrades needed
  else
    echo "${output}"
    return ${exit_code} # Other result (possibly error)
  fi
}

main() {
  # If not in container, enter once and run everything inside
  if ! in_container; then
    exec distrobox-enter -n "${CONTAINER_NAME}" -- "$0" "$@"
  fi

  # Inside container: detect browser and proceed
  local pkgname
  pkgname="$(detect_browser)" || {
    echo "Error: 'brave-browser-beta' or 'brave-browser' not found in PATH!" >&2
    exit 1
  }

  if is_process_running "${pkgname}"; then
    send_notification "Browser Running" "${pkgname} is currently running. Please close it before upgrading."
    echo "Error: ${pkgname} is currently running. Please close it before upgrading." >&2
    exit 1
  fi

  local upgrade_result=0
  upgrade_package "${pkgname}" || upgrade_result=$?

  case ${upgrade_result} in
  0)
    send_notification "Upgrade Complete" "${pkgname} has been successfully upgraded."
    ;;
  2)
    # No upgrades needed
    ;;
  *)
    send_notification "Upgrade Failed" "Failed to upgrade ${pkgname}."
    echo "Error: something went wrong when upgrading '${pkgname}'!" >&2
    exit 1
    ;;
  esac

  exec "${LAUNCHER_SCRIPT}" "${pkgname}" "$@"
}

main "$@"
