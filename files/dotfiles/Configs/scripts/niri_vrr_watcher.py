#!/usr/bin/env python3
"""
niri_vrr_watcher.py — Auto-enable VRR for fullscreen applications in niri.

Architecture:
    config       — Pure dataclasses / settings (no I/O at import time)
    models       — Immutable value objects parsed from niri JSON
    fetchers     — Thin I/O wrappers that return raw JSON strings
    parsers      — Pure JSON → model converters (easy to unit-test)
    evaluators   — Pure business-logic predicates (easy to unit-test)
    gpu          — GPU-PID ancestor resolution (side-effectful, mockable)
    hooks        — Hook execution (side-effectful, mockable)
    niri         — niri msg command wrappers (side-effectful, mockable)
    state        — Mutable runtime state containers
    orchestrator — Main poll loop; wires all layers together
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import signal
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

# ---------------------------------------------------------------------------
# Logging — module-level reference; handlers attached in main()
# ---------------------------------------------------------------------------

log = logging.getLogger("niri_vrr")


# ===========================================================================
# config — immutable settings, no I/O at import time
#
# Config is a frozen dataclass with two construction paths:
#
#   1. Config.from_env()  — reads environment variables at call time and
#      builds a fully-populated instance.  This is the normal entry point
#      used by ``main()`` and by real systemd service runs.
#
#   2. Config(...)        — uses the zero-value defaults for every field.
#      Because defaults are plain literals (no env lookups, no Path.home()),
#      ``Config()`` is safe to call during import, in tests, or anywhere
#      that must not touch the filesystem or environment.
#
# All fields are read-only after construction (frozen=True).
#
# Environment variable reference (consumed by from_env()):
#
#   NIRI_VRR_POLL_INTERVAL   float  Seconds between poll cycles       [2]
#   NIRI_VRR_LOG_FILE        path   Log file path override            [$XDG_RUNTIME_DIR/niri-vrr-watcher.log]
#   NIRI_VRR_STARTUP_DELAY   float  Seconds to wait before first poll [3]
#   NIRI_VRR_DEBUG           "0"/"1" Enable DEBUG-level logging       [0]
#   NIRI_VRR_RELAXED_MODE    "0"/"1" Skip GPU-activity check          [0]
#   NIRI_VRR_HOOK_ON         str    Colon-separated on-hooks          []
#   NIRI_VRR_HOOK_OFF        str    Colon-separated off-hooks         []
#   NIRI_VRR_EXCLUDED_APPS   str    Colon-separated app-ids to append []
#
# ===========================================================================


_DEFAULT_EXCLUDED = (
    "brave-browser",
    "brave-browser-beta",
    "org.mozilla.firefox",
    "org.kde.haruna",
    "mpv",
    "io.mpv.Mpv",
    "com.spotify.Client",
    "vesktop",
    "com.discordapp.Discord",
)


@dataclass(frozen=True)
class Config:
    """Immutable watcher configuration.

    Construct directly for testing (all fields default to zero-values),
    or use ``Config.from_env()`` to populate from environment variables.
    """

    poll_interval: float = 2.0
    log_file: Path = Path("/tmp/niri-vrr-watcher.log")
    startup_delay: float = 3.0
    debug_mode: bool = False
    relaxed_mode: bool = False
    hook_on: list[str] = field(default_factory=list)
    hook_off: list[str] = field(default_factory=list)
    excluded_apps: frozenset[str] = frozenset()

    @classmethod
    def from_env(cls) -> Config:
        """Build a Config from the ``NIRI_VRR_*`` environment variables.

        Designed to be called once at startup (in ``main()``).  Env vars
        are read at call time, not at import time, so the module can be
        safely imported without side effects.
        """
        runtime_dir = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
        return cls(
            poll_interval=float(os.environ.get("NIRI_VRR_POLL_INTERVAL", "2")),
            log_file=Path(
                os.environ.get(
                    "NIRI_VRR_LOG_FILE",
                    f"{runtime_dir}/niri-vrr-watcher.log",
                )
            ),
            startup_delay=float(os.environ.get("NIRI_VRR_STARTUP_DELAY", "3")),
            debug_mode=os.environ.get("NIRI_VRR_DEBUG", "0") == "1",
            relaxed_mode=os.environ.get("NIRI_VRR_RELAXED_MODE", "0") == "1",
            hook_on=_parse_hook_var("NIRI_VRR_HOOK_ON"),
            hook_off=_parse_hook_var("NIRI_VRR_HOOK_OFF"),
            excluded_apps=frozenset(_DEFAULT_EXCLUDED)
            | frozenset(
                e.strip()
                for e in os.environ.get("NIRI_VRR_EXCLUDED_APPS", "").split(":")
                if e.strip()
            ),
        )


def _parse_hook_var(name: str) -> list[str]:
    """Parse a colon-separated hook environment variable into a list.

    Format (set in the systemd ``.service`` file or shell):

    ::

        NIRI_VRR_HOOK_ON="/path/to/boost.sh on"
        NIRI_VRR_HOOK_ON="/path/to/boost.sh on:/path/to/notify.sh on"

    Colons delimit individual commands.  Leading/trailing whitespace
    around each command is stripped.  Empty entries are ignored.
    If the variable is unset or empty, returns an empty list.
    """
    raw = os.environ.get(name, "").strip()
    if not raw:
        return []
    return [entry.strip() for entry in raw.split(":") if entry.strip()]


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


def _run_cmd(args: list[str]) -> str | None:
    """Run a command and return stdout, or ``None`` on failure/empty."""
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=5)
        stripped = result.stdout.strip()
        return stripped if stripped else None
    except (FileNotFoundError, subprocess.TimeoutExpired, OSError):
        return None


def fetch_niri_outputs() -> str:
    return _run_cmd(["niri", "msg", "-j", "outputs"]) or "{}"


def fetch_niri_windows() -> str:
    return _run_cmd(["niri", "msg", "-j", "windows"]) or "[]"


def fetch_niri_workspaces() -> str:
    return _run_cmd(["niri", "msg", "-j", "workspaces"]) or "[]"


def fetch_gpu_pids() -> list[int]:
    """Return PIDs of processes doing GPU graphic+compute work via nvtop -s."""
    try:
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


def parse_outputs(outputs_json: str | None) -> dict[str, OutputInfo]:
    """
    Parse niri outputs JSON (object keyed by output name).
    Returns {output_name: OutputInfo}.
    """
    if not outputs_json:
        return {}
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


def parse_workspaces(workspaces_json: str | None) -> dict[int, str]:
    """
    Parse niri workspaces JSON (array).
    Returns {workspace_id: output_name}.
    """
    if not workspaces_json:
        return {}
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


def parse_windows(windows_json: str | None) -> list[WindowInfo]:
    """
    Parse niri windows JSON (array).
    Returns list of WindowInfo objects.
    """

    def _int_or_none(v: object) -> int | None:
        try:
            return int(float(str(v)))  # handles "1920.0" etc.
        except (TypeError, ValueError):
            return None

    if not windows_json:
        return []
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


@dataclass(frozen=True)
class EvalContext:
    """Groups all context needed for a single poll-cycle evaluation."""

    ws_to_output: dict[int, str]
    outputs: dict[str, OutputInfo]
    excluded_apps: frozenset[str]
    gpu_ancestor_pids: set[int]
    relaxed_mode: bool


def is_app_excluded(app_id: str, excluded: frozenset[str]) -> bool:
    return app_id in excluded


def is_fullscreen(window: WindowInfo, output: OutputInfo) -> bool:
    size = window.effective_size
    if size is None:
        return False
    return size == output.resolution


def resolve_output_for_window(
    window: WindowInfo,
    ctx: EvalContext,
) -> OutputInfo | None:
    """Return the OutputInfo the window lives on, or None if unknown."""
    if window.workspace_id is None:
        return None
    output_name = ctx.ws_to_output.get(window.workspace_id)
    if output_name is None:
        return None
    return ctx.outputs.get(output_name)


def window_wants_vrr(
    window: WindowInfo,
    ctx: EvalContext,
) -> OutputInfo | None:
    """
    Return the OutputInfo that should have VRR enabled for this window,
    or None if VRR should not be enabled.

    Pure function — all external state passed via EvalContext.
    """
    if not window.is_focused:
        return None

    output = resolve_output_for_window(window, ctx)
    if output is None:
        return None

    if window.app_id and is_app_excluded(window.app_id, ctx.excluded_apps):
        log.debug("\u2298 Excluded: %s", window.app_id)
        return None

    if not is_fullscreen(window, output):
        return None

    if not ctx.relaxed_mode:
        has_any_gpu = bool(ctx.gpu_ancestor_pids)
        pid_is_gpu = window.pid is not None and window.pid in ctx.gpu_ancestor_pids
        if not pid_is_gpu:
            if not has_any_gpu:
                return None
            log.debug("\u2713 GPU activity (fallback): %s", window.app_id)
        # pid_is_gpu -> direct match, pass through
    else:
        log.debug("\u2713 Fullscreen (relaxed mode): %s", window.app_id)

    return output


def compute_desired_vrr(
    windows: list[WindowInfo],
    ctx: EvalContext,
) -> dict[str, bool]:
    """
    Return {output_name: vrr_desired} for all known outputs.

    Pure function — deterministic given its inputs.
    """
    desired = {name: False for name in ctx.outputs}

    for window in windows:
        output = window_wants_vrr(window, ctx)
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
    leaf_count = 0
    for leaf in leaf_pids:
        leaf_count += 1
        current: int | None = leaf
        while current is not None and current not in (0, 1):
            if current in ancestors:
                break  # already walked this branch
            ancestors.add(current)
            current = _get_ppid(current)

    log.debug(
        "GPU ancestor set: %d PIDs from %d leaves",
        len(ancestors),
        leaf_count,
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
            [cmd, *args],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        log.info("Executing hook: %s", hook_spec)
    except OSError as exc:
        log.warning("Hook execution failed (%s): %s", hook_spec, exc)


# ===========================================================================
# niri — niri msg command wrappers
# ===========================================================================


def niri_set_vrr(output_name: str, enable: bool) -> bool:
    """
    Call ``niri msg output <name> vrr on|off``.
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
# state — mutable runtime state containers
# ===========================================================================


