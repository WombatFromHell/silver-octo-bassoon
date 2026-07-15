#!/usr/bin/env bash
set -euo pipefail

# Mount / unmount SSHFS; prompts for password if no valid key is found.
NAS_HOME="$HOME/.mnt/nas-home"
MOUNT_POINT="josh@192.168.1.153:/home/josh"

# /run/user/$UID is a Linux-only (systemd) convention; macOS has no equivalent
RUNTIME_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
PID_FILE="$RUNTIME_DIR/nasmount-sshfs.pid"
LOG_FILE="$RUNTIME_DIR/nasmount-sshfs.log"
SSH_KEY="$HOME/.ssh/id_rsa"
#
LINK="$HOME/Backups"
TARGET="$NAS_HOME/GDrive/Backups"

# symlinking into $HOME is a side effect the user must opt into
is_truthy() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
  1 | true | y | yes | on) return 0 ;;
  *) return 1 ;;
  esac
}

if is_truthy "${LINK_ENABLED:-}"; then
  LINK_ENABLED=true
else
  LINK_ENABLED=false
fi

IS_MACOS=false
if [[ "$(uname)" == "Darwin" ]]; then
  IS_MACOS=true
fi

SSHFS_CONNECTION_OPTS=(-o "delay_connect,reconnect,ServerAliveInterval=30,ConnectTimeout=3,ConnectionAttempts=1")
SSHFS_OPTS=(-o "follow_symlinks,noatime,compression=no")
#
LINUX_SSHFS_OPTS=(-o "idmap=user")
MAC_SSHFS_OPTS=(-o "noappledouble,noapplexattr")
if ! $IS_MACOS; then
  # idmap=user is Linux-FUSE-only; macFUSE/fuse-t's sshfs rejects it
  SSHFS_OPTS+=("${SSHFS_CONNECTION_OPTS[@]}" "${LINUX_SSHFS_OPTS[@]}")
else
  SSHFS_OPTS+=("${SSHFS_CONNECTION_OPTS[@]}" "${MAC_SSHFS_OPTS[@]}")
fi

# `mountpoint` doesn't exist on macOS (even under fuse-t); use mount(1) instead
is_mounted() { if $IS_MACOS; then mount | grep -q " on $1 "; else mountpoint -q "$1"; fi; }

# `fusermount` doesn't exist on macOS/fuse-t either; use native umount
os_unmount() { if $IS_MACOS; then umount "$1"; else fusermount -u "$1"; fi; }

link_matches_target() {
  [[ -L "$LINK" ]] && [[ "$(readlink -f "$LINK")" == "$(readlink -f "$TARGET")" ]]
}

sync_link() {
  if [[ "$LINK_ENABLED" != "true" ]]; then
    remove_link
    return 0
  fi
  if link_matches_target; then
    return 0
  fi
  rm -f "$LINK"
  ln -sf "$TARGET" "$LINK"
}

remove_link() {
  if link_matches_target; then
    rm -f "$LINK"
  fi
  return 0
}

finish_mount() {
  echo "$1" >"$PID_FILE"
  sync_link
  return 0
}

deps=(sshfs)
if ! $IS_MACOS; then
  deps+=(fusermount)
fi
for d in "${deps[@]}"; do
  command -v "$d" &>/dev/null || {
    echo "nasmount: missing dependency: '$d'" >&2
    exit 127
  }
done

do_mount() {
  # Idempotency gate: lock file with live process OR active mountpoint
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    return 0
  fi
  if [[ -f "$PID_FILE" ]]; then
    rm -f "$PID_FILE"
  fi
  if is_mounted "$NAS_HOME"; then
    sync_link
    return 0
  fi

  mkdir -p "$NAS_HOME"
  HAS_KEY=false
  if [[ -r "$SSH_KEY" ]]; then
    SSHFS_OPTS+=(-o "IdentityFile=$SSH_KEY")
    HAS_KEY=true
  fi
  # Detect if we have a usable TTY for an interactive password prompt
  HAS_TTY=false
  if [[ -t 0 && -t 2 ]]; then
    HAS_TTY=true
  fi

  if $HAS_KEY || ! $HAS_TTY; then
    # Key-based OR no TTY (e.g., systemd): run detached
    # In no-TTY/no-key case, sshfs will fail fast rather than hang
    nohup sshfs "${SSHFS_OPTS[@]}" \
      "$MOUNT_POINT" "$NAS_HOME" \
      </dev/null >"$LOG_FILE" 2>&1 &
    local bg_pid=$!
    disown

    # Wait briefly for mount to appear (non-interactive path)
    for _ in {1..10}; do
      if is_mounted "$NAS_HOME"; then
        break
      fi
      sleep 1
    done

    if is_mounted "$NAS_HOME"; then
      finish_mount "$bg_pid"
    else
      echo "nasmount: background mount failed (check $LOG_FILE)" >&2
      return 1
    fi
  else
    # Interactive terminal + no key: foreground for password prompt
    echo "nasmount: mounting (password prompt expected)..."
    sshfs "${SSHFS_OPTS[@]}" "$MOUNT_POINT" "$NAS_HOME"
    local rc=$?
    if [[ $rc -ne 0 ]]; then
      return "$rc"
    fi
    local fg_pid
    fg_pid="$(pgrep -f "sshfs.*$NAS_HOME" | head -n1 || true)"
    finish_mount "$fg_pid"
  fi
}

do_unmount() {
  if [[ ! -f "$PID_FILE" ]] && ! is_mounted "$NAS_HOME"; then
    return 0
  fi
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
  fi
  os_unmount "$NAS_HOME" 2>/dev/null || true
  remove_link
  return 0
}

case "${1:-}" in
mount) do_mount ;;
unmount) do_unmount ;;
remount)
  do_unmount
  do_mount
  ;;
*)
  echo "Usage: nasmount-sshfs.sh <mount|unmount|remount>" >&2
  exit 1
  ;;
esac
