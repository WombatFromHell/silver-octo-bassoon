#!/usr/bin/env bash

# nascopy.sh - A wrapper script for rsync that includes common options and .gitignore handling
# This script provides a convenient way to copy files with rsync while automatically
# respecting .gitignore patterns and using sensible default options.

set -euo pipefail

# Global variables
EXCLUDE_FILE=""
RSYNC_FLAGS=("-avhP" "--update" "--omit-dir-times" "--modify-window=1")
POSITIONAL_ARGS=()
PROFILE_VAR=""

# Display usage information
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] <source>... <destination>

A wrapper script for rsync that includes common options and .gitignore handling.

Options:
  --profile <name>  Use a predefined profile from ~/.config/nascopyrc
  Any rsync option can be passed through (e.g., --delete, --progress)
  The script automatically adds: ${RSYNC_FLAGS[*]}

Arguments:
  <sources>      One or more source files/directories to copy
  <destination>  Destination directory

Examples:
  $(basename "$0") myfile.txt /backup/
  $(basename "$0") --delete src/ someuser@somehost:/backup/src/
  $(basename "$0") --profile MYBACKUP

Profile Format (in ~/.config/nascopyrc):
  MYBACKUP=--delete --progress /source/path user@host:/backup/path

Notes:
  - Automatically uses .gitignore in current directory if it exists
  - Remove --dry-run from the script to actually perform the copy
  - All rsync options are supported and passed through
  - Profile definitions are loaded from ~/.config/nascopy/nascopyrc or $XDG_CONFIG_HOME/nascopy/nascopyrc
EOF
}

# Check if .gitignore exists in the current directory
check_gitignore() {
  if [ -f ".gitignore" ]; then
    EXCLUDE_FILE=".gitignore"
    echo "Found .gitignore - will use it for exclusions"
  fi
}

# Parse command line arguments
parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    # Handle help flag
    -h | --help)
      usage
      exit 0
      ;;
    # Handle profile flag
    --profile)
      if [[ -z "${2:-}" ]]; then
        echo "Error: --profile requires a profile name" >&2
        usage >&2
        exit 1
      fi
      PROFILE_VAR="$2"
      shift 2
      ;;
    # Handle flags that start with - or --
    -*)
      RSYNC_FLAGS+=("$1")
      shift
      ;;
    # Handle positional arguments (sources and destination)
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
    esac
  done
}

# Get the profile configuration file path
get_profile_file() {
  if [ -n "${XDG_CONFIG_HOME:-}" ]; then
    echo "${XDG_CONFIG_HOME}/nascopyrc"
  else
    echo "${HOME}/.config/nascopyrc"
  fi
}

# Parse profile file and extract the specified profile
parse_profile() {
  local profile_name="$1"
  local profile_file
  profile_file="$(get_profile_file)"

  # Check if profile file exists
  if [ ! -f "$profile_file" ]; then
    echo "Warning: Profile file not found at $profile_file" >&2
    return 1
  fi

  # Look for the profile definition (skip comments and empty lines)
  local profile_line
  profile_line=$(grep -E "^${profile_name}=" "$profile_file" | grep -v '^#' | head -1)

  if [ -z "$profile_line" ]; then
    echo "Error: Profile '$profile_name' not found in $profile_file" >&2
    return 1
  fi

  # Extract everything after the '=' sign
  local profile_content
  profile_content="${profile_line#*=}"

  # Trim leading whitespace
  profile_content="${profile_content#"${profile_content%%[![:space:]]*}"}"

  # Trim trailing whitespace
  profile_content="${profile_content%"${profile_content##*[![:space:]]}"}"

  echo "$profile_content"
  return 0
}

# Validate arguments
validate_arguments() {
  if [ ${#POSITIONAL_ARGS[@]} -lt 2 ]; then
    echo "Error: At least one source and a destination are required." >&2
    usage >&2
    exit 1
  fi
}

# Extract sources and destination
extract_paths() {
  # Extract destination (last argument)
  DESTINATION="${POSITIONAL_ARGS[-1]}"
  unset "POSITIONAL_ARGS[${#POSITIONAL_ARGS[@]}-1]"

  # Remaining arguments are sources
  SOURCES=("${POSITIONAL_ARGS[@]}")
}

# Build and execute rsync command
build_and_execute_rsync() {
  local RSYNC_CMD=("rsync" "${RSYNC_FLAGS[@]}")

  # Add exclude file if it exists
  if [ -n "$EXCLUDE_FILE" ]; then
    RSYNC_CMD+=("--exclude-from=$EXCLUDE_FILE")
  fi

  # Add sources and destination
  RSYNC_CMD+=("${SOURCES[@]}" "$DESTINATION")

  echo "Executing: ${RSYNC_CMD[*]}"
  exec "${RSYNC_CMD[@]}"
}

# Expand profile if specified
expand_profile() {
  if [ -n "$PROFILE_VAR" ]; then
    local profile_content
    profile_content=$(parse_profile "$PROFILE_VAR")

    if profile_content=$(parse_profile "$PROFILE_VAR"); then
      echo "Using profile: $PROFILE_VAR"

      # Parse the profile content and prepend to arguments
      # Format: --blah /source /anothersource user@somehost:/target
      # Use eval to properly handle quoted arguments and spaces
      local profile_args
      eval "profile_args=($profile_content)"

      # Prepend profile arguments to POSITIONAL_ARGS
      POSITIONAL_ARGS=("${profile_args[@]}" "${POSITIONAL_ARGS[@]}")

      echo "Expanded arguments: ${POSITIONAL_ARGS[*]}"
    else
      echo "No profile expansion performed" >&2
    fi
  fi
}

# Main execution
main() {
  parse_arguments "$@"
  expand_profile
  validate_arguments
  extract_paths
  check_gitignore
  build_and_execute_rsync
}

# Run main function with all arguments
main "$@"
