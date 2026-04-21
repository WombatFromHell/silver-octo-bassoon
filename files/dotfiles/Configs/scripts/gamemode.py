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
* Configuration is a frozen dataclass populated from a merged config file
  + environment variables, with sensible defaults.
* Toggle mode and wrapper mode are decoupled.  Wrapper mode automatically
  skips feature toggles if toggle mode is already active, applying only
  the configured command wrappers (e.g. systemd-run).

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
import json
import sys
import textwrap
from contextlib import contextmanager
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any, Callable, Iterator, Protocol, cast, runtime_checkable


# ============================================================================
# Module: Configuration File Loader
# Responsibility: Parse $HOME/.config/gamemode.conf (KEY=VALUE)
# ============================================================================
def load_config_file(path: Path = Path.home() / ".config" / "gamemode.conf") -> None:
    """Load KEY=VALUE config from file into os.environ (env vars take precedence)."""
    if not path.is_file():
        return
    try:
        for line in path.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if len(val) >= 2 and val[0] in ("'", '"') and val[0] == val[-1]:
                val = val[1:-1]
            val = val.strip()
            # Only inject if not already set in the environment
            if key not in os.environ:
                os.environ[key] = val
    except OSError:
        pass  # Gracefully ignore read errors


# ============================================================================
# Module: Configuration
# Responsibility: Load and expose configuration values from merged sources
# ============================================================================
def _env_bool(name: str, default: bool) -> bool:
    """Parse an env var as a boolean (``true``/``1``/``yes`` → True)."""
    val = os.environ.get(name)
    if val is None:
        return default
    return val.lower() in ("true", "1", "yes")


def _env_set(name: str, default: str) -> set[str]:
    """Parse a comma-separated env var into a lowercase set."""
    raw = os.environ.get(name, default)
    return {s.strip().lower() for s in raw.split(",") if s.strip()}


@dataclass(frozen=True, slots=True)
class Config:
    """Immutable, env-driven configuration.
    Every field reads from the corresponding environment variable at
    construction time and then becomes read-only.  Feature toggles use
    ``True`` / ``False`` strings to match the bash convention so that
    ``ENABLE_VRR=false python3 gamemode.py on`` works as expected.
    """

    # -- mode routing ------------------------------------------------------
    toggle_features: set[str] = field(
        default_factory=lambda: _env_set(
            "TOGGLE_FEATURES", "vrr,scx,tuned,audio,inhibit,steam"
        ),
    )
    wrapper_features: set[str] = field(
        default_factory=lambda: _env_set(
            "WRAPPER_FEATURES", "systemd_run,steam,inhibit"
        ),
    )
    # -- feature toggles ---------------------------------------------------
    enable_scx: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SCX_SCHEDULER", True)
    )
    enable_vrr: bool = field(default_factory=lambda: _env_bool("ENABLE_VRR", True))
    enable_tuned: bool = field(
        default_factory=lambda: _env_bool("ENABLE_PERFORMANCE_MODE", False)
    )
    enable_inhibit: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SCREEN_KEEP_AWAKE", True)
    )
    enable_audio: bool = field(
        default_factory=lambda: _env_bool("ENABLE_AUDIO_PRIORITY_BOOST", False)
    )
    enable_steam: bool = field(
        default_factory=lambda: _env_bool("ENABLE_STEAM_ENV", True)
    )
    enable_systemd_run: bool = field(
        default_factory=lambda: _env_bool("ENABLE_SYSTEMD_RUN", True)
    )

    # -- feature parameters ------------------------------------------------
    scx_scheduler: str = field(
        default_factory=lambda: os.environ.get("SCX_SCHEDULER", "lavd")
    )
    scx_mode: str = field(
        default_factory=lambda: os.environ.get("SCX_SCHEDULER_MODE", "gaming")
    )
    profile_game: str = field(
        default_factory=lambda: os.environ.get(
            "GAME_PROFILE", "throughput-performance-bazzite"
        )
    )
    profile_desktop: str = field(
        default_factory=lambda: os.environ.get("DESKTOP_PROFILE", "balanced-bazzite")
    )
    audio_latency: str = field(
        default_factory=lambda: os.environ.get("PULSE_LATENCY_MSEC", "60")
    )
    steam_script: str = field(
        default_factory=lambda: os.environ.get(
            "STEAM_ENV_SCRIPT",
            str(Path.home() / ".local" / "bin" / "scripts" / "steam-env-base.sh"),
        )
    )
    vrr_output_default: str = field(
        default_factory=lambda: os.environ.get("VRR_OUTPUT", "DP-1")
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
        default_factory=lambda: os.environ.get("XDG_RUNTIME_DIR", "/tmp")
    )

    # -- derived paths -----------------------------------------------------
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
    def log_file(self) -> Path:
        return Path(self.runtime_dir) / "gamemode.log"

    @property
    def audio_env_file(self) -> Path:
        return self.state_dir / "audio.env"


