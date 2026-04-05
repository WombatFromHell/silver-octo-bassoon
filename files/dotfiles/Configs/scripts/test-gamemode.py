#!/usr/bin/env -S pytest --tb=short -v
"""Test suite for gamemode.py.

Run via: pytest --tb=short test-gamemode.py -v
"""

import fcntl
import json
import logging
import os
import signal
import subprocess
import time
from pathlib import Path
from unittest.mock import patch
from typing import Any

import pytest  # ty: ignore[unresolved-import]

# Import everything from the module under test (no mocking of the SUT).
import gamemode


# ============================================================================
# Fixtures & helpers
# ============================================================================


def _cfg(**overrides: Any) -> gamemode.Config:
    """Build a frozen Config with every toggle off and paths in *tmp_path*.

    Keyword overrides are mapped directly onto dataclass fields.
    """
    defaults: dict[str, Any] = dict(
        enable_scx=False,
        enable_vrr=False,
        enable_tuned=False,
        enable_inhibit=False,
        enable_audio=False,
        enable_steam=False,
        scx_name="scx_lavd",
        scx_args="",
        profile_game="throughput-performance-bazzite",
        profile_desktop="balanced-bazzite",
        audio_latency="60",
        steam_script="",
        vrr_output_default="DP-1",
        runtime_dir="/tmp",
    )
    defaults.update(overrides)
    return gamemode.Config(**defaults)


@pytest.fixture()
def tmp_runtime(tmp_path):
    """Provide a Config whose state paths live inside *tmp_path*."""
    return _cfg(runtime_dir=str(tmp_path))


@pytest.fixture()
def logger():
    """A deterministic logger."""
    log = logging.getLogger("gamemode.test-fixture")
    log.handlers.clear()
    log.setLevel(logging.DEBUG)
    log.addHandler(logging.NullHandler())
    return log


@pytest.fixture()
def runner(logger):
    """A real Runner backed by the fixture logger."""
    return gamemode.Runner(logger)


# ============================================================================
# Helper: Fake Runner
# ============================================================================


class FakeRunner(gamemode.Runner):
    """Runner subclass that returns canned responses.

    Used only in tests — the SUT itself is never mocked.
    """

    def __init__(self, log, *, resolve_map=None, run_map=None, pipe_map=None):
        super().__init__(log)
        # resolve_map: {cmd: path_or_None}
        self._resolve_map = resolve_map or {}
        # run_map: {tuple(args): CompletedProcess}
        self._run_map = run_map or {}
        # pipe_map: {tuple(args): CompletedProcess}  (stdin data ignored for matching)
        self._pipe_map = pipe_map or {}
        self.calls = []  # list of ("run"|"pipe"|"capture", args)

    def resolve(self, cmd):
        return self._resolve_map.get(cmd)

    def run(self, args, **kwargs):
        self.calls.append(("run", list(args)))
        key = tuple(args)
        if key in self._run_map:
            return self._run_map[key]
        return subprocess.CompletedProcess(args, returncode=0, stdout="", stderr="")

    def capture(self, args):
        self.calls.append(("capture", list(args)))
        return self.run(args)

    def pipe(self, args, input_data):
        self.calls.append(("pipe", list(args)))
        key = tuple(args)
        if key in self._pipe_map:
            return self._pipe_map[key]
        return self.run(args)


def _cp(stdout="", stderr="", rc=0):
    """Shorthand for a successful CompletedProcess."""
    return subprocess.CompletedProcess([], returncode=rc, stdout=stdout, stderr=stderr)


# ============================================================================
# Config
# ============================================================================


class TestConfig:
    def test_defaults_from_env(self, monkeypatch):
        monkeypatch.setenv("ENABLE_VRR", "false")
        monkeypatch.setenv("SCX_SCHEDULER_NAME", "scx_custom")
        monkeypatch.setenv("XDG_RUNTIME_DIR", "/run/user/999")
        cfg = gamemode.Config()
        assert cfg.enable_vrr is False
        assert cfg.scx_name == "scx_custom"
        assert cfg.runtime_dir == "/run/user/999"

    def test_state_dir_derived(self, tmp_path):
        cfg = _cfg(runtime_dir=str(tmp_path))
        assert cfg.state_dir == tmp_path / "gamemode"
        assert cfg.lock_file == tmp_path / "gamemode" / "lock"

    @pytest.mark.parametrize(
        "val,expected",
        [
            ("true", True),
            ("True", True),
            ("1", True),
            ("yes", True),
            ("false", False),
            ("0", False),
            ("no", False),
            ("", False),
        ],
    )
    def test_env_bool_parsing(self, monkeypatch, val, expected):
        monkeypatch.setenv("TEST_BOOL", val)
        assert gamemode._env_bool("TEST_BOOL", False) == expected

    def test_env_bool_missing_default(self):
        assert gamemode._env_bool("NONEXISTENT_XYZ", True) is True
        assert gamemode._env_bool("NONEXISTENT_XYZ", False) is False


# ============================================================================
# Logging
# ============================================================================


