#!/usr/bin/env bash

set -euo pipefail
IFS=$'\n\t'

# Configuration
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
readonly LOG_DIR="${HOME}/.local/share/logs"
readonly LOG_FILE="${LOG_DIR}/topgrade.log"
readonly MAX_LOG_SIZE=$((1024 * 1024)) # 1MB
readonly MAX_ROTATED_LOGS=5

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

# Get file size in bytes (cross-platform)
get_file_size() {
  local file
  file="${1}"

  if [[ ! -f "${file}" ]]; then
    echo 0
    return 0
  fi

  # Try GNU stat first, then BSD stat
  if stat -c%s "${file}" 2>/dev/null; then
    return 0
  elif stat -f%z "${file}" 2>/dev/null; then
    return 0
  else
    echo 0
    return 0
  fi
}

# Rotate logs if needed
rotate_logs() {
  local log_file
  local max_size
  local max_rotations
  local current_size
  local old_log
  local new_log

  log_file="${1}"
  max_size="${2}"
  max_rotations="${3}"

  # Check if log file exists and exceeds max size
  if [[ ! -f "${log_file}" ]]; then
    return 0
  fi

  current_size=$(get_file_size "${log_file}")

  if ((current_size < max_size)); then
    return 0
  fi

  # Rotate existing logs (from oldest to newest)
  for ((i = max_rotations - 1; i >= 1; i--)); do
    old_log="${log_file}.${i}"
    new_log="${log_file}.$((i + 1))}"

    if [[ -f "${old_log}" ]]; then
      if ! mv "${old_log}" "${new_log}"; then
        warn "Failed to rotate ${old_log} to ${new_log}"
      fi
    fi
  done

  # Move current log to .1
  if ! mv "${log_file}" "${log_file}.1"; then
    warn "Failed to rotate current log file"
    return 1
  fi

  # Compress old rotated logs in background
  compress_old_logs "${log_file}" "${max_rotations}" &

  return 0
}

# Compress rotated logs (runs in background)
compress_old_logs() {
  local log_file
  local max_rotations
  local rotated_log

  log_file="${1}"
  max_rotations="${2}"

  # Compress uncompressed rotated logs
  for ((i = 2; i <= max_rotations; i++)); do
    rotated_log="${log_file}.${i}"

    if [[ -f "${rotated_log}" && ! -f "${rotated_log}.gz" ]]; then
      if gzip -f "${rotated_log}" 2>/dev/null; then
        : # Success
      else
        warn "Failed to compress ${rotated_log}"
      fi
    fi
  done

  # Remove logs beyond max rotation
  for ((i = max_rotations + 1; i <= max_rotations + 10; i++)); do
    rm -f "${log_file}.${i}" "${log_file}.${i}.gz" 2>/dev/null || true
  done
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

  # Rotate logs if needed
  rotate_logs "${LOG_FILE}" "${MAX_LOG_SIZE}" "${MAX_ROTATED_LOGS}" || true

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
