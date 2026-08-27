#!/usr/bin/env python3
"""Session-scoped LG TV resume waker.

Wrapper mode : lgc1-wold.py -- <rest-of-chain>
    Spawns the listener (detached), blocks until the TV finishes switching
    inputs, then execs into the launch chain. The listener dies with the
    chain, so it is active exactly for the session.
Poke         : lgc1-wold.py poke
    Send "wake" to the daemon and block until the TV finishes switching.
Listener     : lgc1-wold.py --_listen <parent-pid> <sock> <wol>  (internal)
"""

import atexit
import os
import select
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time

GRACE = 3.0  # let the NIC come back before sending WOL
MIN_INTERVAL = 30.0  # debounce window for repeated resume signals
_LOG_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
# No level knob: default is "full" (log everything). Override path via LG_WOL_LOG.
LOG = os.environ.get("LG_WOL_LOG", os.path.join(_LOG_DIR, "lgc1-wold.log"))
DEBUG = os.environ.get("LG_WOL_DEBUG")  # set non-empty to log raw dbus lines


def rotate_logs(path):
    # ponytail: keep only the previous run's log; add size/multi-backup policy if logs grow
    try:
        os.replace(path, f"{path}.0")
    except OSError:
        pass


def log(msg):
    if not LOG:
        return
    try:
        with open(LOG, "a") as f:
            f.write(time.strftime("%H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def sock_path():
    base = os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
    return os.environ.get("LG_WOL_SOCK", os.path.join(base, "lgc1-wol.sock"))


def wol_path():
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "lgc1-wol.py")


def spawn_dbus():
    cmd = os.environ.get("LG_WOL_DBUS_CMD")
    argv = (
        shlex.split(cmd)
        if cmd
        else [
            "dbus-monitor",
            "--system",
            "type='signal',sender='org.freedesktop.login1',interface='org.freedesktop.login1.Manager',member='PrepareForSleep'",
        ]
    )
    try:
        return subprocess.Popen(
            argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True
        )
    except OSError:
        return None


def daemon(parent_pid, sock, wol):
    last_start = 0.0
    last_loop = time.monotonic()
    RESUME_GAP = 5.0  # loop frozen longer than this => we resumed from suspend
    suspended = False

    def _ack(addr, status):
        if not addr:
            return
        try:
            s.sendto(status, addr)
        except OSError as e:
            log(f"ack send failed: {e}")

    def do_wake(reply_addr=None):
        nonlocal last_start, last_loop
        now = time.time()
        # ponytail: debounce alone suffices — do_wake blocks for GRACE + the
        # whole lgc1-wol.py run, so the single thread can't re-enter within
        # MIN_INTERVAL; no in-flight pid check.
        if now - last_start < MIN_INTERVAL:
            log("wake skipped (debounce)")
            _ack(reply_addr, b"skipped")
            return
        last_loop = time.monotonic()  # don't let GRACE sleep look like a freeze
        last_start = now
        time.sleep(GRACE)
        rc = None
        try:
            r = subprocess.run(
                [wol], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False
            )
            rc = r.returncode
            log(f"wake finished (rc={rc})")
        except OSError as e:
            log(f"wake failed: {e}")
        _ack(reply_addr, b"done" if rc == 0 else b"fail")

    def cleanup():
        try:
            os.unlink(sock)
        except OSError:
            pass

    try:
        os.unlink(sock)
    except OSError:
        pass

    rotate_logs(LOG)
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    s.bind(sock)
    log(f"listener started (parent={parent_pid} sock={sock})")

    # Default-on startup poke: wake the TV at session start through the same
    # path as resume/poke. Disable with LGC1_WOLD_POKE_ON_STARTUP=0.
    if os.environ.get("LGC1_WOLD_POKE_ON_STARTUP", "1") != "0":
        s.sendto(b"wake", sock)
        log("startup poke scheduled")

    dbus = spawn_dbus()

    def _term(*_):
        cleanup()
        sys.exit(0)

    signal.signal(signal.SIGTERM, _term)
    signal.signal(signal.SIGHUP, _term)
    atexit.register(cleanup)

    def on_resume(how):
        nonlocal suspended
        log(f"resume ({how})" + ("" if suspended else " [no prior standby seen]"))
        suspended = False
        s.sendto(b"wake", sock)

    while True:
        try:
            os.kill(parent_pid, 0)
        except OSError:
            break  # chain gone -> session over
        fds = [s]
        if dbus:
            fds.append(dbus.stdout)
        r, _, _ = select.select(fds, [], [], 1.0)

        # ponytail: dbus-monitor's bus conn drops on suspend and the
        # PrepareForSleep=false signal can be missed. A large loop gap means we
        # were frozen -> treat as resume regardless of dbus, and refresh the monitor.
        gap = time.monotonic() - last_loop
        if gap > RESUME_GAP:
            log(f"loop gap {gap:.1f}s (possible suspend/resume)")
            on_resume("clock-gap")
            if dbus:
                dbus.stdout.close()
                dbus = spawn_dbus()
                log(f"dbus-monitor respawned (pid={dbus.pid if dbus else None})")

        if s in r:
            try:
                data, addr = s.recvfrom(1024)
            except OSError:
                break
            if b"wake" in data:
                log("wake request via socket")
                do_wake(addr if b"wait" in data else None)
        if dbus and dbus.stdout in r:
            line = dbus.stdout.readline()
            if not line:
                dbus.stdout.close()
                dbus = spawn_dbus()
                log(f"dbus-monitor EOF -> respawned (pid={dbus.pid if dbus else None})")
                last_loop = time.monotonic()
                continue
            if DEBUG:
                log(f"dbus: {line.rstrip()}")
            if line.strip().startswith("boolean"):
                val = line.strip().split()[1]
                if val == "false":
                    on_resume("dbus PrepareForSleep=false")
                elif val == "true":
                    last_start = 0.0
                    suspended = True
                    log("standby (suspend imminent)")
        last_loop = time.monotonic()

    log(f"parent {parent_pid} gone -> exiting")
    cleanup()


def blocking_poke():
    # ponytail: the AF_UNIX datagram client must bind a reply socket here — an
    # unbound sender yields addr=None, so the daemon has nowhere to ack.
    s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    with tempfile.NamedTemporaryFile(delete=False, suffix=".sock", dir=_LOG_DIR) as tmp:
        reply_sock = tmp.name
    os.unlink(reply_sock)
    s.bind(reply_sock)
    s.settimeout(180)  # GRACE + lgc1-wol.py's 120s port poll
    try:
        s.sendto(b"wake\nwait", sock_path())
    except OSError as e:
        sys.exit(f"poke failed: {e}")
    try:
        data, _ = s.recvfrom(1024)
    except TimeoutError:
        sys.exit("poke timed out waiting for the TV to switch inputs")
    finally:
        try:
            os.unlink(reply_sock)
        except OSError:
            pass
    return data


def _poke_or_die(tag: str):
    if blocking_poke() == b"fail":
        sys.exit(f"poke: TV wake/switch failed ({tag})")


def poke():
    # b"done" or b"skipped" (debounced, a wake already in flight) -> success
    _poke_or_die("see daemon log")


def _wait_socket(path, timeout=10):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            os.stat(path)
            return True
        except OSError:
            time.sleep(0.05)
    return False


def wrapper(chain):
    if not chain:
        sys.exit("wrapper mode requires a command after --")
    # Disable the daemon's own startup poke so the wrapper drives exactly one
    # blocking wake and waits for it to finish before exec'ing the chain.
    env = dict(os.environ, LGC1_WOLD_POKE_ON_STARTUP="0")
    subprocess.Popen(
        [
            sys.executable,
            os.path.abspath(__file__),
            "--_listen",
            str(os.getpid()),
            sock_path(),
            wol_path(),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
        env=env,
    )
    if not _wait_socket(sock_path()):
        sys.exit("listener failed to start; aborting wrapped command")
    _poke_or_die("aborting wrapped command")
    os.execvp(chain[0], chain)


def main():
    argv = sys.argv[1:]
    if not argv:
        sys.exit("Usage: lgc1-wold.py -- <cmd...> | poke")
    match argv[0]:
        case "poke":
            poke()
        case "--_listen":
            daemon(int(argv[1]), argv[2], argv[3])
        case "--":
            wrapper(argv[1:])
        case _:
            sys.exit("Usage: lgc1-wold.py -- <cmd...> | poke")


if __name__ == "__main__":
    main()