class TestLogging:
    def test_setup_creates_handlers(self, tmp_runtime, logger):
        log = gamemode.setup_logging(tmp_runtime, to_file=False, debug=False)
        assert len(log.handlers) >= 1

    def test_idempotent(self, tmp_runtime):
        log = gamemode.setup_logging(tmp_runtime)
        count = len(log.handlers)
        log = gamemode.setup_logging(tmp_runtime)
        assert len(log.handlers) == count

    def test_file_handler(self, tmp_runtime):
        log = gamemode.setup_logging(tmp_runtime, to_file=True)
        file_handlers = [h for h in log.handlers if isinstance(h, logging.FileHandler)]
        assert len(file_handlers) == 1
        assert Path(file_handlers[0].baseFilename) == tmp_runtime.log_file


# ============================================================================
# Runner
# ============================================================================


class TestRunner:
    def test_resolve_existing(self, runner):
        assert runner.resolve("sh") is not None

    def test_resolve_missing(self, runner):
        assert runner.resolve("this_command_should_not_exist_xyz") is None

    def test_require_existing(self, runner, caplog):
        caplog.set_level(logging.ERROR)
        assert runner.require("sh") is True
        assert not caplog.records

    def test_require_missing(self, runner, caplog):
        caplog.set_level(logging.ERROR)
        result = runner.require("no_such_cmd_xyz", feature="test")
        assert result is False
        assert any("no_such_cmd_xyz" in r.message for r in caplog.records)

    def test_run_success(self, runner):
        result = runner.run(["echo", "-n", "hello"], capture_output=True, text=True)
        assert result.returncode == 0
        assert result.stdout.strip() == "hello"

    def test_capture(self, runner):
        result = runner.capture(["echo", "-n", "captured"])
        assert result.stdout.strip() == "captured"

    def test_pipe(self, runner):
        result = runner.pipe(["cat"], input_data="piped")
        assert result.returncode == 0
        assert result.stdout.strip() == "piped"


# ============================================================================
# Dependency Validation
# ============================================================================


class TestValidateDeps:
    @pytest.mark.parametrize(
        "enable_scx,enable_vrr,enable_tuned,enable_inhibit",
        [
            (False, False, False, False),
            (True, True, True, True),
        ],
    )
    def test_dep_checks(
        self,
        tmp_path,
        logger,
        enable_scx,
        enable_vrr,
        enable_tuned,
        enable_inhibit,
    ):
        cfg = _cfg(
            runtime_dir=str(tmp_path),
            enable_scx=enable_scx,
            enable_vrr=enable_vrr,
            enable_tuned=enable_tuned,
            enable_inhibit=enable_inhibit,
        )
        r = FakeRunner(
            logger,
            resolve_map={
                "scxctl": "/usr/bin/scxctl" if enable_scx else None,
                "jq": "/usr/bin/jq" if enable_vrr else None,
                "tuned-adm": "/usr/bin/tuned-adm" if enable_tuned else None,
                "systemd-inhibit": "/usr/bin/systemd-inhibit"
                if enable_inhibit
                else None,
            },
        )
        ok = gamemode.validate_deps(cfg, r, logger)
        if enable_scx or enable_vrr or enable_tuned or enable_inhibit:
            all_present = all(
                [
                    not enable_scx or r.resolve("scxctl") is not None,
                    not enable_vrr or r.resolve("jq") is not None,
                    not enable_tuned or r.resolve("tuned-adm") is not None,
                    not enable_inhibit or r.resolve("systemd-inhibit") is not None,
                ]
            )
            assert ok is all_present
        else:
            assert ok is True


# ============================================================================
# Compositor Detection
# ============================================================================


