#!/usr/bin/env python3
"""
gamemode.py — Performance toggle for gaming sessions.

Rewrite of gamemode.sh in modern Python.  Single-file, zero external
dependencies (stdlib only + host executables accessed via subprocess).

Design principles
-----------------
* Every host-executable call passes through a ``Runner`` object that is
  injected into features, making the whole thing straightforwardly
  mockable in tests without touching ``subprocess`` globals.
* Features implement the ``Feature`` protocol (``enable`` / ``disable``),
  so adding a new toggle is a one-class change + one registry line.
* State management uses ``fcntl.flock`` with a context manager so lock
  lifetime is always bounded.
* Configuration is a frozen dataclass populated from environment
  variables, with sensible defaults matching the original script.

Usage
-----
    python3 gamemode.py on                    # activate
    python3 gamemode.py off                   # deactivate
    python3 gamemode.py -- steam              # wrapper: enable, run steam, disable on exit
    python3 gamemode.py -- ~/Games/foo/run.sh
"""

from __future__ import annotations

import ctypes
import ctypes.util
import fcntl
import logging
import os
import shutil
import signal
import subprocess
import sys
import textwrap
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Iterator, Protocol, cast, runtime_checkable


# ============================================================================
# Module: Configuration
# Responsibility: Load and expose configuration values from environment
# ============================================================================


@dataclass(frozen=True, slots=True)
class Config:
    """Immutable, env-driven configuration.

    Every field reads from the corresponding environment variable at
    construction time and then becomes read-only.  Feature toggles use
    ``True`` / ``False`` strings to match the bash convention so that
    ``ENABLE_VRR=false python3 gamemode.py on`` works as expected.
    """

    # -- feature toggles ---------------------------------------------------
    enable_scx: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SCX_SCHEDULER", True),
    )
    enable_vrr: bool = field(
        default_factory=lambda: _env_bool("ENABLE_VRR", True),
    )
    enable_tuned: bool = field(
        default_factory=lambda: _env_bool("ENABLE_PERFORMANCE_MODE", False),
    )
    enable_inhibit: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SCREEN_KEEP_AWAKE", True),
    )
    enable_audio: bool = field(
        default_factory=lambda: _env_bool("ENABLE_AUDIO_PRIORITY_BOOST", False),
    )
    enable_steam: bool = field(
        default_factory=lambda: _env_bool("ENABLE_STEAM_ENV", True),
    )

    # -- feature parameters ------------------------------------------------
    scx_scheduler: str = field(
        default_factory=lambda: os.environ.get("SCX_SCHEDULER", "lavd"),
    )
    scx_mode: str = field(
        default_factory=lambda: os.environ.get("SCX_SCHEDULER_MODE", "gaming"),
    )
    profile_game: str = field(
        default_factory=lambda: os.environ.get(
            "GAME_PROFILE",
            "throughput-performance-bazzite",
        ),
    )
    profile_desktop: str = field(
        default_factory=lambda: os.environ.get(
            "DESKTOP_PROFILE",
            "balanced-bazzite",
        ),
    )
    audio_latency: str = field(
        default_factory=lambda: os.environ.get("PULSE_LATENCY_MSEC", "60"),
    )
    steam_script: str = field(
        default_factory=lambda: os.environ.get(
            "STEAM_ENV_SCRIPT",
            str(Path.home() / ".local" / "bin" / "scripts" / "steam-env-base.sh"),
        ),
    )
    vrr_output_default: str = field(
        default_factory=lambda: os.environ.get("VRR_OUTPUT", "DP-1"),
    )

    # -- systemd-run wrapper ------------------------------------------------
    enable_systemd_run: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SYSTEMD_RUN", True),
    )
    systemd_run_args: list[str] = field(
        default_factory=lambda: (
            os.environ.get("SYSTEMD_RUN_ARGS", "").split()
            or [
                "--user",
                "--scope",
                "--slice=app.slice",
                "--property=CPUWeight=500",
                "--property=IOWeight=500",
            ]
        )
    )

    # -- runtime paths -----------------------------------------------------
    runtime_dir: str = field(
        default_factory=lambda: os.environ.get("XDG_RUNTIME_DIR", "/tmp"),
    )

    # -- derived paths (computed lazily, exposed as properties) ------------
    @property
    def state_dir(self) -> Path:
        return Path(self.runtime_dir) / "gamemode"

    @property
    def state_file(self) -> Path:
        return self.state_dir / "gamemode.state"

    @property
    def lock_file(self) -> Path:
        return self.state_dir / "lock"

    @property
    def pid_file(self) -> Path:
        return self.state_dir / "wrapper.pid"

    @property
    def log_file(self) -> Path:
        return Path(self.runtime_dir) / "gamemode.log"

    @property
    def audio_env_file(self) -> Path:
        return self.state_dir / "audio.env"


def _env_bool(name: str, default: bool) -> bool:
    """Parse an env var as a boolean (``true``/``1``/``yes`` → True)."""
    val = os.environ.get(name)
    if val is None:
        return default
    return val.lower() in ("true", "1", "yes")


# ============================================================================
# Module: Logging
# Responsibility: Structured log output + optional file redirection
# ============================================================================


def setup_logging(
    config: Config, *, to_file: bool = False, debug: bool = False
) -> logging.Logger:
    """Create and return the ``gamemode`` logger.

    Parameters
    ----------
    config:
        Used to locate the log file.
    to_file:
        When *True*, attach a ``FileHandler`` (used by ``on``/``off``
        which are short-lived but should persist their output).
    debug:
        When *True*, set the console handler to DEBUG level.
    """
    log = logging.getLogger("gamemode")

    # Prevent duplicate handlers on repeated calls.
    if log.handlers:
        log.handlers.clear()

    log.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        "%(asctime)s [gamemode] %(levelname)s: %(message)s",
        datefmt="%H:%M:%S",
    )

    console = logging.StreamHandler(sys.stderr)
    console.setLevel(logging.DEBUG if debug else logging.INFO)
    console.setFormatter(fmt)
    log.addHandler(console)

    if to_file:
        config.log_file.parent.mkdir(parents=True, exist_ok=True)
        fh = logging.FileHandler(config.log_file, mode="w")
        fh.setLevel(logging.DEBUG)
        fh.setFormatter(fmt)
        log.addHandler(fh)

    return log


# ============================================================================
# Module: Runner
# Responsibility: Subprocess abstraction for testability & dep checking
#
# Every external command invoked by gamemode goes through this thin
# wrapper.  In production it delegates to ``subprocess.run``; tests can
# subclass or monkey-patch it to inject canned responses.
#
# Factory pattern:
#   The ``Runner`` class now provides factory methods that produce
#   specialised command executors.  This eliminates the repetitive
#   ``require`` → ``run`` → ``returncode check`` boilerplate that was
#   duplicated across every Feature class.
# ============================================================================


