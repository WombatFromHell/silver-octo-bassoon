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
declare -i FORCE=0
declare -i KIO_MODE=0
declare -i OPEN_MOUNT=0
declare -i PRINT_MOUNTPOINT=0
declare MOUNTS_FOLDER="squish-mounts"
declare SOURCES=()
declare OUTPUT_FILE=""

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

  resolve_checksum_pair "$archive_abs"
  if ! require_existing_pair "$ARCHIVE_ABS" "$CHECKSUM_ABS"; then
    log error "If you want to skip verification, use the -y flag: $SCRIPT_NAME -y -m '$archive_abs'"
    exit 1
  fi

  verify_checksum_pair "$ARCHIVE_ABS" "$CHECKSUM_ABS" "SquashFS Archival" || exit $?
}

generate_checksum() {
  local file="$1"
  local dir base hash
  dir="$(dirname "$file")"
  base="$(basename "$file")"
  log info "Generating SHA-256 checksum for '$base'..."
  hash="$(cd "$dir" && hash_with_progress "$base" "SquashFS Archival")" || exit 1
  printf '%s  %s\n' "$hash" "$base" >"${dir}/${base}.sha256"
}

#######################################
# TRACKER FILE MANAGEMENT
#
# Tracker format:
#   line 1 — canonical path to mountpoint directory
#   line 2 — canonical path to .sqsh archive
#
# Named $XDG_RUNTIME_DIR/<stem>.<nn>.mounted (or /tmp as fallback)
# where <nn> is 01-99 for collision-free same-stem archives. Mountpoints live
# one level down, in the one managed mounts folder, so neither placement depends
# on the folder the command happens to run in and reading a location creates
# nothing.
#######################################

get_tracker_dir() {
  echo "${XDG_RUNTIME_DIR:-/tmp}"
}

get_mounts_dir() {
  echo "$(get_tracker_dir)/$MOUNTS_FOLDER"
}

read_tracker_mountpoint() { head -n1 "$1"; }
read_tracker_archive() { tail -n1 "$1"; }

is_mounted() {
  mountpoint -q "$1" 2>/dev/null
}

remove_stale_trackers() {
  local candidates=("$@")
  local candidate mountpoint
  for candidate in "${candidates[@]}"; do
    mountpoint="$(read_tracker_mountpoint "$candidate")"
    if [[ -n $mountpoint ]] && ! is_mounted "$mountpoint"; then
      rm -f "$candidate"
      rmdir "$mountpoint" 2>/dev/null || true
      log warn "Removed stale tracker '$candidate' (mountpoint '$mountpoint' is not mounted)."
    fi
  done
}