class TestCompositorDetection:
    def test_niri_via_env(self, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        assert gamemode.compositor_is_niri() is True

    def test_kde_via_env(self, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "KDE")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        assert gamemode.session_is_kde() is True

    def test_not_kde(self, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        assert gamemode.session_is_kde() is False


# ============================================================================
# Output Resolution
# ============================================================================


class TestOutputResolve:
    def test_default(self, tmp_runtime, monkeypatch):
        monkeypatch.delenv("NIRI_OUTPUT_NAME", raising=False)
        assert gamemode.output_resolve(tmp_runtime) == "DP-1"

    def test_env_override(self, tmp_runtime, monkeypatch):
        monkeypatch.setenv("NIRI_OUTPUT_NAME", "HDMI-A-1")
        assert gamemode.output_resolve(tmp_runtime) == "HDMI-A-1"


# ============================================================================
# State Management
# ============================================================================


class TestStateManager:
    def test_init_creates_dir(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        assert tmp_runtime.state_dir.is_dir()

    def test_mark_and_read_wrapper(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        sm.mark_wrapper()
        assert sm.value() == "wrapper"
        assert sm.is_wrapper is True
        assert sm.is_active is False

    def test_mark_and_read_active(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        sm.mark_active()
        assert sm.value() == "active"
        assert sm.is_active is True
        assert sm.is_wrapper is False

    def test_clear(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        sm.mark_active()
        sm.clear()
        assert sm.value() == ""

    def test_lock_serialisation(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        with sm.locked() as acquired:
            assert acquired is True

    def test_is_lock_held_when_free(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        assert sm.is_lock_held() is False

    def test_is_lock_held_when_held(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        fd = os.open(str(tmp_runtime.lock_file), os.O_CREAT | os.O_WRONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            assert sm.is_lock_held() is True
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def test_lock_contention_returns_false(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        fd = os.open(str(tmp_runtime.lock_file), os.O_CREAT | os.O_WRONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with sm.locked() as acquired:
                assert acquired is False
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def test_value_empty_when_missing(self, tmp_runtime):
        sm = gamemode.StateManager(tmp_runtime)
        sm.init()
        assert sm.value() == ""


# ============================================================================
# FeatureResult
# ============================================================================


class TestFeatureResult:
    def test_skip(self):
        r = gamemode.FeatureResult.skip("no niri")
        assert r.ok is True
        assert r.skipped is True
        assert r.changed is False

    def test_did_change(self):
        r = gamemode.FeatureResult.did_change("on")
        assert r.changed is True
        assert r.ok is True

    def test_error(self):
        r = gamemode.FeatureResult.error("failed")
        assert r.ok is False

    def test_noop(self):
        r = gamemode.FeatureResult.noop()
        assert r.ok is True
        assert r.skipped is False
        assert r.changed is False

    @pytest.mark.parametrize(
        "factory,expected_repr_substring",
        [
            (lambda: gamemode.FeatureResult.skip("x"), "skipped"),
            (lambda: gamemode.FeatureResult.did_change("x"), "changed"),
            (lambda: gamemode.FeatureResult.error("x"), "error"),
            (lambda: gamemode.FeatureResult.noop(), "noop"),
        ],
    )
    def test_repr(self, factory, expected_repr_substring):
        assert expected_repr_substring in repr(factory())


# ============================================================================
# Feature: VRR
# ============================================================================


class TestVRR:
    def _make_vrr(self, cfg, logger, resolve_map=None, run_map=None, pipe_map=None):
        r = FakeRunner(
            logger,
            resolve_map=resolve_map or {},
            run_map=run_map or {},
            pipe_map=pipe_map or {},
        )
        return gamemode.VRR(cfg, r, logger), r

    @staticmethod
    def _niri_outputs_json(vrr_supported=True, vrr_enabled=False):
        return '{"DP-1":{"vrr_supported":%s,"vrr_enabled":%s}}' % (
            str(vrr_supported).lower(),
            str(vrr_enabled).lower(),
        )

    @pytest.mark.parametrize("enabled", [True, False])
    def test_skip_when_disabled(self, tmp_path, logger, enabled):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=enabled)
        vrr, _ = self._make_vrr(cfg, logger)
        result = vrr.enable("DP-1")
        if not enabled:
            assert result.skipped is True

    def test_skip_when_not_niri(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "gnome")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: False)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)
        vrr, _ = self._make_vrr(cfg, logger)
        result = vrr.enable("DP-1")
        assert result.skipped is True

    def test_enable_success(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: True)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)

        niri_json = self._niri_outputs_json(vrr_supported=True, vrr_enabled=False)
        resolve_map = {
            "niri": "/usr/bin/niri",
            "jq": "/usr/bin/jq",
        }
        run_map = {
            ("niri", "msg", "-j", "outputs"): _cp(stdout=niri_json),
            ("niri", "msg", "output", "DP-1", "vrr", "on"): _cp(),
        }
        pipe_map = {
            ("jq", "-r", "--arg", "o", "DP-1", ".[$o].vrr_supported // true"): _cp(
                stdout="true"
            ),
            (
                "jq",
                "-r",
                "--arg",
                "o",
                "DP-1",
                'if .[$o].vrr_enabled == true then "true" '
                'elif .[$o].vrr_enabled == false then "false" '
                'else "" end',
            ): _cp(stdout="false"),
        }
        vrr, fake = self._make_vrr(cfg, logger, resolve_map, run_map, pipe_map)

        result = vrr.enable("DP-1")
        assert result.changed is True
        assert result.ok is True

    def test_enable_already_on(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: True)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)

        niri_json = self._niri_outputs_json(vrr_supported=True, vrr_enabled=True)
        resolve_map = {"niri": "/usr/bin/niri", "jq": "/usr/bin/jq"}
        run_map = {
            ("niri", "msg", "-j", "outputs"): _cp(stdout=niri_json),
        }
        pipe_map = {
            ("jq", "-r", "--arg", "o", "DP-1", ".[$o].vrr_supported // true"): _cp(
                stdout="true"
            ),
            (
                "jq",
                "-r",
                "--arg",
                "o",
                "DP-1",
                'if .[$o].vrr_enabled == true then "true" '
                'elif .[$o].vrr_enabled == false then "false" '
                'else "" end',
            ): _cp(stdout="true"),
        }
        vrr, _ = self._make_vrr(cfg, logger, resolve_map, run_map, pipe_map)

        result = vrr.enable("DP-1")
        assert result.changed is False
        assert result.skipped is False

    def test_disable_success(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: True)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)

        niri_json = self._niri_outputs_json(vrr_supported=True, vrr_enabled=True)
        resolve_map = {"niri": "/usr/bin/niri", "jq": "/usr/bin/jq"}
        run_map = {
            ("niri", "msg", "-j", "outputs"): _cp(stdout=niri_json),
            ("niri", "msg", "output", "DP-1", "vrr", "off"): _cp(),
        }
        pipe_map = {
            ("jq", "-r", "--arg", "o", "DP-1", ".[$o].vrr_supported // true"): _cp(
                stdout="true"
            ),
            (
                "jq",
                "-r",
                "--arg",
                "o",
                "DP-1",
                'if .[$o].vrr_enabled == true then "true" '
                'elif .[$o].vrr_enabled == false then "false" '
                'else "" end',
            ): _cp(stdout="true"),
        }
        vrr, _ = self._make_vrr(cfg, logger, resolve_map, run_map, pipe_map)

        result = vrr.disable("DP-1")
        assert result.changed is True

    def test_disable_already_off(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: True)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)

        niri_json = self._niri_outputs_json(vrr_supported=True, vrr_enabled=False)
        resolve_map = {"niri": "/usr/bin/niri", "jq": "/usr/bin/jq"}
        run_map = {
            ("niri", "msg", "-j", "outputs"): _cp(stdout=niri_json),
        }
        pipe_map = {
            ("jq", "-r", "--arg", "o", "DP-1", ".[$o].vrr_supported // true"): _cp(
                stdout="true"
            ),
            (
                "jq",
                "-r",
                "--arg",
                "o",
                "DP-1",
                'if .[$o].vrr_enabled == true then "true" '
                'elif .[$o].vrr_enabled == false then "false" '
                'else "" end',
            ): _cp(stdout="false"),
        }
        vrr, _ = self._make_vrr(cfg, logger, resolve_map, run_map, pipe_map)

        result = vrr.disable("DP-1")
        assert result.changed is False
        assert result.skipped is False

    def test_skip_not_capable(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: True)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_vrr=True)

        niri_json = self._niri_outputs_json(vrr_supported=False, vrr_enabled=False)
        resolve_map = {"niri": "/usr/bin/niri", "jq": "/usr/bin/jq"}
        run_map = {
            ("niri", "msg", "-j", "outputs"): _cp(stdout=niri_json),
        }
        pipe_map = {
            ("jq", "-r", "--arg", "o", "DP-1", ".[$o].vrr_supported // true"): _cp(
                stdout="false"
            ),
        }
        vrr, _ = self._make_vrr(cfg, logger, resolve_map, run_map, pipe_map)

        result = vrr.enable("DP-1")
        assert result.skipped is True


# ============================================================================
# Feature: PowerProfile
# ============================================================================


class TestPowerProfile:
    def _make_pp(self, cfg, logger, resolve_map=None, run_map=None):
        r = FakeRunner(logger, resolve_map=resolve_map or {}, run_map=run_map or {})
        return gamemode.PowerProfile(cfg, r, logger), r

    def test_skip_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path))
        pp, _ = self._make_pp(cfg, logger)
        result = pp.enable("DP-1")
        assert result.skipped is True

    def test_enable_changes_profile(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_tuned=True)

        resolve_map = {"tuned-adm": "/usr/bin/tuned-adm"}
        run_map = {
            ("tuned-adm", "active"): _cp(stdout="Active profile: balanced-bazzite"),
            ("tuned-adm", "profile", "throughput-performance-bazzite"): _cp(),
        }
        pp, fake = self._make_pp(cfg, logger, resolve_map, run_map)

        result = pp.enable("DP-1")
        assert result.changed is True
        assert (
            "run",
            ["tuned-adm", "profile", "throughput-performance-bazzite"],
        ) in fake.calls

    def test_enable_noop_when_already_game(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_tuned=True)
        resolve_map = {"tuned-adm": "/usr/bin/tuned-adm"}
        run_map = {
            ("tuned-adm", "active"): _cp(
                stdout="Active profile: throughput-performance-bazzite"
            ),
        }
        pp, _ = self._make_pp(cfg, logger, resolve_map, run_map)
        result = pp.enable("DP-1")
        assert result.changed is False
        assert result.skipped is False

    def test_disable_changes_desktop(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_tuned=True)
        resolve_map = {"tuned-adm": "/usr/bin/tuned-adm"}
        run_map = {
            ("tuned-adm", "active"): _cp(
                stdout="Active profile: throughput-performance-bazzite"
            ),
            ("tuned-adm", "profile", "balanced-bazzite"): _cp(),
        }
        pp, fake = self._make_pp(cfg, logger, resolve_map, run_map)
        result = pp.disable("DP-1")
        assert result.changed is True
        assert ("run", ["tuned-adm", "profile", "balanced-bazzite"]) in fake.calls


# ============================================================================
# Feature: SCXScheduler
# ============================================================================


class TestSCXScheduler:
    def _make_scx(self, cfg, logger, resolve_map=None, run_map=None):
        r = FakeRunner(logger, resolve_map=resolve_map or {}, run_map=run_map or {})
        return gamemode.SCXScheduler(cfg, r, logger), r

    def test_skip_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path))
        scx, _ = self._make_scx(cfg, logger)
        result = scx.enable("DP-1")
        assert result.skipped is True

    def test_enable_starts_when_none_running(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_scx=True)
        resolve_map = {"scxctl": "/usr/bin/scxctl", "scx_lavd": "/usr/bin/scx_lavd"}
        run_map = {
            ("scxctl", "get"): _cp(stdout="no scx scheduler running"),
            ("scxctl", "start", "-s", "scx_lavd", "--args="): _cp(),
        }
        scx, fake = self._make_scx(cfg, logger, resolve_map, run_map)
        result = scx.enable("DP-1")
        assert result.changed is True
        assert ("run", ["scxctl", "start", "-s", "scx_lavd", "--args="]) in fake.calls

    def test_enable_noop_when_already_loaded(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_scx=True)
        resolve_map = {"scxctl": "/usr/bin/scxctl", "scx_lavd": "/usr/bin/scx_lavd"}
        run_map = {
            ("scxctl", "get"): _cp(stdout="scx_lavd running"),
        }
        scx, _ = self._make_scx(cfg, logger, resolve_map, run_map)
        result = scx.enable("DP-1")
        assert result.changed is False
        assert result.skipped is False

    def test_enable_switches_scheduler(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_scx=True)
        resolve_map = {"scxctl": "/usr/bin/scxctl", "scx_lavd": "/usr/bin/scx_lavd"}
        run_map = {
            ("scxctl", "get"): _cp(stdout="scx_rustland running"),
            ("scxctl", "switch", "-s", "scx_lavd", "--args="): _cp(),
        }
        scx, fake = self._make_scx(cfg, logger, resolve_map, run_map)
        result = scx.enable("DP-1")
        assert result.changed is True
        assert ("run", ["scxctl", "switch", "-s", "scx_lavd", "--args="]) in fake.calls

    def test_disable_unloads(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_scx=True)
        resolve_map = {"scxctl": "/usr/bin/scxctl"}
        run_map = {
            ("scxctl", "get"): _cp(stdout="scx_lavd running"),
            ("scxctl", "stop"): _cp(),
        }
        scx, fake = self._make_scx(cfg, logger, resolve_map, run_map)
        result = scx.disable("DP-1")
        assert result.changed is True
        assert ("run", ["scxctl", "stop"]) in fake.calls

    def test_disable_noop_when_none_running(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_scx=True)
        resolve_map = {"scxctl": "/usr/bin/scxctl"}
        run_map = {
            ("scxctl", "get"): _cp(stdout="no scx scheduler running"),
        }
        scx, _ = self._make_scx(cfg, logger, resolve_map, run_map)
        result = scx.disable("DP-1")
        assert result.changed is False
        assert result.skipped is False


