#!/usr/bin/env bash
#######################################
# squish-common.sh
#
# Shared logic for squish.sh and unsquish.sh. Sourced, not executed.
# Expects PIPE_MODE (declare -i, 0/1) to be defined by the sourcing script.
#######################################

# PROGRESS_PIPE says stdout is a progress stream (--pipe, not merely
# machine-readable): only that mode puts hash percentages on stdout.
# HASH_RESULT carries the hash out of band, so progress lines never mix into it.
declare -i PROGRESS_PIPE=0
declare HASH_RESULT=""

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
# Only --pipe gets PROGRESS_PIPE: a path on stdout must not be interrupted by
# percentage lines.
pre_scan_pipe_mode() {
  local arg
  for arg in "$@"; do
    case "$arg" in
    --pipe)
      PIPE_MODE=1
      PROGRESS_PIPE=1
      ;;
    --print-mountpoint)
      PIPE_MODE=1
      ;;
    esac
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
    # Declaring Cancel (exit code 1) also drops yad's default OK button, whose exit 0
    # reads as completion and lets the build run on.
    DIALOG_ARGS=(yad --progress --title="$title" --text="$text" --percentage=0 --auto-close --center --width=450 --borders=15 --bar-style=normal --button=Cancel:1)
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
    # Backgrounded like every other renderer: in the foreground, `set -m` gives the
    # tool its own process group, so Ctrl-C never reaches it and the cancel trap only
    # runs after the tool has finished the whole build.
    "${BACKEND_ARGS[@]}" &
    BACKEND_PID=$!
    local rc=0
    wait "$BACKEND_PID" || rc=$?
    BACKEND_PID=""
    [[ $CANCELLED -eq 1 ]] && return 2
    return "$rc"
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
# ONE OPERATION PER ARCHIVE
#######################################

# Locks and mount trackers share one per-user runtime dir, so the rule is written
# once here: a change to it moves both together.
# The per-user root. A shared /tmp fallback would be owned by whoever creates it
# first, so every other user's lock, tracker and temp file would fail.
runtime_root() { echo "${XDG_RUNTIME_DIR:-/tmp/squish-$(id -u)}"; }

# Locks live in the same per-user runtime dir as the mount trackers, so a lock
# never sits next to the archive (it would show up in listings and cannot be
# created on a read-only share).
lock_root() { echo "$(runtime_root)/squish-locks"; }

# Usage: lock_dir_for <absolute-path>
# The archive path is an operation's identity, so squish and unsquish contend on
# the same key. '_' is escaped first, so '/a_b' and '/a/b' never share a lock.
lock_dir_for() {
  local escaped="${1//_/__}"
  echo "$(lock_root)/${escaped//\//_}"
}

# Set while this run owns a lock.
declare LOCK_PID=""

# A pid is alive when /proc says so. `kill -0` is not the question: it also fails
# on a live process owned by another user (EPERM), which would make this run
# reclaim a lock somebody else is holding.
lock_pid_alive() { [[ -d "/proc/$1" ]]; }

# Usage: release_archive_lock
# Only the owner removes the lock, and the function always returns 0: a failing
# EXIT trap would replace the run's own exit status.
release_archive_lock() {
  if [[ -n $LOCK_PID ]] && [[ "$(readlink "$LOCK_PID" 2>/dev/null || true)" == "$BASHPID" ]]; then
    rm -f "$LOCK_PID"
  fi
  LOCK_PID=""
  return 0
}

# Usage: acquire_archive_lock <absolute-path>
# The lock is a symlink to the owner's pid: `ln` claims it atomically with the
# pid already recorded, so a second run can never read a half-written lock and
# steal it. A lock whose pid is gone is stale and gets reclaimed. Returns 3 when
# another run holds it — busy refuses rather than queues — and 1 when the lock root
# itself cannot be created, which is a broken runtime dir, not a busy archive.
acquire_archive_lock() {
  local dir pid
  dir="$(lock_dir_for "$1")"
  # A lock root we cannot create is not a busy archive: falling through to the busy
  # branch would tell the user to retry an operation nobody is holding. Locking is
  # what keeps two runs off one archive, so a run that cannot lock must not run.
  if ! mkdir -p "$dir" 2>/dev/null; then
    log error "Cannot create the lock directory '$dir'. Set XDG_RUNTIME_DIR to a writable directory."
    return 1
  fi

  if ln -s "$BASHPID" "$dir/pid" 2>/dev/null; then
    LOCK_PID="$dir/pid"
    trap release_archive_lock EXIT
    return 0
  fi

  pid="$(readlink "$dir/pid" 2>/dev/null || true)"
  if [[ -n $pid ]] && ! lock_pid_alive "$pid"; then
    # A run killed hard left a stale lock behind; take it and try once more.
    rm -f "$dir/pid"
    if ln -s "$BASHPID" "$dir/pid" 2>/dev/null; then
      LOCK_PID="$dir/pid"
      trap release_archive_lock EXIT
      return 0
    fi
  fi

  if [[ -z $pid ]]; then
    log error "Another squish operation on '$1' is starting. Try again shortly."
  else
    log error "Another squish operation on '$1' is running (pid $pid). Stop it with --cancel."
  fi
  return 3
}

