#!/usr/bin/env bash
#######################################
# squish-common.sh
#
# Shared logic for squish.sh and unsquish.sh. Sourced, not executed.
# Expects PIPE_MODE (declare -i, 0/1) to be defined by the sourcing script.
#######################################

#######################################
# LOGGING
#######################################

log() {
  local level="$1"
  shift
  if [[ $PIPE_MODE -eq 1 || $level != "info" ]]; then
    echo "[${level^^}] $*" >&2
  else
    echo "[INFO] $*"
  fi
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
}

#######################################
# PIPE MODE
#######################################

# Usage: pipe_progress <cmd args...>
# Machine-readable mode: bare percentage lines to stdout, rest to stderr.
pipe_progress() {
  "$@" 2>&1 | awk '/^[0-9]+$/{print; fflush(); next} {print > "/dev/stderr"}'
}

#######################################
# PROGRESS DIALOG
#######################################

# Usage: run_with_dialog <backend args...> -- <dialog args...>
# Runs the backend producing bare percentage lines, filters them through a
# fifo into the dialog, and propagates either exit code. Cancelling the
# dialog kills the backend.
run_with_dialog() {
  local -a backend=() dialog=()
  local seen=0 arg
  for arg in "$@"; do
    if [[ $arg == "--" ]]; then
      seen=1
      continue
    fi
    [[ $seen -eq 0 ]] && backend+=("$arg") || dialog+=("$arg")
  done

  local status_file fifo pipe_pid
  status_file=$(mktemp)
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  run_progress_pipeline pipe_pid "$fifo" "$status_file" "${backend[@]}"

  "${dialog[@]}" <"$fifo"
  local dialog_exit=$?

  if [[ $dialog_exit -ne 0 ]]; then
    # ponytail: killing the drain subshell suffices; SIGPIPE propagates
    # drain -> grep -> tee -> backend and kills it.
    kill "$pipe_pid" 2>/dev/null || true
    wait "$pipe_pid" 2>/dev/null || true
    rm -f "$status_file" "$fifo"
    return "$dialog_exit"
  fi

  wait "$pipe_pid" || true
  local cmd_exit
  cmd_exit=$(cat "$status_file")
  rm -f "$status_file" "$fifo"

  [[ $cmd_exit -ne 0 ]] && return "$cmd_exit"
  return 0
}

# Usage: run_progress_pipeline <pipe_pid_ref> <fifo> <status_file> <cmd args...>
run_progress_pipeline() {
  local -n _pipe_pid_ref=$1
  shift
  local fifo="$1"
  shift
  local status_file="$1"
  shift
  local cmd=("$@")

  (
    local rc=0
    "${cmd[@]}" 2>&1 || rc=$?
    echo "$rc" >"$status_file"
  ) | tee >(grep -v -E '^[0-9]+$' >&2) | grep --line-buffered -E '^[0-9]+$' |
    {
      # ponytail: keep draining after the dialog closes at 100% so the backend
      # never sees a broken pipe mid-final-write; drop overruns after the reader
      # (yad/zenity) is gone. Open the fifo once; per-line opens would block.
      trap '' PIPE
      exec 3>"$fifo"
      while IFS= read -r p; do printf '%s\n' "$p" >&3 2>/dev/null || :; done
    } &

  _pipe_pid_ref=$!
}

#######################################
# KIO URI HANDLING
#######################################

