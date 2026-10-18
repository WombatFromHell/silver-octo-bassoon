#!/usr/bin/env bash
#######################################
# squish-common.sh
#
# Shared logic for squish.sh and unsquish.sh. Sourced, not executed.
# Expects PIPE_MODE (declare -i, 0/1) to be defined by the sourcing script.
#######################################

#
# Renderer contract: resolve_renderer decides once per run how progress reaches
# the user, and everything downstream reads RENDERER. A script fills BACKEND_ARGS
# with its tool argv for that renderer; show_progress runs it and feeds the
# dialog argv in DIALOG_ARGS. Nothing else re-decides, so a GUI cannot be found
# twice and disagree with itself mid-run.
#
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

# Usage: is_option_value <candidate>
# True when the candidate can be an option's value: present, and not another
# flag. Both CLIs ask the same question, so they ask it here.
is_option_value() {
  [[ -n ${1:-} && $1 != -* ]]
}

# Usage: missing_option_value <option-name>
# One sentence for every option used without a value; it ends the run.
missing_option_value() {
  log error "Argument for $1 is missing or invalid."
  exit 1
}

# Both markers mean machine-readable output for the whole run: --pipe streams
# progress, and squish's --print-mountpoint wants stdout to carry only a path.
# Scanning before the renderer is chosen keeps that one decision for the run.
pre_scan_pipe_mode() {
  local arg
  for arg in "$@"; do
    if [[ $arg == "--pipe" || $arg == "--print-mountpoint" ]]; then
      PIPE_MODE=1
      return 0
    fi
  done
}

#######################################
# RENDERER SELECTION
#######################################

# Usage: resolve_renderer
# Sets RENDERER to pipe, yad, zenity or cli. Call it once, after the arguments
# are scanned, before anything reports progress.
resolve_renderer() {
  if [[ $PIPE_MODE -eq 1 ]]; then
    RENDERER=pipe
  elif command -v yad &>/dev/null; then
    RENDERER=yad
  elif command -v zenity &>/dev/null; then
    RENDERER=zenity
  else
    RENDERER=cli
  fi
}

# Usage: dialog_args <yad|zenity> <title> <text>
# Sets DIALOG_ARGS to the gauge argv for that renderer.
dialog_args() {
  local ui="$1" title="$2" text="$3"
  DIALOG_ARGS=()
  case "$ui" in
  yad)
    DIALOG_ARGS=(yad --progress --title="$title" --text="$text" --percentage=0 --auto-close --center --width=450 --borders=15 --bar-style=normal)
    ;;
  zenity)
    DIALOG_ARGS=(zenity --progress --title="$title" --text="$text" --percentage=0 --auto-close)
    ;;
  *)
    log error "No GUI dialog arguments for renderer '$ui'."
    return 1
    ;;
  esac
}

