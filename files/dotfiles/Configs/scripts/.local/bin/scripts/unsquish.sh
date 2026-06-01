#!/usr/bin/env bash

set -euo pipefail

#######################################
# CONSTANTS
#######################################

declare -r VERSION="dev"
declare -r SCRIPT_NAME=$(basename "$0")

declare -ra BASE_UNSQUASHFS_ARGS=(
  -no-xattrs
)

#######################################
# GLOBAL STATE
#######################################

declare -i SKIP_CHECKSUM=0
declare -i PIPE_MODE=0
declare INPUT_FILE=""
declare OUTPUT_DIR=""

#######################################
# LOGGING
#######################################

log() {
  local level="$1"
  shift
  if [[ $PIPE_MODE -eq 1 ]]; then
    echo "[${level^^}] $*" >&2
  elif [[ $level == "info" ]]; then
    echo "[INFO] $*"
  else
    echo "[${level^^}] $*" >&2
  fi
}

#######################################
# DEPENDENCIES
#######################################

check_dependencies() {
  if ! command -v unsquashfs &>/dev/null; then
    log error "'unsquashfs' is not installed!"
    exit 1
  fi
}

#######################################
# CHECKSUM OPERATIONS
#######################################

check_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  local archive_abs checksum_abs
  if [[ $input_abs == *.sha256 ]]; then
    checksum_abs="$input_abs"
    archive_abs="${input_abs%.sha256}"
  else
    archive_abs="$input_abs"
    checksum_abs="${input_abs}.sha256"
  fi

  if [[ ! -f $archive_abs ]]; then
    log error "Archive file not found: '$archive_abs'"
    return 1
  fi

  if [[ ! -f $checksum_abs ]]; then
    log error "No paired checksum file found: '$checksum_abs'"
    return 1
  fi

  local target_dir target_basename checksum_file
  target_dir="$(dirname "$archive_abs")"
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log info "Verifying '$target_basename' against '$checksum_file'..."

  local exit_code
  exit_code=$(cd "$target_dir" && sha256sum -c "$checksum_file" >/dev/null 2>&1 && echo 0 || echo $?)

  if [[ $exit_code -ne 0 ]]; then
    log error "Checksum verification FAILED for '$target_basename'."
    return "$exit_code"
  fi

  log info "Checksum verification passed for '$target_basename'."
}

#######################################
# LISTING OPERATIONS
#######################################

list_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  local archive_abs
  if [[ $input_abs == *.sha256 ]]; then
    archive_abs="${input_abs%.sha256}"
  else
    archive_abs="$input_abs"
  fi

  if [[ ! -f $archive_abs ]]; then
    log error "Archive file not found: '$archive_abs'"
    exit 1
  fi

  log info "Listing contents of '$(basename "$archive_abs")'..."
  unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}" -d "" -llc "$archive_abs"
}

#######################################
# EXTRACTION OPERATIONS
#######################################

run_progress_pipeline() {
  local -n _pipe_pid_ref=$1
  shift
  local fifo="$1"
  shift
  local status_file="$1"
  shift
  local target="$1"
  shift
  local cmd=("$@")

  (
    "${cmd[@]}" "${BASE_UNSQUASHFS_ARGS[@]}" -percentage -d "$target" "$INPUT_FILE" 2>&1
    echo "$?" >"$status_file"
  ) | tee >(grep -v -E '^[0-9]+$' >/dev/tty) | grep --line-buffered -E '^[0-9]+$' >"$fifo" &

  _pipe_pid_ref=$!
}

run_with_dialog() {
  local target="$1"
  shift
  local dialog_cmd=("$@")

  local status_file fifo pipe_pid
  status_file=$(mktemp)
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  run_progress_pipeline pipe_pid "$fifo" "$status_file" "$target" unsquashfs

  "${dialog_cmd[@]}" <"$fifo"
  local dialog_exit=$?

  if [[ $dialog_exit -ne 0 ]]; then
    kill -- -"$pipe_pid" 2>/dev/null || true
    wait "$pipe_pid" 2>/dev/null || true
    rm -f "$status_file" "$fifo"
    return "$dialog_exit"
  fi

  wait "$pipe_pid"
  local cmd_exit
  cmd_exit=$(cat "$status_file")
  rm -f "$status_file" "$fifo"

  [[ $cmd_exit -ne 0 ]] && return "$cmd_exit"
  return 0
}

extract_with_yad() {
  local target="$1"
  run_with_dialog "$target" \
    yad --progress \
    --title="SquashFS Extraction" \
    --text="Extracting to ${target}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill \
    --center \
    --width=450 \
    --borders=15 \
    --bar-style=normal
}

extract_with_zenity() {
  local target="$1"
  run_with_dialog "$target" \
    zenity --progress \
    --title="SquashFS Extraction" \
    --text="Extracting to ${target}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill
}

extract_cli() {
  local target="$1"
  unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}" -d "$target" "$INPUT_FILE"
}

