#!/usr/bin/env -S pytest --tb=short -v
"""
Unit tests for niri_watcher.py.

Run with:
    pytest tests/test-niri_watcher.py

Rules followed:
    1. Never mock the system-under-test — only external dependencies.
    2. Test everything directly — pure functions unmocked, I/O mocked at boundaries.
    3. Leverage fixtures to reduce repetition and maintenance burden.
"""

from __future__ import annotations

import json
import logging
import os
import sys
from dataclasses import FrozenInstanceError
from unittest.mock import MagicMock, patch

import pytest  # ty: ignore[unresolved-import]

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from niri_watcher import (
    AppTracker,
    Config,
    EvalContext,
    FullscreenState,
    OutputInfo,
    VrrOrchestrator,
    WindowInfo,
    compute_desired_fullscreen,
    execute_hook,
    is_app_excluded,
    is_fullscreen,
    parse_outputs,
    parse_windows,
    parse_workspaces,
    resolve_output_for_window,
    window_is_fullscreen_and_active,
)


# ===========================================================================
# Fixtures — shared test data via pytest.fixture
# ===========================================================================


@pytest.fixture
def excluded_apps() -> frozenset[str]:
    """Standard excluded-apps set for tests."""
    return frozenset({"brave-browser", "mpv"})


@pytest.fixture
def single_output() -> dict[str, OutputInfo]:
    """Single 1080p output, workspace 1 → DP-1."""
    return {"DP-1": OutputInfo(name="DP-1", width=1920, height=1080)}


@pytest.fixture
def ws_to_output_single() -> dict[int, str]:
    """Workspace 1 maps to DP-1."""
    return {1: "DP-1"}


@pytest.fixture
def dual_outputs() -> dict[str, OutputInfo]:
    """DP-1 (1080p) and DP-2 (1440p)."""
    return {
        "DP-1": OutputInfo(name="DP-1", width=1920, height=1080),
        "DP-2": OutputInfo(name="DP-2", width=2560, height=1440),
    }


@pytest.fixture
def ws_to_output_dual() -> dict[int, str]:
    """Workspace 1 → DP-1, workspace 2 → DP-2."""
    return {1: "DP-1", 2: "DP-2"}


@pytest.fixture
def three_outputs() -> dict[str, OutputInfo]:
    """DP-1 (1080p), DP-2 (1440p), HDMI-1 (4K)."""
    return {
        "DP-1": OutputInfo(name="DP-1", width=1920, height=1080),
        "DP-2": OutputInfo(name="DP-2", width=2560, height=1440),
        "HDMI-1": OutputInfo(name="HDMI-1", width=3840, height=2160),
    }


@pytest.fixture
def ws_to_output_three() -> dict[int, str]:
    """Workspaces 1,2,3 → DP-1, DP-2, HDMI-1."""
    return {1: "DP-1", 2: "DP-2", 3: "HDMI-1"}


@pytest.fixture
def eval_ctx_single(single_output, ws_to_output_single, excluded_apps) -> EvalContext:
    """EvalContext for single-output tests."""
    return EvalContext(
        ws_to_output=ws_to_output_single,
        outputs=single_output,
        excluded_apps=excluded_apps,
    )


# -- Window factories via fixtures --


@pytest.fixture
def focused_fullscreen() -> WindowInfo:
    """Focused fullscreen window on workspace 1, PID 1234."""
    return WindowInfo(
        app_id="com.example.Game",
        pid=1234,
        workspace_id=1,
        tile_w=1920,
        tile_h=1080,
        win_w=None,
        win_h=None,
        is_focused=True,
    )


@pytest.fixture
def unfocused_window() -> WindowInfo:
    """Unfocused window."""
    return WindowInfo(
        app_id="com.example.App",
        pid=9999,
        workspace_id=1,
        tile_w=800,
        tile_h=600,
        win_w=None,
        win_h=None,
        is_focused=False,
    )


def make_window(**overrides) -> WindowInfo:
    """Convenience builder for WindowInfo (kept for parameterised tests)."""
    return WindowInfo(
        app_id=overrides.get("app_id", "com.example.Game"),
        pid=overrides.get("pid", 1234),
        workspace_id=overrides.get("workspace_id", 1),
        tile_w=overrides.get("tile_w", 1920),
        tile_h=overrides.get("tile_h", 1080),
        win_w=overrides.get("win_w"),
        win_h=overrides.get("win_h"),
        is_focused=overrides.get("is_focused", True),
    )


def make_output(name="DP-1", w=1920, h=1080) -> OutputInfo:
    """Convenience constructor for OutputInfo."""
    return OutputInfo(name=name, width=w, height=h)


def make_eval_ctx(
    outputs=None,
    ws_to_output=None,
    excluded=None,
) -> EvalContext:
    """Convenience constructor for EvalContext."""
    return EvalContext(
        ws_to_output=ws_to_output or {1: "DP-1"},
        outputs=outputs or {"DP-1": make_output()},
        excluded_apps=excluded or frozenset(),
    )


# -- Orchestrator helpers (still the proper way to inject I/O) --


def _default_outputs_json() -> str:
    return json.dumps(
        {"DP-1": {"modes": [{"width": 1920, "height": 1080}], "current_mode": 0}}
    )


def _default_windows_json() -> str:
    return json.dumps(
        [
            {
                "app_id": "com.example.Game",
                "pid": 1234,
                "workspace_id": 1,
                "layout": {"tile_size": [1920, 1080], "window_size": []},
                "is_focused": True,
            }
        ]
    )


def _default_workspaces_json() -> str:
    return json.dumps([{"id": 1, "output": "DP-1"}])


