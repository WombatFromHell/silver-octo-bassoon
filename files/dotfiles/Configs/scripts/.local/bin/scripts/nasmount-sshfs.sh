#!/usr/bin/env bash
# Mount / unmount SSHFS asynchronously; safe to call repeatedly.

NAS_HOME="$HOME/.nas-home"
MOUNT_POINT="nxxel@192.168.1.153:/share/homes/nxxel"
LINK="$HOME/Backups"
TARGET="$NAS_HOME/GDrive/Backups"
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
PID_FILE="$RUNTIME_DIR/nasmount-sshfs.pid"
LOG_FILE="$RUNTIME_DIR/nasmount-sshfs.log"

deps=(sshfs fusermount)
for d in "${deps[@]}"; do
  command -v "$d" &>/dev/null || {
    echo "nasmount: missing dependency: '$d'" >&2
    exit 127
  }
done

do_mount() {
  # Idempotency gate: lock file with live process OR mountpoint
  if [[ -f "$PID_FILE" ]]; then
    if kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
      exit 0
    fi
    # Stale PID file — clean up and continue
    rm -f "$PID_FILE"
  fi
  if mountpoint -q "$NAS_HOME"; then
    if [[ ! -L "$LINK" ]] || [[ "$(readlink -f "$LINK")" != "$(readlink -f "$TARGET")" ]]; then
      rm -f "$LINK"
      ln -sf "$TARGET" "$LINK"
    fi
    exit 0
  fi

  # Detach — everything below runs in background
  nohup bash -c "
        mkdir -p '$NAS_HOME'
        sshfs -p 2222 -o reconnect,noatime,cache_timeout=1,IdentityFile=~/.ssh/id_rsa,idmap=user '$MOUNT_POINT' '$NAS_HOME' &
        echo \$! > '$PID_FILE'

        # Wait for mount to be visible
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if mountpoint -q '$NAS_HOME'; then
                rm -f '$LINK'
                ln -sf '$TARGET' '$LINK'
                break
            fi
            sleep 1
        done

        # Keep subshell alive so sshfs stays attached to a parent
        wait \$!
    " </dev/null >"$LOG_FILE" 2>&1 &
  disown

  exit 0
}

do_unmount() {
  # Idempotency gate: nothing to unmount if no lock AND no mount
  if [[ ! -f "$PID_FILE" ]] && ! mountpoint -q "$NAS_HOME"; then
    exit 0
  fi

  # Kill the backgrounded sshfs if it's still running
  if [[ -f "$PID_FILE" ]]; then
    kill "$(cat "$PID_FILE")" 2>/dev/null
    rm -f "$PID_FILE"
  fi

  # Unmount (best-effort)
  fusermount -u "$NAS_HOME" 2>/dev/null || true

  # Clean up symlink
  if [[ -L "$LINK" ]]; then
    rm -f "$LINK"
  fi

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
