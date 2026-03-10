#!/usr/bin/env bash

set -euo pipefail

SCRIPT_NAME=$(basename "$0")
VERSION="1.4.0"
BASE_MKSQUASHFS_ARGS=(
  -comp zstd
  -Xcompression-level 19
  -b 1M
  -keep-as-directory
  -no-xattrs
)

log_info() { echo "[INFO] $*"; }
log_warn() { echo "[WARN] $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

# Global flag: skip checksum verification before mounting (-y)
SKIP_VERIFY=0

check_dependencies() {
  if ! command -v mksquashfs &>/dev/null; then
    log_error "'mksquashfs' is not installed!"
    exit 1
  fi
}

check_squashfuse() {
  if ! command -v squashfuse &>/dev/null; then
    log_error "'squashfuse' is not installed! It is required for mount/unmount operations."
    exit 1
  fi
}

# Verify the .sha256 checksum for a given archive before mounting.
# Returns 0 on pass, exits non-zero on failure or missing checksum file.
# If SKIP_VERIFY=1 this is a no-op (with a warning).
verify_archive_checksum() {
  local archive_abs="$1"

  if [[ $SKIP_VERIFY -eq 1 ]]; then
    log_warn "Checksum verification skipped (-y). Mounting without integrity check."
    return 0
  fi

  local checksum_abs="${archive_abs}.sha256"

  if [[ ! -f $checksum_abs ]]; then
    log_error "No checksum file found at '$checksum_abs'."
    log_error "Cannot verify archive integrity before mounting."
    log_error "If you want to skip verification, use the -y flag: $SCRIPT_NAME -y -m '$archive_abs'"
    exit 1
  fi

  local target_dir target_basename checksum_file
  target_dir="$(dirname "$archive_abs")"
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log_info "Verifying '$target_basename' against '$checksum_file' before mounting..."

  pushd "$target_dir" >/dev/null
  sha256sum -c "$checksum_file"
  local exit_code=$?
  popd >/dev/null

  if [[ $exit_code -ne 0 ]]; then
    log_error "Checksum verification FAILED for '$target_basename'. Refusing to mount."
    exit "$exit_code"
  fi

  log_info "Checksum verification passed."
}

# Tracker file format (two lines):
#   line 1 — canonical path to the mountpoint directory
#   line 2 — canonical path to the .sqsh archive
#
# Tracker files are named /tmp/<stem>.<nn>.mounted where <nn> is a zero-padded
# integer (01-99), allowing same-stem archives from different directories to
# coexist without collision.

read_tracker_mountpoint() { sed -n '1p' "$1"; }
read_tracker_archive() { sed -n '2p' "$1"; }

write_tracker_file() {
  local tracker_file="$1"
  local mountpoint="$2"
  local archive_abs="$3"
  printf '%s\n%s\n' "$mountpoint" "$archive_abs" >"$tracker_file"
}

# Find the next free /tmp/<stem>.<nn>.mounted slot (01-99).
# Prints the full tracker path. Exits if all 99 slots are taken.
alloc_tracker_file() {
  local stem="$1"
  local n
  for n in $(seq -f '%02g' 1 99); do
    local candidate="/tmp/${stem}.${n}.mounted"
    if [[ ! -f $candidate ]]; then
      echo "$candidate"
      return 0
    fi
  done
  log_error "All 99 tracker slots for stem '$stem' are in use. Cannot mount."
  exit 1
}

# Return all existing tracker files for a given stem.
# Prints one path per line; prints nothing if none exist.
find_tracker_files_by_stem() {
  local stem="$1"
  local candidate
  for candidate in /tmp/${stem}.[0-9][0-9].mounted; do
    [[ -f $candidate ]] && echo "$candidate"
  done
}

# Resolve a tracker file from either a .sqsh path or a mountpoint directory.
# Sets TRACKER_FILE in the caller's scope.
resolve_tracker_file() {
  local input_abs="$1"

  if [[ -f $input_abs && $input_abs == *.sqsh ]]; then
    # Input is the archive — find the tracker whose line 2 matches this archive.
    local stem
    stem="$(basename "$input_abs" .sqsh)"
    local candidate matches=()
    while IFS= read -r candidate; do
      local arc
      arc="$(read_tracker_archive "$candidate")"
      if [[ $arc == "$input_abs" ]]; then
        matches+=("$candidate")
      fi
    done < <(find_tracker_files_by_stem "$stem")

    if [[ ${#matches[@]} -eq 0 ]]; then
      log_error "No tracker file found for archive '$input_abs'. Is it currently mounted?"
      exit 1
    fi
    # Multiple trackers pointing at the same archive path should never happen,
    # but guard against it just in case.
    if [[ ${#matches[@]} -gt 1 ]]; then
      log_error "Unexpected: ${#matches[@]} tracker files all reference archive '$input_abs':"
      local m
      for m in "${matches[@]}"; do log_error "  $m"; done
      log_error "Remove stale tracker files manually and retry."
      exit 1
    fi
    TRACKER_FILE="${matches[0]}"

  elif [[ -d $input_abs ]]; then
    # Input is a mountpoint directory — scan all *.mounted files for a match on line 1.
    local candidate matches=()
    for candidate in /tmp/*.[0-9][0-9].mounted; do
      [[ -f $candidate ]] || continue
      local mp
      mp="$(read_tracker_mountpoint "$candidate")"
      if [[ $mp == "$input_abs" ]]; then
        matches+=("$candidate")
      fi
    done

    if [[ ${#matches[@]} -eq 0 ]]; then
      log_error "No tracker file in /tmp found referencing mountpoint '$input_abs'."
      exit 1
    fi
    # Each mountpoint directory is unique, so more than one match is corrupt state.
    if [[ ${#matches[@]} -gt 1 ]]; then
      log_error "Corrupt tracker state: ${#matches[@]} tracker files all reference mountpoint '$input_abs':"
      local m
      for m in "${matches[@]}"; do log_error "  $m"; done
      log_error "Remove stale tracker files manually and retry."
      exit 1
    fi
    TRACKER_FILE="${matches[0]}"

  else
    log_error "Cannot resolve tracker: '$input_abs' is neither a .sqsh file nor a directory."
    exit 1
  fi
}

mount_archive() {
  local input="$1"
  local archive_abs
  archive_abs="$(realpath "$input")"

  if [[ ! -f $archive_abs ]]; then
    log_error "Archive file not found: '$archive_abs'"
    exit 1
  fi

  local stem
  stem="$(basename "$archive_abs" .sqsh)"

  # Check if this specific archive (by canonical path) is already mounted.
  local existing candidates=()
  while IFS= read -r existing; do
    local arc
    arc="$(read_tracker_archive "$existing")"
    if [[ $arc == "$archive_abs" ]]; then
      candidates+=("$existing")
    fi
  done < <(find_tracker_files_by_stem "$stem")

  if [[ ${#candidates[@]} -gt 0 ]]; then
    local existing_mount
    existing_mount="$(read_tracker_mountpoint "${candidates[0]}")"
    log_error "Archive is already mounted at '$existing_mount' (tracker: '${candidates[0]}')."
    log_error "Unmount first with: $SCRIPT_NAME -u '$archive_abs'"
    exit 1
  fi

  local tracker_file
  tracker_file="$(alloc_tracker_file "$stem")"

  # Auto-create mountpoint: <archive_dir>/mounts/<stem>
  local archive_dir mountpoint
  archive_dir="$(dirname "$archive_abs")"
  mountpoint="${archive_dir}/mounts/${stem}"

  verify_archive_checksum "$archive_abs"

  mkdir -p "$mountpoint"
  log_info "Mounting '$archive_abs' -> '$mountpoint'..."

  if ! squashfuse "$archive_abs" "$mountpoint"; then
    log_error "squashfuse failed to mount '$archive_abs'."
    # Clean up empty mountpoint dir if we just created it
    rmdir "$mountpoint" 2>/dev/null || true
    exit 1
  fi

  # Write mountpoint (line 1) and archive path (line 2) to tracker file
  write_tracker_file "$tracker_file" "$mountpoint" "$archive_abs"
  log_info "Mounted successfully."
  log_info "Mountpoint : $mountpoint"
  log_info "Archive    : $archive_abs"
  log_info "Tracker    : $tracker_file"
}

unmount_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  local TRACKER_FILE=""
  resolve_tracker_file "$input_abs"

  if [[ ! -f $TRACKER_FILE ]]; then
    log_error "No tracker file found at '$TRACKER_FILE'. Is the archive currently mounted?"
    exit 1
  fi

  local mountpoint archive_abs
  mountpoint="$(read_tracker_mountpoint "$TRACKER_FILE")"
  archive_abs="$(read_tracker_archive "$TRACKER_FILE")"

  if [[ -z $mountpoint ]]; then
    log_error "Tracker file '$TRACKER_FILE' has no mountpoint entry. Cannot unmount."
    exit 1
  fi

  log_info "Unmounting '$mountpoint'..."
  [[ -n $archive_abs ]] && log_info "Archive    : $archive_abs"

  if ! fusermount -u "$mountpoint" 2>/dev/null && ! umount "$mountpoint" 2>/dev/null; then
    log_error "Failed to unmount '$mountpoint'. Is it still in use?"
    exit 1
  fi

  # Remove the now-empty mountpoint directory.
  if rmdir "$mountpoint" 2>/dev/null; then
    log_info "Removed mountpoint directory '$mountpoint'."
  else
    log_warn "Mountpoint directory '$mountpoint' is not empty; leaving it in place."
  fi

  # Remove the mounts/ parent only if it is now empty (other archives may still
  # be mounted as sibling directories beneath it).
  local mounts_dir
  mounts_dir="$(dirname "$mountpoint")"
  if [[ -d $mounts_dir ]]; then
    if rmdir "$mounts_dir" 2>/dev/null; then
      log_info "Removed empty mounts directory '$mounts_dir'."
    else
      log_info "WARNING: '$mounts_dir' is not empty; leaving it in place."
    fi
  fi

  rm -f "$TRACKER_FILE"
  log_info "Unmounted successfully. Tracker '$TRACKER_FILE' removed."
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
    exit 1
  fi

  if [[ ! -f $checksum_abs ]]; then
    log_error "No paired checksum file found: '$checksum_abs'"
    exit 1
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
    exit "$exit_code"
  fi

  log_info "Checksum verification passed for '$target_basename'."
}

parse_arguments() {
  SOURCES=()
  OUTPUT_FILE=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -o | --output)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          OUTPUT_FILE="$2"
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
      -y | --yes | --skip-verify)
        SKIP_VERIFY=1
        shift
        ;;
      -m | --mount)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          check_squashfuse
          mount_archive "$2"
          exit 0
        else
          log_error "Argument for $1 is missing or invalid."
          exit 1
        fi
        ;;
      -u | --unmount)
        if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
          check_squashfuse
          unmount_archive "$2"
          exit 0
        else
          log_error "Argument for $1 is missing or invalid."
          exit 1
        fi
        ;;
      -h | --help)
        echo "SquashFS Archiver (squish) v${VERSION}"
        echo ""
        echo "Usage:"
        echo "  $SCRIPT_NAME <source1> [source2...] [-o output.sqsh]   Create a new archive"
        echo "  $SCRIPT_NAME --check <archive_file>                  Verify archive integrity"
        echo "  $SCRIPT_NAME -m <archive_file> [-y]                  Mount archive to managed directory"
        echo "  $SCRIPT_NAME -u <archive_file | mountpoint>          Unmount archive and cleanup"
        echo ""
        echo "Options:"
        echo "  -o, --output <file>    Specify output filename (default: <first_source>.sqsh)"
        echo "  -y, --skip-verify      Skip SHA-256 verification before mounting"
        echo "  -h, --help             Show this help message"
        exit 0
        ;;
      *)
        SOURCES+=("$(realpath "$1")")
        shift
        ;;
    esac
  done

  if [[ ${#SOURCES[@]} -eq 0 ]]; then
    log_error "No source directories specified."
    echo "Usage: $SCRIPT_NAME <source1> [source2 ...] [-o output_file]"
    echo "       $SCRIPT_NAME --check <archive_file>"
    echo "       $SCRIPT_NAME [-y] -m|--mount <archive_file>"
    echo "       $SCRIPT_NAME -u|--unmount <archive_file>"
    exit 1
  fi
}

determine_output_filename() {
  if [[ -z $OUTPUT_FILE ]]; then
    local first_source_basename
    first_source_basename=$(basename "${SOURCES[0]}")
    OUTPUT_FILE="${first_source_basename}.sqsh"

    if [[ -e $OUTPUT_FILE ]]; then
      log_info "Conflict detected: '$OUTPUT_FILE' already exists."
      local date_stamp
      date_stamp=$(date +%Y%m%d)
      local counter=1
      local new_file
      while true; do
        new_file="archive-${date_stamp}-${counter}.sqsh"
        if [[ ! -e $new_file ]]; then
          OUTPUT_FILE="$new_file"
          break
        fi
        ((counter++))
      done
    fi
  fi

  OUTPUT_FILE="$(realpath -m "$OUTPUT_FILE")"
  log_info "Output file: '$OUTPUT_FILE'"
  log_info "Sources: ${SOURCES[*]}"
}

# Shared pipeline used by both GUI modes: runs mksquashfs, tees non-integer
# output to the console, and feeds bare integers to the caller's progress dialog.
# Usage: _run_mksquashfs_gui <status_file> <target_file> <source...> | <dialog>
_run_mksquashfs_gui() {
  local fifo="$1"
  local status_file="$2"
  local target_file="$3"
  shift 3
  local sources=("$@")

  (
    mksquashfs "${sources[@]}" "$target_file" \
      "${BASE_MKSQUASHFS_ARGS[@]}" \
      -info \
      -percentage 2>&1
    echo "$?" >"$status_file"
  ) | tee >(grep -v -E '^[0-9]+$' >/dev/tty) \
    | grep --line-buffered -E '^[0-9]+$' >"$fifo" &

  MKSQ_PIPE_PID=$!
}

_compress_with_dialog() {
  local target_file="$1"
  shift
  local dialog_cmd=("$@")

  local mksq_status_file fifo
  mksq_status_file=$(mktemp)
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  _run_mksquashfs_gui "$fifo" "$mksq_status_file" "$target_file" "${SOURCES[@]}"

  "${dialog_cmd[@]}" <"$fifo"
  local dialog_exit=$?

  if [[ $dialog_exit -ne 0 ]]; then
    # User cancelled — kill the entire pipeline process group
    kill -- -"$MKSQ_PIPE_PID" 2>/dev/null || true
    wait "$MKSQ_PIPE_PID" 2>/dev/null || true
    rm -f "$mksq_status_file" "$fifo"
    return "$dialog_exit"
  fi

  wait "$MKSQ_PIPE_PID"
  local mksq_exit
  mksq_exit=$(cat "$mksq_status_file")
  rm -f "$mksq_status_file" "$fifo"

  [[ $mksq_exit -ne 0 ]] && return "$mksq_exit"
  return 0
}

compress_with_yad() {
  local target_file="$1"
  _compress_with_dialog "$target_file" \
    yad --progress \
    --title="SquashFS Archival" \
    --text="Compressing to ${target_file}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill \
    --center \
    --width=450 \
    --borders=15 \
    --bar-style=normal
}

compress_with_zenity() {
  local target_file="$1"
  _compress_with_dialog "$target_file" \
    zenity --progress \
    --title="SquashFS Archival" \
    --text="Compressing to ${target_file}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill
}

compress_cli() {
  local target_file="$1"
  shift
  local sources=("$@")

  mksquashfs "${sources[@]}" "$target_file" \
    "${BASE_MKSQUASHFS_ARGS[@]}" \
    -info \
    -progress
}

main() {
  check_dependencies
  parse_arguments "$@"
  determine_output_filename

  local exit_code=0

  if command -v yad &>/dev/null; then
    log_info "Starting compression with YAD UI..."
    compress_with_yad "$OUTPUT_FILE" "${SOURCES[@]}" || exit_code=$?
  elif command -v zenity &>/dev/null; then
    log_info "Starting compression with Zenity UI..."
    compress_with_zenity "$OUTPUT_FILE" "${SOURCES[@]}" || exit_code=$?
  else
    log_info "No GUI available. Falling back to CLI output..."
    compress_cli "$OUTPUT_FILE" "${SOURCES[@]}" || exit_code=$?
  fi

  if [[ $exit_code -ne 0 ]]; then
    log_error "Compression failed or was cancelled (exit code: $exit_code)."
    [[ -f $OUTPUT_FILE ]] && rm -f "$OUTPUT_FILE"
    exit "$exit_code"
  fi

  log_info "Generating checksum..."
  pushd "$(dirname "$OUTPUT_FILE")" >/dev/null
  sha256sum "$(basename "$OUTPUT_FILE")" >"$(basename "$OUTPUT_FILE").sha256"
  popd >/dev/null
  log_info "Checksum written to '${OUTPUT_FILE}.sha256'."
  log_info "Successfully created '$OUTPUT_FILE'."
}

main "$@"