# ============================================================================
# Module: Logging
# ============================================================================
def setup_logging(
    config: Config, *, to_file: bool = False, debug: bool = False
) -> logging.Logger:
    log = logging.getLogger("gamemode")
    if log.handlers:
        log.handlers.clear()
    log.setLevel(logging.DEBUG)
    fmt = logging.Formatter(
        "%(asctime)s [gamemode] %(levelname)s: %(message)s", datefmt="%H:%M:%S"
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
# ============================================================================
class Runner:
    """Abstraction over subprocess for host-executable calls."""

    def __init__(self, log: logging.Logger) -> None:
        self._log = log

    def resolve(self, cmd: str) -> str | None:
        return shutil.which(cmd)

    def require(self, cmd: str, feature: str = "") -> bool:
        if self.resolve(cmd) is None:
            if feature:
                self._log.error("%s requires '%s' (not found)", feature, cmd)
            return False
        return True

    def run(
        self,
        args: list[str],
        *,
        check: bool = False,
        capture_output: bool = False,
        text: bool = False,
        env: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        self._log.debug("exec: %s", " ".join(args))
        try:
            return subprocess.run(
                args, check=check, capture_output=capture_output, text=text, env=env
            )
        except FileNotFoundError:
            self._log.error("command not found: %s", args[0])
            raise

    def capture(self, args: list[str]) -> subprocess.CompletedProcess[str]:
        return self.run(args, capture_output=True, text=True)

    def pipe(
        self, args: list[str], input_data: str
    ) -> subprocess.CompletedProcess[str]:
        self._log.debug("pipe: %s  (stdin: %d bytes)", " ".join(args), len(input_data))
        return subprocess.run(args, input=input_data, capture_output=True, text=True)

    def make_checked_runner(
        self, cmd: str, feature: str = ""
    ) -> "CheckedCommandRunner":
        return CheckedCommandRunner(self, cmd, feature)


class CheckedCommandRunner:
    def __init__(
        self,
        runner: Runner,
        cmd: str,
        feature: str = "",
        log: logging.Logger | None = None,
    ) -> None:
        self._runner = runner
        self._cmd = cmd
        self._feature = feature
        self._log = log or runner._log
        self._available = runner.require(cmd, feature)

    @property
    def is_available(self) -> bool:
        return self._available

    def run_or_none(
        self, args: list[str], **kwargs: Any
    ) -> subprocess.CompletedProcess[str] | None:
        if not self._available:
            return None
        result = self._runner.run(args, capture_output=True, text=True, **kwargs)
        if result.returncode != 0:
            self._log.debug(
                "%s: %s returned %d",
                self._feature or self._cmd,
                self._cmd,
                result.returncode,
            )
        return result


# ============================================================================
# Module: Dependency Validation
# ============================================================================
def validate_deps(config: Config, runner: Runner, log: logging.Logger) -> bool:
    """Check that all required host executables are available for active toggles."""
    checks: dict[str, bool] = {
        "tuned-adm": config.enable_tuned,
        "systemd-inhibit": config.enable_inhibit,
        "dbus-send": config.enable_inhibit,
        "scxctl": config.enable_scx,
        "jq": config.enable_vrr,
    }
    missing = [
        cmd
        for cmd, enabled in checks.items()
        if enabled and runner.resolve(cmd) is None
    ]
    if missing:
        log.error("Missing dependencies: %s", " ".join(missing))
        return False
    return True


# ============================================================================
# Module: Compositor & Output
# ============================================================================
def _session_contains(substring: str) -> bool:
    session = os.environ.get("XDG_SESSION_DESKTOP", "")
    current = os.environ.get("XDG_CURRENT_DESKTOP", "")
    return substring in (session + current).lower()


@lru_cache(maxsize=1)
def compositor_is_niri() -> bool:
    if _session_contains("niri"):
        return True
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
    return _session_contains("kde")


def output_resolve(config: Config) -> str:
    return os.environ.get("NIRI_OUTPUT_NAME", config.vrr_output_default)


# ============================================================================
# Module: State Management
# ============================================================================
class StateManager:
    def __init__(self, config: Config) -> None:
        self._config = config

    def init(self) -> None:
        self._config.state_dir.mkdir(parents=True, exist_ok=True)

    @staticmethod
    def _try_lock(fd: int) -> bool:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return True
        except (BlockingIOError, OSError):
            return False

    @staticmethod
    def _unlock(fd: int) -> None:
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass

    @staticmethod
    def _close_lock_fd(fd: int, lock_path: Path) -> None:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            lock_path.unlink()
        except OSError:
            pass

    @contextmanager
    def locked(self):
        lock_path = self._config.lock_file
        fd = os.open(str(lock_path), os.O_CREAT | os.O_WRONLY)
        acquired = self._try_lock(fd)
        try:
            yield acquired
        finally:
            self._unlock(fd)
            self._close_lock_fd(fd, lock_path)

    def is_lock_held(self) -> bool:
        lock_path = self._config.lock_file
        fd = os.open(str(lock_path), os.O_CREAT | os.O_WRONLY)
        try:
            return not self._try_lock(fd)
        finally:
            self._unlock(fd)
            self._close_lock_fd(fd, lock_path)

    def _read_state(self) -> dict[str, Any]:
        try:
            return json.loads(self._config.state_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError):
            return {}

    def _write_state(self, data: dict[str, Any]) -> None:
        self._config.state_file.write_text(json.dumps(data))

    @property
    def mode(self) -> str:
        return self._read_state().get("mode", "")

    @property
    def is_wrapper(self) -> bool:
        return self.mode == "wrapper"

    @property
    def is_active(self) -> bool:
        return self.mode == "active"

    def mark_wrapper(self, cmd: list[str] | None = None) -> None:
        data: dict[str, Any] = {"mode": "wrapper", "pid": os.getpid()}
        if cmd:
            data["cmd"] = cmd
        self._write_state(data)

    def mark_active(self) -> None:
        self._write_state({"mode": "active"})

    def clear(self) -> None:
        try:
            self._config.state_file.unlink()
        except FileNotFoundError:
            pass
        for f in self._config.state_dir.glob("lock_*"):
            try:
                f.unlink()
            except OSError:
                pass

    def pid(self) -> int | None:
        return self._read_state().get("pid")

    def cmd(self) -> list[str] | None:
        return self._read_state().get("cmd")

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        try:
            os.kill(pid, 0)
            return True
        except OSError:
            return False

    def pid_alive(self) -> bool:
        p = self.pid()
        return p is not None and self._pid_alive(p)


# ============================================================================
# Module: Feature Protocol & Result
# ============================================================================
class FeatureResult:
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
    def enable(self, _output: str) -> FeatureResult: ...
    def disable(self, _output: str) -> FeatureResult: ...


CommandWrapper = Callable[[list[str]], list[str]]
WrapperFactory = Callable[["Config", "Runner", logging.Logger], CommandWrapper | None]


class _BaseFeature:
    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        self._cfg = config
        self._run = runner
        self._log = log

    def _gate(self, enabled: bool, _name: str) -> FeatureResult | None:
        if not enabled:
            return FeatureResult.skip("disabled by config")
        return None

    def _guarded(
        self, enabled: bool, name: str, fn: Callable[[], FeatureResult]
    ) -> FeatureResult:
        gate = self._gate(enabled, name)
        if gate is not None:
            return gate
        return fn()

    @staticmethod
    def _log_result(name: str, result: FeatureResult, log: logging.Logger) -> None:
        if result.skipped:
            log.debug("%s: skipped (%s)", name, result.detail)
        elif result.changed:
            log.info("%s: %s", name, result.detail)
        elif not result.ok:
            log.warning("%s: %s", name, result.detail)
        else:
            log.debug("%s: no change", name)


# ============================================================================
# Module: Features
# ============================================================================
class VRR(_BaseFeature):
    _JQ_VRR_SUPPORTED = ".[$o].vrr_supported // true"
    _JQ_VRR_ENABLED = 'if .[$o].vrr_enabled == true then "true" elif .[$o].vrr_enabled == false then "false" else "" end'

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        self._niri_cmd = runner.make_checked_runner("niri", "VRR")

    def _jq_query(self, jq_expr: str, jq_args: dict[str, str] | None) -> str | None:
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
        return self._jq_query(self._JQ_VRR_SUPPORTED, {"o": output}) == "true"

    def _current(self, output: str) -> str:
        result = self._jq_query(self._JQ_VRR_ENABLED, {"o": output})
        if result is None:
            return ""
        if result == "true":
            return "on"
        if result == "false":
            return "off"
        return ""

    def _set(self, output: str, state: str) -> bool:
        if not self._niri_cmd.is_available:
            return False
        result = self._niri_cmd.run_or_none(
            ["niri", "msg", "output", output, "vrr", state]
        )
        return result is not None and result.returncode == 0

    def _toggle(self, output: str, desired: str) -> FeatureResult:
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
        return (
            FeatureResult.did_change(f"{current} → {desired} on {output}")
            if ok
            else FeatureResult.error("toggle failed")
        )

    def enable(self, output: str) -> FeatureResult:
        return self._toggle(output, "on")

    def disable(self, output: str) -> FeatureResult:
        return self._toggle(output, "off")


class PowerProfile(_BaseFeature):
    _CMD = "tuned-adm"
    _FEATURE = "Performance mode"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        self._tuned = runner.make_checked_runner(self._CMD, self._FEATURE)

    def _current(self) -> str:
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

    def _set_state(self, desired: str) -> FeatureResult:
        gate = self._gate(self._cfg.enable_tuned, "Performance mode")
        if gate is not None:
            return gate
        current = self._current()
        if current == desired:
            return FeatureResult.noop()
        self._log.info("Profile: %s → %s", current or "none", desired)
        ok = self._set(desired)
        return (
            FeatureResult.did_change(f"{current or 'none'} → {desired}")
            if ok
            else FeatureResult.error(f"failed to set {desired}")
        )

    def enable(self, _output: str) -> FeatureResult:
        return self._set_state(self._cfg.profile_game)

    def disable(self, _output: str) -> FeatureResult:
        return self._set_state(self._cfg.profile_desktop)


class SCXScheduler(_BaseFeature):
    _CMD = "scxctl"
    _FEATURE = "SCX scheduler"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        self._scxctl = runner.make_checked_runner(self._CMD, self._FEATURE)

    def _status(self) -> str:
        result = self._scxctl.run_or_none([self._CMD, "get"])
        return result.stdout.strip() if result else ""

    def _apply(self) -> FeatureResult:
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
        return (
            FeatureResult.did_change(f"{self._cfg.scx_scheduler}/{self._cfg.scx_mode}")
            if ok
            else FeatureResult.error("scxctl failed")
        )

    def _set_state(self, desired: str) -> FeatureResult:
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
                and self._cfg.scx_scheduler.lower() in status.lower()
                and self._cfg.scx_mode.lower() in status.lower()
            ):
                return FeatureResult.noop()
            return self._apply()
        else:
            if not status or "no scx scheduler running" in status:
                return FeatureResult.noop()
            result = self._scxctl.run_or_none([self._CMD, "stop"])
            ok = result is not None and result.returncode == 0
            return (
                FeatureResult.did_change("stopped")
                if ok
                else FeatureResult.error("stop failed")
            )

    def enable(self, _output: str) -> FeatureResult:
        return self._set_state("on")

    def disable(self, _output: str) -> FeatureResult:
        return self._set_state("off")


class AudioPriority(_BaseFeature):
    def _set_state(self, desired: str) -> FeatureResult:
        return self._guarded(
            self._cfg.enable_audio, "Audio priority", lambda: self._set(desired)
        )

    def _set(self, desired: str) -> FeatureResult:
        if desired == "on":
            self._log.debug("Audio: PULSE_LATENCY_MSEC=%s", self._cfg.audio_latency)
            os.environ["PULSE_LATENCY_MSEC"] = self._cfg.audio_latency
            self._cfg.audio_env_file.parent.mkdir(parents=True, exist_ok=True)
            self._cfg.audio_env_file.write_text(
                f"export PULSE_LATENCY_MSEC={self._cfg.audio_latency}\n"
            )
            return FeatureResult.did_change(
                f"PULSE_LATENCY_MSEC={self._cfg.audio_latency}"
            )
        else:
            os.environ.pop("PULSE_LATENCY_MSEC", None)
            try:
                self._cfg.audio_env_file.unlink()
            except FileNotFoundError:
                pass
            return FeatureResult.did_change("cleared PULSE_LATENCY_MSEC")

    def enable(self, _output: str) -> FeatureResult:
        return self._set_state("on")

    def disable(self, _output: str) -> FeatureResult:
        return self._set_state("off")


class SystemdRun:
    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        self._cfg = config
        self._run = runner
        self._log = log

    def wrap_argv(self, argv: list[str]) -> list[str]:
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


class ScreenInhibit(_BaseFeature):
    _DMS_CMD = "dms"
    _DMS_FEATURE = "DMS inhibit"
    _DBUS_SERVICE = "org.freedesktop.ScreenSaver"
    _DBUS_PATH = "/ScreenSaver"
    _DBUS_IFACE = "org.freedesktop.ScreenSaver"

    def __init__(self, config: Config, runner: Runner, log: logging.Logger) -> None:
        super().__init__(config, runner, log)
        self._dms = runner.make_checked_runner(self._DMS_CMD, self._DMS_FEATURE)
        self._dbus_send: str | None = runner.resolve("dbus-send")
        self._screensaver_cookie: int | None = None

    def _dms_inhibit_enabled(self) -> bool:
        result = self._dms.run_or_none(
            [self._DMS_CMD, "ipc", "call", "inhibit", "status"]
        )
        return result is not None and "Idle inhibit is disabled" not in result.stdout

    def _dms_inhibit_enable(self, reason: str = "gamemode.py gaming session") -> bool:
        if not self._dms.is_available:
            return False
        if self._dms_inhibit_enabled():
            return True
        for cmd, desc in (
            (["enable"], "enable DMS inhibit"),
            (["reason", reason], "set DMS inhibit reason"),
        ):
            r = self._dms.run_or_none([self._DMS_CMD, "ipc", "call", "inhibit", *cmd])
            if r is None or r.returncode != 0:
                self._log.error("Failed to %s", desc)
                return False
        return True

    def _dms_inhibit_disable(self) -> None:
        if not self._dms.is_available or not self._dms_inhibit_enabled():
            return
        self._dms.run_or_none([self._DMS_CMD, "ipc", "call", "inhibit", "disable"])

    def _screensaver_inhibit_enable(
        self, reason: str = "gamemode.py gaming session"
    ) -> bool:
        if self._screensaver_cookie is not None:
            return True
        if self._dbus_send is None:
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
            self._log.warning("ScreenSaver.Inhibit failed: %s", result.stderr.strip())
            return False
        cookie_str = result.stdout.strip()
        if cookie_str.startswith("uint32 "):
            cookie_str = cookie_str[7:]
        try:
            self._screensaver_cookie = int(cookie_str)
        except ValueError:
            self._log.warning("Unexpected cookie value: %r", cookie_str)
            return False
        return True

    def _screensaver_inhibit_disable(self) -> None:
        if self._screensaver_cookie is None:
            return
        if self._dbus_send is None:
            return
        result = self._run.capture(
            [
                self._dbus_send,
                "--session",
                f"--dest={self._DBUS_SERVICE}",
                "--type=method_call",
                "--print-reply=literal",
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
                self._log.warning("ScreenSaver.UnInhibit failed: %s", err)
        else:
            self._log.debug("ScreenSaver cookie released: %d", self._screensaver_cookie)
        self._screensaver_cookie = None

    def _set_state(self, desired: str) -> FeatureResult:
        return self._guarded(
            self._cfg.enable_inhibit, "Screen inhibit", lambda: self._set(desired)
        )

    def _set(self, desired: str) -> FeatureResult:
        results: list[str] = []
        if desired == "on":
            if compositor_is_niri():
                if self._dms_inhibit_enable():
                    results.append("DMS inhibit enabled")
                else:
                    self._log.warning("DMS inhibit failed, falling back to DBus")
            if self._screensaver_inhibit_enable():
                results.append("ScreenSaver cookie acquired")
            if not results:
                return FeatureResult.error("all inhibit mechanisms failed")
            return FeatureResult.did_change("; ".join(results))
        else:
            if compositor_is_niri():
                self._dms_inhibit_disable()
                results.append("DMS inhibit disabled")
            self._screensaver_inhibit_disable()
            results.append("ScreenSaver cookie released")
            return FeatureResult(changed=True, detail="; ".join(results))

    def enable(self, _output: str) -> FeatureResult:
        return self._set_state("on")

    def disable(self, _output: str) -> FeatureResult:
        return self._set_state("off")


def steam_wrapper_factory(
    config: Config, _runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    if not config.enable_steam:
        return None

    def wrap(argv: list[str]) -> list[str]:
        path = Path(config.steam_script)
        if not path.is_file() or not os.access(path, os.X_OK):
            log.debug("Steam wrapper not available: %s", path)
            return argv
        return [str(path), *argv]

    return wrap


def inhibit_wrapper_factory(
    config: Config, runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    if not config.enable_inhibit:
        return None
    inhibit = runner.resolve("systemd-inhibit")
    if inhibit is None:
        return None

    def wrapper(argv: list[str]) -> list[str]:
        return [
            inhibit,
            "--what=idle:sleep",
            "--mode=block",
            "--why=gamemode.py",
            "--",
            *argv,
        ]

    return wrapper


def systemd_run_wrapper_factory(
    config: Config, runner: Runner, log: logging.Logger
) -> CommandWrapper | None:
    if not config.enable_systemd_run:
        return None
    return SystemdRun(config, runner, log).wrap_argv


WRAPPER_FACTORIES: dict[str, WrapperFactory] = {
    "steam": steam_wrapper_factory,
    "inhibit": inhibit_wrapper_factory,
    "systemd_run": systemd_run_wrapper_factory,
}


class WrapperChain:
    def __init__(self) -> None:
        self._wrappers: list[CommandWrapper] = []

    def add(self, wrapper: CommandWrapper | None) -> None:
        if wrapper is not None:
            self._wrappers.append(wrapper)

    def add_factory(
        self,
        factory: WrapperFactory,
        config: Config,
        runner: Runner,
        log: logging.Logger,
    ) -> None:
        wrapper = factory(config, runner, log)
        if wrapper is not None:
            self._wrappers.append(wrapper)

    def apply(self, argv: list[str]) -> list[str]:
        result = list(argv)
        for wrapper in self._wrappers:
            result = wrapper(result)
        return result


# ============================================================================
# Module: Orchestration
# ============================================================================
def collect_features(
    config: Config, runner: Runner, log: logging.Logger
) -> list[tuple[str, Feature]]:
    result: list[tuple[str, Feature]] = []
    for name, feat in [
        ("tuned", PowerProfile(config, runner, log)),
        ("vrr", VRR(config, runner, log)),
        ("scx", SCXScheduler(config, runner, log)),
        ("audio", AudioPriority(config, runner, log)),
        ("inhibit", ScreenInhibit(config, runner, log)),
    ]:
        if name in config.toggle_features:
            result.append((name, cast(Feature, feat)))
    return result


def _apply_features(
    features: list[tuple[str, Feature]], output: str, log: logging.Logger, method: str
) -> None:
    log.debug("%sing features for output: %s", method.capitalize(), output)
    for name, feat in features:
        result = getattr(feat, method)(output)
        _BaseFeature._log_result(name, result, log)


def features_enable(
    features: list[tuple[str, Feature]], output: str, log: logging.Logger
) -> None:
    _apply_features(features, output, log, "enable")


def features_disable(
    features: list[tuple[str, Feature]], output: str, log: logging.Logger
) -> None:
    _apply_features(features, output, log, "disable")


# ============================================================================
# Module: Actions
# ============================================================================
def _prepare_action(
    config: Config, runner: Runner, log: logging.Logger, *, debug: bool = False
) -> tuple[str, list[tuple[str, Feature]], StateManager]:
    output = output_resolve(config)
    state = StateManager(config)
    state.init()
    setup_logging(config, to_file=debug)
    features = collect_features(config, runner, log)
    return output, features, state


def action_on(
    config: Config, runner: Runner, log: logging.Logger, *, debug: bool = False
) -> int:
    output, features, state = _prepare_action(config, runner, log, debug=debug)
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
) -> int:
    output, features, state = _prepare_action(config, runner, log, debug=debug)

    # Redesign: Always assume --force. Unconditionally disable features and clear state.
    # This bypasses the previous early returns that skipped cleanup when wrapper/toggle
    # states conflicted or when the state file was missing/corrupted.
    features_disable(features, output, log)
    state.clear()
    log.info("Cleanup complete")
    return 0


def action_status(config: Config) -> int:
    state = StateManager(config)
    state.init()
    mode = state.mode
    pid = state.pid()
    cmd = state.cmd()
    niri = compositor_is_niri()
    kde = session_is_kde()
    session = os.environ.get("XDG_SESSION_DESKTOP", "(unset)")
    current_desktop = os.environ.get("XDG_CURRENT_DESKTOP", "(unset)")
    output = output_resolve(config)
    stale: bool | None = None
    alive: bool | None = None
    if mode == "wrapper" and pid is not None:
        alive = state.pid_alive()
        stale = not alive
    lines = [
        f"State:            {mode or '(none)'}",
        f"Mode:             {mode or '(none)'}",
        f"PID:              {pid if pid is not None else 'N/A (toggle mode)'}",
        f"Alive:            {alive if alive is not None else 'N/A'}",
        f"Stale:            {stale if stale is not None else 'N/A'}",
        "",
        f"Command:          {' '.join(cmd) if cmd else '(toggle mode)'}",
        "",
        f"Compositor:       {'niri' if niri else 'kde' if kde else 'unknown'}",
        f"  XDG_SESSION_DESKTOP:    {session}",
        f"  XDG_CURRENT_DESKTOP:    {current_desktop}",
        f"Target output:    {output}",
        "",
        f"State dir:        {config.state_dir}",
    ]
    print("\n".join(lines))
    return 0


def _build_cleanup_closure(
    features: list[tuple[str, Feature]],
    output: str,
    log: logging.Logger,
    state: StateManager,
    *,
    preserve_state: bool = False,
):
    _done = [False]

    def _cleanup() -> None:
        if _done[0]:
            return
        _done[0] = True
        try:
            features_disable(features, output, log)
            if not preserve_state:
                state.clear()
        except Exception:
            log.exception("Error during cleanup")

    return _cleanup


@contextmanager
def _signal_guard(
    log: logging.Logger, child_proc: list[subprocess.Popen | None]
) -> Iterator[int]:
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
        pending_signal[0] = 0
        _orig_term = None
        _orig_int = None
        _orig_hup = None
    try:
        yield pending_signal[0]
    finally:
        try:
            signal.signal(signal.SIGTERM, _orig_term)
            signal.signal(signal.SIGINT, _orig_int)
        except (ValueError, OSError):
            pass
        if _orig_hup is not None:
            try:
                signal.signal(signal.SIGHUP, _orig_hup)
            except (ValueError, OSError):
                pass


def _watch_parent(log: logging.Logger) -> None:
    PR_SET_PDEATHSIG = 1
    libc_path = ctypes.util.find_library("c")
    if libc_path is None:
        return
    try:
        libc = ctypes.CDLL(libc_path)
        ret = libc.prctl(PR_SET_PDEATHSIG, signal.SIGTERM)
        if ret != 0:
            log.warning("prctl(PR_SET_PDEATHSIG) failed: %s", os.strerror(-ret))
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
    output = output_resolve(config)
    state = StateManager(config)
    state.init()
    log.info("Wrapper mode (output: %s, command: %s)", output, " ".join(command))
    _watch_parent(log)

    with state.locked() as acquired:
        if not acquired:
            log.debug("Another wrapper instance holds the lock, skipping")
            return 0
        setup_logging(config, to_file=debug)

        # State-aware routing: if toggle mode is already active, skip features
        already_active = state.is_active or state.is_wrapper
        if already_active:
            log.info(
                "Gamemode already active. Wrapper will only apply configured wrappers (feature toggles skipped)."
            )
            features = []
        else:
            state.mark_wrapper(command)
            features = collect_features(config, runner, log)
            features_enable(features, output, log)

        cleanup = _build_cleanup_closure(
            features, output, log, state, preserve_state=already_active
        )

        chain = WrapperChain()
        for name, factory in WRAPPER_FACTORIES.items():
            if name in config.wrapper_features:
                chain.add_factory(factory, config, runner, log)

        exec_cmd = chain.apply(command)
        child_proc: list[subprocess.Popen | None] = [None]
        with _signal_guard(log, child_proc) as pending_signal:
            try:
                child_proc[0] = subprocess.Popen(exec_cmd, start_new_session=True)
                retcode = child_proc[0].wait()
            except OSError as exc:
                log.error("Failed to execute command: %s", exc)
                return 1
            finally:
                cleanup()
        if pending_signal:
            sys.exit(128 + pending_signal)
        return retcode


# ============================================================================
# Module: Usage
# ============================================================================
USAGE = textwrap.dedent("""\
Usage: gamemode.py [MODE] [COMMAND...]
Performance toggle for gaming sessions.

MODES:
  on              Activate gaming mode (applies TOGGLE_FEATURES)
  off             Deactivate gaming mode, restore desktop defaults (always force cleanup)
  status          Show current state and diagnostics
  <command>       Wrapper mode: enable features, then run <command> (auto-cleanup)
                  Applies WRAPPER_FEATURES only. Skips features if 'on' was already run.

CONFIGURATION:
  File: $HOME/.config/gamemode.conf (KEY=VALUE format, # comments supported)
  Env vars override file values.

FEATURE ROUTING (comma-separated, case-insensitive):
  TOGGLE_FEATURES   Applied by 'on'/'off'. Default: vrr,scx,tuned,audio,inhibit,steam
  WRAPPER_FEATURES  Applied by '-- <cmd>'. Default: systemd_run,steam,inhibit

ENVIRONMENT:
  NIRI_OUTPUT_NAME   Override target output (falls back to VRR_OUTPUT)
  DEBUG=1            Enable debug logging
  XDG_RUNTIME_DIR    State dir and log file location (default: /tmp)

EXAMPLES:
  python3 gamemode.py on                          # Toggle on
  python3 gamemode.py off                         # Toggle off
  python3 gamemode.py -- steam                    # Wrapper: launch steam
  python3 gamemode.py -- ~/Games/hero/main.sh     # Wrapper: run a game directly
  ENABLE_SYSTEMD_RUN=false python3 gamemode.py -- steam  # Disable systemd-run wrapper
  TOGGLE_FEATURES=vrr,scx python3 gamemode.py on  # Only enable VRR & SCX
""")


# ============================================================================
# Module: CLI Parser
# ============================================================================
def cli_parse(argv: list[str] | None = None) -> tuple[str | None, list[str]]:
    if argv is None:
        argv = sys.argv[1:]
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE, end="")
        return None, []
    mode = argv[0]
    if mode in ("on", "off", "status"):
        return mode, []
    if mode == "--":
        command = argv[1:]
        if not command:
            print("Error: wrapper mode requires a command after '--'", file=sys.stderr)
            print(USAGE, end="", file=sys.stderr)
            return None, []
        return "wrapper", command
    return "wrapper", argv


# ============================================================================
# Entry Point
# ============================================================================
def main(argv: list[str] | None = None) -> int:
    # Load config file before anything else
    load_config_file()

    config = Config()
    debug = os.environ.get("DEBUG", "") in ("1", "true", "yes")
    log = setup_logging(config, to_file=False, debug=debug)
    mode, command = cli_parse(argv)
    if mode is None:
        return 1

    runner = Runner(log)
    # Validate deps only for what's actually enabled
    if not validate_deps(config, runner, log):
        return 1

    if mode == "on":
        return action_on(config, runner, log, debug=debug)
    if mode == "off":
        # Removed force argument passing
        return action_off(config, runner, log, debug=debug)
    if mode == "status":
        return action_status(config)
    if mode == "wrapper":
        return action_wrapper(config, runner, log, command, debug=debug)

    log.error("Unknown subcommand: '%s'", mode)
    return 1


if __name__ == "__main__":
    sys.exit(main())
