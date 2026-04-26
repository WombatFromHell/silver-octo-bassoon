#!/usr/bin/env bash

set -euo pipefail

#######################################
# CONSTANTS
#######################################

declare -r VERSION="dev"
declare -r SCRIPT_NAME=$(basename "$0")

declare -ra BASE_MKSQUASHFS_ARGS=(
  -comp zstd
  -Xcompression-level 19
  -b 1M
  -keep-as-directory
  -no-xattrs
)

#######################################
# GLOBAL STATE
#######################################

declare -i SKIP_VERIFY=0
declare -i PIPE_MODE=0
declare SOURCES=()
declare OUTPUT_FILE=""

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
  if ! command -v mksquashfs &>/dev/null; then
    log error "'mksquashfs' is not installed!"
    exit 1
  fi
}

check_squashfuse() {
  if ! command -v squashfuse &>/dev/null; then
    log error "'squashfuse' is not installed! It is required for mount/unmount operations."
    exit 1
  fi
}

#######################################
# CHECKSUM OPERATIONS
#######################################

verify_archive_checksum() {
  local archive_abs="$1"

  if [[ $SKIP_VERIFY -eq 1 ]]; then
    log warn "Checksum verification skipped (-y). Mounting without integrity check."
    return 0
  fi

  local checksum_abs="${archive_abs}.sha256"

  if [[ ! -f $checksum_abs ]]; then
    log error "No checksum file found at '$checksum_abs'."
    log error "Cannot verify archive integrity before mounting."
    log error "If you want to skip verification, use the -y flag: $SCRIPT_NAME -y -m '$archive_abs'"
    exit 1
  fi

  local target_dir target_basename checksum_file
  target_dir="$(dirname "$archive_abs")"
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log info "Verifying '$target_basename' against '$checksum_file' before mounting..."

  local exit_code
  exit_code=$(cd "$target_dir" && sha256sum -c "$checksum_file" >/dev/null 2>&1 && echo 0 || echo $?)

  if [[ $exit_code -ne 0 ]]; then
    log error "Checksum verification FAILED for '$target_basename'. Refusing to mount."
    exit "$exit_code"
  fi

  log info "Checksum verification passed."
}

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
    exit 1
  fi

  if [[ ! -f $checksum_abs ]]; then
    log error "No paired checksum file found: '$checksum_abs'"
    exit 1
  fi

  local target_dir target_basename checksum_file
  target_dir="$(dirname "$archive_abs")"
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log info "Verifying '$target_basename' against '$checksum_file'..."

  local exit_code
  exit_code=$(cd "$target_dir" && sha256sum -c "$checksum_file" && echo 0 || echo $?)

  if [[ $exit_code -ne 0 ]]; then
    log error "Checksum verification FAILED for '$target_basename'."
    exit "$exit_code"
  fi

  log info "Checksum verification passed for '$target_basename'."
}

generate_checksum() {
  local file="$1"
  local dir basename
  dir="$(dirname "$file")"
  basename="$(basename "$file")"
  (cd "$dir" && sha256sum "$basename" >"${basename}.sha256")
}

#######################################
# TRACKER FILE MANAGEMENT
#
# Tracker format:
#   line 1 — canonical path to mountpoint directory
#   line 2 — canonical path to .sqsh archive
#
# Named $XDG_RUNTIME_DIR/<stem>.<nn>.mounted (or /tmp as fallback)
# where <nn> is 01-99 for collision-free same-stem archives.
#######################################

get_tracker_dir() {
  echo "${XDG_RUNTIME_DIR:-/tmp}"
}

get_mounts_dir() {
  echo "$(get_tracker_dir)/squish-mounts"
}

read_tracker_mountpoint() { head -n1 "$1"; }
read_tracker_archive() { tail -n1 "$1"; }

write_tracker_file() {
  local tracker_file="$1"
  local mountpoint="$2"
  local archive_abs="$3"
  printf '%s\n%s\n' "$mountpoint" "$archive_abs" >"$tracker_file"
}

alloc_tracker_file() {
  local stem="$1"
  local tracker_dir
  tracker_dir="$(get_tracker_dir)"
  local n candidate
  for n in $(seq -f '%02g' 1 99); do
    candidate="${tracker_dir}/${stem}.${n}.mounted"
    if [[ ! -f $candidate ]]; then
      echo "$candidate"
      return 0
    fi
  done
  log error "All 99 tracker slots for stem '$stem' are in use. Cannot mount."
  exit 1
}