# Usage: all_trackers
# Prints every tracker file in the tracker directory.
all_trackers() {
  local tracker_dir candidate
  tracker_dir="$(get_tracker_dir)"
  for candidate in "${tracker_dir}"/*.[0-9][0-9].mounted; do
    [[ -f $candidate ]] && echo "$candidate"
  done
}

# Usage: tracker_matches <reader-fn> <value>
# Prints tracker files whose recorded value, read with <reader-fn>
# (read_tracker_archive or read_tracker_mountpoint), equals <value>.
tracker_matches() {
  local reader="$1" want="$2" candidate have
  while IFS= read -r candidate; do
    have="$("$reader" "$candidate")"
    [[ $have == "$want" ]] && echo "$candidate"
  done < <(all_trackers)
}

# Usage: live_trackers_for_archive <archive_abs>
# Trackers for this archive; with --force, trackers whose mount died are
# dropped first and the archive is rescanned.
live_trackers_for_archive() {
  local archive_abs="$1"
  local candidates=() candidate
  mapfile -t candidates < <(tracker_matches read_tracker_archive "$archive_abs")
  if [[ ${#candidates[@]} -gt 0 && $FORCE -eq 1 ]]; then
    remove_stale_trackers "${candidates[@]}"
    mapfile -t candidates < <(tracker_matches read_tracker_archive "$archive_abs")
  fi
  for candidate in "${candidates[@]}"; do
    echo "$candidate"
  done
}

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

list_mounts() {
  local candidate mountpoint archive_abs count=0

  while IFS= read -r candidate; do
    mountpoint="$(read_tracker_mountpoint "$candidate")"
    archive_abs="$(read_tracker_archive "$candidate")"
    echo "${archive_abs} -> ${mountpoint}"
    ((count++)) || true
  done < <(all_trackers)

  if [[ $count -eq 0 ]]; then
    log info "No active mounts found."
  fi
}

resolve_tracker_file() {
  local input_abs="$1"
  local reader none_msg
  if [[ -f $input_abs && $input_abs == *.sqsh ]]; then
    reader=read_tracker_archive
    none_msg="No tracker file found for archive '$input_abs'. Is it currently mounted?"
  elif [[ -d $input_abs ]]; then
    reader=read_tracker_mountpoint
    none_msg="No tracker file in '$(get_tracker_dir)' found referencing mountpoint '$input_abs'."
  else
    log error "Cannot resolve tracker: '$input_abs' is neither a .sqsh file nor a directory."
    return 1
  fi

  local matches=()
  mapfile -t matches < <(tracker_matches "$reader" "$input_abs")

  case ${#matches[@]} in
  0)
    log error "$none_msg"
    return 1
    ;;
  1)
    echo "${matches[0]}"
    return 0
    ;;
  *)
    log error "Corrupt tracker state: ${#matches[@]} tracker files all reference '$input_abs':"
    local m
    for m in "${matches[@]}"; do log error "  $m"; done
    log error "Remove stale tracker files manually and retry."
    return 1
    ;;
  esac
}

#######################################
# MOUNT/UNMOUNT OPERATIONS
#######################################

mount_archive() {
  local input="$1"
  local archive_abs
  archive_abs="$(realpath "$input")"

  require_existing_archive "$archive_abs" || exit 1

  local candidates=()
  mapfile -t candidates < <(live_trackers_for_archive "$archive_abs")

  if [[ ${#candidates[@]} -gt 0 ]]; then
    local existing_mount
    existing_mount="$(read_tracker_mountpoint "${candidates[0]}")"
    log error "Archive is already mounted at '$existing_mount' (tracker: '${candidates[0]}')."
    log error "Unmount first with: $SCRIPT_NAME -u '$archive_abs'"
    exit 1
  fi

  local stem tracker_file
  stem="$(basename "$archive_abs" .sqsh)"
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

  if [[ $PRINT_MOUNTPOINT -eq 1 ]]; then
    echo "$mountpoint"
  fi

  if [[ $OPEN_MOUNT -eq 1 ]]; then
    open_mounts_folder "$mounts_dir" ||
      log warn "Could not show the mounts folder; it is at '$mounts_dir'."
  fi
  return 0
}

# Usage: open_mounts_folder <folder>
# Hands the shared mounts folder to the desktop's own folder handler, so the
# file manager the desktop is configured for opens it. Fails when there is no
# such handler or it refuses; the mount itself is already done by then.
open_mounts_folder() {
  if ! command -v xdg-open >/dev/null 2>&1; then
    return 1
  fi
  xdg-open "$1" >/dev/null 2>&1
}

do_unmount() {
  local mountpoint="$1"
  if ! fusermount -u "$mountpoint" 2>/dev/null && ! umount "$mountpoint" 2>/dev/null; then
    return 1
  fi
  if rmdir "$mountpoint" 2>/dev/null; then
    log info "Removed mountpoint directory '$mountpoint'."
  else
    log warn "Mountpoint directory '$mountpoint' is not empty; leaving it in place."
  fi
  return 0
}

unmount_tracker() {
  local tracker_file="$1"
  local mountpoint archive_abs
  mountpoint="$(read_tracker_mountpoint "$tracker_file")"
  archive_abs="$(read_tracker_archive "$tracker_file")"

  if [[ -z $mountpoint ]]; then
    log error "Tracker file '$tracker_file' has no mountpoint entry. Cannot unmount."
    return 1
  fi

  log info "Unmounting '$mountpoint'..."
  [[ -n $archive_abs ]] && log info "Archive    : $archive_abs"

  if ! do_unmount "$mountpoint"; then
    log error "Failed to unmount '$mountpoint'. Is it still in use?"
    return 1
  fi

  local mounts_parent
  mounts_parent="$(dirname "$mountpoint")"
  if [[ $mounts_parent == */"$MOUNTS_FOLDER" ]]; then
    rmdir "$mounts_parent" 2>/dev/null &&
      log info "Removed empty mounts directory '$mounts_parent'."
  fi

  rm -f "$tracker_file"
  log info "Unmounted successfully. Tracker '$tracker_file' removed."
}