# ============================================================================
# Feature: AudioPriority
# ============================================================================


class TestAudioPriority:
    def _make_audio(self, cfg, logger):
        return gamemode.AudioPriority(cfg, gamemode.Runner(logger), logger)

    def test_skip_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path))
        audio = self._make_audio(cfg, logger)
        result = audio.enable("DP-1")
        assert result.skipped is True

    def test_enable_sets_env(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_audio=True, audio_latency="120")
        audio = self._make_audio(cfg, logger)
        result = audio.enable("DP-1")
        assert result.changed is True
        assert os.environ.get("PULSE_LATENCY_MSEC") == "120"
        os.environ.pop("PULSE_LATENCY_MSEC", None)

    def test_enable_writes_env_file(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_audio=True, audio_latency="80")
        audio = self._make_audio(cfg, logger)
        audio.enable("DP-1")
        content = cfg.audio_env_file.read_text()
        assert "PULSE_LATENCY_MSEC=80" in content
        os.environ.pop("PULSE_LATENCY_MSEC", None)

    def test_disable_clears_env(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_audio=True)
        os.environ["PULSE_LATENCY_MSEC"] = "50"
        audio = self._make_audio(cfg, logger)
        result = audio.disable("DP-1")
        assert result.changed is True
        assert "PULSE_LATENCY_MSEC" not in os.environ

    def test_disable_removes_env_file(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_audio=True)
        cfg.audio_env_file.parent.mkdir(parents=True, exist_ok=True)
        cfg.audio_env_file.write_text("export PULSE_LATENCY_MSEC=50\n")
        audio = self._make_audio(cfg, logger)
        audio.disable("DP-1")
        assert cfg.audio_env_file.exists() is False

    def test_disable_missing_file_is_noop(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_audio=True)
        audio = self._make_audio(cfg, logger)
        result = audio.disable("DP-1")
        assert result.changed is True


