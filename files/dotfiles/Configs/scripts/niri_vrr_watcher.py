#!/usr/bin/env python3
"""
niri_vrr_watcher.py — Auto-enable VRR for fullscreen applications in niri.

Architecture:
    config       — Pure dataclasses / settings (no I/O)
    models       — Immutable value objects parsed from niri JSON
    fetchers     — Thin I/O wrappers that return raw JSON strings
    parsers      — Pure JSON → model converters (easy to unit-test)
    evaluators   — Pure business-logic predicates (easy to unit-test)
    gpu          — GPU-PID ancestor resolution (side-effectful, mockable)
    hooks        — Hook execution (side-effectful, mockable)
    niri         — niri msg command wrappers (side-effectful, mockable)
    state        — Mutable runtime state container
    orchestrator — Main poll loop; wires all layers together
"""

from __future__ import annotations

import logging
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Logging setup (done before imports that might log)
# ---------------------------------------------------------------------------


def _build_logger(log_path: Path, debug: bool, use_journald: bool = False) -> logging.Logger:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("niri_vrr")
    logger.setLevel(logging.DEBUG if debug else logging.INFO)
    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s", datefmt="%F %T"
    )

    # File handler (always present)
    fh = logging.FileHandler(log_path, mode="w", encoding="utf-8")
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    # Journald handler (for systemd service units)
    if use_journald:
        try:
            from systemd.journal import JournalHandler

            jfmt = logging.Formatter(
                "%(levelname)s: %(message)s"
            )
            jh = JournalHandler(SYSLOG_IDENTIFIER="niri-vrr-watcher")
            jh.setFormatter(jfmt)
            # Mirror to stderr so journalctl also captures it
            logger.addHandler(jh)

            sh = logging.StreamHandler(sys.stderr)
            sh.setFormatter(jfmt)
            logger.addHandler(sh)
        except ImportError:
            # python-systemd not installed — fall back to stderr only
            sh = logging.StreamHandler(sys.stderr)
            sh.setFormatter(fmt)
            logger.addHandler(sh)
            logger.debug("python-systemd not available; using stderr only")

    return logger


log = logging.getLogger("niri_vrr")  # module-level; wired in main()


# ===========================================================================
# config — pure settings, no I/O
# ===========================================================================

_RUNTIME_DIR = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
_HOME = str(Path.home())


@dataclass(frozen=True)
class Config:
    poll_interval: float = float(os.environ.get("NIRI_VRR_POLL_INTERVAL", "2"))
    log_file: Path = Path(
        os.environ.get("NIRI_VRR_LOG_FILE", f"{_RUNTIME_DIR}/niri-watcher.log")
    )
    startup_delay: float = float(os.environ.get("NIRI_VRR_STARTUP_DELAY", "3"))
    debug_mode: bool = os.environ.get("NIRI_VRR_DEBUG", "0") == "1"
    relaxed_mode: bool = os.environ.get("NIRI_VRR_RELAXED_MODE", "0") == "1"

    hook_on: str = f"{_HOME}/.local/bin/scripts/perfboost.sh on"
    hook_off: str = f"{_HOME}/.local/bin/scripts/perfboost.sh off"

    excluded_apps: frozenset[str] = frozenset(
        {
            "brave-browser",
            "brave-browser-beta",
            "org.mozilla.firefox",
            "org.kde.haruna",
            "mpv",
            "io.mpv.Mpv",
            "com.spotify.Client",
            "vesktop",
            "com.discordapp.Discord",
        }
    )


# ===========================================================================
# models — immutable value objects
# ===========================================================================


@dataclass(frozen=True)
class OutputInfo:
    name: str
    width: int
    height: int

    @property
    def resolution(self) -> tuple[int, int]:
        return (self.width, self.height)


@dataclass(frozen=True)
class WindowInfo:
    app_id: str
    pid: int | None
    workspace_id: int | None
    tile_w: int | None
    tile_h: int | None
    win_w: int | None
    win_h: int | None
    is_focused: bool

    @property
    def effective_size(self) -> tuple[int, int] | None:
        """Prefer tile size, fall back to window size."""
        if self.tile_w is not None and self.tile_h is not None:
            return (self.tile_w, self.tile_h)
        if self.win_w is not None and self.win_h is not None:
            return (self.win_w, self.win_h)
        return None


# ===========================================================================
# fetchers — thin I/O wrappers (mockable in tests)
# ===========================================================================