unmount_archive() {
  local input="$1"
  local input_abs
  input_abs="$(realpath "$input")"

  if [[ $FORCE -eq 1 ]]; then
    if [[ -f $input_abs && $input_abs == *.sqsh ]]; then
      local live=()
      mapfile -t live < <(live_trackers_for_archive "$input_abs")

      if [[ ${#live[@]} -eq 0 ]]; then
        log info "Archive '$input_abs' is not currently mounted."
        return 0
      fi
      for candidate in "${live[@]}"; do
        unmount_tracker "$candidate" || exit 1
      done
      return 0
    elif [[ -d $input_abs ]]; then
      if is_mounted "$input_abs"; then
        log info "Unmounting orphan mount '$input_abs' (no tracker)..."
        if ! do_unmount "$input_abs"; then
          log error "Failed to unmount '$input_abs'. Is it still in use?"
          exit 1
        fi
        log info "Unmounted successfully."
        return 0
      else
        rmdir "$input_abs" 2>/dev/null && log info "Removed unused mountpoint directory '$input_abs'."
        log info "Mountpoint '$input_abs' is not currently mounted."
        return 0
      fi
    fi
  fi

  local TRACKER_FILE
  TRACKER_FILE="$(resolve_tracker_file "$input_abs")" || exit 1
  unmount_tracker "$TRACKER_FILE" || exit 1
}

#######################################
# COMPRESSION OPERATIONS
#######################################

# Usage: compress_backend_args
# Sets BACKEND_ARGS to the mksquashfs argv for this RENDERER. The flag set is
# what differs per renderer: -info suppresses the bare percentage lines a gauge
# reads, -percentage alone is what --pipe prints.
compress_backend_args() {
  BACKEND_ARGS=(mksquashfs "${SOURCES[@]}" "$OUTPUT_FILE" "${BASE_MKSQUASHFS_ARGS[@]}")
  case "$RENDERER" in
  pipe)
    BACKEND_ARGS+=(-percentage)
    ;;
  yad | zenity)
    BACKEND_ARGS+=(-progress -percentage)
    ;;
  cli)
    BACKEND_ARGS+=(-info -progress)
    ;;
  esac
}

#######################################
# OUTPUT FILENAME RESOLUTION
#######################################

