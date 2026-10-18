#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$(realpath -- "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=src/squish-common.sh
source "${SCRIPT_DIR}/squish-common.sh"

#######################################
# CONSTANTS
#######################################

declare -r VERSION="dev"
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

declare -ra BASE_UNSQUASHFS_ARGS=(
  -no-xattrs
)

#######################################
# GLOBAL STATE
#######################################

declare -i IGNORE_CHECKSUM=0
declare -i PIPE_MODE=0
declare INPUT_FILE=""
declare OUTPUT_DIR=""

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
# LISTING OPERATIONS
#######################################

list_archive() {
  local input="$1"
  resolve_checksum_pair "$input"
  require_existing_archive "$ARCHIVE_ABS" || exit 1

  log info "Listing contents of '$(basename "$ARCHIVE_ABS")'..."
  unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}" -d "" -llc "$ARCHIVE_ABS"
}

#######################################
# EXTRACTION OPERATIONS
#######################################

# Usage: extract_backend_args
# Sets BACKEND_ARGS to the unsquashfs argv for this RENDERER. Only the
# percentage flag differs per renderer, and it has to precede -d and the
# archive: unsquashfs reads its positional arguments after the archive as
# files to extract.
extract_backend_args() {
  BACKEND_ARGS=(unsquashfs "${BASE_UNSQUASHFS_ARGS[@]}")
  if [[ $RENDERER != cli ]]; then
    BACKEND_ARGS+=(-percentage)
  fi
  BACKEND_ARGS+=(-d "$OUTPUT_DIR" "$INPUT_FILE")
}

#######################################
# OUTPUT DIRECTORY RESOLUTION
#######################################

determine_output_dir() {
  if [[ -z $OUTPUT_DIR ]]; then
    local basename
    basename="$(basename "$INPUT_FILE" .sha256)"
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

parse_arguments() {
  pre_scan_pipe_mode "$@"
  resolve_renderer

  local action="" action_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -y | --yes)
      IGNORE_CHECKSUM=1
      shift
      ;;
    --pipe)
      shift
      ;;
    -o | --output)
      if is_option_value "${2:-}"; then
        OUTPUT_DIR="$2"
        shift 2
      else
        missing_option_value "$1"
      fi
      ;;
    --check)
      action="check"
      if is_option_value "${2:-}"; then
        action_arg="$2"
        shift 2
      else
        shift
      fi
      ;;
    --list | --ls)
      if is_option_value "${2:-}"; then
        list_archive "$2"
        exit 0
      else
        missing_option_value "$1"
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

  if [[ $action == check ]]; then
    if [[ -z $action_arg && -n $INPUT_FILE ]]; then
      action_arg="$INPUT_FILE"
    fi
    if [[ -z $action_arg ]]; then
      missing_option_value "--check"
    fi
    run_check "$action_arg" "SquashFS Extraction"
  fi

  if [[ -z $INPUT_FILE ]]; then
    log error "No archive file specified."
    echo "Usage: $SCRIPT_NAME <archive.sqsh> [-o output_dir] [-y]"
    echo "       $SCRIPT_NAME --check <archive_file>"
    echo "       $SCRIPT_NAME --list <archive_file>"
    exit 1
  fi

  require_existing_archive "$INPUT_FILE" || exit 1
}

#######################################
# MAIN
#######################################

main() {
  parse_arguments "$@"
  check_dependencies
  determine_output_dir

  local exit_code=0 check_rc=0
  check_archive "$INPUT_FILE" "SquashFS Extraction" || check_rc=$?
  if [[ $check_rc -ne 0 ]]; then
    if [[ $IGNORE_CHECKSUM -eq 1 ]]; then
      log info "Checksum verification did not pass but -y was passed; continuing anyway."
    else
      exit $check_rc
    fi
  fi

  extract_backend_args
  if [[ $RENDERER != pipe ]]; then
    log info "Rendering extraction with '$RENDERER'..."
  fi
  show_progress "SquashFS Extraction" "Extracting to ${OUTPUT_DIR}..." || exit_code=$?

  if [[ $exit_code -ne 0 ]]; then
    log error "Extraction failed or was cancelled (exit code: $exit_code)."
    [[ -d $OUTPUT_DIR ]] && rm -rf "$OUTPUT_DIR"
    exit "$exit_code"
  fi

  log info "Successfully extracted '$INPUT_FILE' to '$OUTPUT_DIR'."
}

main "$@"
