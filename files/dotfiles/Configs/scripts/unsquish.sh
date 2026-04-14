#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
VERSION="1.4.1"
BASE_UNSQUASHFS_ARGS=(
  -no-xattrs
)

log_info() { echo "[INFO] $*"; }
log_error() { echo "[ERROR] $*" >&2; }

# Global flag: skip checksum verification before extracting (-y)
SKIP_CHECKSUM=0

# Global flag: pipe mode — machine-readable progress to stdout, all else to stderr
PIPE_MODE=0

check_dependencies() {
  if ! command -v unsquashfs &>/dev/null; then
    log_error "'unsquashfs' is not installed!"
    exit 1
  fi
}

list_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  # Accept either the archive or its checksum as input
  local archive_abs
  if [[ $input_abs == *.sha256 ]]; then
    archive_abs="${input_abs%.sha256}"
  else
    archive_abs="$input_abs"
  fi

  if [[ ! -f $archive_abs ]]; then
    log_error "Archive file not found: '$archive_abs'"
    exit 1
  fi

  log_info "Listing contents of '$(basename "$archive_abs")'..."
  unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}" -d "" -llc "$archive_abs"
}

check_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  # Derive archive and checksum paths regardless of which was passed
  local archive_abs checksum_abs
  if [[ $input_abs == *.sha256 ]]; then
    checksum_abs="$input_abs"
    archive_abs="${input_abs%.sha256}"
  else
    archive_abs="$input_abs"
    checksum_abs="${input_abs}.sha256"
  fi

  if [[ ! -f $archive_abs ]]; then
    log_error "Archive file not found: '$archive_abs'"
    return 1
  fi

  if [[ ! -f $checksum_abs ]]; then
    log_error "No paired checksum file found: '$checksum_abs'"
    return 1
  fi

  local target_dir target_basename checksum_file
  target_dir="$(dirname "$archive_abs")"
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log_info "Verifying '$target_basename' against '$checksum_file'..."

  pushd "$target_dir" >/dev/null
  sha256sum -c "$checksum_file"
  local exit_code=$?
  popd >/dev/null

  if [[ $exit_code -ne 0 ]]; then
    log_error "Checksum verification FAILED for '$target_basename'."
    return "$exit_code"
  fi

  log_info "Checksum verification passed for '$target_basename'."
}

parse_arguments() {
  INPUT_FILE=""
  OUTPUT_DIR=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -y | --yes)
        SKIP_CHECKSUM=1
        shift
        ;;
      -o | --output)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          OUTPUT_DIR="$2"
          shift
        else
          log_error "Argument for $1 is missing or invalid."
          exit 1
        fi
        shift
        ;;
      --check)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          check_archive "$2"
          exit 0
        else
          log_error "Argument for $1 is missing or invalid."
          exit 1
        fi
        ;;
      --list | --ls)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          list_archive "$2"
          exit 0
        else
          log_error "Argument for $1 is missing or invalid."
          exit 1
        fi
        ;;
      -h | --help)
        echo "SquashFS Extractor (unsquish) v${VERSION}"
        echo ""
        echo "Usage:"
        echo "  $SCRIPT_NAME <archive.sqsh> [-o output_dir] [-y]   Extract archive"
        echo "  $SCRIPT_NAME --check <archive_file>                Verify archive integrity"
        echo "  $SCRIPT_NAME --list <archive_file>                 List archive contents"
        echo ""
        echo "Options:"
        echo "  -o, --output <dir>     Specify extraction directory (default: archive stem)"
        echo "  -y, --yes              Skip checksum verification errors"
        echo "  --pipe                 Machine-readable mode: percentages to stdout, logs to stderr"
        echo "  -h, --help             Show this help message"
        exit 0
        ;;
      --pipe)
        PIPE_MODE=1
        shift
        ;;
      *)
        if [[ -n $INPUT_FILE ]]; then
          log_error "Unexpected argument: '$1'. Only one archive file may be specified."
          exit 1
        fi
        INPUT_FILE="$(realpath "$1")"
        shift
        ;;
    esac
  done

  if [[ -z $INPUT_FILE ]]; then
    log_error "No archive file specified."
    echo "Usage: $SCRIPT_NAME <archive.sqsh> [-o output_dir] [-y]"
    echo "       $SCRIPT_NAME --check <archive_file>"
    echo "       $SCRIPT_NAME --list  <archive_file>"
    exit 1
  fi

  if [[ ! -f $INPUT_FILE ]]; then
    log_error "Archive file not found: '$INPUT_FILE'"
    exit 1
  fi
}

determine_output_dir() {
  if [[ -z $OUTPUT_DIR ]]; then
    # Strip known extensions to derive a sensible directory name
    local basename
    basename="$(basename "$INPUT_FILE")"
    basename="${basename%.sqsh}"
    basename="${basename%.squashfs}"
    OUTPUT_DIR="$(dirname "$INPUT_FILE")/${basename}"
    log_info "No output directory specified; auto-detected: '$OUTPUT_DIR'"
  fi

  OUTPUT_DIR="$(realpath -m "$OUTPUT_DIR")"

  if [[ -e $OUTPUT_DIR ]]; then
    if [[ ! -d $OUTPUT_DIR ]]; then
      log_error "Output path exists and is not a directory: '$OUTPUT_DIR'."
      exit 1
    fi
    if [[ -n "$(ls -A "$OUTPUT_DIR")" ]]; then
      log_error "Output directory already exists and is not empty: '$OUTPUT_DIR'. Refusing to overwrite."
      exit 1
    fi
  fi

  log_info "Output directory: '$OUTPUT_DIR'"
}

