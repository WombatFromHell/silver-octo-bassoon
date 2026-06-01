#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Configuration
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly LOG_DIR="${HOME}/.local/share/logs"
readonly LOG_FILE="${LOG_DIR}/topgrade.log"

# Print error message to stderr
error() {
  echo "${SCRIPT_NAME}: error: $*" >&2
}

# Print warning message to stderr
warn() {
  echo "${SCRIPT_NAME}: warning: $*" >&2
}

# Find topgrade binary in PATH
find_topgrade() {
  local topgrade_path

  if topgrade_path=$(command -v topgrade 2>/dev/null); then
    echo "${topgrade_path}"
    return 0
  else
    return 1
  fi
}

# Verify topgrade is available
check_topgrade() {
  local topgrade_path

  if topgrade_path=$(find_topgrade); then
    echo "${topgrade_path}"
    return 0
  else
    error "topgrade binary not found in PATH"
    error "Install topgrade or ensure it's in your PATH"
    return 1
  fi
}

# Check if config file exists
check_config() {
  local config_file
  config_file="${1}"

  if [[ ! -f "${config_file}" ]]; then
    warn "Config file not found: ${config_file}"
    warn "topgrade will use default configuration"
    return 1
  fi

  return 0
}

# Ensure log directory exists
setup_logging() {
  if ! mkdir -p "${LOG_DIR}"; then
    error "Failed to create log directory: ${LOG_DIR}"
    return 1
  fi

  return 0
}

# Move existing log to .last.log before new run
move_existing_log() {
  local log_file="${1}"
  local last_log="${log_file%.*}.last.log"

  if [[ -f "${log_file}" ]]; then
    if ! mv "${log_file}" "${last_log}"; then
      warn "Failed to move existing log ${log_file} to ${last_log}"
      return 1
    fi
  fi

  return 0
}

# Format log entry with timestamp and separator
log_header() {
  local status
  local timestamp

  status="${1}"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

  cat <<-EOF
	╔════════════════════════════════════════════════════════════════════════════╗
	║ Topgrade Run ${status}
	║ Timestamp: ${timestamp}
	╚════════════════════════════════════════════════════════════════════════════╝
	EOF
}

log_footer() {
  local exit_code
  local duration
  local timestamp
  local status_message

  exit_code="${1}"
  duration="${2}"
  timestamp=$(date '+%Y-%m-%d %H:%M:%S %Z')

  if ((exit_code == 0)); then
    status_message="SUCCESS"
  else
    status_message="FAILED (exit code: ${exit_code})"
  fi

  cat <<-EOF
	╔════════════════════════════════════════════════════════════════════════════╗
	║ Topgrade Run ${status_message}
	║ Duration: ${duration}
	║ Timestamp: ${timestamp}
	╚════════════════════════════════════════════════════════════════════════════╝
	
	EOF
}

# Format duration in human-readable form
format_duration() {
  local seconds

  seconds="${1}"

  if ((seconds < 60)); then
    echo "${seconds}s"
  elif ((seconds < 3600)); then
    echo "$((seconds / 60))m $((seconds % 60))s"
  else
    echo "$((seconds / 3600))h $(((seconds % 3600) / 60))m $((seconds % 60))s"
  fi
}

# Run topgrade with proper error handling
run_topgrade() {
  local topgrade_binary
  local config_file
  local exit_code

  topgrade_binary="${1}"
  config_file="${2}"

  # Run topgrade and capture exit code using modern bash practices
  set +e
  if [[ -f "${config_file}" ]]; then
    "${topgrade_binary}" --config "${config_file}"
  else
    "${topgrade_binary}"
  fi
  exit_code=$?
  set -e

  return "${exit_code}"
}

# Main execution
main() {
  local topgrade_binary
  local config_file
  local exit_code
  local start_time
  local end_time
  local duration
  local formatted_duration
  local temp_exit_file

  # Create a temporary file to store the exit code
  temp_exit_file=$(mktemp)

  # Check if topgrade exists
  if ! topgrade_binary=$(check_topgrade); then
    rm -f "${temp_exit_file}"
    return 1
  fi

  # Setup logging
  if ! setup_logging; then
    rm -f "${temp_exit_file}"
    return 1
  fi

  # Check config (warn but don't fail)
  config_file="${HOME}/.config/topgrade.toml"
  check_config "${config_file}" || true

  # Move existing log to .last.log before new run
  move_existing_log "${LOG_FILE}" || true

  # Capture start time
  start_time=$(date +%s)

  # Run topgrade with logging to both file and terminal
  # Store exit code in temp file to avoid subshell issues
  {
    log_header "STARTED"

    set +e
    run_topgrade "${topgrade_binary}" "${config_file}"
    exit_code=$?
    set -e

    echo "${exit_code}" >"${temp_exit_file}"

    end_time=$(date +%s)
    duration=$((end_time - start_time))
    formatted_duration=$(format_duration "${duration}")

    log_footer "${exit_code}" "${formatted_duration}"
  } 2>&1 | tee -a "${LOG_FILE}"

  # Read exit code from temp file
  exit_code=$(cat "${temp_exit_file}")
  rm -f "${temp_exit_file}"

  # Exit with the same code as topgrade
  return "${exit_code}"
}

# Execute main function
if ! main "$@"; then
  exit_code=$?
  exit "${exit_code}"
fi