@dataclass
class VrrState:
    """Tracks which outputs currently have VRR enabled."""

    _vrr_enabled: dict[str, bool] = field(default_factory=dict)

    def get(self, output_name: str) -> bool | None:
        return self._vrr_enabled.get(output_name)

    def mark(self, output_name: str, enabled: bool) -> None:
        self._vrr_enabled[output_name] = enabled

    def clear(self, output_name: str) -> None:
        self._vrr_enabled.pop(output_name, None)

    def all_tracked(self) -> set[str]:
        """Return names of all outputs with a recorded VRR state."""
        return set(self._vrr_enabled)


@dataclass
class AppTracker:
    """Deduplicates fullscreen-app log lines per output."""

    _output_current_app: dict[str, str] = field(default_factory=dict)

    def record_app(self, output_name: str, window: WindowInfo) -> bool:
        """Record the fullscreen app. Returns True if it changed."""
        key = f"{window.app_id}:{window.pid}"
        if self._output_current_app.get(output_name) != key:
            self._output_current_app[output_name] = key
            return True
        return False

    def clear(self, output_name: str) -> None:
        self._output_current_app.pop(output_name, None)


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
        fetch_outputs: Callable[[], str] = fetch_niri_outputs,
        fetch_windows: Callable[[], str] = fetch_niri_windows,
        fetch_workspaces: Callable[[], str] = fetch_niri_workspaces,
        fetch_gpu: Callable[[], list[int]] = fetch_gpu_pids,
        set_vrr: Callable[[str, bool], bool] = niri_set_vrr,
        run_hook: Callable[[str, str, int | None], None] = execute_hook,
    ):
        self.config = config
        self._fetch_outputs = fetch_outputs
        self._fetch_windows = fetch_windows
        self._fetch_workspaces = fetch_workspaces
        self._fetch_gpu = fetch_gpu
        self._set_vrr = set_vrr
        self._run_hook = run_hook
        self._vrr_state = VrrState()
        self._app_tracker = AppTracker()

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
        self,
        outputs_json: str,
        windows_json: str,
        workspaces_json: str,
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
        ctx = EvalContext(
            ws_to_output=ws_to_output,
            outputs=outputs,
            excluded_apps=self.config.excluded_apps,
            gpu_ancestor_pids=gpu_ancestors,
            relaxed_mode=self.config.relaxed_mode,
        )
        desired = compute_desired_vrr(windows, ctx)

        # Log newly-fullscreen apps
        for window in windows:
            if not window.is_focused:
                continue
            output = resolve_output_for_window(window, ctx)
            if output and desired.get(output.name):
                if self._app_tracker.record_app(output.name, window):
                    log.info(
                        "Fullscreen: %s (PID %s) on %s",
                        window.app_id,
                        window.pid,
                        output.name,
                    )
        return desired

    # ------------------------------------------------------------------
    # Phase 4: Act
    # ------------------------------------------------------------------

    def _apply_vrr_transitions(
        self, desired: dict[str, bool]
    ) -> list[tuple[str, bool]]:
        """Compare desired vs current state, apply changes.

        Returns a list of ``(output_name, new_state)`` transitions that
        were successfully applied to niri.
        """
        transitions: list[tuple[str, bool]] = []
        for output_name, want_on in desired.items():
            prev = self._vrr_state.get(output_name)
            if prev == want_on:
                continue  # no change
            if prev is None and not want_on:
                continue  # never set VRR and it should be off — skip

            if self._set_vrr(output_name, want_on):
                self._vrr_state.mark(output_name, want_on)
                transitions.append((output_name, want_on))
                log.info(
                    "%s VRR on %s",
                    "Enabling" if want_on else "Disabling",
                    output_name,
                )
        return transitions

    def _execute_transition_hooks(
        self,
        transitions: list[tuple[str, bool]],
        gpu_ancestors: set[int],
    ) -> None:
        """Run on/off hooks for completed VRR transitions."""
        for output_name, want_on in transitions:
            hooks = self.config.hook_on if want_on else self.config.hook_off
            for spec in hooks:
                pid = next(iter(gpu_ancestors), None) if want_on else None
                self._run_hook(spec, output_name, pid)
            if not want_on:
                self._app_tracker.clear(output_name)

    def _cleanup_stale_outputs(self, known_outputs: set[str]) -> None:
        """Remove state for outputs that disappeared."""
        for gone in self._vrr_state.all_tracked() - known_outputs:
            log.info("Output %s disconnected, cleaning state", gone)
            self._vrr_state.clear(gone)
            self._app_tracker.clear(gone)

    def _act(
        self,
        desired: dict[str, bool],
        gpu_ancestors: set[int],
    ) -> None:
        transitions = self._apply_vrr_transitions(desired)
        self._execute_transition_hooks(transitions, gpu_ancestors)
        self._cleanup_stale_outputs(set(desired))

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
        """Disable VRR and run off-hooks for all tracked outputs."""
        log.info("Shutting down, disabling all VRR states...")
        for output_name in list(self._vrr_state._vrr_enabled):
            was_on = self._vrr_state.get(output_name)
            if was_on:
                self._set_vrr(output_name, False)
                for spec in self.config.hook_off:
                    self._run_hook(spec, output_name, None)
                log.info("Disabling VRR on %s (shutdown)", output_name)
            self._vrr_state.clear(output_name)
            self._app_tracker.clear(output_name)

    # ------------------------------------------------------------------
    # Main loop
    # ------------------------------------------------------------------

    def run(self, *, handle_signals: bool = True) -> None:
        """Run the poll loop. Set ``handle_signals=False`` for testing or embedding."""
        log.info("Waiting %.0fs for niri...", self.config.startup_delay)
        time.sleep(self.config.startup_delay)

        if handle_signals:

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
    if not shutil.which("niri"):
        missing.append("niri")
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