# ============================================================================
# Feature: ScreenInhibit
# ============================================================================


class TestScreenInhibit:
    def _make_inhibit(self, cfg, logger, resolve_map=None, run_map=None):
        r = FakeRunner(logger, resolve_map=resolve_map or {}, run_map=run_map or {})
        return gamemode.ScreenInhibit(cfg, r, logger), r

    def test_skip_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path))
        inh, _ = self._make_inhibit(cfg, logger)
        result = inh.enable("DP-1")
        assert result.skipped is True

    def test_skip_when_not_niri(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "gnome")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        # pgrep may find niri on the user's real system — isolate from that.
        monkeypatch.setattr(gamemode, "compositor_is_niri", lambda: False)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=True)
        inh, _ = self._make_inhibit(cfg, logger)
        result = inh.enable("DP-1")
        assert result.skipped is True

    def test_enable_dms(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=True)

        resolve_map = {"dms": "/usr/bin/dms"}
        run_map = {
            ("dms", "ipc", "call", "inhibit", "status"): _cp(
                stdout="Idle inhibit is disabled"
            ),
            ("dms", "ipc", "call", "inhibit", "enable"): _cp(),
            (
                "dms",
                "ipc",
                "call",
                "inhibit",
                "reason",
                "gamemode.py gaming session",
            ): _cp(),
        }
        inh, _ = self._make_inhibit(cfg, logger, resolve_map, run_map)
        result = inh.enable("DP-1")
        assert result.changed is True

    def test_disable_dms(self, tmp_path, logger, monkeypatch):
        monkeypatch.setenv("XDG_SESSION_DESKTOP", "niri")
        monkeypatch.delenv("XDG_CURRENT_DESKTOP", raising=False)
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=True)

        resolve_map = {"dms": "/usr/bin/dms"}
        run_map = {
            ("dms", "ipc", "call", "inhibit", "status"): _cp(
                stdout="Idle inhibit reason: gamemode.py"
            ),
            ("dms", "ipc", "call", "inhibit", "disable"): _cp(),
        }
        inh, _ = self._make_inhibit(cfg, logger, resolve_map, run_map)
        result = inh.disable("DP-1")
        assert result.changed is True
        assert "disabled" in result.detail

    def test_inhibit_argv_wraps_with_systemd_inhibit(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=True)
        resolve_map = {
            "systemd-inhibit": "/usr/bin/systemd-inhibit",
        }
        inh, _ = self._make_inhibit(cfg, logger, resolve_map)
        result = inh.inhibit_argv(["mygame", "--arg"])
        assert result[0] == "/usr/bin/systemd-inhibit"
        assert "--what=idle:sleep" in result
        assert "--" in result
        assert "mygame" in result

    def test_inhibit_argv_returns_raw_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=False)
        inh, _ = self._make_inhibit(cfg, logger)
        result = inh.inhibit_argv(["mygame"])
        assert result == ["mygame"]

    def test_inhibit_argv_returns_raw_when_no_systemd_inhibit(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path), enable_inhibit=True)
        resolve_map = {}
        inh, _ = self._make_inhibit(cfg, logger, resolve_map)
        result = inh.inhibit_argv(["mygame"])
        assert result == ["mygame"]