# Shared pipeline used by both GUI modes: runs unsquashfs, tees non-integer
# output to the console, and feeds bare integers to the caller's progress dialog.
_run_unsquashfs_gui() {
  local fifo="$1"
  local status_file="$2"
  local target_dir="$3"

  (
    unsquashfs \
      "${BASE_UNSQUASHFS_ARGS[@]}" \
      -percentage \
      -d "$target_dir" \
      "$INPUT_FILE" 2>&1
    echo "$?" >"$status_file"
  ) | tee >(grep -v -E '^[0-9]+$' >/dev/tty) \
    | grep --line-buffered -E '^[0-9]+$' >"$fifo" &

  UNSQ_PIPE_PID=$!
}

_extract_with_dialog() {
  local target_dir="$1"
  shift
  local dialog_cmd=("$@")

  local unsq_status_file fifo
  unsq_status_file=$(mktemp)
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  _run_unsquashfs_gui "$fifo" "$unsq_status_file" "$target_dir"

  "${dialog_cmd[@]}" <"$fifo"
  local dialog_exit=$?

  if [[ $dialog_exit -ne 0 ]]; then
    # User cancelled — kill the entire pipeline process group
    kill -- -"$UNSQ_PIPE_PID" 2>/dev/null || true
    wait "$UNSQ_PIPE_PID" 2>/dev/null || true
    rm -f "$unsq_status_file" "$fifo"
    return "$dialog_exit"
  fi

  wait "$UNSQ_PIPE_PID"
  local unsq_exit
  unsq_exit=$(cat "$unsq_status_file")
  rm -f "$unsq_status_file" "$fifo"

  [[ $unsq_exit -ne 0 ]] && return "$unsq_exit"
  return 0
}

extract_with_yad() {
  local target_dir="$1"
  _extract_with_dialog "$target_dir" \
    yad --progress \
    --title="SquashFS Extraction" \
    --text="Extracting to ${target_dir}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill \
    --center \
    --width=450 \
    --borders=15 \
    --bar-style=normal
}

extract_with_zenity() {
  local target_dir="$1"
  _extract_with_dialog "$target_dir" \
    zenity --progress \
    --title="SquashFS Extraction" \
    --text="Extracting to ${target_dir}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill
}

extract_cli() {
  local target_dir="$1"

  unsquashfs \
    "${BASE_UNSQUASHFS_ARGS[@]}" \
    -d "$target_dir" \
    "$INPUT_FILE"
}

# Pipe mode: emit bare integer percentages to stdout, all other output to stderr.
# Designed for embedding in tools like Yazi that parse stdout for progress.
extract_pipe() {
  local target_dir="$1"

  local unsq_status_file
  unsq_status_file=$(mktemp)

  (
    unsquashfs \
      "${BASE_UNSQUASHFS_ARGS[@]}" \
      -percentage \
      -d "$target_dir" \
      "$INPUT_FILE" 2>&1 \
      | awk '/[0-9]+%/ { gsub(/[^0-9]/, ""); print; fflush() }'
    echo "$?" >"$unsq_status_file"
  ) &
  local unsq_pid=$!

  wait "$unsq_pid"
  local unsq_exit
  unsq_exit=$(cat "$unsq_status_file" 2>/dev/null || echo "1")
  rm -f "$unsq_status_file"

  return "$unsq_exit"
}

main() {
  check_dependencies
  parse_arguments "$@"

  # In pipe mode, override all log functions to stderr before any other code runs.
  # This prevents log_info from leaking to stdout and corrupting the percentage stream.
  if [[ $PIPE_MODE -eq 1 ]]; then
    log_info()  { echo "[INFO] $*"  >&2; }
    log_error() { echo "[ERROR] $*" >&2; }

    # Suppress all stderr for the entire script so nothing leaks into the
    # caller's terminal (e.g. Yazi's TUI). We only want bare integers on
    # stdout; real errors are reported via the exit code.
    exec 2>/dev/null
  fi

  determine_output_dir

  # Verify checksum before extracting; -y skips hard failure but still warns
  if ! check_archive "$INPUT_FILE"; then
    if [[ $SKIP_CHECKSUM -eq 1 ]]; then
      log_info "Checksum verification failed but -y was passed; continuing anyway." >&2
    else
      exit 1
    fi
  fi

  # In pipe mode, skip GUI detection entirely — designed for TUI/embedded use.
  if [[ $PIPE_MODE -eq 1 ]]; then
    local exit_code=0
    extract_pipe "$OUTPUT_DIR" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      log_error "Extraction failed or was cancelled (exit code: $exit_code)." >&2
      [[ -d $OUTPUT_DIR ]] && rm -rf "$OUTPUT_DIR"
      exit "$exit_code"
    fi

    log_info "Successfully extracted '$INPUT_FILE' to '$OUTPUT_DIR'." >&2
    echo "100"
    exit 0
  fi

  local exit_code=0

  if command -v yad &>/dev/null; then
    log_info "Starting extraction with YAD UI..."
    extract_with_yad "$OUTPUT_DIR" || exit_code=$?
  elif command -v zenity &>/dev/null; then
    log_info "Starting extraction with Zenity UI..."
    extract_with_zenity "$OUTPUT_DIR" || exit_code=$?
  else
    log_info "No GUI available. Falling back to CLI output..."
    extract_cli "$OUTPUT_DIR" || exit_code=$?
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_error "Extraction failed or was cancelled (exit code: $exit_code)."
    [[ -d $OUTPUT_DIR ]] && rm -rf "$OUTPUT_DIR"
    exit "$exit_code"
  fi

  log_info "Successfully extracted '$INPUT_FILE' to '$OUTPUT_DIR'."
}

main "$@"