@pytest.fixture
def orchestrator_factory():
    """Return a callable that builds a VrrOrchestrator with mocked I/O.

    Usage:
        orch, mocks = factory(cfg, fetch_windows=...)
    """

    def _build(cfg=None, **io_overrides) -> tuple[VrrOrchestrator, dict]:
        cfg = cfg or Config(hook_on=["/bin/hook on"], hook_off=["/bin/hook off"])
        mocks: dict[str, MagicMock] = {
            "fetch_outputs": MagicMock(return_value=_default_outputs_json()),
            "fetch_windows": MagicMock(return_value=_default_windows_json()),
            "fetch_workspaces": MagicMock(return_value=_default_workspaces_json()),
            "run_hook": MagicMock(),
        }
        mocks.update(io_overrides)
        orch = VrrOrchestrator(cfg, **mocks)
        return orch, mocks

    return _build


# ===========================================================================
# Parsers — pure functions, never mocked
# ===========================================================================


class TestParseOutputs:
    def test_happy_path(self):
        data = {
            "DP-1": {
                "modes": [
                    {"width": 1920, "height": 1080},
                    {"width": 2560, "height": 1440},
                ],
                "current_mode": 1,
            }
        }
        result = parse_outputs(json.dumps(data))
        assert "DP-1" in result
        assert result["DP-1"].width == 2560
        assert result["DP-1"].height == 1440

    def test_current_mode_null_marks_output_disabled(self):
        """When current_mode is null, output is marked as disabled."""
        data = {
            "HDMI-1": {
                "modes": [{"width": 3840, "height": 2160}],
                "current_mode": None,
            }
        }
        result = parse_outputs(json.dumps(data))
        assert "HDMI-1" in result
        assert result["HDMI-1"].enabled is False
        assert result["HDMI-1"].width == 0
        assert result["HDMI-1"].height == 0
        assert result["HDMI-1"].is_enabled is False

    def test_output_without_valid_mode_skipped(self):
        """Output with no modes and current_mode null is still tracked as disabled."""
        data = {"DP-2": {"modes": [], "current_mode": None}}
        result = parse_outputs(json.dumps(data))
        assert "DP-2" in result
        assert result["DP-2"].enabled is False
        assert result["DP-2"].width == 0
        assert result["DP-2"].height == 0

    def test_empty_object(self):
        assert parse_outputs("{}") == {}

    def test_invalid_json(self):
        assert parse_outputs("not json") == {}

    def test_multiple_outputs(self):
        data = {
            "DP-1": {"modes": [{"width": 1920, "height": 1080}], "current_mode": 0},
            "HDMI-1": {"modes": [{"width": 2560, "height": 1440}], "current_mode": 0},
        }
        result = parse_outputs(json.dumps(data))
        assert len(result) == 2

    def test_mixed_enabled_and_disabled_outputs(self):
        """Test parsing outputs with both enabled and disabled states."""
        data = {
            "DP-1": {"modes": [{"width": 1920, "height": 1080}], "current_mode": 0},
            "HDMI-1": {
                "modes": [{"width": 3840, "height": 2160}],
                "current_mode": None,
            },
        }
        result = parse_outputs(json.dumps(data))
        assert len(result) == 2
        assert result["DP-1"].enabled is True
        assert result["DP-1"].is_enabled is True
        assert result["HDMI-1"].enabled is False
        assert result["HDMI-1"].is_enabled is False


class TestParseWorkspaces:
    def test_happy_path(self):
        data = [
            {"id": 1, "output": "DP-1"},
            {"id": 2, "output": "HDMI-1"},
        ]
        result = parse_workspaces(json.dumps(data))
        assert result == {1: "DP-1", 2: "HDMI-1"}

    def test_missing_output_key_skipped(self):
        data = [{"id": 1}]
        result = parse_workspaces(json.dumps(data))
        assert result == {}

    def test_empty_list(self):
        assert parse_workspaces("[]") == {}

    def test_invalid_json(self):
        assert parse_workspaces("garbage") == {}


class TestParseWindows:
    def _make_raw_window(self, **overrides) -> dict:
        base = {
            "app_id": "com.example.App",
            "pid": 9999,
            "workspace_id": 1,
            "layout": {
                "tile_size": [1920, 1080],
                "window_size": [800, 600],
            },
            "is_focused": True,
        }
        base.update(overrides)
        return base

    def test_happy_path(self):
        raw = [self._make_raw_window()]
        result = parse_windows(json.dumps(raw))
        assert len(result) == 1
        w = result[0]
        assert w.app_id == "com.example.App"
        assert w.pid == 9999
        assert w.tile_w == 1920
        assert w.tile_h == 1080
        assert w.is_focused is True

    def test_prefers_tile_size(self):
        raw = [self._make_raw_window()]
        w = parse_windows(json.dumps(raw))[0]
        assert w.effective_size == (1920, 1080)

    def test_falls_back_to_window_size(self):
        raw = [
            self._make_raw_window(layout={"tile_size": [], "window_size": [800, 600]})
        ]
        w = parse_windows(json.dumps(raw))[0]
        assert w.effective_size == (800, 600)

    def test_both_sizes_missing(self):
        raw = [self._make_raw_window(layout={})]
        w = parse_windows(json.dumps(raw))[0]
        assert w.effective_size is None

    def test_invalid_json_returns_empty(self):
        assert parse_windows("not json") == []

    def test_empty_array(self):
        assert parse_windows("[]") == []

    def test_float_dimensions_coerced(self):
        raw = [
            self._make_raw_window(
                layout={"tile_size": [1920.0, 1080.0], "window_size": []}
            )
        ]
        w = parse_windows(json.dumps(raw))[0]
        assert w.tile_w == 1920
        assert w.tile_h == 1080


# ===========================================================================
# Evaluators — pure functions, never mocked
# ===========================================================================