class Runner:
    """Abstraction over subprocess for host-executable calls.

    Provides:
    - ``resolve(cmd)`` — returns the path to *cmd* if on ``$PATH``, else ``None``.
    - ``require(cmd, feature)`` — like resolve but logs on failure.
    - ``run(args, ...)`` — thin wrapper around ``subprocess.run``.
    - ``capture(args)`` — convenience for ``run(capture_output=True, text=True)``.
    - ``pipe(input_data, args)`` — run *args* feeding *input_data* on stdin.
    - Factory methods for common patterns (see below).
    """

    def __init__(self, log: logging.Logger) -> None:
        self._log = log

    # -- dependency resolution ---------------------------------------------

    def resolve(self, cmd: str) -> str | None:
        """Return the path to *cmd* if it exists on ``$PATH``, else ``None``."""
        return shutil.which(cmd)

    def require(self, cmd: str, feature: str = "") -> bool:
        """Log an error and return ``False`` if *cmd* is missing."""
        if self.resolve(cmd) is None:
            if feature:
                self._log.error("%s requires '%s' (not found)", feature, cmd)
            return False
        return True

    # -- execution ---------------------------------------------------------

    def run(
        self,
        args: list[str],
        *,
        check: bool = False,
        capture_output: bool = False,
        text: bool = False,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Execute *args*, returning the ``CompletedProcess``."""
        self._log.debug("exec: %s", " ".join(args))
        try:
            return subprocess.run(
                args,
                check=check,
                capture_output=capture_output,
                text=text,
                env=env,
            )
        except FileNotFoundError:
            self._log.error("command not found: %s", args[0])
            raise

    def capture(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        """Run and capture stdout+stderr as text."""
        return self.run(args, capture_output=True, text=True)

    def pipe(
        self, args: list[str], input_data: str
    ) -> subprocess.CompletedProcess[str]:
        """Run *args* feeding *input_data* on stdin; capture stdout as text."""
        self._log.debug("pipe: %s  (stdin: %d bytes)", " ".join(args), len(input_data))
        return subprocess.run(
            args,
            input=input_data,
            capture_output=True,
            text=True,
        )

    # -- factory methods for common patterns -------------------------------

    def make_checked_runner(
        self, cmd: str, feature: str = ""
    ) -> "CheckedCommandRunner":
        """Return a ``CheckedCommandRunner`` for *cmd*.

        Use when you need to repeatedly run commands that must be
        available and succeed.  The returned runner automatically logs
        errors and checks return codes.
        """
        return CheckedCommandRunner(self, cmd, feature)


class CheckedCommandRunner:
    """Runner that enforces dependency availability and checks return codes.

    Eliminates the repetitive pattern::

        if not self._run.require("cmd", "feature"):
            return FeatureResult.skip("...")
        result = self._run.run(["cmd", "args"])
        if result.returncode != 0:
            return FeatureResult.error("...")

    Instead::

        cmd = self._run.make_checked_runner("cmd", "feature")
        result = cmd.run_or_none(["cmd", "args"])
        # Returns CompletedProcess or None (with logging)
    """

    def __init__(self, runner: Runner, cmd: str, feature: str = "") -> None:
        self._runner = runner
        self._cmd = cmd
        self._feature = feature
        self._available = runner.require(cmd, feature)

    @property
    def is_available(self) -> bool:
        return self._available

    def run_or_none(
        self, args: list[str], **kwargs: Any
    ) -> subprocess.CompletedProcess[str] | None:
        """Run *args* if the command is available, else return ``None``."""
        if not self._available:
            return None
        result = self._runner.run(args, capture_output=True, text=True, **kwargs)
        if result.returncode != 0:
            self._runner._log.debug(
                "%s: %s returned %d",
                self._feature or self._cmd,
                self._cmd,
                result.returncode,
            )
        return result


# ============================================================================
# Module: Dependency Validation
# Responsibility: Verify required dependencies for enabled features
# ============================================================================


def validate_deps(config: Config, runner: Runner, log: logging.Logger) -> bool:
    """Check that all required host executables are available.

    Returns ``True`` if everything is present, ``False`` otherwise.
    """
    checks = [
        (config.enable_tuned, "tuned-adm"),
        (config.enable_inhibit, "systemd-inhibit"),
        (config.enable_inhibit, "dbus-send"),
        (config.enable_scx, "scxctl"),
        (config.enable_vrr, "jq"),
        (config.enable_systemd_run, "systemd-run"),
    ]
    missing = [
        cmd for enabled, cmd in checks if enabled and runner.resolve(cmd) is None
    ]
    if missing:
        log.error("Missing dependencies: %s", " ".join(missing))
        return False
    return True


# ============================================================================
# Module: Compositor Detection
# Responsibility: Identify the active compositor / desktop environment
#
# Priority: environment variables (set by the session) > process table.
#   $XDG_SESSION_DESKTOP / $XDG_CURRENT_DESKTOP are set to "niri" in a
#   niri session and "KDE" / "kde" on Plasma.  pgrep is a fallback.
# ============================================================================


def _session_contains(substring: str) -> bool:
    """Return ``True`` if *substring* appears in session env vars (case-insensitive)."""
    session = os.environ.get("XDG_SESSION_DESKTOP", "")
    current = os.environ.get("XDG_CURRENT_DESKTOP", "")
    return substring in (session + current).lower()


def compositor_is_niri() -> bool:
    """Return ``True`` if the niri compositor is active."""
    if _session_contains("niri"):
        return True
    # Fallback: process table
    if shutil.which("pgrep") is None:
        return False
    return (
        subprocess.run(
            ["pgrep", "-x", "niri"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def session_is_kde() -> bool:
    """Return ``True`` if the session is KDE Plasma."""
    return _session_contains("kde")


# ============================================================================
# Module: Output Resolution
# Responsibility: Determine target niri output name
# ============================================================================


def output_resolve(config: Config) -> str:
    """Return the output name to use for VRR operations.

    Priority: ``$NIRI_OUTPUT_NAME`` env var > config default.
    """
    return os.environ.get("NIRI_OUTPUT_NAME", config.vrr_output_default)


# ============================================================================
# Module: State Management
# Responsibility: Persist and query activation state with file locking
#
# State values:
#   "wrapper" — wrapper mode is running (on/off should skip)
#   "active"  — manually activated via ``gamemode.py on``
#   absent    — nothing active
#
# Locking:
#   A non-blocking flock on ``$STATE_DIR/lock`` serialises concurrent
#   wrapper invocations so that the first to finish doesn't clobber
#   state for still-running wrappers.  on/off check the lock to detect
#   concurrent activity.
# ============================================================================


class StateManager:
    """File-based state store with advisory locking.

    All paths are derived from *config*.  The lock file uses
    ``fcntl.flock(LOCK_NB | LOCK_EX)`` to avoid blocking the caller
    when another wrapper holds the lock.
    """

    def __init__(self, config: Config) -> None:
        self._config = config

    # -- state directory ---------------------------------------------------

    def init(self) -> None:
        self._config.state_dir.mkdir(parents=True, exist_ok=True)

    # -- locking -----------------------------------------------------------

    @staticmethod
    def _try_lock(fd: int) -> bool:
        """Attempt a non-blocking exclusive lock on *fd*.

        Returns ``True`` if acquired, ``False`` if already held.
        """
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except (BlockingIOError, OSError):
            return False

    @staticmethod
    def _unlock(fd: int) -> None:
        """Release a flock on *fd*, ignoring errors."""
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass

    @contextmanager
    def locked(self):
        """Context manager: acquire an exclusive, non-blocking lock.

        Yields ``True`` if the lock was acquired, ``False`` if it was
        already held by another process.  The lock is held for the
        entire duration of the ``with`` block.
        """
        fd = os.open(str(self._config.lock_file), os.O_CREAT | os.O_WRONLY)
        acquired = self._try_lock(fd)
        try:
            yield acquired
        finally:
            self._unlock(fd)
            os.close(fd)

    def is_lock_held(self) -> bool:
        """Return ``True`` if another process holds the wrapper lock.

        Opens a separate fd, attempts a non-blocking lock, and releases
        immediately — does not disturb any existing holder.
        """
        fd = os.open(str(self._config.lock_file), os.O_CREAT | os.O_WRONLY)
        try:
            return not self._try_lock(fd)
        finally:
            self._unlock(fd)
            os.close(fd)

    # -- state value -------------------------------------------------------

    def value(self) -> str:
        """Read the current state string (empty string if absent)."""
        try:
            return self._config.state_file.read_text().strip()
        except FileNotFoundError:
            return ""

    @property
    def is_wrapper(self) -> bool:
        return self.value() == "wrapper"

    @property
    def is_active(self) -> bool:
        return self.value() == "active"

    def mark_wrapper(self) -> None:
        self._config.state_file.write_text("wrapper\n")

    def mark_active(self) -> None:
        self._config.state_file.write_text("active\n")

    def clear(self) -> None:
        try:
            self._config.state_file.unlink()
        except FileNotFoundError:
            pass
        try:
            self._config.pid_file.unlink()
        except FileNotFoundError:
            pass

    # -- PID tracking ------------------------------------------------------

    def write_pid(self) -> None:
        """Write the current process PID to the pid file."""
        self._config.pid_file.write_text(f"{os.getpid()}\n")

    def wrapper_pid(self) -> int | None:
        """Read the stored wrapper PID, or ``None`` if absent."""
        try:
            return int(self._config.pid_file.read_text().strip())
        except (FileNotFoundError, ValueError):
            return None

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        """Return ``True`` if a process with *pid* exists."""
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def wrapper_alive(self) -> bool:
        """Return ``True`` if the stored wrapper PID is still alive."""
        pid = self.wrapper_pid()
        if pid is None:
            return False
        return self._pid_alive(pid)


# ============================================================================
# Module: Feature Protocol & Result
# Responsibility: Define the Feature interface and structured result type
# ============================================================================


class FeatureResult:
    """Structured outcome of a feature enable/disable operation.

    Attributes
    ----------
    ok : bool
        ``True`` if the operation succeeded (including "skipped").
    skipped : bool
        The feature was intentionally not applied (disabled by config,
        wrong compositor, etc.).
    changed : bool
        The feature changed system state (e.g. flipped VRR on).
    detail : str
        Human-readable description for logging.
    """

    __slots__ = ("ok", "skipped", "changed", "detail")

    def __init__(
        self,
        ok: bool = True,
        skipped: bool = False,
        changed: bool = False,
        detail: str = "",
    ) -> None:
        self.ok = ok
        self.skipped = skipped
        self.changed = changed
        self.detail = detail

    def __repr__(self) -> str:
        if self.skipped:
            return f"FeatureResult(skipped: {self.detail})"
        if self.changed:
            return f"FeatureResult(changed: {self.detail})"
        if not self.ok:
            return f"FeatureResult(error: {self.detail})"
        return "FeatureResult(noop)"

    # Convenience constructors ----------------------------------------------

    @classmethod
    def skip(cls, reason: str = "") -> FeatureResult:
        return cls(ok=True, skipped=True, detail=reason)

    @classmethod
    def did_change(cls, detail: str = "") -> FeatureResult:
        return cls(ok=True, changed=True, detail=detail)

    @classmethod
    def noop(cls) -> FeatureResult:
        return cls(ok=True)

    @classmethod
    def error(cls, detail: str = "") -> FeatureResult:
        return cls(ok=False, detail=detail)


@runtime_checkable
class Feature(Protocol):
    """Protocol that all gamemode features implement.

    Each feature receives a :class:`Config`, :class:`Runner`, and
    :class:`logging.Logger` at construction time so that external
    dependencies are explicit and mockable.
    """

    def enable(self, output: str) -> FeatureResult: ...
    def disable(self, output: str) -> FeatureResult: ...


CommandWrapper = Callable[[list[str]], list[str]]
WrapperFactory = Callable[["Config", "Runner", logging.Logger], CommandWrapper | None]


def _steam_wrapper_factory(
    config: Config, _runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    """Steam wrapper factory — returns None if disabled/not found."""
    if not config.enable_steam:
        return None

    def wrap(argv: list[str]) -> list[str]:
        path = Path(config.steam_script)
        if not path.is_file() or not os.access(path, os.X_OK):
            log.debug("Steam wrapper not available: %s", path)
            return argv
        return [str(path), *argv]

    return wrap


def _inhibit_wrapper_factory(
    config: Config, runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    """ScreenInhibit factory — returns None if disabled."""
    if not config.enable_inhibit:
        return None
    return ScreenInhibit(config, runner, log).inhibit_argv


def _systemd_run_wrapper_factory(
    config: Config, runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    """SystemdRun factory — returns None if disabled."""
    if not config.enable_systemd_run:
        return None
    return SystemdRun(config, runner, log).wrap_argv


WRAPPER_FACTORIES: list[WrapperFactory] = [
    _steam_wrapper_factory,
    _inhibit_wrapper_factory,
    _systemd_run_wrapper_factory,
]


class WrapperChain:
    """Composable chain of command wrappers.

    Wrappers are applied in order: first added = outermost (runs first).
    Example: [steam, inhibit, systemd_run] produces:
        systemd-run -- systemd-inhibit -- steam-wrapper -- command
    """

    def __init__(self) -> None:
        self._wrappers: list[CommandWrapper] = []

    def add(self, wrapper: CommandWrapper | None) -> "WrapperChain":
        """Add a wrapper to the chain. Returns self for chaining. Skips None."""
        if wrapper is not None:
            self._wrappers.append(wrapper)
        return self

    def add_factory(
        self,
        factory: WrapperFactory,
        config: Config,
        runner: Runner,
        log: logging.Logger,
    ) -> "WrapperChain":
        """Invoke factory, add result if not None. Returns self for chaining."""
        wrapper = factory(config, runner, log)
        if wrapper is not None:
            self._wrappers.append(wrapper)
        return self

    def apply(self, argv: list[str]) -> list[str]:
        """Apply all wrappers in order, returning final command."""
        result = list(argv)
        for wrapper in self._wrappers:
            result = wrapper(result)
        return result


class _BaseFeature:
    """Shared base for all feature implementations.

    Provides:
    - ``_gate(enabled, name)`` — config-check guard returning skip result.
    - ``_log_result(name, result)`` — log a feature enable/disable outcome.
    """

    def __init__(
        self,
        config: Config,
        runner: Runner,
        log: logging.Logger,
    ) -> None:
        self._cfg = config
        self._run = runner
        self._log = log

    def _gate(self, enabled: bool, _name: str) -> FeatureResult | None:
        """Return a skip result when *enabled* is ``False``, else ``None``."""
        if not enabled:
            return FeatureResult.skip("disabled by config")
        return None

    def _guarded(
        self, enabled: bool, name: str, fn: "Callable[[], FeatureResult]"
    ) -> FeatureResult:
        """Call *fn* only when *enabled* is ``True``, returning a skip result otherwise.

        Eliminates the repetitive::

            gate = self._gate(...)
            if gate is not None:
                return gate

        pattern used across every feature's enable/disable methods.
        """
        gate = self._gate(enabled, name)
        if gate is not None:
            return gate
        return fn()

    @staticmethod
    def _log_result(name: str, result: FeatureResult, log: logging.Logger) -> None:
        """Log a feature enable/disable outcome at the appropriate level."""
        if result.skipped:
            log.debug("%s: skipped (%s)", name, result.detail)
        elif result.changed:
            log.info("%s: %s", name, result.detail)
        elif not result.ok:
            log.warning("%s: %s", name, result.detail)
        else:
            log.debug("%s: no change", name)


# ============================================================================
# Module: Feature — VRR (niri)
# Responsibility: Toggle VRR on a specified niri output
#
# Adopted from niri_vrr_watcher.py pattern:
#   - Check vrr_supported (capability) before attempting toggle
#   - Only invoke niri commands when niri compositor is running
#   - Skip gracefully when output doesn't support VRR
# ============================================================================


class VRR(_BaseFeature):
    """Toggle Variable Refresh Rate via ``niri msg`` + ``jq``.

    Checks VRR capability before attempting a toggle, parses niri's
    JSON output with the host ``jq`` executable (matching the original
    bash behaviour), and skips gracefully when the compositor is not
    niri or the output lacks VRR support.

    Return semantics via FeatureResult:
      - ``skip``   — feature disabled / wrong compositor / not capable
      - ``noop``   — already in desired state
      - ``changed``— successfully toggled
      - ``error``  — toggle command failed
    """

    _JQ_VRR_SUPPORTED = ".[$o].vrr_supported // true"
    _JQ_VRR_ENABLED = (
        'if .[$o].vrr_enabled == true then "true" '
        'elif .[$o].vrr_enabled == false then "false" '
        'else "" end'
    )

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        self._niri_cmd = runner.make_checked_runner("niri", "VRR")

    # -- internal helpers --------------------------------------------------

    def _jq_query(self, jq_expr: str, jq_args: dict[str, str] | None) -> str | None:
        """Run ``niri msg -j outputs`` and pipe through ``jq``.

        Returns the stripped stdout string, or ``None`` on any failure.
        """
        if not self._run.require("jq", "VRR"):
            return None

        data_result = self._run.capture(["niri", "msg", "-j", "outputs"])
        if data_result.returncode != 0:
            return None

        jq_argv: list[str] = ["jq", "-r"]
        if jq_args:
            for key, val in jq_args.items():
                jq_argv.extend(["--arg", key, val])
        jq_argv.append(jq_expr)

        jq_result = self._run.pipe(jq_argv, data_result.stdout)
        if jq_result.returncode != 0:
            return None
        return jq_result.stdout.strip()

    def _is_capable(self, output: str) -> bool:
        """Check whether *output* reports VRR support via niri JSON."""
        result = self._jq_query(self._JQ_VRR_SUPPORTED, {"o": output})
        return result == "true"

    def _current(self, output: str) -> str:
        """Query current VRR state for *output*.

        Returns ``"on"``, ``"off"``, or ``""`` (not found / error).
        """
        result = self._jq_query(self._JQ_VRR_ENABLED, {"o": output})
        if result is None:
            return ""
        if result == "true":
            return "on"
        if result == "false":
            return "off"
        return ""

    def _set(self, output: str, state: str) -> bool:
        """Send a VRR toggle command to niri.  Returns ``True`` on success."""
        if not self._niri_cmd.is_available:
            return False
        result = self._niri_cmd.run_or_none(
            ["niri", "msg", "output", output, "vrr", state]
        )
        return result is not None and result.returncode == 0

    # -- Feature interface -------------------------------------------------

    def _toggle(self, output: str, desired: str) -> FeatureResult:
        """Shared enable/disable implementation.

        *desired* is ``"on"`` or ``"off"``.
        """
        gate = self._gate(self._cfg.enable_vrr, "VRR")
        if gate is not None:
            return gate
        if not compositor_is_niri():
            return FeatureResult.skip("niri not running")
        if not self._is_capable(output):
            return FeatureResult.skip(f"output '{output}' not VRR-capable")

        current = self._current(output)
        if current == "":
            return FeatureResult.skip(f"output '{output}' not found")
        if current == desired:
            return FeatureResult.noop()

        ok = self._set(output, desired)
        if ok:
            return FeatureResult.did_change(f"{current} → {desired} on {output}")
        return FeatureResult.error("toggle failed")

    def enable(self, output: str) -> FeatureResult:
        return self._toggle(output, "on")

    def disable(self, output: str) -> FeatureResult:
        return self._toggle(output, "off")


# ============================================================================
# Module: Feature — Power Profile (tuned-adm)
# Responsibility: Switch system power profiles
# ============================================================================


class PowerProfile(_BaseFeature):
    """Switch tuned-adm between gaming and desktop profiles."""

    _CMD = "tuned-adm"
    _FEATURE = "Performance mode"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        # Factory runner for tuned-adm commands
        self._tuned = runner.make_checked_runner(self._CMD, self._FEATURE)

    def _current(self) -> str:
        """Return the active tuned-adm profile name, or ``""``."""
        result = self._tuned.run_or_none([self._CMD, "active"])
        if result is None:
            return ""
        for line in result.stdout.splitlines():
            if line.startswith("Active profile:"):
                return line.split(":", 1)[1].strip()
        return ""

    def _set(self, profile: str) -> bool:
        result = self._tuned.run_or_none([self._CMD, "profile", profile])
        return result is not None and result.returncode == 0

    def _ensure(self, desired: str) -> FeatureResult:
        gate = self._gate(self._cfg.enable_tuned, "Performance mode")
        if gate is not None:
            return gate

        current = self._current()
        if current == desired:
            return FeatureResult.noop()

        if current:
            self._log.info("Profile: %s → %s", current, desired)
        else:
            self._log.info("Profile: setting %s", desired)

        ok = self._set(desired)
        if ok:
            return FeatureResult.did_change(f"{current or 'none'} → {desired}")
        return FeatureResult.error(f"failed to set {desired}")

    def enable(self, _output: str) -> FeatureResult:
        return self._ensure(self._cfg.profile_game)

    def disable(self, _output: str) -> FeatureResult:
        return self._ensure(self._cfg.profile_desktop)


# ============================================================================
# Module: Feature — SCX Scheduler
# Responsibility: Manage scxctl scheduler lifecycle
# ============================================================================


class SCXScheduler(_BaseFeature):
    """Load, switch, and unload the sched-ext scheduler via ``scxctl``."""

    _CMD = "scxctl"
    _FEATURE = "SCX scheduler"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        # Factory runner for scxctl commands
        self._scxctl = runner.make_checked_runner(self._CMD, self._FEATURE)

    def _status(self) -> str:
        """Return the current scxctl status string, or ``""``."""
        result = self._scxctl.run_or_none([self._CMD, "get"])
        if result is None:
            return ""
        return result.stdout.strip()

    def _apply(self) -> FeatureResult:
        """Run ``scxctl start -s <scheduler> -m <mode>`` and return a result."""
        result = self._scxctl.run_or_none(
            [
                self._CMD,
                "start",
                "-s",
                self._cfg.scx_scheduler,
                "-m",
                self._cfg.scx_mode,
            ]
        )
        ok = result is not None and result.returncode == 0
        if ok:
            return FeatureResult.did_change(
                f"{self._cfg.scx_scheduler}/{self._cfg.scx_mode}",
            )
        return FeatureResult.error("scxctl failed")

    def _toggle(self, desired: str) -> FeatureResult:
        return self._guarded(
            self._cfg.enable_scx, "SCX scheduler", lambda: self._set(desired)
        )

    def _set(self, desired: str) -> FeatureResult:
        if not self._scxctl.is_available:
            return FeatureResult.skip("scxctl not found")

        status = self._status()
        if desired == "on":
            if (
                status
                and self._cfg.scx_scheduler in status
                and self._cfg.scx_mode in status
            ):
                return FeatureResult.noop()
            return self._apply()
        else:
            if not status or "no scx scheduler running" in status:
                return FeatureResult.noop()
            result = self._scxctl.run_or_none([self._CMD, "stop"])
            ok = result is not None and result.returncode == 0
            if ok:
                return FeatureResult.did_change("stopped")
            return FeatureResult.error("stop failed")

    def enable(self, _output: str) -> FeatureResult:
        return self._toggle("on")

    def disable(self, _output: str) -> FeatureResult:
        return self._toggle("off")


# ============================================================================
# Module: Feature — Audio Priority
# Responsibility: Set audio latency environment variable
#
# In wrapper mode the export is inherited by the child process tree.
# In ``on`` mode there is no persistent process, so we write an env file
# that external tools or launchers can source.
# ============================================================================


class AudioPriority(_BaseFeature):
    """Manage the ``PULSE_LATENCY_MSEC`` environment variable."""

    def _toggle(self, desired: str) -> FeatureResult:
        return self._guarded(
            self._cfg.enable_audio, "Audio priority", lambda: self._set(desired)
        )

    def _set(self, desired: str) -> FeatureResult:
        if desired == "on":
            self._log.debug("Audio: PULSE_LATENCY_MSEC=%s", self._cfg.audio_latency)
            os.environ["PULSE_LATENCY_MSEC"] = self._cfg.audio_latency
            self._cfg.audio_env_file.parent.mkdir(parents=True, exist_ok=True)
            self._cfg.audio_env_file.write_text(
                f"export PULSE_LATENCY_MSEC={self._cfg.audio_latency}\n",
            )
            return FeatureResult.did_change(
                f"PULSE_LATENCY_MSEC={self._cfg.audio_latency}",
            )
        else:
            os.environ.pop("PULSE_LATENCY_MSEC", None)
            try:
                self._cfg.audio_env_file.unlink()
            except FileNotFoundError:
                pass
            return FeatureResult.did_change("cleared PULSE_LATENCY_MSEC")

    def enable(self, _output: str) -> FeatureResult:
        return self._toggle("on")

    def disable(self, _output: str) -> FeatureResult:
        return self._toggle("off")


# ============================================================================
# Module: Steam Environment
# Responsibility: Provide optional Steam wrapper script path
# ============================================================================


def steam_wrapper_path(
    config: Config, _runner: Runner, log: logging.Logger
) -> Path | None:
    """Return the path to the Steam wrapper script, or ``None``."""
    if not config.enable_steam:
        return None
    path = Path(config.steam_script)
    if path.is_file() and os.access(path, os.X_OK):
        return path
    log.debug("Steam wrapper script not found or not executable: %s", path)
    return None


class SystemdRun:
    """Wrapper that prepends systemd-run with resource limits.

    Wraps a command argv with ``systemd-run [args] -- <command>`` to apply
    cgroup resource limits (CPU, memory, I/O, nice) to the child process.
    """

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        self._cfg = config
        self._run = runner
        self._log = log

    def wrap_argv(self, argv: list[str]) -> list[str]:
        """Wrap *argv* with systemd-run if enabled.

        Returns the original argv unchanged if ``enable_systemd_run`` is False
        or if systemd-run is not available.
        """
        if not self._cfg.enable_systemd_run:
            return argv

        if not self._run.require("systemd-run", "systemd-run"):
            return argv

        if not self._cfg.systemd_run_args:
            self._log.warning("ENABLE_SYSTEMD_RUN is set but SYSTEMD_RUN_ARGS is empty")
            return argv

        self._log.debug(
            "systemd-run wrapping: %s",
            " ".join(self._cfg.systemd_run_args + ["--", *argv]),
        )

        return ["systemd-run", *self._cfg.systemd_run_args, "--", *argv]


# ============================================================================
# Module: Feature — Screen Inhibit
# Responsibility: Run command with idle/sleep inhibition
#
# When niri is the compositor, DMS inhibit is used directly (enable/disable).
# The freedesktop ScreenSaver DBus API is used as a universal fallback
# (acquire/release an inhibition cookie via dbus-send).
# ``systemd-inhibit`` wraps the child command for all compositors.
# On KDE, ``kde-inhibit --colorCorrect`` is also invoked as a one-shot
# setup step (it is not a command wrapper and cannot be chained).
# ============================================================================


class ScreenInhibit(_BaseFeature):
    """Manage idle/sleep inhibition via systemd-inhibit, DMS, and DBus ScreenSaver."""

    _DMS_CMD = "dms"
    _DMS_FEATURE = "DMS inhibit"
    _DBUS_SERVICE = "org.freedesktop.ScreenSaver"
    _DBUS_PATH = "/ScreenSaver"
    _DBUS_IFACE = "org.freedesktop.ScreenSaver"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        # Factory runner for DMS commands
        self._dms = runner.make_checked_runner(self._DMS_CMD, self._DMS_FEATURE)
        # Resolve dbus-send once (used in enable/disable for ScreenSaver cookies).
        self._dbus_send: str | None = runner.resolve("dbus-send")
        # DBus ScreenSaver cookie (uint32), acquired on enable, released on disable.
        self._screensaver_cookie: int | None = None

    # -- DMS helpers -------------------------------------------------------

    def _dms_inhibit_enabled(self) -> bool:
        """Return ``True`` if DMS idle inhibit is currently enabled."""
        result = self._dms.run_or_none(
            [self._DMS_CMD, "ipc", "call", "inhibit", "status"]
        )
        if result is None:
            return False
        return "Idle inhibit is disabled" not in result.stdout

    def _dms_inhibit_enable(self, reason: str = "gamemode.py gaming session") -> bool:
        """Enable DMS inhibit.  Returns ``True`` on success."""
        if not self._dms.is_available:
            return False
        if self._dms_inhibit_enabled():
            self._log.debug("DMS inhibit already active")
            return True

        for cmd, desc in (
            (["enable"], "enable DMS inhibit"),
            (["reason", reason], "set DMS inhibit reason"),
        ):
            r = self._dms.run_or_none([self._DMS_CMD, "ipc", "call", "inhibit", *cmd])
            if r is None or r.returncode != 0:
                self._log.error("Failed to %s", desc)
                return False

        self._log.debug("DMS inhibit enabled")
        return True

    def _dms_inhibit_disable(self) -> None:
        """Disable DMS inhibit (if currently enabled)."""
        if not self._dms.is_available:
            return
        if not self._dms_inhibit_enabled():
            self._log.debug("DMS inhibit not active, skipping disable")
            return

        self._dms.run_or_none([self._DMS_CMD, "ipc", "call", "inhibit", "disable"])
        self._log.debug("DMS inhibit disabled")

    # -- DBus ScreenSaver cookie management --------------------------------

    def _screensaver_inhibit_enable(
        self, reason: str = "gamemode.py gaming session"
    ) -> bool:
        """Acquire a ScreenSaver inhibition cookie via DBus.

        Returns ``True`` if a cookie was successfully acquired and stored.
        """
        if self._screensaver_cookie is not None:
            self._log.debug("ScreenSaver cookie already acquired")
            return True

        if self._dbus_send is None:
            self._log.debug("dbus-send not found, cannot use ScreenSaver inhibit")
            return False

        result = self._run.capture(
            [
                self._dbus_send,
                "--session",
                f"--dest={self._DBUS_SERVICE}",
                "--type=method_call",
                "--print-reply=literal",
                self._DBUS_PATH,
                f"{self._DBUS_IFACE}.Inhibit",
                "string:gamemode.py",
                f"string:{reason}",
            ]
        )
        if result.returncode != 0:
            self._log.warning(
                "ScreenSaver.Inhibit failed: %s",
                result.stderr.strip(),
            )
            return False

        cookie_str = result.stdout.strip()
        if cookie_str.startswith("uint32 "):
            cookie_str = cookie_str[7:]
        try:
            self._screensaver_cookie = int(cookie_str)
        except ValueError:
            self._log.warning("Unexpected cookie value: %r", cookie_str)
            return False

        self._log.debug("ScreenSaver cookie acquired: %d", self._screensaver_cookie)
        return True

    def _screensaver_inhibit_disable(self) -> None:
        """Release the ScreenSaver inhibition cookie if held."""
        if self._screensaver_cookie is None:
            self._log.debug("No ScreenSaver cookie to release")
            return

        if self._dbus_send is None:
            self._log.warning("dbus-send not found, cannot release ScreenSaver cookie")
            return

        result = self._run.capture(
            [
                self._dbus_send,
                "--session",
                f"--dest={self._DBUS_SERVICE}",
                "--type=method_call",
                "--print-reply",
                self._DBUS_PATH,
                f"{self._DBUS_IFACE}.UnInhibit",
                f"uint32:{self._screensaver_cookie}",
            ]
        )
        if result.returncode != 0:
            err = result.stderr.strip()
            if "invalid cookie" in err.lower():
                self._log.debug("ScreenSaver cookie invalid (already released)")
            else:
                self._log.warning(
                    "ScreenSaver.UnInhibit failed (cookie=%d): %s",
                    self._screensaver_cookie,
                    err,
                )
        else:
            self._log.debug(
                "ScreenSaver cookie released: %d",
                self._screensaver_cookie,
            )
        self._screensaver_cookie = None

    # -- Feature interface -------------------------------------------------

    def _toggle(self, desired: str) -> FeatureResult:
        return self._guarded(
            self._cfg.enable_inhibit, "Screen inhibit", lambda: self._set(desired)
        )

    def _set(self, desired: str) -> FeatureResult:
        results: list[str] = []

        if desired == "on":
            # Try DMS inhibit (niri only).
            if compositor_is_niri():
                ok = self._dms_inhibit_enable()
                if ok:
                    results.append("DMS inhibit enabled")
                else:
                    self._log.warning("DMS inhibit failed, falling back to DBus")

            # Always try DBus ScreenSaver inhibit as a universal mechanism.
            if self._screensaver_inhibit_enable():
                results.append("ScreenSaver cookie acquired")

            if not results:
                return FeatureResult.error("all inhibit mechanisms failed")
            return FeatureResult.did_change("; ".join(results))
        else:
            # Disable DMS inhibit (niri only).
            if compositor_is_niri():
                self._dms_inhibit_disable()
                results.append("DMS inhibit disabled")

            # Release DBus ScreenSaver cookie.
            self._screensaver_inhibit_disable()
            results.append("ScreenSaver cookie released")

            return FeatureResult(changed=True, detail="; ".join(results))

    def enable(self, _output: str) -> FeatureResult:
        """Enable idle/sleep inhibit via DMS (niri) and/or DBus ScreenSaver."""
        return self._toggle("on")

    def disable(self, _output: str) -> FeatureResult:
        """Disable idle/sleep inhibit via DMS (niri) and/or DBus ScreenSaver."""
        return self._toggle("off")

    # -- inhibit wrapper for child commands --------------------------------

    def inhibit_argv(self, argv: list[str]) -> list[str]:
        """Wrap *argv* with ``systemd-inhibit`` if available.

        On KDE, also runs ``kde-inhibit --colorCorrect`` as a one-shot
        preamble before returning the wrapped command.
        """
        if not self._cfg.enable_inhibit:
            return argv

        inhibit = self._run.resolve("systemd-inhibit")
        if inhibit is None:
            return argv

        # On KDE, run kde-inhibit --colorCorrect as a one-shot setup.
        # It is not a wrapper and cannot be chained after systemd-inhibit.
        if session_is_kde():
            kde_inhibit = self._run.resolve("kde-inhibit")
            if kde_inhibit is not None:
                self._log.debug("Running kde-inhibit --colorCorrect (one-shot)")
                try:
                    subprocess.run(
                        [str(kde_inhibit), "--colorCorrect"],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                except OSError:
                    self._log.debug("kde-inhibit --colorCorrect failed")

        return [
            str(inhibit),
            "--what=idle:sleep",
            "--mode=block",
            "--why=gamemode.py",
            "--",
            *argv,
        ]


# ============================================================================
# Module: Feature Orchestration
# Responsibility: Coordinate feature enable/disable operations
# ============================================================================


def collect_features(
    config: Config,
    runner: Runner,
    log: logging.Logger,
) -> list[tuple[str, Feature]]:
    """Instantiate every feature based on the current config.

    Returns a list of ``(name, feature)`` tuples.  The order matches
    the original bash script's ``features_enable``/``features_disable``.
    """
    return cast(
        list[tuple[str, Feature]],
        [
            ("tuned", PowerProfile(config, runner, log)),
            ("vrr", VRR(config, runner, log)),
            ("scx", SCXScheduler(config, runner, log)),
            ("audio", AudioPriority(config, runner, log)),
            ("inhibit", ScreenInhibit(config, runner, log)),
        ],
    )


def _apply_features(
    features: list[tuple[str, Feature]],
    output: str,
    log: logging.Logger,
    method: str,
) -> None:
    """Run *method* (``"enable"`` or ``"disable"``) on every feature, logging results."""
    log.debug("%sing features for output: %s", method.capitalize(), output)
    for name, feat in features:
        result = getattr(feat, method)(output)
        _BaseFeature._log_result(name, result, log)


def features_enable(
    features: list[tuple[str, Feature]],
    output: str,
    log: logging.Logger,
) -> None:
    _apply_features(features, output, log, "enable")


def features_disable(
    features: list[tuple[str, Feature]],
    output: str,
    log: logging.Logger,
) -> None:
    _apply_features(features, output, log, "disable")


# ============================================================================
# Module: Actions
# Responsibility: Implement user-facing on/off/wrapper commands
# ============================================================================


def _prepare_action(
    config: Config,
    runner: Runner,
    log: logging.Logger,
    *,
    debug: bool = False,
) -> tuple[str, list[tuple[str, Feature]], StateManager]:
    """Common setup shared by ``action_on`` and ``action_off``.

    Returns the resolved output name, collected features, and state manager.
    """
    output = output_resolve(config)
    state = StateManager(config)
    state.init()
    setup_logging(config, to_file=debug)
    features = collect_features(config, runner, log)
    return output, features, state


def action_on(
    config: Config, runner: Runner, log: logging.Logger, *, debug: bool = False
) -> int:
    """Activate gaming mode.  Returns an exit code."""
    output, features, state = _prepare_action(
        config,
        runner,
        log,
        debug=debug,
    )

    log.info("Activating (output: %s)", output)

    if state.is_wrapper:
        log.debug("Wrapper mode active, skipping on")
        return 0
    if state.is_active:
        log.info("Already active (idempotent)")
        return 0

    state.mark_active()
    features_enable(features, output, log)
    log.info("Activation complete")
    return 0


def action_off(
    config: Config,
    runner: Runner,
    log: logging.Logger,
    *,
    debug: bool = False,
    force: bool = False,
) -> int:
    """Deactivate gaming mode.  Returns an exit code."""
    output, features, state = _prepare_action(
        config,
        runner,
        log,
        debug=debug,
    )

    log.debug("Checking state for deactivation (output: %s)", output)

    if state.is_wrapper:
        # Check if the wrapper process is still alive.
        if state.wrapper_alive():
            # Wrapper is running — normal case, skip off (let wrapper handle cleanup).
            log.debug("Wrapper mode active, skipping off")
            return 0
        else:
            # Stale state: wrapper process is dead, force cleanup.
            pid = state.wrapper_pid()
            log.warning(
                "Stale wrapper state detected (PID %s dead), forcing cleanup",
                pid if pid is not None else "unknown",
            )
    elif force:
        log.info("Force cleanup requested (state: %r)", state.value())
    elif not state.value():
        log.info("Nothing active, skipping")
        return 0
    elif state.is_active:
        log.info("Deactivating manual activation (output: %s)", output)
    else:
        log.debug("Unknown state %r, cleaning up anyway", state.value())

    if state.is_wrapper or force or state.is_active or state.value():
        features_disable(features, output, log)
        state.clear()
        log.info("Cleanup complete")

    return 0


def action_status(config: Config, _runner: Runner, _log: logging.Logger) -> int:
    """Print current state for diagnostics.  Returns 0."""
    state = StateManager(config)
    state.init()

    value = state.value()
    pid = state.wrapper_pid()
    lock_held = state.is_lock_held()
    alive = state.wrapper_alive() if pid is not None else False

    # Compositor info
    niri = compositor_is_niri()
    kde = session_is_kde()
    session = os.environ.get("XDG_SESSION_DESKTOP", "(unset)")
    current_desktop = os.environ.get("XDG_CURRENT_DESKTOP", "(unset)")

    output = output_resolve(config)

    lines = [
        f"State:            {value or '(none)'}",
        f"Wrapper PID:      {pid if pid is not None else '(none)'}",
        f"PID alive:        {alive if pid is not None else 'N/A'}",
        f"Lock held:        {lock_held}",
        f"Stale state:      {value == 'wrapper' and pid is not None and not alive}",
        "",
        f"Compositor:       {'niri' if niri else 'kde' if kde else 'unknown'}",
        f"  XDG_SESSION_DESKTOP:    {session}",
        f"  XDG_CURRENT_DESKTOP:    {current_desktop}",
        f"Target output:    {output}",
        "",
        f"State dir:        {config.state_dir}",
        f"State file:       {config.state_file}",
        f"Lock file:        {config.lock_file}",
        f"PID file:         {config.pid_file}",
    ]
    print("\n".join(lines))
    return 0


def _build_cleanup_closure(
    features: list[tuple[str, Feature]],
    output: str,
    log: logging.Logger,
    state: StateManager,
):
    """Return a cleanup callable that captures current feature/output state."""
    _done = [False]  # mutable closure cell

    def _cleanup() -> None:
        if _done[0]:
            return
        _done[0] = True
        try:
            features_disable(features, output, log)
            state.clear()
        except Exception:
            log.exception("Error during cleanup")

    return _cleanup


@contextmanager
def _signal_guard(
    log: logging.Logger,
    child_proc: list[subprocess.Popen | None],
) -> "Iterator[int]":
    """Context manager: install SIGTERM/SIGINT/SIGHUP handlers that kill *child_proc*.

    Yields a mutable cell (``pending_signal[0]``) that will be set to the
    received signal number if one arrives.  On exit, original handlers are
    restored.

    Usage::
        pending = [0]
        child: list[subprocess.Popen | None] = [None]
        with _signal_guard(log, child) as pending:
            child[0] = subprocess.Popen(cmd, start_new_session=True)
            retcode = child[0].wait()
        if pending[0]:
            sys.exit(128 + pending[0])
    """
    pending_signal = [0]
    _orig_term = signal.getsignal(signal.SIGTERM)
    _orig_int = signal.getsignal(signal.SIGINT)
    _orig_hup = signal.getsignal(signal.SIGHUP) if hasattr(signal, "SIGHUP") else None

    def _handler(signum: int, _frame: object) -> None:
        log.info("Received signal %s, terminating child and cleaning up", signum)
        pending_signal[0] = signum
        if child_proc[0] is not None:
            try:
                child_proc[0].kill()
            except OSError:
                pass

    try:
        signal.signal(signal.SIGTERM, _handler)
        signal.signal(signal.SIGINT, _handler)
        if hasattr(signal, "SIGHUP"):
            signal.signal(signal.SIGHUP, _handler)
    except (ValueError, OSError):
        # Not the main thread — signals cannot be installed.
        pending_signal[0] = 0
        _orig_term = None
        _orig_int = None
        _orig_hup = None

    try:
        yield pending_signal[0]
    finally:
        if _orig_term is not None:
            try:
                signal.signal(signal.SIGTERM, _orig_term)
                signal.signal(signal.SIGINT, _orig_int)
            except (ValueError, OSError):
                pass
        if _orig_hup is not None and hasattr(signal, "SIGHUP"):
            try:
                signal.signal(signal.SIGHUP, _orig_hup)
            except (ValueError, OSError):
                pass


def _watch_parent(log: logging.Logger) -> None:
    """Install a PR_SET_PDEATHSIG so the kernel kills us if our parent dies.

    This prevents orphaned gamemode.py processes from holding locks or
    state files when the launching shell script exits unexpectedly.

    Uses SIGTERM so the _signal_guard cleanup handlers still fire.
    """
    PR_SET_PDEATHSIG = 1
    libc_path = ctypes.util.find_library("c")
    if libc_path is None:
        log.warning("Cannot find libc for PR_SET_PDEATHSIG")
        return
    try:
        libc = ctypes.CDLL(libc_path)
        ret = libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
        if ret != 0:
            log.warning(
                "prctl(PR_SET_PDEATHSIG) failed: %s", os.strerror(ctypes.get_errno())
            )
    except (OSError, AttributeError) as exc:
        log.warning("prctl unavailable for parent-death detection: %s", exc)


def action_wrapper(
    config: Config,
    runner: Runner,
    log: logging.Logger,
    command: list[str],
    *,
    debug: bool = False,
) -> int:
    """Wrapper mode: enable features, run *command*, disable on exit.

    Returns the child process exit code, or 1 on internal failure.

    Signal handling: SIGTERM/SIGINT trigger cleanup before exit.
    The child process runs in its own session (``start_new_session``)
    so that signals to this process don't reach the game and vice versa.
    """
    output = output_resolve(config)
    state = StateManager(config)
    state.init()

    log.info("Wrapper mode (output: %s, command: %s)", output, " ".join(command))

    # If the parent shell (bazzite-steam-bpm.sh) dies, we get SIGTERM and
    # run the same cleanup path as a normal exit.
    _watch_parent(log)

    with state.locked() as acquired:
        if not acquired:
            log.debug("Another wrapper instance holds the lock, skipping")
            return 0

        setup_logging(config, to_file=debug)

        state.mark_wrapper()
        state.write_pid()
        features = collect_features(config, runner, log)
        features_enable(features, output, log)

        cleanup = _build_cleanup_closure(features, output, log, state)

        chain = WrapperChain()
        for factory in WRAPPER_FACTORIES:
            chain.add_factory(factory, config, runner, log)
        exec_cmd = chain.apply(list(command))

        # Run the child process with signal-guarded cleanup.
        child_proc: list[subprocess.Popen | None] = [None]

        with _signal_guard(log, child_proc) as pending_signal:
            try:
                # start_new_session isolates the child into its own
                # process group so signals don't cross the boundary.
                child_proc[0] = subprocess.Popen(exec_cmd, start_new_session=True)
                retcode = child_proc[0].wait()
            except OSError as exc:
                log.error("Failed to execute command: %s", exc)
                return 1
            finally:
                cleanup()

        # After cleanup, exit with the signal number if one arrived.
        if pending_signal:
            sys.exit(128 + pending_signal)

        return retcode


# ============================================================================
# Module: Usage
# Responsibility: Print help / usage information
# ============================================================================


USAGE = textwrap.dedent("""\
    Usage: gamemode.py [MODE] [COMMAND...]

    Performance toggle for gaming sessions.

    MODES:
      on              Activate gaming mode (VRR, scheduler, profile, etc.)
      off             Deactivate gaming mode, restore desktop defaults
      off --force     Force cleanup even if state looks corrupted
      status          Show current state and diagnostics
      <command>       Wrapper mode: enable features, then run <command>
                      (auto-cleanup on exit)

    OPTIONS:
      -h, --help      Show this help message

    FEATURES (env-overridable):
      VRR             Toggle VRR on the active niri output
                        ENABLE_VRR=true       VRR_OUTPUT=DP-1
      SCX Scheduler   Load/switch scx scheduler
                        ENABLE_SCX_SCHEDULER=true
                        SCX_SCHEDULER=lavd
                        SCX_SCHEDULER_MODE=gaming
      Power Profile   Switch tuned-adm profile
                        ENABLE_PERFORMANCE_MODE=false  (set to true to enable)
                        GAME_PROFILE=throughput-performance-bazzite
                        DESKTOP_PROFILE=balanced-bazzite
      Screen Inhibit  Prevent idle/sleep during gaming
                        ENABLE_SCREEN_KEEP_AWAKE=true
      Audio Priority  Set Pulse latency for lower-latency audio
                        ENABLE_AUDIO_PRIORITY_BOOST=false
                        PULSE_LATENCY_MSEC=60
      Steam Env       Prepend steam-env-base.sh to wrapped commands
                        ENABLE_STEAM_ENV=true
      Systemd Run     Wrap command with systemd-run for resource limits
                        ENABLE_SYSTEMD_RUN=false
                        SYSTEMD_RUN_ARGS="--user --scope --slice=app.slice ..."

    ENVIRONMENT:
      NIRI_OUTPUT_NAME   Override the target output (falls back to VRR_OUTPUT)
      DEBUG=1            Enable debug logging
      XDG_RUNTIME_DIR    State dir and log file location (default: /tmp)

    LOGGING:
      Runs log to $XDG_RUNTIME_DIR/gamemode.log (or /tmp/gamemode.log)
      Set DEBUG=1 for verbose output.

    EXAMPLES:
      python3 gamemode.py on                          # Toggle on
      python3 gamemode.py off                         # Toggle off
      python3 gamemode.py off --force                 # Force cleanup stale state
      python3 gamemode.py status                      # Show current state
      python3 gamemode.py -- steam                    # Wrapper: launch steam with gaming features
      python3 gamemode.py -- ~/Games/hero/main.sh     # Wrapper: run a game directly
      ENABLE_VRR=false python3 gamemode.py on         # Toggle on without VRR
      ENABLE_SYSTEMD_RUN=true SYSTEMD_RUN_ARGS='--user --scope --slice=app.slice --property=CPUWeight=500' python3 gamemode.py -- steam
""")


# ============================================================================
# Module: CLI Parser
# Responsibility: Parse arguments and route to actions
# ============================================================================


def cli_parse(argv: list[str] | None = None) -> tuple[str | None, list[str]]:
    """Parse CLI arguments and return ``(mode, command, force)``.

    Modes returned:
      ``"on"``      — activate
      ``"off"``     — deactivate
      ``"status"``   — show diagnostics
      ``"wrapper"`` — wrapper mode (command follows ``--``)
      ``None``       — help was printed or error occurred
    """
    if argv is None:
        argv = sys.argv[1:]

    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE, end="")
        return None, []

    mode = argv[0]

    if mode in ("on", "off", "status"):
        # Check for --force flag after 'off'
        force = "--force" in argv[1:]
        return mode, ["--force"] if force else []

    if mode == "--":
        command = argv[1:]
        if not command:
            print(
                "Error: wrapper mode requires a command after '--'",
                file=sys.stderr,
            )
            print(USAGE, end="", file=sys.stderr)
            return None, []
        return "wrapper", command

    # Treat unknown first arg as an implicit wrapper command (matches
    # the bash behaviour where any non-on/off arg falls through to
    # the wrapper case).
    return "wrapper", argv


# ============================================================================
# Entry Point
# ============================================================================


def main(argv: list[str] | None = None) -> int:
    """Main entry point.  Returns a process exit code."""
    config = Config()

    debug = os.environ.get("DEBUG", "") in ("1", "true", "yes")
    log = setup_logging(config, to_file=False, debug=debug)

    mode, command = cli_parse(argv)
    if mode is None:
        return 1

    runner = Runner(log)

    if not validate_deps(config, runner, log):
        return 1

    if mode == "on":
        return action_on(config, runner, log, debug=debug)
    if mode == "off":
        force = "--force" in command
        return action_off(config, runner, log, debug=debug, force=force)
    if mode == "status":
        return action_status(config, runner, log)
    if mode == "wrapper":
        return action_wrapper(config, runner, log, command, debug=debug)

    # Unreachable, but satisfy type checkers.
    log.error("Unknown subcommand: '%s'", mode)
    return 1


if __name__ == "__main__":
    sys.exit(main())
