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
  - Automatically uses .gitignore in the first source directory if it exists
  - All rsync options are supported and passed through
  - Profile definitions are loaded from \$XDG_CONFIG_HOME/nascopyrc or ~/.config/nascopyrc
EOF
}

# Resolve a path to an absolute path, without requiring it to exist.
# Usage: abs_path <path>
abs_path() {
  local path="$1"
  if command -v realpath &>/dev/null; then
    # Note: no -m here — BSD/macOS realpath doesn't support it (GNU-only).
    # Callers already verify the path exists before calling abs_path.
    realpath "$path"
  else
    case "$path" in
    /*) echo "$path" ;;
    *) echo "$(cd "$(dirname "$path")" && pwd)/$(basename "$path")" ;;
    esac
  fi
}

# Check if .gitignore exists in a source directory
# Usage: check_gitignore <source_directory>
check_gitignore() {
  local source_dir="$1"

  # Skip remote destinations (user@host:/path or host:/path)
  if [[ "$source_dir" == *:* ]]; then
    return 1
  fi

  # Resolve to absolute directory path (strip trailing slash)
  source_dir="${source_dir%/}"

  local gitignore_path="${source_dir}/.gitignore"

  if [ -f "$gitignore_path" ]; then
    EXCLUDE_FILE="$(abs_path "$gitignore_path")"
    echo "Found .gitignore in '${source_dir}' - will use it for exclusions"
    return 0
  fi
  return 1
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
  # Note: negative indices like POSITIONAL_ARGS[-1] require bash 4.3+ and
  # raise "bad array subscript" on bash 3.2 (macOS default), so compute the
  # last index explicitly instead.
  local last_idx=$((${#POSITIONAL_ARGS[@]} - 1))
  DESTINATION="${POSITIONAL_ARGS[$last_idx]}"
  unset "POSITIONAL_ARGS[$last_idx]"

  # Remaining arguments are sources
  SOURCES=("${POSITIONAL_ARGS[@]}")
}

# Build and execute rsync command
build_and_execute_rsync() {
  local has_exclude_from=false

  # Resolve relative --exclude-from paths against the first source directory
  local resolve_dir=""
  if [ ${#SOURCES[@]} -gt 0 ]; then
    resolve_dir="${SOURCES[0]%/}"
    # Skip remote sources
    if [[ "$resolve_dir" == *:* ]]; then
      resolve_dir=""
    fi
  fi

  # Process flags: resolve relative --exclude-from paths to absolute
  local processed_flags=()
  local flag
  for flag in "${RSYNC_FLAGS[@]}"; do
    case "$flag" in
    --exclude-from=*)
      has_exclude_from=true
      local exclude_path="${flag#--exclude-from=}"
      # Resolve relative paths to absolute, skip if file doesn't exist
      if [[ "$exclude_path" != /* ]]; then
        if [ -f "$exclude_path" ]; then
          exclude_path="$(abs_path "$exclude_path")"
        elif [ -n "$resolve_dir" ] && [ -f "${resolve_dir}/${exclude_path}" ]; then
          exclude_path="$(abs_path "${resolve_dir}/${exclude_path}")"
        else
          # File doesn't exist anywhere — skip this flag
          echo "Warning: --exclude-from='${flag#--exclude-from=}' file not found, skipping" >&2
          continue
        fi
      fi
      processed_flags+=("--exclude-from=$exclude_path")
      ;;
    *)
      processed_flags+=("$flag")
      ;;
    esac
  done

  # Auto-add .gitignore if not already specified
  if [ "$has_exclude_from" = false ] && [ -n "$EXCLUDE_FILE" ]; then
    processed_flags+=("--exclude-from=$EXCLUDE_FILE")
  fi

  local rsync_cmd=("rsync" "${processed_flags[@]}" "${SOURCES[@]}" "$DESTINATION")

  echo "Executing: ${rsync_cmd[*]}"
  exec "${rsync_cmd[@]}"
}

# Expand profile if specified
expand_profile() {
  if [ -z "$PROFILE_VAR" ]; then
    return 0
  fi

  local profile_content
  if ! profile_content=$(parse_profile "$PROFILE_VAR"); then
    echo "No profile expansion performed" >&2
    return 0
  fi

  echo "Using profile: $PROFILE_VAR"

  # Parse the profile content and split into rsync flags and positional args
  # Format: --blah /source /anothersource user@somehost:/target
  # ponytail: eval is used to honor quoting/tilde-expansion in profile entries.
  # nascopyrc is a trusted, user-owned local config file, not external input.
  local profile_args
  eval "profile_args=($profile_content)"

  local profile_flags=()
  local profile_paths=()
  local arg
  for arg in "${profile_args[@]-}"; do
    [ -z "$arg" ] && continue
    case "$arg" in
    -*)
      profile_flags+=("$arg")
      ;;
    *)
      profile_paths+=("$arg")
      ;;
    esac
  done

  # Prepend profile flags to RSYNC_FLAGS
  if [ ${#profile_flags[@]} -gt 0 ]; then
    RSYNC_FLAGS=("${profile_flags[@]}" "${RSYNC_FLAGS[@]}")
  fi

  # Prepend profile paths to POSITIONAL_ARGS
  # Note: POSITIONAL_ARGS may be empty here (e.g. `--profile X` with no other
  # args). On bash 3.2 (macOS default) "${arr[@]}" on an empty array trips
  # `set -u`'s unbound-variable check, but "${arr[@]-}" is NOT a safe fix:
  # when the array is truly empty, bash 3.2 substitutes the default as one
  # literal (empty-string) word instead of zero words, injecting a phantom
  # positional arg. Check length explicitly instead.
  if [ ${#profile_paths[@]} -gt 0 ]; then
    if [ ${#POSITIONAL_ARGS[@]} -gt 0 ]; then
      POSITIONAL_ARGS=("${profile_paths[@]}" "${POSITIONAL_ARGS[@]}")
    else
      POSITIONAL_ARGS=("${profile_paths[@]}")
    fi
  fi
}

# Main execution
main() {
  parse_arguments "$@"
  expand_profile
  validate_arguments
  extract_paths
  check_gitignore "${SOURCES[0]}" || true
  build_and_execute_rsync
}

# Run main function with all arguments
main "$@"