# Usage: cancel_archive <absolute-path>
# The only way to free a busy archive is to stop the run holding it. That run's
# trap takes its backend down with it and exits 2, the existing "cancelled, not
# corrupted" code.
cancel_archive() {
  local dir pid cmd
  dir="$(lock_dir_for "$1")"
  pid="$(readlink "$dir/pid" 2>/dev/null || true)"
  if [[ -z $pid ]] || ! lock_pid_alive "$pid"; then
    log error "Nothing running for '$1'."
    return 1
  fi

  # A lock is a pid number, and a number proves nothing about who owns it: one
  # recycled after a hard kill would be the user's browser.
  cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
  if ! is_squish_run "$cmd"; then
    log error "Lock pid $pid is not a squish run; refusing to kill it."
    return 1
  fi

  log info "Cancelling the operation on '$1' (pid $pid)."
  kill -TERM "$pid"
}

# Usage: lock_key_to_path <lock-dir-name>
# Undo lock_dir_for's escaping: a doubled '__' is a literal '_' that was escaped, so it goes
# to a placeholder first, every remaining '_' is a '/', then the placeholder comes back.
lock_key_to_path() {
  local key="${1//__/$'\x01'}"
  key="${key//_//}"
  printf '%s' "${key//$'\x01'/_}"
}

# Usage: cancel_running
# --cancel with no archive, for a caller that cannot name one: a keyboard binding pressed
# mid-build does not know which dated output a multi-item build chose. The lock root already
# records who is running, so exactly one live squish run is stopped. Several are refused and
# named rather than guessed, and a lock naming something that is not a squish run is ignored.
cancel_running() {
  local root dir key pid cmd paths=() n=0
  root="$(lock_root)"
  for dir in "$root"/*/; do
    dir="${dir%/}"
    # The pid entry is a symlink whose target is a number, not a file, so test the link.
    [[ -L "$dir/pid" ]] || continue
    pid="$(readlink "$dir/pid" 2>/dev/null || true)"
    if [[ -z $pid ]]; then
      continue
    fi
    if ! lock_pid_alive "$pid"; then
      continue
    fi
    cmd="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null || true)"
    is_squish_run "$cmd" || continue
    key="${dir##*/}"
    paths+=("$(lock_key_to_path "$key")")
    n=$((n + 1))
  done

  if ((n == 0)); then
    log error "Nothing running for this user."
    return 1
  fi
  if ((n > 1)); then
    log error "$n squish operations are running; --cancel needs one of them named:"
    for dir in "${paths[@]}"; do
      log error "  $dir"
    done
    return 1
  fi

  cancel_archive "${paths[0]}"
}

# Usage: cancel_or_exit [archive-path]
# The shared --cancel tail of both scripts: with a path, resolve a possible KIO URI and stop
# whoever holds that lock; without one, ask the lock root who is running. Either way the
# outcome is this run's exit code.
cancel_or_exit() {
  if [[ -n $1 ]]; then
    cancel_archive "$(realpath "$(uri_to_path "$1")")" || exit 1
  else
    cancel_running || exit 1
  fi
  exit 0
}

# Usage: is_squish_run <cmdline>
# Ownership of a lock is proved by the owner's command line naming the script, under
# whichever name it was invoked with: squish.sh, the installed symlink `squish`, or a
# `sh -c "squish ..."` from a GUI caller such as the yazi plugin.
is_squish_run() {
  [[ $1 =~ (^|[[:space:]/])(squish|unsquish)(\.sh)?([[:space:]]|$) ]]
}

#######################################
# PIPE MODE
#######################################

# Set while a tool child of this run is alive, and once a signal has hit it.
declare BACKEND_PID=""
declare -i CANCELLED=0

# Usage: install_cancel_trap
# A TERM/INT aimed at this script must stop whatever tool it is running, or that
# tool keeps writing into a directory the script is about to delete. Every phase
# that spawns a long child sets BACKEND_PID, so one trap covers hash, build and
# extract alike.
install_cancel_trap() {
  # The handler must never fail: under `set -e` a failing kill would abort the
  # run with status 1 instead of the cancelled code 2. The kill aims at the
  # child's process group, which needs the sourcing script's `set -m`.
  # shortcut: TERM/INT only — a SIGKILL aimed at this script leaves its tool
  # running; upgrade to killing the whole process group if anyone uses -9.
  trap 'CANCELLED=1; [[ -n $BACKEND_PID ]] && kill -- -"$BACKEND_PID" 2>/dev/null || true' TERM INT
}

