#!/usr/bin/env bash
# Mount / unmount SSHFS; prompts for password if no valid key is found.

NAS_HOME="$HOME/.mnt/nas-home"
MOUNT_POINT="josh@192.168.1.153:/home/josh"
LINK="$HOME/Backups"
TARGET="$NAS_HOME/GDrive/Backups"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
PID_FILE="$RUNTIME_DIR/nasmount-sshfs.pid"
LOG_FILE="$RUNTIME_DIR/nasmount-sshfs.log"
SSH_KEY="$HOME/.ssh/id_rsa"

SSHFS_OPTS=(-o "delay_connect,default_permissions,follow_symlinks,reconnect,ServerAliveInterval=15,ConnectTimeout=3,ConnectionAttempts=1,noatime,idmap=user")

deps=(sshfs fusermount)
for d in "${deps[@]}"; do
  command -v "$d" &>/dev/null || {
    echo "nasmount: missing dependency: '$d'" >&2
    exit 127
  }
done

do_mount() {
  # Idempotency gate: lock file with live process OR active mountpoint
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    exit 0
  fi
  [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"

  if mountpoint -q "$NAS_HOME"; then
    if [[ ! -L "$LINK" ]] || [[ "$(readlink -f "$LINK")" != "$(readlink -f "$TARGET")" ]]; then
      rm -f "$LINK"
      ln -sf "$TARGET" "$LINK"
    fi
    exit 0
  fi

  mkdir -p "$NAS_HOME"

  HAS_KEY=false
  if [[ -r "$SSH_KEY" ]]; then
    SSHFS_OPTS+=(-o "IdentityFile=$SSH_KEY")
    HAS_KEY=true
  fi

  # Detect if we have a usable TTY
  HAS_TTY=false
  if [[ -t 0 ]] && [[ -t 2 ]]; then
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
      mountpoint -q "$NAS_HOME" && break
      sleep 1
    done

    if mountpoint -q "$NAS_HOME"; then
      echo "$bg_pid" >"$PID_FILE"
      rm -f "$LINK" && ln -sf "$TARGET" "$LINK"
      exit 0
    else
      echo "nasmount: background mount failed (check $LOG_FILE)" >&2
      exit 1
    fi
  else
    # Interactive terminal + no key: foreground for password prompt
    echo "nasmount: mounting (password prompt expected)..."
    sshfs "${SSHFS_OPTS[@]}" "$MOUNT_POINT" "$NAS_HOME"
    local rc=$?
    [[ $rc -ne 0 ]] && exit "$rc"

    rm -f "$LINK" && ln -sf "$TARGET" "$LINK"
    pgrep -f "sshfs.*$NAS_HOME" | head -n1 >"$PID_FILE"
    exit 0
  fi
}

do_unmount() {
  if [[ ! -f "$PID_FILE" ]] && ! mountpoint -q "$NAS_HOME"; then
    exit 0
  fi

  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
  fi

  fusermount -u "$NAS_HOME" 2>/dev/null || true

  [[ -L "$LINK" ]] && rm -f "$LINK"

  exit 0
}

case "$1" in
mount) do_mount ;;
unmount) do_unmount ;;
*)
  echo "Usage: nasmount-sshfs.sh <mount|unmount>" >&2
  exit 1
  ;;
esac