def _run_json(args: list[str]) -> str:
    """Run a command and return stdout as a string; return sentinel on failure."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        return result.stdout.strip() or (
            "[]" if args[-1] in ("windows", "workspaces") else "{}"
        )
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return "[]" if args[-1] in ("windows", "workspaces") else "{}"


def fetch_niri_outputs() -> str:
    return _run_json(["niri", "msg", "-j", "outputs"]) or "{}"


def fetch_niri_windows() -> str:
    return _run_json(["niri", "msg", "-j", "windows"]) or "[]"


def fetch_niri_workspaces() -> str:
    return _run_json(["niri", "msg", "-j", "workspaces"]) or "[]"


def fetch_gpu_pids() -> list[int]:
    """Return PIDs of processes doing GPU graphic+compute work via nvtop -s."""
    try:
        import json

        result = subprocess.run(
            ["nvtop", "-s"], capture_output=True, text=True, timeout=5
        )
        data = json.loads(result.stdout)
        pids: list[int] = []
        for entry in data:
            for proc in entry.get("processes", []):
                if proc.get("kind") == "graphic & compute":
                    pid = proc.get("pid")
                    if pid is not None:
                        try:
                            pids.append(int(pid))
                        except (ValueError, TypeError):
                            pass
        return pids
    except Exception:
        return []


# ===========================================================================
# parsers — pure JSON → model converters
# ===========================================================================


def parse_outputs(outputs_json: str) -> dict[str, OutputInfo]:
    """
    Parse niri outputs JSON (object keyed by output name).
    Returns {output_name: OutputInfo}.
    """
    import json

    try:
        data: dict = json.loads(outputs_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse outputs JSON")
        return {}

    result: dict[str, OutputInfo] = {}
    for name, info in data.items():
        modes = info.get("modes", [])
        current_idx = info.get("current_mode")
        try:
            mode = modes[current_idx] if current_idx is not None else modes[0]
            w, h = int(mode["width"]), int(mode["height"])
        except (IndexError, KeyError, TypeError, ValueError):
            log.debug("Could not determine mode for output %s", name)
            continue
        result[name] = OutputInfo(name=name, width=w, height=h)

    return result


def parse_workspaces(workspaces_json: str) -> dict[int, str]:
    """
    Parse niri workspaces JSON (array).
    Returns {workspace_id: output_name}.
    """
    import json

    try:
        data: list = json.loads(workspaces_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse workspaces JSON")
        return {}

    result: dict[int, str] = {}
    for ws in data:
        ws_id = ws.get("id")
        output = ws.get("output", "")
        if ws_id is not None and output:
            result[int(ws_id)] = output

    return result


def parse_windows(windows_json: str) -> list[WindowInfo]:
    """
    Parse niri windows JSON (array).
    Returns list of WindowInfo objects.
    """
    import json

    def _int_or_none(v: object) -> int | None:
        try:
            return int(float(str(v)))  # handles "1920.0" etc.
        except (TypeError, ValueError):
            return None

    try:
        data: list = json.loads(windows_json)
    except json.JSONDecodeError:
        log.warning("Failed to parse windows JSON")
        return []

    windows: list[WindowInfo] = []
    for win in data:
        layout = win.get("layout", {})
        tile_size = layout.get("tile_size") or []
        win_size = layout.get("window_size") or []

        windows.append(
            WindowInfo(
                app_id=str(win.get("app_id") or ""),
                pid=_int_or_none(win.get("pid")),
                workspace_id=_int_or_none(win.get("workspace_id")),
                tile_w=_int_or_none(tile_size[0]) if len(tile_size) > 0 else None,
                tile_h=_int_or_none(tile_size[1]) if len(tile_size) > 1 else None,
                win_w=_int_or_none(win_size[0]) if len(win_size) > 0 else None,
                win_h=_int_or_none(win_size[1]) if len(win_size) > 1 else None,
                is_focused=bool(win.get("is_focused", False)),
            )
        )

    return windows


# ===========================================================================
# evaluators — pure business-logic predicates
# ===========================================================================


def is_app_excluded(app_id: str, excluded: frozenset[str]) -> bool:
    return app_id in excluded


def is_fullscreen(window: WindowInfo, output: OutputInfo) -> bool:
    size = window.effective_size
    if size is None:
        return False
    return size == output.resolution


def resolve_output_for_window(
    window: WindowInfo,
    ws_to_output: dict[int, str],
    outputs: dict[str, OutputInfo],
) -> OutputInfo | None:
    """Return the OutputInfo the window lives on, or None if unknown."""
    if window.workspace_id is None:
        return None
    output_name = ws_to_output.get(window.workspace_id)
    if output_name is None:
        return None
    return outputs.get(output_name)


def window_wants_vrr(
    window: WindowInfo,
    ws_to_output: dict[int, str],
    outputs: dict[str, OutputInfo],
    excluded_apps: frozenset[str],
    gpu_ancestor_pids: set[int],
    relaxed_mode: bool,
) -> OutputInfo | None:
    """
    Return the OutputInfo that should have VRR enabled for this window,
    or None if VRR should not be enabled.

    Pure function — all external state passed as arguments.
    """
    if not window.is_focused:
        return None

    output = resolve_output_for_window(window, ws_to_output, outputs)
    if output is None:
        return None

    if window.app_id and is_app_excluded(window.app_id, excluded_apps):
        log.debug("⊘ Excluded: %s", window.app_id)
        return None

    if not is_fullscreen(window, output):
        return None

    if not relaxed_mode:
        has_any_gpu = bool(gpu_ancestor_pids)
        pid_is_gpu = window.pid is not None and window.pid in gpu_ancestor_pids
        if not pid_is_gpu:
            if not has_any_gpu:
                return None
            log.debug("✓ GPU activity (fallback): %s", window.app_id)
        # pid_is_gpu → direct match, pass through
    else:
        log.debug("✓ Fullscreen (relaxed mode): %s", window.app_id)

    return output


def compute_desired_vrr(
    windows: list[WindowInfo],
    ws_to_output: dict[int, str],
    outputs: dict[str, OutputInfo],
    excluded_apps: frozenset[str],
    gpu_ancestor_pids: set[int],
    relaxed_mode: bool,
) -> dict[str, bool]:
    """
    Return {output_name: vrr_desired} for all known outputs.

    Pure function — deterministic given its inputs.
    """
    desired = {name: False for name in outputs}

    for window in windows:
        output = window_wants_vrr(
            window,
            ws_to_output,
            outputs,
            excluded_apps,
            gpu_ancestor_pids,
            relaxed_mode,
        )
        if output is not None:
            desired[output.name] = True

    return desired


# ===========================================================================
# gpu — GPU-PID ancestor resolution
# ===========================================================================


def _get_ppid(pid: int) -> int | None:
    """Return parent PID for pid, or None if unavailable."""
    try:
        result = subprocess.run(
            ["ps", "-o", "ppid=", "-p", str(pid)],
            capture_output=True,
            text=True,
            timeout=2,
        )
        ppid_str = result.stdout.strip()
        return int(ppid_str) if ppid_str else None
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return None


def build_gpu_ancestor_set(leaf_pids: Iterable[int]) -> set[int]:
    """
    Walk the process tree upward from each GPU leaf PID.
    Returns a set of all ancestor PIDs (including the leaves).
    """
    ancestors: set[int] = set()
    for leaf in leaf_pids:
        current: int | None = leaf
        while current is not None and current not in (0, 1):
            if current in ancestors:
                break  # already walked this branch
            ancestors.add(current)
            current = _get_ppid(current)

    log.debug(
        "GPU ancestor set: %d PIDs from %d leaves",
        len(ancestors),
        len(list(leaf_pids) if hasattr(leaf_pids, "__len__") else []),
    )
    return ancestors


# ===========================================================================
# hooks — hook execution
# ===========================================================================


def execute_hook(
    hook_spec: str,
    output_name: str,
    app_pid: int | None = None,
) -> None:
    """Execute a hook command asynchronously. Failures are logged, not raised."""
    if not hook_spec:
        return
    parts = hook_spec.split()
    cmd, args = parts[0], parts[1:]
    if not shutil.which(cmd) and not Path(cmd).is_file():
        log.warning("Hook not found/executable: %s", cmd)
        return
    env = {
        **os.environ,
        "NIRI_OUTPUT_NAME": output_name,
        "NIRI_APP_PID": str(app_pid) if app_pid is not None else "",
    }
    try:
        subprocess.Popen(
            [cmd, *args], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        log.info("Executing hook: %s", hook_spec)
    except OSError as exc:
        log.warning("Hook execution failed (%s): %s", hook_spec, exc)


# ===========================================================================
# niri — niri msg command wrappers
# ===========================================================================


def niri_set_vrr(output_name: str, enable: bool) -> bool:
    """
    Call `niri msg output <name> vrr on|off`.
    Returns True on success, False on failure.
    """
    state = "on" if enable else "off"
    try:
        result = subprocess.run(
            ["niri", "msg", "output", output_name, "vrr", state],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode != 0:
            log.warning(
                "niri vrr %s failed for %s: %s",
                state,
                output_name,
                result.stderr.strip(),
            )
            return False
        return True
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError) as exc:
        log.warning("niri command error: %s", exc)
        return False


# ===========================================================================
# state — mutable runtime state
# ===========================================================================


@dataclass
class WatcherState:
    """All mutable runtime state in one place."""

    vrr_enabled: dict[str, bool] = field(default_factory=dict)
    # output_name → "app_id:pid" — used to suppress duplicate log lines
    output_current_app: dict[str, str] = field(default_factory=dict)

    def record_app(self, output_name: str, window: WindowInfo) -> bool:
        """Log the fullscreen app if it changed. Returns True if it changed."""
        key = f"{window.app_id}:{window.pid}"
        if self.output_current_app.get(output_name) != key:
            self.output_current_app[output_name] = key
            return True
        return False

    def clear_output(self, output_name: str) -> None:
        self.vrr_enabled.pop(output_name, None)
        self.output_current_app.pop(output_name, None)


# ===========================================================================
# orchestrator — main poll loop
# ===========================================================================


class VrrOrchestrator:
    """
    Wires all layers together.  The constructor accepts injectable
    callables for every I/O operation — making it fully testable.
    """

    def __init__(
        self,
        config: Config,
        *,
        # Injected I/O (defaults to real implementations)
        fetch_outputs=fetch_niri_outputs,
        fetch_windows=fetch_niri_windows,
        fetch_workspaces=fetch_niri_workspaces,
        fetch_gpu=fetch_gpu_pids,
        set_vrr=niri_set_vrr,
        run_hook=execute_hook,
    ):
        self.config = config
        self._fetch_outputs = fetch_outputs
        self._fetch_windows = fetch_windows
        self._fetch_workspaces = fetch_workspaces
        self._fetch_gpu = fetch_gpu
        self._set_vrr = set_vrr
        self._run_hook = run_hook
        self._state = WatcherState()

    # ------------------------------------------------------------------
    # Phase 1: Collect
    # ------------------------------------------------------------------

    def _collect(self) -> tuple[str, str, str]:
        return (
            self._fetch_outputs(),
            self._fetch_windows(),
            self._fetch_workspaces(),
        )

    # ------------------------------------------------------------------
    # Phase 2: Parse  (delegates to pure parsers)
    # ------------------------------------------------------------------

    def _parse(
        self, outputs_json: str, windows_json: str, workspaces_json: str
    ) -> tuple[dict[str, OutputInfo], list[WindowInfo], dict[int, str]]:
        outputs = parse_outputs(outputs_json)
        windows = parse_windows(windows_json)
        ws_to_output = parse_workspaces(workspaces_json)
        log.debug(
            "Parsed: %d outputs, %d windows, %d workspaces",
            len(outputs),
            len(windows),
            len(ws_to_output),
        )
        return outputs, windows, ws_to_output

    # ------------------------------------------------------------------
    # Phase 3: Decide  (delegates to pure evaluators)
    # ------------------------------------------------------------------

    def _decide(
        self,
        outputs: dict[str, OutputInfo],
        windows: list[WindowInfo],
        ws_to_output: dict[int, str],
        gpu_ancestors: set[int],
    ) -> dict[str, bool]:
        desired = compute_desired_vrr(
            windows,
            ws_to_output,
            outputs,
            self.config.excluded_apps,
            gpu_ancestors,
            self.config.relaxed_mode,
        )
        # Log newly-fullscreen apps
        for window in windows:
            if not window.is_focused:
                continue
            output = resolve_output_for_window(window, ws_to_output, outputs)
            if output and desired.get(output.name):
                if self._state.record_app(output.name, window):
                    log.info(
                        "🎮 Fullscreen: %s (PID %s) on %s",
                        window.app_id,
                        window.pid,
                        output.name,
                    )
        return desired

    # ------------------------------------------------------------------
    # Phase 4: Act
    # ------------------------------------------------------------------

    def _act(
        self,
        desired: dict[str, bool],
        gpu_ancestors: set[int],
    ) -> None:
        for output_name, want_on in desired.items():
            prev = self._state.vrr_enabled.get(output_name)
            if prev == want_on:
                continue  # no change

            # Skip if we've never set VRR and it should be off (no transition)
            if prev is None and not want_on:
                continue

            if self._set_vrr(output_name, want_on):
                self._state.vrr_enabled[output_name] = want_on
                _label = "on" if want_on else "off"
                log.info(
                    "%s VRR on %s", "Enabling" if want_on else "Disabling", output_name
                )
                if want_on:
                    first_pid = next(iter(gpu_ancestors), None)
                    self._run_hook(self.config.hook_on, output_name, first_pid)
                else:
                    self._run_hook(self.config.hook_off, output_name)
                    self._state.output_current_app.pop(output_name, None)

        # Clean up state for outputs that disappeared
        known_outputs = set(desired)
        for gone in list(self._state.vrr_enabled):
            if gone not in known_outputs:
                log.info("Output %s disconnected, cleaning state", gone)
                self._state.clear_output(gone)

    # ------------------------------------------------------------------
    # Single poll cycle (exposed for testing)
    # ------------------------------------------------------------------

    def poll_once(self, gpu_ancestors: set[int]) -> None:
        outputs_json, windows_json, workspaces_json = self._collect()
        outputs, windows, ws_to_output = self._parse(
            outputs_json, windows_json, workspaces_json
        )
        desired = self._decide(outputs, windows, ws_to_output, gpu_ancestors)
        self._act(desired, gpu_ancestors)

    # ------------------------------------------------------------------
    # Shutdown
    # ------------------------------------------------------------------

    def shutdown(self) -> None:
        log.info("Shutting down, disabling all VRR states...")
        for output_name in list(self._state.vrr_enabled):
            self._set_vrr(output_name, False)

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run(self) -> None:
        log.info("Waiting %.0fs for niri...", self.config.startup_delay)
        time.sleep(self.config.startup_delay)

        def _handle_signal(signum, _frame):  # noqa: ANN001
            log.info("Received signal %s", signum)
            self.shutdown()
            sys.exit(0)

        signal.signal(signal.SIGINT, _handle_signal)
        signal.signal(signal.SIGTERM, _handle_signal)

        log.info(
            "Monitoring active (interval: %.1fs, relaxed=%s)",
            self.config.poll_interval,
            self.config.relaxed_mode,
        )

        while True:
            cycle_start = time.monotonic()

            gpu_ancestors: set[int] = set()
            if not self.config.relaxed_mode:
                leaf_pids = self._fetch_gpu()
                gpu_ancestors = build_gpu_ancestor_set(leaf_pids)

            try:
                self.poll_once(gpu_ancestors)
            except Exception:
                log.exception("Unexpected error in poll cycle")

            elapsed = time.monotonic() - cycle_start
            remaining = self.config.poll_interval - elapsed
            if remaining > 0.1:
                time.sleep(remaining)


# ===========================================================================
# Dependency checking
# ===========================================================================


def check_dependencies(relaxed_mode: bool) -> bool:
    missing: list[str] = []
    for cmd in ["niri", "jq"]:
        if not shutil.which(cmd):
            missing.append(cmd)
    if not relaxed_mode and not shutil.which("nvtop"):
        missing.append("nvtop")
    if missing:
        log.error("Missing required commands: %s", ", ".join(missing))
        print(f"Error: Missing: {', '.join(missing)}", file=sys.stderr)
        return False
    return True


# ===========================================================================
# Entry point
# ===========================================================================


def _detect_systemd_service() -> bool:
    """Return True if we appear to be running as a systemd service."""
    return (
        os.environ.get("INVOCATION_ID") is not None
        or os.environ.get("JOURNAL_STREAM") is not None
    )


def main() -> None:
    config = Config()

    # Auto-detect journald when running under systemd
    use_journald = os.environ.get("NIRI_VRR_JOURNALD", "").lower() in ("1", "true", "yes")
    if not use_journald:
        use_journald = _detect_systemd_service()

    # Wire up logging
    global log
    log = _build_logger(config.log_file, config.debug_mode, use_journald)

    if not check_dependencies(config.relaxed_mode):
        sys.exit(1)

    orchestrator = VrrOrchestrator(config)
    orchestrator.run()


if __name__ == "__main__":
    main()