# Usage: pipe_progress <cmd args...>
# Machine-readable mode: bare percentage lines to stdout, rest to stderr.
# The backend is a direct child writing to a FIFO, not half of a pipeline, so its
# pid is known: a TERM/INT aimed at this script (Ctrl-C, yazi's start_kill,
# --cancel) has to take the backend down too, and exit code 2 says "cancelled",
# not "corrupted".
pipe_progress() {
  local fifo backend_pid line rc=0
  fifo="$(mktemp -u)"
  mkfifo "$fifo"

  "$@" >"$fifo" 2>&1 &
  backend_pid=$!
  BACKEND_PID="$backend_pid"

  while IFS= read -r line; do
    if [[ $line =~ ^[0-9]+$ ]]; then
      printf '%s\n' "$line"
    else
      printf '%s\n' "$line" >&2
    fi
  done <"$fifo"

  wait "$backend_pid" || rc=$?
  BACKEND_PID=""
  rm -f "$fifo"
  [[ $CANCELLED -eq 1 ]] && rc=2
  return "$rc"
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

  local status_file fifo pipe_pid dialog_pid
  status_file=$(mktemp)
  fifo=$(mktemp -u)
  mkfifo "$fifo"

  # The whole pipeline is ONE background job. `set -m` gives every element of a bare
  # pipeline its own process group and `$!` names only the last element, so a bare
  # pipeline's `$!` is never the group the tool lives in. Wrapped, `$!` is the group
  # leader and a cancel reaches mksquashfs itself instead of only the drain.
  {
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
      }
  } &
  pipe_pid=$!
  # The dialog's backend is this pipeline's process group, so the cancel trap aims at
  # it. SIGPIPE alone is not enough: the tool's stdout is a pipe, so its C library
  # buffers progress lines and it may never write again, and never see the signal.
  BACKEND_PID="$pipe_pid"

  # A dialog in the foreground would defer the cancel trap until it closes, so
  # the run would finish instead of stopping. As a background job, `wait` returns
  # as soon as the signal lands.
  "${dialog[@]}" <"$fifo" &
  dialog_pid=$!
  local dialog_exit=0
  wait "$dialog_pid" || dialog_exit=$?
  BACKEND_PID=""

  # A cancel signal already took the drain down; the dialog gets EOF, and one
  # that ignores it is closed outright. The run's contract is exit 2
  # ("cancelled"), whatever the backend or dialog reported in that race.
  if [[ $CANCELLED -eq 1 ]]; then
    kill -- -"$dialog_pid" -"$pipe_pid" 2>/dev/null || true
    wait "$dialog_pid" 2>/dev/null || true
    wait "$pipe_pid" 2>/dev/null || true
    rm -f "$status_file" "$fifo"
    return 2
  fi

  # A dialog that vanishes while the tool is still working is the user stopping the run,
  # whatever code it exits with: yad answers 1 for its Cancel button and 252 for Esc or a
  # window close, but a window manager on Wayland can answer 0. Give the tool a moment to
  # record an exit first, so an auto-close at 100% is still read as success.
  local cmd_exit dismissed=0
  cmd_exit="$(cat "$status_file" 2>/dev/null || true)"
  if [[ $dialog_exit -eq 0 && -z $cmd_exit ]]; then
    local settle=20
    while ((settle-- > 0)) && [[ -z $cmd_exit ]]; do
      sleep 0.05
      cmd_exit="$(cat "$status_file" 2>/dev/null || true)"
    done
    [[ -z $cmd_exit ]] && dismissed=1
  fi

  if [[ $dismissed -eq 1 || $dialog_exit -ne 0 ]]; then
    # Kill the pipeline's group, then answer cancelled unless the tool had already
    # recorded a failure of its own. The code is read before the kill, so a killed
    # backend's 143 never replaces the user's cancel.
    kill -- -"$pipe_pid" 2>/dev/null || true
    wait "$pipe_pid" 2>/dev/null || true
    rm -f "$status_file" "$fifo"
    [[ -n $cmd_exit ]] && return "$cmd_exit"
    # Callers decide on this flag, not on the code: a dismissed dialog is a cancel.
    CANCELLED=1
    return 2
  fi

  wait "$pipe_pid" || true
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

  # Reading the hash file is the first step of a verify; a pipe consumer hears it
  # before the archive's own hash starts streaming percentages.
  [[ $PROGRESS_PIPE -eq 1 ]] && printf 'phase hashfile-read\n'
  expected="$(head -n1 "$checksum_abs" | awk '{print $1}')"
  hash_with_progress "$archive_abs" "$ui_title" || hash_rc=$?
  actual="$HASH_RESULT"
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
# Hashes <file> and puts the bare hex in HASH_RESULT. Progress reaches the
# renderer chosen for the run: --pipe emits a `phase hash` marker and bare
# percentage lines on stdout, yad shows a gauge, everything else gets pv's bar.
# Returns 2 when the progress dialog was closed or cancelled, 1 when hashing
# itself failed.
hash_with_progress() {
  local file="$1" title="$2" tmp fifo rc=0
  tmp="$(mktemp)"
  if [[ $PROGRESS_PIPE -eq 1 ]] && command -v pv &>/dev/null; then
    # pv's percentage lines have to reach the script's stdout while its bytes
    # go to sha256sum, so the progress stream is handed out on fd 4.
    printf 'phase hash\n'
    exec 4>&1
    # Backgrounded so a cancel lands during the hash instead of after it: a
    # foreground pipeline defers the trap, and a background child ignores SIGTERM.
    pv -n -i 0.5 -- "$file" 2>&4 | sha256sum >"$tmp" &
    local pid=$!
    BACKEND_PID="$pid"
    wait "$pid" || rc=$?
    BACKEND_PID=""
    exec 4>&-
    if [[ $CANCELLED -eq 1 ]]; then
      rm -f "$tmp"
      return 2
    fi
    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      return 1
    fi
  elif [[ $RENDERER == pipe ]] || ! command -v pv &>/dev/null; then
    # Backgrounded like the branch above: a foreground hash defers the cancel trap
    # until the whole file is hashed, so Ctrl-C finished the verification instead of
    # stopping it.
    sha256sum -- "$file" >"$tmp" &
    local pid=$!
    BACKEND_PID="$pid"
    wait "$pid" || rc=$?
    BACKEND_PID=""
    if [[ $CANCELLED -eq 1 ]]; then
      rm -f "$tmp"
      return 2
    fi
    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      return 1
    fi
  elif [[ $RENDERER == yad ]]; then
    fifo="$(mktemp -u)"
    mkfifo "$fifo"
    # One job, so one process group: `set -m` splits a bare pipeline into a group per
    # element and `$!` names only the last, so the cancel kill would miss pv.
    { pv -n "$file" 2>"$fifo" | sha256sum >"$tmp"; } &
    local pid=$!
    BACKEND_PID="$pid"
    # The dialog is a background job too: a foreground dialog defers the cancel
    # trap until it closes, so the hash would run to the end.
    dialog_args yad "$title" "Hashing '$(basename "$file")'..."
    "${DIALOG_ARGS[@]}" <"$fifo" &
    local dialog_pid=$!
    local dialog_exit=0
    wait "$dialog_pid" || dialog_exit=$?
    BACKEND_PID=""

    if [[ $CANCELLED -eq 1 ]]; then
      kill -- -"$dialog_pid" -"$pid" 2>/dev/null || true
      wait "$dialog_pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$fifo" "$tmp"
      return 2
    fi
    # Same contract as run_with_dialog: a dialog gone while pv is still hashing is a
    # cancel, so the empty hash decides, not the dialog's code (a window manager can
    # answer 0). A written hash means the dialog closed at 100% and the run succeeded.
    local dismissed=0
    if [[ $dialog_exit -eq 0 && ! -s "$tmp" ]]; then
      local settle=20
      while ((settle-- > 0)) && [[ ! -s "$tmp" ]]; do sleep 0.05; done
      [[ ! -s "$tmp" ]] && dismissed=1
    fi
    if [[ $dismissed -eq 1 || $dialog_exit -ne 0 ]]; then
      kill -- -"$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      rm -f "$fifo" "$tmp"
      # Same flag, so a dismissed hash gauge reports a cancel, not a failed hash.
      CANCELLED=1
      return 2
    fi
    if ! wait "$pid"; then
      rm -f "$fifo" "$tmp"
      return 1
    fi
    rm -f "$fifo"
  else
    # Same shape: the hash has to be cancellable while it is running, not after.
    pv "$file" | sha256sum >"$tmp" &
    local pid=$!
    BACKEND_PID="$pid"
    wait "$pid" || rc=$?
    BACKEND_PID=""
    if [[ $CANCELLED -eq 1 ]]; then
      rm -f "$tmp"
      return 2
    fi
    if [[ $rc -ne 0 ]]; then
      rm -f "$tmp"
      return 1
    fi
  fi
  HASH_RESULT="$(awk '{print $1}' "$tmp")"
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