class TestIsAppExcluded:
    def test_excluded(self, excluded_apps):
        assert is_app_excluded("mpv", excluded_apps) is True

    def test_not_excluded(self, excluded_apps):
        assert is_app_excluded("com.example.Game", excluded_apps) is False

    def test_empty_app_id(self, excluded_apps):
        assert is_app_excluded("", excluded_apps) is False


class TestIsFullscreen:
    def test_fullscreen_via_tile(self):
        w = make_window(tile_w=1920, tile_h=1080)
        o = make_output(w=1920, h=1080)
        assert is_fullscreen(w, o) is True

    def test_not_fullscreen(self):
        w = make_window(tile_w=1280, tile_h=720)
        o = make_output(w=1920, h=1080)
        assert is_fullscreen(w, o) is False

    def test_no_size_info(self):
        w = make_window(tile_w=None, tile_h=None, win_w=None, win_h=None)
        o = make_output()
        assert is_fullscreen(w, o) is False

    def test_fullscreen_via_window_size(self):
        w = make_window(tile_w=None, tile_h=None, win_w=1920, win_h=1080)
        o = make_output(w=1920, h=1080)
        assert is_fullscreen(w, o) is True


class TestEvalContext:
    """Tests for the EvalContext value object."""

    def test_frozen_dataclass(self):
        ctx = make_eval_ctx()
        with pytest.raises(FrozenInstanceError):
            ctx.outputs = {}  # ty: ignore[invalid-assignment]

    def test_defaults(self):
        ctx = EvalContext(
            ws_to_output={},
            outputs={},
            excluded_apps=frozenset(),
        )
        assert ctx.excluded_apps == frozenset()


class TestWindowIsFullscreenAndActive:
    """Tests for the central fullscreen predicate."""

    def _call(
        self,
        window,
        outputs=None,
        ws_to_output=None,
        excluded=None,
    ) -> OutputInfo | None:
        ctx = make_eval_ctx(
            outputs=outputs,
            ws_to_output=ws_to_output,
            excluded=excluded or frozenset({"brave-browser", "mpv"}),
        )
        return window_is_fullscreen_and_active(window, ctx)

    def test_focused_fullscreen(self):
        w = make_window(pid=1234)
        result = self._call(w)
        assert result is not None
        assert result.name == "DP-1"

    def test_not_focused_returns_none(self):
        w = make_window(is_focused=False)
        assert self._call(w) is None

    def test_excluded_app_returns_none(self):
        w = make_window(app_id="mpv", pid=1234)
        assert self._call(w) is None

    def test_not_fullscreen_returns_none(self):
        w = make_window(tile_w=1280, tile_h=720)
        assert self._call(w) is None

    def test_unknown_workspace_returns_none(self):
        w = make_window(workspace_id=99)
        assert self._call(w) is None

    def test_disabled_output_returns_none(self):
        """Windows on disabled outputs (current_mode: null) should be ignored."""
        w = make_window(pid=1234, workspace_id=1)
        disabled_output = OutputInfo(name="HDMI-1", width=0, height=0, enabled=False)
        result = self._call(
            w,
            outputs={"HDMI-1": disabled_output},
            ws_to_output={1: "HDMI-1"},
        )
        assert result is None

    def test_disabled_output_with_fullscreen_window_returns_none(self):
        """Even fullscreen windows on disabled outputs should be ignored."""
        w = make_window(pid=1234, workspace_id=1, tile_w=1920, tile_h=1080)
        disabled_output = OutputInfo(name="HDMI-1", width=0, height=0, enabled=False)
        result = self._call(
            w,
            outputs={"HDMI-1": disabled_output},
            ws_to_output={1: "HDMI-1"},
        )
        assert result is None