find_tracker_files_by_stem() {
  local stem="$1"
  local tracker_dir candidate
  tracker_dir="$(get_tracker_dir)"
  for candidate in "${tracker_dir}"/${stem}.[0-9][0-9].mounted; do
    [[ -f $candidate ]] && echo "$candidate"
  done
}

list_mounts() {
  local tracker_dir candidate count=0
  tracker_dir="$(get_tracker_dir)"

  for candidate in "${tracker_dir}"/*.[0-9][0-9].mounted; do
    [[ -f $candidate ]] || continue
    local mountpoint archive_abs
    mountpoint="$(read_tracker_mountpoint "$candidate")"
    archive_abs="$(read_tracker_archive "$candidate")"
    echo "${archive_abs} -> ${mountpoint}"
    ((count++))
  done

  if [[ $count -eq 0 ]]; then
    log info "No active mounts found."
  fi
}

resolve_tracker_file() {
  local input_abs="$1"

  if [[ -f $input_abs && $input_abs == *.sqsh ]]; then
    local stem candidate matches=()
    stem="$(basename "$input_abs" .sqsh)"
    while IFS= read -r candidate; do
      local arc
      arc="$(read_tracker_archive "$candidate")"
      [[ $arc == "$input_abs" ]] && matches+=("$candidate")
    done < <(find_tracker_files_by_stem "$stem")

    case ${#matches[@]} in
    0)
      log error "No tracker file found for archive '$input_abs'. Is it currently mounted?"
      exit 1
      ;;
    1)
      TRACKER_FILE="${matches[0]}"
      ;;
    *)
      log error "Unexpected: ${#matches[@]} tracker files all reference archive '$input_abs':"
      local m
      for m in "${matches[@]}"; do log error "  $m"; done
      log error "Remove stale tracker files manually and retry."
      exit 1
      ;;
    esac

  elif [[ -d $input_abs ]]; then
    local tracker_dir candidate matches=()
    tracker_dir="$(get_tracker_dir)"
    for candidate in "${tracker_dir}"/*.[0-9][0-9].mounted; do
      [[ -f $candidate ]] || continue
      local mp
      mp="$(read_tracker_mountpoint "$candidate")"
      [[ $mp == "$input_abs" ]] && matches+=("$candidate")
    done

    case ${#matches[@]} in
    0)
      log error "No tracker file in '${tracker_dir}' found referencing mountpoint '$input_abs'."
      exit 1
      ;;
    1)
      TRACKER_FILE="${matches[0]}"
      ;;
    *)
      log error "Corrupt tracker state: ${#matches[@]} tracker files all reference mountpoint '$input_abs':"
      local m
      for m in "${matches[@]}"; do log error "  $m"; done
      log error "Remove stale tracker files manually and retry."
      exit 1
      ;;
    esac

  else
    log error "Cannot resolve tracker: '$input_abs' is neither a .sqsh file nor a directory."
    exit 1
  fi
}

#######################################
# MOUNT/UNMOUNT OPERATIONS
#######################################

mount_archive() {
  local input="$1"
  local archive_abs
  archive_abs="$(realpath "$input")"

  if [[ ! -f $archive_abs ]]; then
    log error "Archive file not found: '$archive_abs'"
    exit 1
  fi

  local stem existing candidates=()
  stem="$(basename "$archive_abs" .sqsh)"

  while IFS= read -r existing; do
    local arc
    arc="$(read_tracker_archive "$existing")"
    [[ $arc == "$archive_abs" ]] && candidates+=("$existing")
  done < <(find_tracker_files_by_stem "$stem")

  if [[ ${#candidates[@]} -gt 0 ]]; then
    local existing_mount
    existing_mount="$(read_tracker_mountpoint "${candidates[0]}")"
    log error "Archive is already mounted at '$existing_mount' (tracker: '${candidates[0]}')."
    log error "Unmount first with: $SCRIPT_NAME -u '$archive_abs'"
    exit 1
  fi

  local tracker_file
  tracker_file="$(alloc_tracker_file "$stem")"

  local tracker_basename mounts_dir mountpoint
  tracker_basename="$(basename "$tracker_file")"
  mounts_dir="$(get_mounts_dir)"
  mountpoint="${mounts_dir}/${tracker_basename}"

  verify_archive_checksum "$archive_abs"

  mkdir -p "$mounts_dir"
  mkdir -p "$mountpoint"
  log info "Mounting '$archive_abs' -> '$mountpoint'..."

  if ! squashfuse "$archive_abs" "$mountpoint"; then
    log error "squashfuse failed to mount '$archive_abs'."
    rmdir "$mountpoint" 2>/dev/null || true
    exit 1
  fi

  write_tracker_file "$tracker_file" "$mountpoint" "$archive_abs"
  log info "Mounted successfully."
  log info "Mountpoint : $mountpoint"
  log info "Archive    : $archive_abs"
  log info "Tracker    : $tracker_file"
}

unmount_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  local TRACKER_FILE=""
  resolve_tracker_file "$input_abs"

  if [[ ! -f $TRACKER_FILE ]]; then
    log error "No tracker file found at '$TRACKER_FILE'. Is the archive currently mounted?"
    exit 1
  fi

  local mountpoint archive_abs
  mountpoint="$(read_tracker_mountpoint "$TRACKER_FILE")"
  archive_abs="$(read_tracker_archive "$TRACKER_FILE")"

  if [[ -z $mountpoint ]]; then
    log error "Tracker file '$TRACKER_FILE' has no mountpoint entry. Cannot unmount."
    exit 1
  fi

  log info "Unmounting '$mountpoint'..."
  [[ -n $archive_abs ]] && log info "Archive    : $archive_abs"

  if ! fusermount -u "$mountpoint" 2>/dev/null && ! umount "$mountpoint" 2>/dev/null; then
    log error "Failed to unmount '$mountpoint'. Is it still in use?"
    exit 1
  fi

  if rmdir "$mountpoint" 2>/dev/null; then
    log info "Removed mountpoint directory '$mountpoint'."
  else
    log warn "Mountpoint directory '$mountpoint' is not empty; leaving it in place."
  fi

  local mounts_dir
  mounts_dir="$(get_mounts_dir)"
  if [[ -d $mounts_dir ]]; then
    rmdir "$mounts_dir" 2>/dev/null && log info "Removed empty mounts directory '$mounts_dir'."
  fi

  rm -f "$TRACKER_FILE"
  log info "Unmounted successfully. Tracker '$TRACKER_FILE' removed."
}

#######################################
# COMPRESSION OPERATIONS
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
    "${cmd[@]}" "$target" "${BASE_MKSQUASHFS_ARGS[@]}" -info -percentage 2>&1
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

  run_progress_pipeline pipe_pid "$fifo" "$status_file" "$target" mksquashfs "${SOURCES[@]}"

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

compress_with_yad() {
  local target="$1"
  run_with_dialog "$target" \
    yad --progress \
    --title="SquashFS Archival" \
    --text="Compressing to ${target}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill \
    --center \
    --width=450 \
    --borders=15 \
    --bar-style=normal
}

compress_with_zenity() {
  local target="$1"
  run_with_dialog "$target" \
    zenity --progress \
    --title="SquashFS Archival" \
    --text="Compressing to ${target}..." \
    --percentage=0 \
    --auto-close \
    --auto-kill
}

compress_cli() {
  local target="$1"
  mksquashfs "${SOURCES[@]}" "$target" "${BASE_MKSQUASHFS_ARGS[@]}" -info -progress
}

compress_pipe() {
  local target="$1"
  mksquashfs "${SOURCES[@]}" "$target" "${BASE_MKSQUASHFS_ARGS[@]}" -percentage 2>&1 |
    awk '/^[0-9]+$/{print; fflush(); next} {print > "/dev/stderr"}'
}

#######################################
# OUTPUT FILENAME RESOLUTION
#######################################

determine_output_filename() {
  if [[ -z $OUTPUT_FILE ]]; then
    local first_source_basename
    first_source_basename=$(basename "${SOURCES[0]}")
    OUTPUT_FILE="${first_source_basename}.sqsh"

    if [[ -e $OUTPUT_FILE ]]; then
      log info "Conflict detected: '$OUTPUT_FILE' already exists."
      local date_stamp counter new_file
      date_stamp=$(date +%Y%m%d)
      counter=1
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
  log info "Output file: '$OUTPUT_FILE'"
  log info "Sources: ${SOURCES[*]}"
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

  local action=""
  local action_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -o | --output)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        OUTPUT_FILE="$2"
        shift 2
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    --check)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        action="check"
        action_arg="$2"
        shift 2
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    -y | --yes | --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    --pipe)
      shift
      ;;
    -m | --mount)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        action="mount"
        action_arg="$2"
        shift 2
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    -u | --unmount)
      if [[ -n ${2:-} && ! $2 =~ ^- ]]; then
        action="unmount"
        action_arg="$2"
        shift 2
      else
        log error "Argument for $1 is missing or invalid."
        exit 1
      fi
      ;;
    --list-mounts)
      action="list-mounts"
      shift
      ;;
    -h | --help)
      echo "SquashFS Archiver (squish) v${VERSION}"
      echo ""
      echo "Usage:"
      echo " $SCRIPT_NAME <source1> [source2...] [-o output.sqsh] Create a new archive"
      echo " $SCRIPT_NAME --check <archive_file> Verify archive integrity"
      echo " $SCRIPT_NAME -m <archive_file> [-y] Mount archive to managed directory"
      echo " $SCRIPT_NAME -u <archive_file | mountpoint> Unmount archive and cleanup"
      echo " $SCRIPT_NAME --list-mounts List all active mounts"
      echo ""
      echo "Options:"
      echo " -o, --output <file> Specify output filename (default: <first_source>.sqsh)"
      echo " -y, --skip-verify Skip SHA-256 verification before mounting"
      echo " --pipe Machine-readable mode: percentages to stdout, logs to stderr"
      echo " -h, --help Show this help message"
      exit 0
      ;;
    *)
      SOURCES+=("$(realpath "$1")")
      shift
      ;;
    esac
  done

  case "$action" in
  check)
    check_archive "$action_arg"
    exit 0
    ;;
  mount)
    check_squashfuse
    mount_archive "$action_arg"
    exit 0
    ;;
  unmount)
    check_squashfuse
    unmount_archive "$action_arg"
    exit 0
    ;;
  list-mounts)
    check_squashfuse
    list_mounts
    exit 0
    ;;
  esac

  if [[ ${#SOURCES[@]} -eq 0 ]]; then
    log error "No source directories specified."
    echo "Usage: $SCRIPT_NAME <source1> [source2 ...] [-o output_file]"
    echo " $SCRIPT_NAME --check <archive_file>"
    echo " $SCRIPT_NAME [-y] -m|--mount <archive_file>"
    echo " $SCRIPT_NAME -u|--unmount <archive_file>"
    exit 1
  fi
}

#######################################
# MAIN
#######################################

main() {
  check_dependencies
  parse_arguments "$@"
  determine_output_filename

  local exit_code=0

  if [[ $PIPE_MODE -eq 1 ]]; then
    compress_pipe "$OUTPUT_FILE" || exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
      log error "Compression failed (exit code: $exit_code)."
      [[ -f $OUTPUT_FILE ]] && rm -f "$OUTPUT_FILE"
      exit "$exit_code"
    fi

    generate_checksum "$OUTPUT_FILE"
    log info "Checksum written to '${OUTPUT_FILE}.sha256'."
    log info "Successfully created '$OUTPUT_FILE'."
    exit 0
  fi

  if command -v yad &>/dev/null; then
    log info "Starting compression with YAD UI..."
    compress_with_yad "$OUTPUT_FILE" || exit_code=$?
  elif command -v zenity &>/dev/null; then
    log info "Starting compression with Zenity UI..."
    compress_with_zenity "$OUTPUT_FILE" || exit_code=$?
  else
    log info "No GUI available. Falling back to CLI output..."
    compress_cli "$OUTPUT_FILE" || exit_code=$?
  fi

  if [[ $exit_code -ne 0 ]]; then
    log error "Compression failed or was cancelled (exit code: $exit_code)."
    [[ -f $OUTPUT_FILE ]] && rm -f "$OUTPUT_FILE"
    exit "$exit_code"
  fi

  generate_checksum "$OUTPUT_FILE"
  log info "Checksum written to '${OUTPUT_FILE}.sha256'."
  log info "Successfully created '$OUTPUT_FILE'."
}

main "$@"