# ============================================================================
# Steam Wrapper Path
# ============================================================================


class TestSteamWrapperPath:
    def test_returns_none_when_disabled(self, tmp_path, logger):
        cfg = _cfg(runtime_dir=str(tmp_path))
        result = gamemode.steam_wrapper_path(cfg, gamemode.Runner(logger), logger)
        assert result is None

    def test_returns_path_when_executable(self, tmp_path, logger):
        cfg = _cfg(
            runtime_dir=str(tmp_path),
            enable_steam=True,
            steam_script=str(tmp_path / "steam-env-base.sh"),
        )
        script = tmp_path / "steam-env-base.sh"
        script.write_text("#!/bin/sh\n")
        script.chmod(0o755)
        result = gamemode.steam_wrapper_path(cfg, gamemode.Runner(logger), logger)
        assert result == script


# ============================================================================
# Feature Orchestration
# ============================================================================


class TestFeatureOrchestration:
    def test_collect_features_returns_all(self, tmp_runtime, logger):
        features = gamemode.collect_features(
            tmp_runtime, gamemode.Runner(logger), logger
        )
        names = [name for name, _ in features]
        assert names == ["tuned", "vrr", "scx", "audio", "inhibit"]

    def test_features_enable_calls_each_feature(self, tmp_runtime, logger):
        features = gamemode.collect_features(
            tmp_runtime, gamemode.Runner(logger), logger
        )
        gamemode.features_enable(features, "DP-1", logger)

    def test_features_disable_calls_each_feature(self, tmp_runtime, logger):
        features = gamemode.collect_features(
            tmp_runtime, gamemode.Runner(logger), logger
        )
        gamemode.features_disable(features, "DP-1", logger)


# ============================================================================
# CLI Parser
# ============================================================================


class TestCliParser:
    @pytest.mark.parametrize(
        "argv,expected_mode,expected_cmd",
        [
            (["on"], "on", []),
            (["off"], "off", []),
            (["--", "steam"], "wrapper", ["steam"]),
            (["--", "~/Games/foo/run.sh"], "wrapper", ["~/Games/foo/run.sh"]),
            (["mygame"], "wrapper", ["mygame"]),
            (["mygame", "--flag"], "wrapper", ["mygame", "--flag"]),
            ([], None, []),
            (["--help"], None, []),
            (["-h"], None, []),
        ],
    )
    def test_cli_parse(self, argv, expected_mode, expected_cmd, capsys):
        mode, cmd = gamemode.cli_parse(argv)
        assert mode == expected_mode
        assert cmd == expected_cmd

    def test_wrapper_empty_returns_none(self, capsys):
        mode, cmd = gamemode.cli_parse(["--"])
        assert mode is None
        assert cmd == []


# ============================================================================
# Action: Wrapper Mode — action_wrapper
# ============================================================================