class TestComputeDesiredFullscreen:
    def _ctx(self, outputs, ws_to_output, excluded):
        return EvalContext(
            ws_to_output=ws_to_output,
            outputs=outputs,
            excluded_apps=excluded,
        )

    def test_single_fullscreen_window(
        self, single_output, ws_to_output_single, focused_fullscreen, excluded_apps
    ):
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=excluded_apps,
        )
        desired = compute_desired_fullscreen([focused_fullscreen], ctx)
        assert desired == {"DP-1": True}

    def test_no_fullscreen_all_off(self, single_output, ws_to_output_single):
        windows = [make_window(tile_w=800, tile_h=600, pid=1234)]
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired == {"DP-1": False}

    def test_multi_monitor_independent(self, dual_outputs, ws_to_output_dual):
        windows = [
            make_window(workspace_id=1, tile_w=1920, tile_h=1080, pid=1234),
            make_window(
                workspace_id=2, tile_w=800, tile_h=600, pid=5678, is_focused=False
            ),
        ]
        ctx = self._ctx(
            outputs=dual_outputs,
            ws_to_output=ws_to_output_dual,
            excluded=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired["DP-1"] is True
        assert desired["DP-2"] is False

    def test_excluded_app_does_not_enable(self, single_output, ws_to_output_single):
        windows = [make_window(app_id="mpv", pid=1234)]
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired["DP-1"] is False


# ===========================================================================
# FullscreenState — mutable state container, never mocked
# ===========================================================================


class TestFullscreenState:
    def test_get_returns_none_for_unknown(self):
        state = FullscreenState()
        assert state.get("DP-1") is None

    def test_mark_and_get(self):
        state = FullscreenState()
        state.mark("DP-1", True)
        assert state.get("DP-1") is True

    def test_mark_overwrites(self):
        state = FullscreenState()
        state.mark("DP-1", True)
        state.mark("DP-1", False)
        assert state.get("DP-1") is False

    def test_clear_removes_entry(self):
        state = FullscreenState()
        state.mark("DP-1", True)
        state.clear("DP-1")
        assert state.get("DP-1") is None

    def test_clear_unknown_is_noop(self):
        state = FullscreenState()
        state.clear("DP-1")  # should not raise
        assert state.get("DP-1") is None

    def test_all_tracked(self):
        state = FullscreenState()
        state.mark("DP-1", True)
        state.mark("HDMI-1", False)
        assert state.all_tracked() == {"DP-1", "HDMI-1"}

    def test_all_tracked_empty(self):
        state = FullscreenState()
        assert state.all_tracked() == set()


# ===========================================================================
# AppTracker — mutable state container, never mocked
# ===========================================================================


class TestAppTracker:
    def test_record_app_new(self):
        tracker = AppTracker()
        w = make_window(app_id="game", pid=1)
        changed = tracker.record_app("DP-1", w)
        assert changed is True

    def test_record_app_same_no_change(self):
        tracker = AppTracker()
        w = make_window(app_id="game", pid=1)
        tracker.record_app("DP-1", w)
        changed = tracker.record_app("DP-1", w)
        assert changed is False

    def test_record_app_different_pid(self):
        tracker = AppTracker()
        w1 = make_window(app_id="game", pid=1)
        w2 = make_window(app_id="game", pid=2)
        tracker.record_app("DP-1", w1)
        changed = tracker.record_app("DP-1", w2)
        assert changed is True

    def test_clear_removes_entry(self):
        tracker = AppTracker()
        w = make_window(app_id="game", pid=1)
        tracker.record_app("DP-1", w)
        tracker.clear("DP-1")
        # Re-recording should be "new" again
        assert tracker.record_app("DP-1", w) is True

    def test_clear_unknown_is_noop(self):
        tracker = AppTracker()
        tracker.clear("DP-1")  # should not raise


# ===========================================================================
# resolve_output_for_window — pure function, never mocked
# ===========================================================================


class TestResolveOutputForWindow:
    def _call(self, window, outputs=None, ws_to_output=None):
        ctx = make_eval_ctx(
            outputs=outputs,
            ws_to_output=ws_to_output,
        )
        return resolve_output_for_window(window, ctx)

    def test_happy_path(self):
        w = make_window(workspace_id=1)
        result = self._call(
            w, ws_to_output={1: "DP-1"}, outputs={"DP-1": make_output()}
        )
        assert result is not None
        assert result.name == "DP-1"

    def test_none_workspace_id_returns_none(self):
        w = make_window(workspace_id=None)
        result = self._call(w)
        assert result is None

    def test_unknown_workspace_returns_none(self):
        w = make_window(workspace_id=99)
        result = self._call(
            w, ws_to_output={1: "DP-1"}, outputs={"DP-1": make_output()}
        )
        assert result is None

    def test_output_not_in_outputs_dict_returns_none(self):
        w = make_window(workspace_id=1)
        result = self._call(w, ws_to_output={1: "HDMI-2"}, outputs={})
        assert result is None


# ===========================================================================
# Orchestrator integration — I/O injected, SUT exercised directly
# ===========================================================================


class TestVrrOrchestratorPollOnce:
    def test_tracks_fullscreen_app(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True

    def test_no_double_hook_call(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        orch.poll_once()
        # Hook should only be called once (no state change on second poll)
        assert mocks["run_hook"].call_count == 1

    def test_hook_off_called_when_window_leaves_fullscreen(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True

        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": 1234,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        orch.poll_once()
        hook_call = mocks["run_hook"].call_args
        assert "off" in hook_call[0][0]

    def test_hook_on_called_on_fullscreen(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["run_hook"].assert_called_once()
        hook_call = mocks["run_hook"].call_args
        assert "on" in hook_call[0][0]

    def test_hook_off_called_on_exit_fullscreen(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["run_hook"].reset_mock()

        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        hook_call = mocks["run_hook"].call_args
        assert "off" in hook_call[0][0]

    def test_excluded_app_does_not_trigger_hooks(self, orchestrator_factory):
        cfg = Config(
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            excluded_apps=frozenset({"mpv"}),
        )
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "mpv",
                            "pid": 1234,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
        )
        orch.poll_once()
        # Excluded app should never trigger hooks
        mocks["run_hook"].assert_not_called()

    def test_disconnected_output_cleaned_up(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert "DP-1" in orch._fullscreen_state.all_tracked()

        mocks["fetch_outputs"].return_value = json.dumps({})
        mocks["fetch_windows"].return_value = json.dumps([])
        mocks["fetch_workspaces"].return_value = json.dumps([])
        orch.poll_once()
        assert "DP-1" not in orch._fullscreen_state.all_tracked()

    def test_disabled_output_ignores_fullscreen_windows(self, orchestrator_factory):
        """Fullscreen windows on disabled outputs (current_mode: null) should be ignored."""
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "HDMI-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": None,  # disabled output
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "HDMI-1"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.example.Game",
                            "pid": 1234,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.example.DisabledApp",
                            "pid": 5678,
                            "workspace_id": 2,
                            "layout": {"tile_size": [3840, 2160], "window_size": []},
                            "is_focused": True,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        # Only DP-1 should be tracked, HDMI-1 should be ignored
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("HDMI-1") is None

    def test_multi_monitor_fullscreen(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "HDMI-1": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "HDMI-1"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.example.Game",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.example.Other",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {"tile_size": [2560, 1440], "window_size": []},
                            "is_focused": False,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("HDMI-1") is None

    def test_app_tracker_records_fullscreen_app(self, orchestrator_factory):
        """App tracker records apps when fullscreen."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert "DP-1" in orch._fullscreen_state.all_tracked()
        # App tracker should have recorded the app
        assert "com.example.Game" in orch._app_tracker._output_current_app.get(
            "DP-1", ""
        )


class TestVrrOrchestratorShutdown:
    def test_shutdown_clears_state(self, orchestrator_factory):
        orch, _ = orchestrator_factory()
        orch._fullscreen_state.mark("DP-1", True)
        orch.shutdown()
        assert "DP-1" not in orch._fullscreen_state.all_tracked()

    def test_shutdown_calls_hook_off_for_active_outputs(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch._fullscreen_state.mark("DP-1", True)
        orch._fullscreen_state.mark("HDMI-1", True)
        orch.shutdown()
        assert mocks["run_hook"].call_count == 2
        for call in mocks["run_hook"].call_args_list:
            assert "off" in call[0][0]


# ===========================================================================
# State Transition Coverage
# ===========================================================================


class TestStateTransitions:
    """Comprehensive tests for fullscreen state machine transitions.

    State diagram per output:
        None ──want_on=True──> True ──want_on=False──> False
          │                      │                       │
          └──want_on=False──X───┘                       │
                  (no-op)         ──want_on=True──> True
    """

    # --- None → True ---

    def test_none_to_true_tracks_state_and_calls_hook_on(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        mocks["run_hook"].assert_called_once()
        assert "on" in mocks["run_hook"].call_args[0][0]

    # --- None → False (no-op) ---

    def test_none_to_false_no_hook_called(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg, fetch_windows=MagicMock(return_value=json.dumps([]))
        )
        orch.poll_once()
        mocks["run_hook"].assert_not_called()

    def test_none_to_false_state_unchanged(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg, fetch_windows=MagicMock(return_value=json.dumps([]))
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is None

    # --- True → True ---

    def test_true_to_true_no_duplicate_hook(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["run_hook"].reset_mock()
        orch.poll_once()
        mocks["run_hook"].assert_not_called()

    # --- True → False ---

    def test_true_to_false_tracks_state(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is False

    def test_true_to_false_calls_hook_off(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["run_hook"].reset_mock()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]

    def test_true_to_false_clears_current_app(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert "DP-1" in orch._app_tracker._output_current_app
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        assert "DP-1" not in orch._app_tracker._output_current_app

    # --- False → True ---

    def test_false_to_true_tracks_state(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        mocks["fetch_windows"].return_value = _default_windows_json()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True

    def test_false_to_true_calls_hook_on(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        mocks["run_hook"].reset_mock()
        mocks["fetch_windows"].return_value = _default_windows_json()
        orch.poll_once()
        mocks["run_hook"].assert_called_once()
        assert "on" in mocks["run_hook"].call_args[0][0]

    # --- False → False ---

    def test_false_to_false_no_op(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        mocks["run_hook"].reset_mock()
        orch.poll_once()
        mocks["run_hook"].assert_not_called()

    # --- Full transition ---

    def test_full_transition_cycle(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()

        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert mocks["run_hook"].call_count == 1

        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is False
        assert mocks["run_hook"].call_count == 2

        mocks["fetch_windows"].return_value = _default_windows_json()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert mocks["run_hook"].call_count == 3

    # --- App switching ---

    def test_app_switch_same_output_no_hook_toggle(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["run_hook"].reset_mock()

        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.OtherGame",
                    "pid": 5678,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        orch.poll_once()
        mocks["run_hook"].assert_not_called()
        assert "OtherGame" in orch._app_tracker._output_current_app.get("DP-1", "")


# ===========================================================================
# Hook Execution — external deps (subprocess, shutil) mocked, SUT exercised
# ===========================================================================


class TestHookExecution:
    def test_hook_on_receives_output_name(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        hook_call = mocks["run_hook"].call_args
        assert hook_call[0][1] == "DP-1"

    def test_hook_off_receives_output_name(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        hook_call = mocks["run_hook"].call_args
        assert hook_call[0][1] == "DP-1"

    def test_execute_hook_with_env_vars(self):
        mock_popen = MagicMock()
        with patch("niri_watcher.subprocess.Popen", mock_popen):
            with patch("niri_watcher.shutil.which", return_value="/bin/echo"):
                execute_hook("/bin/echo test", "DP-1", app_pid=1234)
        mock_popen.assert_called_once()
        env = mock_popen.call_args[1]["env"]
        assert env["NIRI_OUTPUT_NAME"] == "DP-1"
        assert env["NIRI_APP_PID"] == "1234"

    def test_execute_hook_without_pid(self):
        mock_popen = MagicMock()
        with patch("niri_watcher.subprocess.Popen", mock_popen):
            with patch("niri_watcher.shutil.which", return_value="/bin/echo"):
                execute_hook("/bin/echo test", "DP-1", app_pid=None)
        env = mock_popen.call_args[1]["env"]
        assert env["NIRI_APP_PID"] == ""

    def test_execute_hook_command_not_found(self, caplog):
        with patch("niri_watcher.shutil.which", return_value=None):
            with patch("niri_watcher.Path.is_file", return_value=False):
                execute_hook("/nonexistent/cmd", "DP-1")
        assert any(
            r.levelno == logging.WARNING
            for r in caplog.records
            if r.name == "niri_watcher"
        )

    def test_execute_hook_empty_spec(self):
        with patch("niri_watcher.subprocess.Popen") as mock_popen:
            execute_hook("", "DP-1")
        mock_popen.assert_not_called()


# ===========================================================================
# Edge Cases and Regression Guards
# ===========================================================================


class TestEdgeCases:
    def test_empty_outputs_no_windows(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(return_value=json.dumps({})),
            fetch_windows=MagicMock(return_value=json.dumps([])),
            fetch_workspaces=MagicMock(return_value=json.dumps([])),
        )
        orch.poll_once()
        mocks["run_hook"].assert_not_called()

    def test_window_with_empty_app_id(self, single_output, ws_to_output_single):
        window = make_window(app_id="", pid=1234)
        ctx = EvalContext(
            ws_to_output=ws_to_output_single,
            outputs=single_output,
            excluded_apps=frozenset({"brave-browser", "mpv"}),
        )
        result = window_is_fullscreen_and_active(window, ctx)
        assert result is not None

    def test_window_with_none_workspace_id(self):
        w = make_window(workspace_id=None, pid=1234)
        ctx = EvalContext(
            ws_to_output={},
            outputs={"DP-1": make_output()},
            excluded_apps=frozenset({"brave-browser", "mpv"}),
        )
        result = window_is_fullscreen_and_active(w, ctx)
        assert result is None

    def test_multiple_windows_same_output_mixed_focus(
        self, single_output, ws_to_output_single
    ):
        windows = [
            make_window(app_id="com.focused.Game", pid=1, is_focused=True),
            make_window(app_id="com.unfocused.App", pid=2, is_focused=False),
        ]
        ctx = EvalContext(
            ws_to_output=ws_to_output_single,
            outputs=single_output,
            excluded_apps=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired["DP-1"] is True

    def test_desktop_environment_no_fullscreen(
        self, single_output, ws_to_output_single
    ):
        windows = [
            make_window(app_id="org.kde.dolphin", pid=1000, tile_w=800, tile_h=600),
        ]
        ctx = EvalContext(
            ws_to_output=ws_to_output_single,
            outputs=single_output,
            excluded_apps=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired["DP-1"] is False

    def test_config_frozen_immutability(self):
        cfg = Config()
        with pytest.raises(FrozenInstanceError):
            cfg.poll_interval = 5.0  # ty: ignore[invalid-assignment]

    def test_output_info_resolution_property(self):
        output = make_output(w=3840, h=2160)
        assert output.resolution == (3840, 2160)

    def test_window_effective_size_tile_priority(self):
        w = WindowInfo(
            app_id="test",
            pid=1,
            workspace_id=1,
            tile_w=1920,
            tile_h=1080,
            win_w=800,
            win_h=600,
            is_focused=True,
        )
        assert w.effective_size == (1920, 1080)

    def test_window_effective_size_window_fallback(self):
        w = WindowInfo(
            app_id="test",
            pid=1,
            workspace_id=1,
            tile_w=None,
            tile_h=None,
            win_w=800,
            win_h=600,
            is_focused=True,
        )
        assert w.effective_size == (800, 600)

    def test_compute_desired_fullscreen_empty_windows(self):
        outputs = {"DP-1": make_output(), "HDMI-1": make_output("HDMI-1")}
        ctx = EvalContext(
            ws_to_output={1: "DP-1", 2: "HDMI-1"},
            outputs=outputs,
            excluded_apps=frozenset({"brave-browser", "mpv"}),
        )
        desired = compute_desired_fullscreen([], ctx)
        assert desired == {"DP-1": False, "HDMI-1": False}

    def test_shutdown_on_empty_state(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.shutdown()
        mocks["run_hook"].assert_not_called()


# ===========================================================================
# Per-Output Fullscreen State Detection
# ===========================================================================


class TestPerOutputFullscreenState:
    def test_dual_monitor_independent_fullscreen(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "DP-2": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "DP-2"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {
                                "tile_size": [1920, 1080],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.game.Two",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {
                                "tile_size": [2560, 1440],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is True

    def test_dual_monitor_one_fullscreen_one_not(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "DP-2": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "DP-2"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {
                                "tile_size": [1920, 1080],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.desktop.App",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {
                                "tile_size": [1280, 720],
                                "window_size": [],
                            },
                            "is_focused": False,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is None

    def test_output_specific_app_tracking(self):
        tracker = AppTracker()
        w1 = make_window(app_id="game", pid=1, workspace_id=1)
        w2 = make_window(app_id="video", pid=2, workspace_id=2)
        tracker.record_app("DP-1", w1)
        tracker.record_app("DP-2", w2)
        assert "game:1" == tracker._output_current_app["DP-1"]
        assert "video:2" == tracker._output_current_app["DP-2"]

    def test_one_output_leaves_fullscreen_other_stays(self, orchestrator_factory):
        cfg = Config(hook_on=["/bin/hook on"], hook_off=["/bin/hook off"])
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "DP-2": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "DP-2"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {
                                "tile_size": [1920, 1080],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.game.Two",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {
                                "tile_size": [2560, 1440],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        mocks["run_hook"].reset_mock()

        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.game.One",
                    "pid": 1,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                },
                {
                    "app_id": "com.game.Two",
                    "pid": 2,
                    "workspace_id": 2,
                    "layout": {"tile_size": [2560, 1440], "window_size": []},
                    "is_focused": True,
                },
            ]
        )
        orch.poll_once()

        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]
        assert orch._fullscreen_state.get("DP-1") is False
        assert orch._fullscreen_state.get("DP-2") is True

    def test_output_reconnection_scenario(self, orchestrator_factory):
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert "DP-1" in orch._fullscreen_state.all_tracked()

        mocks["fetch_outputs"].return_value = json.dumps({})
        mocks["fetch_windows"].return_value = json.dumps([])
        mocks["fetch_workspaces"].return_value = json.dumps([])
        orch.poll_once()
        assert "DP-1" not in orch._fullscreen_state.all_tracked()
        assert "DP-1" not in orch._app_tracker._output_current_app

        mocks["fetch_outputs"].return_value = _default_outputs_json()
        mocks["fetch_workspaces"].return_value = _default_workspaces_json()
        mocks["fetch_windows"].return_value = _default_windows_json()
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True

    def test_three_monitor_setup_independent_states(self, orchestrator_factory):
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        },
                        "DP-2": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                        "HDMI-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [
                        {"id": 1, "output": "DP-1"},
                        {"id": 2, "output": "DP-2"},
                        {"id": 3, "output": "HDMI-1"},
                    ]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {
                                "tile_size": [1920, 1080],
                                "window_size": [],
                            },
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.desk.One",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {
                                "tile_size": [1280, 720],
                                "window_size": [],
                            },
                            "is_focused": False,
                        },
                        {
                            "app_id": "com.desk.Two",
                            "pid": 3,
                            "workspace_id": 3,
                            "layout": {
                                "tile_size": [1280, 720],
                                "window_size": [],
                            },
                            "is_focused": False,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is None
        assert orch._fullscreen_state.get("HDMI-1") is None


# ===========================================================================
# OutputInfo Scale
# ===========================================================================


class TestOutputInfoScale:
    """Tests for OutputInfo scale field and physical_resolution."""

    def test_default_scale_is_1_0(self):
        output = make_output("DP-1", w=1920, h=1080)
        assert output.scale == 1.0

    def test_physical_resolution_without_scale(self):
        output = make_output("DP-1", w=1920, h=1080)
        assert output.physical_resolution == (1920, 1080)

    def test_physical_resolution_with_scale_2x(self):
        output = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        assert output.physical_resolution == (3840, 2160)

    def test_physical_resolution_with_scale_0_5x(self):
        output = OutputInfo(name="DP-1", width=3840, height=2160, scale=0.5)
        assert output.physical_resolution == (1920, 1080)

    def test_is_scaled_false_when_scale_1_0(self):
        output = make_output("DP-1", w=1920, h=1080)
        assert output.is_scaled is False

    def test_is_scaled_true_when_scale_2x(self):
        output = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        assert output.is_scaled is True

    def test_is_scaled_true_when_scale_0_5x(self):
        output = OutputInfo(name="DP-1", width=1920, height=1080, scale=0.5)
        assert output.is_scaled is True


class TestParseOutputsScale:
    """Tests for parse_outputs extracting scale from JSON.

    Note: niri reports mode dimensions as physical pixels, and logical
    dimensions separately.  parse_outputs computes logical dimensions
    as physical / scale so that OutputInfo.resolution returns the
    logical viewport size (matching window tile_size coordinates).
    """

    def test_scale_from_logical_section(self):
        data = {
            "DP-1": {
                "modes": [{"width": 3840, "height": 2160}],
                "current_mode": 0,
                "logical": {
                    "x": 0,
                    "y": 0,
                    "width": 1920,
                    "height": 1080,
                    "scale": 2.0,
                    "transform": "Normal",
                },
            }
        }
        result = parse_outputs(json.dumps(data))
        assert result["DP-1"].scale == 2.0
        # logical dimensions = physical / scale
        assert result["DP-1"].width == 1920
        assert result["DP-1"].height == 1080
        assert result["DP-1"].resolution == (1920, 1080)
        assert result["DP-1"].physical_resolution == (3840, 2160)

    def test_scale_defaults_to_1_when_no_logical(self):
        data = {
            "DP-1": {
                "modes": [{"width": 1920, "height": 1080}],
                "current_mode": 0,
            }
        }
        result = parse_outputs(json.dumps(data))
        assert result["DP-1"].scale == 1.0
        assert result["DP-1"].width == 1920
        assert result["DP-1"].height == 1080

    def test_scale_defaults_to_1_when_logical_without_scale(self):
        data = {
            "DP-1": {
                "modes": [{"width": 1920, "height": 1080}],
                "current_mode": 0,
                "logical": {"x": 0, "y": 0, "width": 1920, "height": 1080},
            }
        }
        result = parse_outputs(json.dumps(data))
        assert result["DP-1"].scale == 1.0

    def test_disabled_output_has_default_scale(self):
        data = {
            "HDMI-1": {
                "modes": [{"width": 3840, "height": 2160}],
                "current_mode": None,
            }
        }
        result = parse_outputs(json.dumps(data))
        assert result["HDMI-1"].scale == 1.0


class TestIsFullscreenWithScale:
    """Tests for is_fullscreen accounting for output scale.

    Window tile_size and output logical resolution are in the same
    coordinate space — a window that fills the logical viewport is
    fullscreen regardless of scale factor.
    """

    def test_fullscreen_without_scale(self):
        w = make_window(tile_w=1920, tile_h=1080)
        o = make_output(w=1920, h=1080)
        assert is_fullscreen(w, o) is True

    def test_fullscreen_with_2x_scale_logical_match(self):
        """Window fills logical viewport (1920x1080) on a 2x scaled output."""
        # Output: physical 3840x2160, scale 2.0 → logical 1920x1080
        o = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        w = make_window(tile_w=1920, tile_h=1080)
        # Window fills logical viewport → fullscreen
        assert is_fullscreen(w, o) is True

    def test_not_fullscreen_on_2x_scale(self):
        """Window smaller than logical viewport → not fullscreen."""
        o = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        w = make_window(tile_w=1280, tile_h=720)
        assert is_fullscreen(w, o) is False

    def test_fullscreen_with_0_5x_scale_logical_match(self):
        """Window fills logical viewport (3840x2160) on a 0.5x scaled output."""
        o = OutputInfo(name="DP-1", width=3840, height=2160, scale=0.5)
        w = make_window(tile_w=3840, tile_h=2160)
        assert is_fullscreen(w, o) is True

    def test_physical_resolution_property(self):
        """physical_resolution is stored correctly for reference."""
        o = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        assert o.physical_resolution == (3840, 2160)


class TestWindowIsFullscreenAndActiveWithScale:
    """Tests for window_is_fullscreen_and_active accounting for output scale."""

    def _call(
        self,
        window,
        outputs=None,
        ws_to_output=None,
        excluded=None,
    ) -> OutputInfo | None:
        ctx = make_eval_ctx(
            outputs=outputs,
            ws_to_output=ws_to_output,
            excluded=excluded or frozenset({"brave-browser", "mpv"}),
        )
        return window_is_fullscreen_and_active(window, ctx)

    def test_logical_fullscreen_on_scaled_output_wants_tracking(self):
        """Window filling logical viewport on scaled output should be tracked."""
        w = make_window(pid=1234, tile_w=1920, tile_h=1080)
        # Output: physical 3840x2160, scale 2.0 → logical 1920x1080
        output = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        result = self._call(
            w,
            outputs={"DP-1": output},
            ws_to_output={1: "DP-1"},
        )
        assert result is not None
        assert result.name == "DP-1"

    def test_not_logical_fullscreen_on_scaled_output_returns_none(self):
        """Window smaller than logical viewport on scaled output → no tracking."""
        w = make_window(pid=1234, tile_w=1280, tile_h=720)
        output = OutputInfo(name="DP-1", width=1920, height=1080, scale=2.0)
        result = self._call(
            w,
            outputs={"DP-1": output},
            ws_to_output={1: "DP-1"},
        )
        assert result is None

    def test_scaled_output_disabled_output_still_ignored(self):
        """Disabled outputs with scale should still be ignored."""
        w = make_window(pid=1234, tile_w=1920, tile_h=1080, workspace_id=1)
        output = OutputInfo(name="HDMI-1", width=0, height=0, scale=1.0, enabled=False)
        result = self._call(
            w,
            outputs={"HDMI-1": output},
            ws_to_output={1: "HDMI-1"},
        )
        assert result is None


class TestOrchestratorScaleIntegration:
    """Integration tests for the orchestrator with scaled outputs."""

    def test_scaled_output_2x_track_logical_fullscreen(self, orchestrator_factory):
        """Fullscreen tracking when window fills logical viewport on 2x scaled output."""
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": 0,
                            "logical": {
                                "x": 0,
                                "y": 0,
                                "width": 1920,
                                "height": 1080,
                                "scale": 2.0,
                                "transform": "Normal",
                            },
                        }
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps([{"id": 1, "output": "DP-1"}])
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.example.Game",
                            "pid": 1234,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True

    def test_scaled_output_2x_not_track_not_fullscreen(self, orchestrator_factory):
        """Fullscreen tracking should NOT occur when window doesn't fill logical viewport on 2x scaled output."""
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": 0,
                            "logical": {
                                "x": 0,
                                "y": 0,
                                "width": 1920,
                                "height": 1080,
                                "scale": 2.0,
                                "transform": "Normal",
                            },
                        }
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps([{"id": 1, "output": "DP-1"}])
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.example.App",
                            "pid": 1234,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1280, 720], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is None

    def test_mixed_scaled_and_unscaled_outputs(self, orchestrator_factory):
        """Multi-monitor with one scaled and one unscaled output."""
        cfg = Config()
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": 0,
                            "logical": {
                                "x": 0,
                                "y": 0,
                                "width": 1920,
                                "height": 1080,
                                "scale": 2.0,
                                "transform": "Normal",
                            },
                        },
                        "DP-2": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "DP-1"}, {"id": 2, "output": "DP-2"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        # Logical fullscreen on DP-1 (1920x1080, scale 2.0 → physical 3840x2160)
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        },
                        # Logical fullscreen on DP-2 (2560x1440, no scale)
                        {
                            "app_id": "com.game.Two",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {"tile_size": [2560, 1440], "window_size": []},
                            "is_focused": True,
                        },
                    ]
                )
            ),
        )
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is True

    def test_scaled_and_unscaled_toggle_independently(self, orchestrator_factory):
        """Both a scaled and an unscaled output go fullscreen, then one leaves — the other stays."""
        cfg = Config(hook_on=["/bin/hook on"], hook_off=["/bin/hook off"])
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        # Scaled: physical 3840x2160, scale 2.0 → logical 1920x1080
                        "HDMI-A-1": {
                            "modes": [{"width": 3840, "height": 2160}],
                            "current_mode": 0,
                            "logical": {
                                "x": 0,
                                "y": 0,
                                "width": 1920,
                                "height": 1080,
                                "scale": 2.0,
                                "transform": "Normal",
                            },
                        },
                        # Unscaled: logical == physical 2560x1440
                        "DP-1": {
                            "modes": [{"width": 2560, "height": 1440}],
                            "current_mode": 0,
                        },
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps(
                    [{"id": 1, "output": "HDMI-A-1"}, {"id": 2, "output": "DP-1"}]
                )
            ),
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        # Fullscreen on HDMI-A-1 (logical 1920x1080)
                        {
                            "app_id": "com.game.One",
                            "pid": 1,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        },
                        # Fullscreen on DP-1 (2560x1440)
                        {
                            "app_id": "com.game.Two",
                            "pid": 2,
                            "workspace_id": 2,
                            "layout": {"tile_size": [2560, 1440], "window_size": []},
                            "is_focused": True,
                        },
                    ]
                )
            ),
        )

        # First poll: both fullscreen → both tracked
        orch.poll_once()
        assert orch._fullscreen_state.get("HDMI-A-1") is True
        assert orch._fullscreen_state.get("DP-1") is True
        mocks["run_hook"].reset_mock()

        # Second poll: HDMI-A-1 leaves fullscreen, DP-1 stays fullscreen
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.game.One",
                    "pid": 1,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                },
                {
                    "app_id": "com.game.Two",
                    "pid": 2,
                    "workspace_id": 2,
                    "layout": {"tile_size": [2560, 1440], "window_size": []},
                    "is_focused": True,
                },
            ]
        )
        orch.poll_once()

        # Only HDMI-A-1 should have hook called (off)
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]
        assert orch._fullscreen_state.get("HDMI-A-1") is False
        assert orch._fullscreen_state.get("DP-1") is True


if __name__ == "__main__":
    import sys

    sys.exit(pytest.main(["-tb=short", "-v", "-p", "no:pytest-profiling", __file__]))