# Converts a KIO URI (file:///path%20with%20space) to a local path.
# ponytail: pure bash percent-decode; paths cannot contain NUL so \x00 is a
# non-issue. Non-file:// inputs pass through untouched.
uri_to_path() {
  [[ $1 == file://* ]] || {
    printf '%s' "$1"
    return 0
  }
  local u="${1#file://}" out="" var
  while [[ $u =~ %([0-9A-Fa-f][0-9A-Fa-f]) ]]; do
    out+="${u%%"${BASH_REMATCH[0]}"*}"
    printf -v var "%b" "\\x${BASH_REMATCH[1]}"
    out+="$var"
    u="${u#*"${BASH_REMATCH[0]}"}"
  done
  printf '%s' "$out$u"
}

#######################################
# CHECKSUM OPERATIONS
#######################################

# Usage: verify_checksum_pair <archive_abs> <checksum_abs> <ui_title>
# Returns 0/1 (never exits); shows the health dialog on failure.
verify_checksum_pair() {
  local archive_abs="$1"
  local checksum_abs="$2"
  local ui_title="$3"
  local target_basename checksum_file expected actual
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log info "Verifying '$target_basename' against '$checksum_file'..."

  expected="$(head -n1 "$checksum_abs" | awk '{print $1}')"
  actual="$(hash_with_progress "$archive_abs" "$ui_title")" || return 1

  if [[ $expected != "$actual" ]]; then
    log error "Checksum verification FAILED for '$target_basename'"
    report_health_dialog 0 "$target_basename" "$ui_title"
    return 1
  fi

  log info "Checksum VERIFIED for '$target_basename'"
}

# Usage: run_check <archive> <ui_title>
# Verifies archive integrity and exits: health dialog + 0 on pass, 1 on fail.
run_check() {
  local archive="$1" title="$2"
  if check_archive "$archive" "$title"; then
    report_health_dialog 1 "$(basename "$archive")" "$title"
    exit 0
  fi
  exit 1
}

# Usage: check_archive <input> <ui_title>
# Resolves <input> (a .sqsh archive or its .sha256) to its pair, checks both
# exist, and verifies. Returns 0/1 (never exits).
check_archive() {
  local input="$1"
  local ui_title="$2"
  local input_abs archive_abs checksum_abs
  input_abs="$(realpath "$input")"

  archive_abs="${input_abs%.sha256}"
  checksum_abs="${archive_abs}.sha256"

  if [[ ! -f $archive_abs ]]; then
    log error "Archive file not found: '$archive_abs'"
    return 1
  fi

  if [[ ! -f $checksum_abs ]]; then
    log error "No paired checksum file found: '$checksum_abs'"
    return 1
  fi

  verify_checksum_pair "$archive_abs" "$checksum_abs" "$ui_title"
}

# Usage: hash_with_progress <file> <ui_title>
# Streams a SHA-256 of <file>, showing a YAD progress bar when a GUI is
# available (silent in --pipe mode). Prints the bare hash on stdout.
hash_with_progress() {
  local file="$1" title="$2" tmp fifo
  tmp="$(mktemp)"
  if ! command -v pv &>/dev/null || [[ $PIPE_MODE -eq 1 ]]; then
    sha256sum -- "$file" >"$tmp"
  elif command -v yad &>/dev/null; then
    fifo="$(mktemp -u)"
    mkfifo "$fifo"
    pv -n "$file" 2>"$fifo" | sha256sum >"$tmp" &
    local pid=$!
    if ! yad --progress \
      --title="$title" \
      --text="Hashing '$(basename "$file")'..." \
      --percentage=0 \
      --auto-close \
      --center \
      --width=450 \
      --borders=15 \
      --bar-style=normal <"$fifo"; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$fifo" "$tmp"
      return 1
    fi
    wait "$pid" || true
    rm -f "$fifo"
  else
    pv "$file" | sha256sum >"$tmp"
  fi
  awk '{print $1}' "$tmp"
  rm -f "$tmp"
}

# Usage: report_health_dialog <healthy:0|1> <file> <ui_title>
# Shows a GUI confirmation of checksum health. No-op without yad.
report_health_dialog() {
  local healthy="$1" file="$2" title="$3"
  # ponytail: --pipe is the headless mode (it already suppresses the yad
  # progress bar in hash_with_progress); no confirmation popup either.
  [[ $PIPE_MODE -eq 1 ]] && return 0
  if ! command -v yad &>/dev/null; then
    return 0
  fi
  if [[ $healthy -eq 1 ]]; then
    yad --info --title="$title" \
      --text="Checksum VERIFIED for '$file'" \
      --button="Continue:0" || true
  else
    yad --error --title="$title" \
      --text="Checksum verification FAILED for '$file'" \
      --button="Exit:0" || true
  fi
  return 0
}