class FakeFeature(gamemode.Feature):
    """Trivial feature that records enable/disable calls."""

    def __init__(self, name: str):
        self.name = name
        self.enable_calls: list[str] = []
        self.disable_calls: list[str] = []
        self.enable_result: gamemode.FeatureResult = gamemode.FeatureResult.did_change(
            f"{name} enabled",
        )
        self.disable_result: gamemode.FeatureResult = gamemode.FeatureResult.did_change(
            f"{name} disabled"
        )

    def enable(self, output: str) -> gamemode.FeatureResult:
        self.enable_calls.append(output)
        return self.enable_result

    def disable(self, output: str) -> gamemode.FeatureResult:
        self.disable_calls.append(output)
        return self.disable_result


class TestActionWrapper:
    """Tests for the wrapper-mode action (action_wrapper).

    Every host-executable call goes through an injected Runner;
    features are injected directly (no global state).
    """

    def _make_cfg(self, tmp_path):
        return _cfg(
            runtime_dir=str(tmp_path),
            enable_scx=False,
            enable_vrr=False,
            enable_tuned=False,
            enable_inhibit=False,
            enable_audio=False,
            enable_steam=False,
        )

    def _make_runner(self, runner):
        """Return a fake runner that succeeds on all subprocess calls."""
        return runner  # real runner; subprocess calls will use /bin/true

    def test_cleanup_fires_on_normal_child_exit(self, tmp_path, logger):
        """When the child exits normally, cleanup must run (features off, state cleared)."""
        cfg = self._make_cfg(tmp_path)
        state = gamemode.StateManager(cfg)
        state.init()

        feature_a = FakeFeature("a")
        feature_b = FakeFeature("b")
        features = [("fake_a", feature_a), ("fake_b", feature_b)]

        # Patch collect_features to return our fakes; patch Runner to use /bin/true.
        true_runner = gamemode.Runner(logger)

        with patch.object(gamemode, "collect_features", return_value=features):
            with patch.object(gamemode.Runner, "resolve", return_value="/bin/true"):
                retcode = gamemode.action_wrapper(
                    cfg, true_runner, logger, ["/bin/true"]
                )

        assert retcode == 0
        # Both features should have been disabled
        assert feature_a.disable_calls == [cfg.vrr_output_default]
        assert feature_b.disable_calls == [cfg.vrr_output_default]
        # State should be cleared
        assert state.value() == ""

    def test_cleanup_fires_on_sigterm(self, tmp_path, logger):
        """When the wrapper receives SIGTERM, cleanup must run before exit.

        The wrapper is launched as a child subprocess so that signal
        handlers are installed on its main thread.  The parent sends
        SIGTERM and verifies that cleanup ran before the child died.
        """
        cfg = self._make_cfg(tmp_path)
        state_file = tmp_path / "feature_state.json"

        # Locate gamemode.py for the child process.
        gamemode_dir = os.path.dirname(os.path.abspath(__file__))

        # Subprocess script: runs action_wrapper on the main thread.
        child_script = tmp_path / "wrapper_sigterm.py"
        child_script.write_text(f"""
import sys, os, time, json, signal
from unittest.mock import patch
sys.path.insert(0, {gamemode_dir!r})
import gamemode
import logging

logger = logging.getLogger("gamemode")
logger.setLevel(logging.DEBUG)
logger.addHandler(logging.NullHandler())

cfg = gamemode.Config(
    enable_scx=False, enable_vrr=False, enable_tuned=False,
    enable_inhibit=False, enable_audio=False, enable_steam=False,
    runtime_dir={str(tmp_path)!r},
    vrr_output_default="DP-1",
)
state = gamemode.StateManager(cfg)
state.init()

state_file = {str(state_file)!r}

class RecordFeature(gamemode.Feature):
    def __init__(self):
        self.en = []
        self.dis = []
    def enable(self, output):
        self.en.append(output)
        return gamemode.FeatureResult.did_change("en")
    def disable(self, output):
        self.dis.append(output)
        with open(state_file, "w") as f:
            json.dump({{"en": self.en, "dis": self.dis}}, f)
        return gamemode.FeatureResult.did_change("dis")

feat = RecordFeature()
features = [("fake", feat)]
runner = gamemode.Runner(logger)

with patch.object(gamemode, "collect_features", return_value=features):
    gamemode.action_wrapper(cfg, runner, logger, ["/bin/sleep", "60"])
""")

        # Launch the wrapper as a subprocess.
        child = subprocess.Popen(
            ["python3", str(child_script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        # Wait for the wrapper to reach "wrapper" state.
        for _ in range(50):
            try:
                s = gamemode.StateManager(cfg).value()
                if s == "wrapper":
                    break
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        else:
            child.kill()
            child.wait()
            pytest.fail("Wrapper did not reach running state")

        # Send SIGTERM to the subprocess.
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=10)

        # Read results
        assert state_file.exists(), (
            f"Child did not write feature state (rc={child.returncode})"
        )
        result = json.loads(state_file.read_text())
        assert result["dis"] == ["DP-1"], f"Cleanup did not run: {result}"
        # Check the actual state file (managed by StateManager) is cleared
        assert gamemode.StateManager(cfg).value() == "", "State not cleared"

    def test_cleanup_fires_on_sigint(self, tmp_path, logger):
        """When the wrapper receives SIGINT, cleanup must run before exit.

        Same approach as SIGTERM — launch as subprocess, send signal.
        """
        cfg = self._make_cfg(tmp_path)
        state_file = tmp_path / "feature_state_sigint.json"
        gamemode_dir = os.path.dirname(os.path.abspath(__file__))

        child_script = tmp_path / "wrapper_sigint.py"
        child_script.write_text(f"""
import sys, os, time, json, signal
from unittest.mock import patch
sys.path.insert(0, {gamemode_dir!r})
import gamemode
import logging

logger = logging.getLogger("gamemode")
logger.setLevel(logging.DEBUG)
logger.addHandler(logging.NullHandler())

cfg = gamemode.Config(
    enable_scx=False, enable_vrr=False, enable_tuned=False,
    enable_inhibit=False, enable_audio=False, enable_steam=False,
    runtime_dir={str(tmp_path)!r},
    vrr_output_default="DP-1",
)
state = gamemode.StateManager(cfg)
state.init()
state_file = {str(state_file)!r}

class RecordFeature(gamemode.Feature):
    def __init__(self):
        self.en = []
        self.dis = []
    def enable(self, output):
        self.en.append(output)
        return gamemode.FeatureResult.did_change("en")
    def disable(self, output):
        self.dis.append(output)
        with open(state_file, "w") as f:
            json.dump({{"en": self.en, "dis": self.dis}}, f)
        return gamemode.FeatureResult.did_change("dis")

feat = RecordFeature()
features = [("fake", feat)]
runner = gamemode.Runner(logger)

with patch.object(gamemode, "collect_features", return_value=features):
    gamemode.action_wrapper(cfg, runner, logger, ["/bin/sleep", "60"])
""")

        child = subprocess.Popen(
            ["python3", str(child_script)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )

        for _ in range(50):
            try:
                s = gamemode.StateManager(cfg).value()
                if s == "wrapper":
                    break
            except FileNotFoundError:
                pass
            time.sleep(0.1)
        else:
            child.kill()
            child.wait()
            pytest.fail("Wrapper did not reach running state")

        child.send_signal(signal.SIGINT)
        child.wait(timeout=10)

        assert state_file.exists(), (
            f"Child did not write feature state (rc={child.returncode})"
        )
        result = json.loads(state_file.read_text())
        assert result["dis"] == ["DP-1"], f"Cleanup did not run: {result}"
        # Check the actual state file (managed by StateManager) is cleared
        assert gamemode.StateManager(cfg).value() == "", "State not cleared"

    def test_concurrent_wrapper_skips(self, tmp_path, logger):
        """A second wrapper instance should skip when the first holds the lock."""
        cfg = self._make_cfg(tmp_path)
        state = gamemode.StateManager(cfg)
        state.init()

        feature_a = FakeFeature("a")
        features = [("fake_a", feature_a)]

        runner = gamemode.Runner(logger)

        # Acquire the lock manually and hold it.
        fd = os.open(str(cfg.lock_file), os.O_CREAT | os.O_WRONLY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

            with patch.object(gamemode, "collect_features", return_value=features):
                retcode = gamemode.action_wrapper(cfg, runner, logger, ["/bin/true"])

            # Should skip without running the command or touching features.
            assert retcode == 0
            assert feature_a.enable_calls == []
            assert feature_a.disable_calls == []
        finally:
            fcntl.flock(fd, fcntl.LOCK_UN)
            os.close(fd)

    def test_child_nonzero_exitcode_propagated(self, tmp_path, logger):
        """The wrapper must return the child's exit code after cleanup."""
        cfg = self._make_cfg(tmp_path)
        state = gamemode.StateManager(cfg)
        state.init()

        features = [("fake", FakeFeature("x"))]
        runner = gamemode.Runner(logger)

        with patch.object(gamemode, "collect_features", return_value=features):
            with patch.object(gamemode.Runner, "resolve", return_value="/bin/false"):
                retcode = gamemode.action_wrapper(cfg, runner, logger, ["/bin/false"])

        assert retcode == 1
        # Cleanup still ran despite non-zero exit
        assert features[0][1].disable_calls == [cfg.vrr_output_default]
        assert state.value() == ""

    def test_cleanup_runs_even_on_oserror(self, tmp_path, logger):
        """If exec fails (OSError), cleanup must still run."""
        cfg = self._make_cfg(tmp_path)
        state = gamemode.StateManager(cfg)
        state.init()

        feature_a = FakeFeature("a")
        features = [("fake_a", feature_a)]

        runner = gamemode.Runner(logger)

        # Point to a non-existent command.
        with patch.object(gamemode, "collect_features", return_value=features):
            with patch.object(
                gamemode.Runner, "resolve", return_value="/nonexistent/bin/cmd"
            ):
                retcode = gamemode.action_wrapper(
                    cfg, runner, logger, ["/nonexistent/bin/cmd"]
                )

        # Should return 1 (OError path) but cleanup ran.
        assert retcode == 1
        assert feature_a.disable_calls == [cfg.vrr_output_default]
        assert state.value() == ""