determine_output_filename() {
  if [[ -z $OUTPUT_FILE ]]; then
    local first_source_basename
    first_source_basename=$(basename "${SOURCES[0]}")
    OUTPUT_FILE="${first_source_basename}.sqsh"

    # ponytail: KIO mode uses the archive-* convention when several sources
    # are bundled into one archive; a single source still infers <name>.sqsh
    [[ $KIO_MODE -eq 1 && ${#SOURCES[@]} -gt 1 ]] && OUTPUT_FILE=""

    if [[ -n $OUTPUT_FILE && -e $OUTPUT_FILE ]]; then
      log info "Conflict detected: '$OUTPUT_FILE' already exists."
    fi

    if [[ -z $OUTPUT_FILE || -e $OUTPUT_FILE ]]; then
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

parse_arguments() {
  pre_scan_pipe_mode "$@"
  resolve_renderer

  local action=""
  local action_arg=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
    -o | --output)
      if is_option_value "${2:-}"; then
        OUTPUT_FILE="$2"
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
    -y | --yes | --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    -f | --force)
      FORCE=1
      shift
      ;;
    --pipe)
      shift
      ;;
    -k | --kio)
      KIO_MODE=1
      shift
      ;;
    -m | --mount)
      action="mount"
      if is_option_value "${2:-}"; then
        action_arg="$2"
        shift 2
      else
        shift
      fi
      ;;
    -u | --unmount)
      action="unmount"
      if is_option_value "${2:-}"; then
        action_arg="$2"
        shift 2
      else
        shift
      fi
      ;;
    --list-mounts)
      action="list-mounts"
      shift
      ;;
    --open)
      OPEN_MOUNT=1
      shift
      ;;
    --print-mountpoint)
      PRINT_MOUNTPOINT=1
      shift
      ;;
    -h | --help)
      echo "SquashFS Archiver (squish) v${VERSION}"
      echo ""
      echo "Usage:"
      echo " $SCRIPT_NAME <source1> [source2...] [-o output.sqsh] Create a new archive"
      echo " $SCRIPT_NAME --check <archive_file> Verify archive integrity"
      echo " $SCRIPT_NAME -m <archive_file> [-y] [--force] [--open] Mount archive to managed directory"
      echo " $SCRIPT_NAME -u <archive_file | mountpoint> [--force] Unmount archive and cleanup"
      echo " $SCRIPT_NAME --list-mounts List all active mounts"
      echo ""
      echo "Options:"
      echo " -o, --output <file> Specify output filename (default: <first_source>.sqsh)"
      echo " -y, --skip-verify Skip SHA-256 verification before mounting"
      echo " -f, --force     Remove stale trackers / tolerate missing ones on mount & unmount"
      echo " -k, --kio       KIO service-menu mode: args are file:// URIs; multi-source output uses 'archive-*' naming"
      echo " --open          With -m: show the mounts folder in the desktop's file manager"
      echo " --print-mountpoint  With -m: print the new mountpoint alone on stdout, logs to stderr"
      echo " --pipe Machine-readable mode: percentages to stdout, logs to stderr"
      echo " -h, --help Show this help message"
      exit 0
      ;;
    *)
      local source_arg="$1"
      if [[ $KIO_MODE -eq 1 && $source_arg == file://* && $source_arg == *" "* ]]; then
        # ponytail: KIO's %U can hand the whole URI list as one argument;
        # URI-encoded tokens never contain literal spaces, so a plain
        # word-split is safe here
        local uri_token
        for uri_token in $source_arg; do
          SOURCES+=("$(realpath "$(uri_to_path "$uri_token")")")
        done
      else
        [[ $KIO_MODE -eq 1 ]] && source_arg="$(uri_to_path "$source_arg")"
        SOURCES+=("$(realpath "$source_arg")")
      fi
      shift
      ;;
    esac
  done

  case $action in
  check | mount | unmount)
    if [[ -z $action_arg ]]; then
      if [[ ${#SOURCES[@]} -eq 1 ]]; then
        action_arg="${SOURCES[0]}"
      else
        missing_option_value "$action"
      fi
    fi
    ;;
  esac

  case "$action" in
  check)
    run_check "$action_arg" "SquashFS Archival"
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
  parse_arguments "$@"
  check_dependencies
  determine_output_filename

  local exit_code=0

  compress_backend_args
  if [[ $RENDERER != pipe ]]; then
    log info "Rendering compression with '$RENDERER'..."
  fi
  show_progress "SquashFS Archival" "Compressing to ${OUTPUT_FILE}..." || exit_code=$?

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