def _configure_logging(
    log_path: Path,
    debug: bool,
    *,
    service_mode: bool = False,
) -> None:
    """Attach handlers to the module-level ``niri_vrr`` logger.

    Parameters
    ----------
    log_path:
        Path to the log file (always written).
    debug:
        If True, set level to DEBUG; otherwise INFO.
    service_mode:
        If True, mirror output to stderr with a compact format.
        When running under systemd, stderr is natively captured into
        the journal — no ``python3-systemd`` package needed.
    """
    log_path.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("niri_vrr")
    logger.setLevel(logging.DEBUG if debug else logging.INFO)

    # Clear stale handlers (important for re-configuration in tests)
    logger.handlers.clear()

    # File handler (always present)
    file_fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%F %T",
    )
    fh = logging.FileHandler(log_path, mode="w", encoding="utf-8")
    fh.setFormatter(file_fmt)
    logger.addHandler(fh)

    # Stderr handler — useful when running as a systemd service (stderr is
    # automatically captured into the journal) or for interactive debugging.
    if service_mode:
        stderr_fmt = logging.Formatter("%(levelname)s: %(message)s")
        sh = logging.StreamHandler(sys.stderr)
        sh.setFormatter(stderr_fmt)
        logger.addHandler(sh)


def _detect_systemd_service() -> bool:
    """Return True if we appear to be running as a systemd service."""
    return (
        os.environ.get("INVOCATION_ID") is not None
        or os.environ.get("JOURNAL_STREAM") is not None
    )


def main() -> None:
    config = Config.from_env()

    # Mirror to stderr when running as a systemd service (captured by
    # journald natively — no python3-systemd required) or when opted-in
    # via NIRI_VRR_STDERR.
    use_stderr = os.environ.get("NIRI_VRR_STDERR", "").lower() in ("1", "true", "yes")
    if not use_stderr:
        use_stderr = _detect_systemd_service()

    _configure_logging(config.log_file, config.debug_mode, service_mode=use_stderr)

    if not check_dependencies(config.relaxed_mode):
        sys.exit(1)

    orchestrator = VrrOrchestrator(config)
    orchestrator.run()


if __name__ == "__main__":
    main()