extract_pipe() {
  local target="$1"
  unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}" -percentage -d "$target" "$INPUT_FILE" 2>&1 |
    awk '/^[0-9]+$/{print; fflush(); next} {print > "/dev/stderr"}'
}

#######################################
# OUTPUT DIRECTORY RESOLUTION
#######################################

determine_output_dir() {
  if [[ -z $OUTPUT_DIR ]]; then
    local basename
    basename="$(basename "$INPUT_FILE")"
    basename="${basename%.sqsh}"
    basename="${basename%.squashfs}"
    OUTPUT_DIR="$(dirname "$INPUT_FILE")/${basename}"
    log info "No output directory specified; auto-detected: '$OUTPUT_DIR'"
  fi

  OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

  if [[ -e $OUTPUT_DIR ]]; then
    if [[ ! -d $OUTPUT_DIR ]]; then
      log error "Output path exists and is not a directory: '$OUTPUT_DIR'."
      exit 1
    fi
    if [[ -n "$(ls -A "$OUTPUT_DIR" 2>/dev/null)" ]]; then
      log error "Output directory already exists and is not empty: '$OUTPUT_DIR'. Refusing to overwrite."
      exit 1
    fi
  fi

  log info "Output directory: '$OUTPUT_DIR'"
}

#######################################
# ARGUMENT PARSING
#######################################

pre_scan_pipe_mode() {
  local arg
  for arg in "$@"; do
    if [[ $arg == "--pipe" ]]; then
      PIPE_MODE=1
      return 0
    fi
  done
  return 0
}

parse_arguments() {
  pre_scan_pipe_mode "$@"

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -y | --yes)
      SKIP_CHECKSUM=1
      shift
      ;;
    --pipe)
      shift
      ;;
    -o | --output)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        OUTPUT_DIR="$2"
        shift 2
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    --check)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        check_archive "$2"
        exit $?
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    --list | --ls)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        list_archive "$2"
        exit 0
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    -h | --help)
      echo "SquashFS Extractor (unsquish) v${VERSION}"
      echo ""
      echo "Usage:"
      echo "  $SCRIPT_NAME <archive.sqsh> [-o output_dir] [-y]  Extract archive"
      echo "  $SCRIPT_NAME --check <archive_file>              Verify archive integrity"
      echo "  $SCRIPT_NAME --list <archive_file>               List archive contents"
      echo ""
      echo "Options:"
      echo "  -o, --output <dir>    Specify extraction directory (default: archive stem)"
      echo "  -y, --yes             Skip checksum verification errors"
      echo "  --pipe                Machine-readable mode: percentages to stdout, logs to stderr"
      echo "  -h, --help            Show this help message"
      exit 0
      ;;
    *)
      if [[ -n $INPUT_FILE ]]; then
        log error "Unexpected argument: '$1'. Only one archive file may be specified."
        exit 1
      fi
      INPUT_FILE="$(realpath "$1")"
      shift
      ;;
    esac
  done

  if [[ -z $INPUT_FILE ]]; then
    log error "No archive file specified."
    echo "Usage: $SCRIPT_NAME <archive.sqsh> [-o output_dir] [-y]"
    echo "       $SCRIPT_NAME --check <archive_file>"
    echo "       $SCRIPT_NAME --list <archive_file>"
    exit 1
  fi

  if [[ ! -f $INPUT_FILE ]]; then
    log error "Archive file not found: '$INPUT_FILE'"
    exit 1
  fi
}

#######################################
# MAIN
#######################################

main() {
  check_dependencies
  parse_arguments "$@"
  determine_output_dir

  if ! check_archive "$INPUT_FILE"; then
    if [[ $SKIP_CHECKSUM -eq 1 ]]; then
      log info "Checksum verification failed but -y was passed; continuing anyway."
    else
      exit 1
    fi
  fi

  local exit_code=0

  if [[ $PIPE_MODE -eq 1 ]]; then
    extract_pipe "$OUTPUT_DIR" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      log error "Extraction failed (exit code: $exit_code)."
      [[ -d $OUTPUT_DIR ]] && rm -rf "$OUTPUT_DIR"
      exit "$exit_code"
    fi

    log info "Successfully extracted '$INPUT_FILE' to '$OUTPUT_DIR'."
    exit 0
  fi

  if command -v yad &>/dev/null; then
    log info "Starting extraction with YAD UI..."
    extract_with_yad "$OUTPUT_DIR" || exit_code=$?
  elif command -v zenity &>/dev/null; then
    log info "Starting extraction with Zenity UI..."
    extract_with_zenity "$OUTPUT_DIR" || exit_code=$?
  else
    log info "No GUI available. Falling back to CLI output..."
    extract_cli "$OUTPUT_DIR" || exit_code=$?
  fi

  if [[ $exit_code -ne 0 ]]; then
    log error "Extraction failed or was cancelled (exit code: $exit_code)."
    [[ -d $OUTPUT_DIR ]] && rm -rf "$OUTPUT_DIR"
    exit "$exit_code"
  fi

  log info "Successfully extracted '$INPUT_FILE' to '$OUTPUT_DIR'."
}

main "$@"