# Usage: show_progress <title> <text>
# Runs BACKEND_ARGS and routes its progress lines into the renderer chosen for
# this run: bare percentages in pipe mode, a GUI gauge otherwise.
show_progress() {
  local title="$1" text="$2"
  case "${RENDERER:-}" in
  pipe)
    pipe_progress "${BACKEND_ARGS[@]}"
    ;;
  cli)
    "${BACKEND_ARGS[@]}"
    ;;
  yad | zenity)
    dialog_args "$RENDERER" "$title" "$text" || return 1
    run_with_dialog "${BACKEND_ARGS[@]}" -- "${DIALOG_ARGS[@]}"
    ;;
  *)
    log error "Renderer '$RENDERER' has no progress path."
    return 1
    ;;
  esac
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
# Runs the backend, whose progress lines the pipeline forwards to the dialog,
# and propagates either exit code. Cancelling the dialog kills the backend.
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

  (
    local rc=0
    "${backend[@]}" 2>&1 || rc=$?
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
  pipe_pid=$!

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
# Returns 0 verified, 1 mismatch or unreadable hash, 2 verification cancelled
# by the user (a closed GUI dialog: not corruption, so no FAILED dialog).
verify_checksum_pair() {
  local archive_abs="$1"
  local checksum_abs="$2"
  local ui_title="$3"
  local target_basename checksum_file expected actual hash_rc=0
  target_basename="$(basename "$archive_abs")"
  checksum_file="$(basename "$checksum_abs")"

  log info "Verifying '$target_basename' against '$checksum_file'..."

  expected="$(head -n1 "$checksum_abs" | awk '{print $1}')"
  actual="$(hash_with_progress "$archive_abs" "$ui_title")"
  hash_rc=$?
  if [[ $hash_rc -eq 2 ]]; then
    log warn "Checksum verification cancelled for '$target_basename'"
    return 2
  elif [[ $hash_rc -ne 0 ]]; then
    log error "Could not hash '$target_basename'"
    report_health_dialog 0 "$target_basename" "$ui_title"
    return 1
  fi

  if [[ $expected != "$actual" ]]; then
    log error "Checksum verification FAILED for '$target_basename'"
    report_health_dialog 0 "$target_basename" "$ui_title"
    return 1
  fi

  log info "Checksum VERIFIED for '$target_basename'"
}

# Usage: run_check <archive> <ui_title>
# Verifies archive integrity and exits: health dialog + 0 on pass, 1 on
# mismatch, 2 when verification was cancelled by the user.
run_check() {
  local archive="$1" title="$2" rc=0
  check_archive "$archive" "$title"
  rc=$?
  if [[ $rc -eq 0 ]]; then
    report_health_dialog 1 "$(basename "$archive")" "$title"
    exit 0
  fi
  exit $rc
}

# Usage: resolve_checksum_pair <input>
# Sets ARCHIVE_ABS and CHECKSUM_ABS from either half of the pair: <input> may
# be the archive or its .sha256. No existence check; which halves a caller
# needs is its own decision.
resolve_checksum_pair() {
  local input_abs
  input_abs="$(realpath "$1")"
  ARCHIVE_ABS="${input_abs%.sha256}"
  CHECKSUM_ABS="${ARCHIVE_ABS}.sha256"
}

# Usage: require_existing_archive <archive_abs>
# The archive half, named the same way by every caller that finds it missing.
require_existing_archive() {
  if [[ ! -f $1 ]]; then
    log error "Archive file not found: '$1'"
    return 1
  fi
}

# Usage: require_existing_pair <archive_abs> <checksum_abs>
# Both halves, for the callers that verify or extract.
require_existing_pair() {
  require_existing_archive "$1" || return 1
  if [[ ! -f $2 ]]; then
    log error "No paired checksum file found: '$2'"
    return 1
  fi
}

# Usage: check_archive <input> <ui_title>
# Resolves <input> (a .sqsh archive or its .sha256) to its pair, checks both
# exist, and verifies. Returns 0/1 (never exits).
check_archive() {
  local input="$1"
  local ui_title="$2"
  resolve_checksum_pair "$input"
  require_existing_pair "$ARCHIVE_ABS" "$CHECKSUM_ABS" || return 1
  verify_checksum_pair "$ARCHIVE_ABS" "$CHECKSUM_ABS" "$ui_title"
}

# Usage: hash_with_progress <file> <ui_title>
# Streams a SHA-256 of <file>, showing a YAD progress bar when a GUI is
# available (silent in --pipe mode). Prints the bare hash on stdout.
# Returns 2 when the progress dialog was closed or cancelled, 1 when hashing
# itself failed.
hash_with_progress() {
  local file="$1" title="$2" tmp fifo
  tmp="$(mktemp)"
  if [[ $RENDERER == pipe ]] || ! command -v pv &>/dev/null; then
    sha256sum -- "$file" >"$tmp"
  elif [[ $RENDERER == yad ]]; then
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
      return 2
    fi
    if ! wait "$pid"; then
      rm -f "$fifo" "$tmp"
      return 1
    fi
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
  [[ $RENDERER != yad ]] && return 0
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
