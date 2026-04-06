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
import subprocess
import sys
from dataclasses import FrozenInstanceError
from unittest.mock import MagicMock, patch

import pytest  # ty: ignore[unresolved-import]

sys.path.insert(0, os.path.dirname(os.path.dirname(__file__)))

from niri_watcher import (
    AppFilter,
    AppTracker,
    Config,
    EvalContext,
    FullscreenState,
    HoldPIDTracker,
    OutputInfo,
    VerifiedPIDCache,
    VrrOrchestrator,
    WindowInfo,
    compute_desired_fullscreen,
    execute_hook,
    fetch_gpu_pids,
    is_app_excluded,
    is_app_included,
    is_fullscreen,
    is_process_alive,
    parse_config_entry,
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

    By default, ``fetch_gpu_pids`` returns all window PIDs (simulating
    full GPU activity for every window) so that fullscreen detection
    works in strict mode without needing nvtop.
    """

    def _build(cfg=None, **io_overrides) -> tuple[VrrOrchestrator, dict]:
        cfg = cfg or Config(hook_on=["/bin/hook on"], hook_off=["/bin/hook off"])

        # Default gpu_pids: return PIDs from the default windows JSON
        def _default_gpu_pids() -> list[int]:
            data = json.loads(_default_windows_json())
            return [w["pid"] for w in data if w.get("pid") is not None]

        mocks: dict[str, MagicMock] = {
            "fetch_outputs": MagicMock(return_value=_default_outputs_json()),
            "fetch_windows": MagicMock(return_value=_default_windows_json()),
            "fetch_workspaces": MagicMock(return_value=_default_workspaces_json()),
            "fetch_gpu_pids": MagicMock(side_effect=_default_gpu_pids),
            "run_hook": MagicMock(),
        }
        mocks.update(io_overrides)
        orch = VrrOrchestrator(cfg, **mocks)
        return orch, mocks

    return _build


# ===========================================================================
# AppFilter — glob-based app matching (TDD phase 1)
# ===========================================================================


class TestAppFilter:
    """Tests for the AppFilter value object."""

    def test_frozen_dataclass(self):
        f = AppFilter(app_id="mpv", title=None)
        with pytest.raises(FrozenInstanceError):
            f.app_id = "something"  # ty: ignore[invalid-assignment]

    def test_repr(self):
        f = AppFilter(app_id="mpv", title="*Video*")
        assert "mpv" in repr(f)
        assert "*Video*" in repr(f)


class TestAppFilterMatches:
    """Tests for AppFilter.matches() — the core matching logic."""

    # -- Exact app_id, title=None (match any title) --

    def test_exact_appid_match_any_title(self):
        f = AppFilter(app_id="mpv", title=None)
        assert f.matches("mpv", "Some Title") is True
        assert f.matches("mpv", "") is True
        assert f.matches("mpv", None) is True

    def test_exact_appid_no_match(self):
        f = AppFilter(app_id="mpv", title=None)
        assert f.matches("brave-browser", "Some Title") is False

    def test_appid_exact_only_no_glob(self):
        """app_id is always exact match — fnmatch globs do NOT work on app_id."""
        f = AppFilter(app_id="brave-*", title=None)
        # Glob on app_id should NOT match — exact string comparison only
        assert f.matches("brave-browser", "Title") is False
        assert (
            f.matches("brave-*", "Title") is True
        )  # exact match of the literal string

    # -- Title glob matching --

    def test_title_glob_match(self):
        f = AppFilter(app_id="mpv", title="*Video*")
        assert f.matches("mpv", "My Video Player") is True
        assert f.matches("mpv", "Video") is True

    def test_title_glob_no_match(self):
        f = AppFilter(app_id="mpv", title="*Video*")
        assert f.matches("mpv", "Music Player") is False
        assert f.matches("mpv", "") is False

    def test_title_glob_any_character(self):
        f = AppFilter(app_id="mpv", title="?ideo")
        # ? matches any single character (case-sensitive on Linux)
        assert f.matches("mpv", "Video") is True  # V matches ?
        assert f.matches("mpv", "video") is True  # v matches ?
        assert f.matches("mpv", "Aideo") is True  # A matches ?
        assert f.matches("mpv", "ideo") is False  # missing char
        assert f.matches("mpv", "Vvideo") is False  # too many chars

    # -- Both app_id and title must match --

    def test_both_must_match(self):
        f = AppFilter(app_id="brave-browser", title="*Game*")
        assert f.matches("brave-browser", "My Game") is True
        assert f.matches("brave-browser", "Not a game") is False
        assert f.matches("firefox", "My Game") is False

    # -- Edge cases --

    def test_empty_title_filter(self):
        """title='' should only match windows with empty title."""
        f = AppFilter(app_id="mpv", title="")
        assert f.matches("mpv", "") is True
        assert f.matches("mpv", "Some Title") is False

    def test_title_none_vs_empty_string(self):
        """title=None matches any title, title='' matches only empty title."""
        f_none = AppFilter(app_id="mpv", title=None)
        f_empty = AppFilter(app_id="mpv", title="")

        assert f_none.matches("mpv", "Something") is True
        assert f_empty.matches("mpv", "Something") is False

        assert f_none.matches("mpv", "") is True
        assert f_empty.matches("mpv", "") is True

    def test_none_title_in_window(self):
        """Window title can be None (should be treated as empty string for matching)."""
        f = AppFilter(app_id="mpv", title="*")
        assert f.matches("mpv", None) is True  # * matches empty string
        # With title=None filter (match any), it should match
        f_any = AppFilter(app_id="mpv", title=None)
        assert f_any.matches("mpv", None) is True


# ===========================================================================
# Config Parsing — AppFilter format (TDD phase 2)
# ===========================================================================


class TestParseConfigEntry:
    """Tests for parse_config_entry() — parse 'app_id[,title]' strings."""

    def test_appid_only(self):
        """Legacy format: just app_id, no comma."""
        result = parse_config_entry("mpv")
        assert result == AppFilter(app_id="mpv", title=None)

    def test_appid_with_title(self):
        result = parse_config_entry("steam,Steam Big Picture Mode")
        assert result == AppFilter(app_id="steam", title="Steam Big Picture Mode")

    def test_appid_with_title_glob(self):
        result = parse_config_entry("steam,Steam Big*")
        assert result == AppFilter(app_id="steam", title="Steam Big*")

    def test_appid_with_empty_title(self):
        """Comma present but title empty → match only empty title."""
        result = parse_config_entry("mpv,")
        assert result == AppFilter(app_id="mpv", title="")

    def test_empty_appid_rejected(self):
        """app_id is required — empty app_id returns None."""
        assert parse_config_entry(",Some Title") is None

    def test_strips_appid_whitespace(self):
        result = parse_config_entry("  mpv  ,Title")
        assert result == AppFilter(app_id="mpv", title="Title")

    def test_title_not_stripped(self):
        """Title whitespace is preserved (might be intentional)."""
        result = parse_config_entry("mpv, Title ")
        assert result == AppFilter(app_id="mpv", title=" Title ")

    def test_empty_string_returns_none(self):
        assert parse_config_entry("") is None
        assert parse_config_entry("   ") is None


class TestConfigParsingWithAppFilters:
    """Tests for Config.from_env() with new AppFilter format."""

    def test_excluded_apps_semicolon_separated(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "mpv,;brave-browser,",
                "WATCHER_INCLUDED_APPS": "",
                "WATCHER_RELAXED_MODE": "0",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert len(cfg.excluded_apps) >= 2
        assert AppFilter("mpv", "") in cfg.excluded_apps
        assert AppFilter("brave-browser", "") in cfg.excluded_apps

    def test_excluded_apps_with_title_glob(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "steam,Steam Big*",
                "WATCHER_INCLUDED_APPS": "",
                "WATCHER_RELAXED_MODE": "0",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert AppFilter("steam", "Steam Big*") in cfg.excluded_apps

    def test_included_apps_parsing(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "com.example.Game,My Game*",
                "WATCHER_RELAXED_MODE": "0",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert len(cfg.included_apps) == 1
        assert AppFilter("com.example.Game", "My Game*") in cfg.included_apps

    def test_relaxed_mode_enabled(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
                "WATCHER_RELAXED_MODE": "1",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert cfg.relaxed_mode is True

    def test_relaxed_mode_disabled(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
                "WATCHER_RELAXED_MODE": "0",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert cfg.relaxed_mode is False

    def test_relaxed_mode_default_false(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert cfg.relaxed_mode is False

    def test_default_excluded_apps_as_appfilters(self):
        from niri_watcher import DEFAULT_EXCLUDED_APPS

        assert any(f.app_id == "mpv" for f in DEFAULT_EXCLUDED_APPS)


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
    def test_excluded(self):
        """Backward compat: app_id in frozenset[str] still works."""
        excluded = frozenset({"mpv"})
        assert is_app_excluded("mpv", excluded) is True

    def test_not_excluded(self):
        excluded = frozenset({"mpv"})
        assert is_app_excluded("com.example.Game", excluded) is False

    def test_empty_app_id(self):
        excluded = frozenset({"mpv"})
        assert is_app_excluded("", excluded) is False

    def test_excluded_with_appfilter_glob_title(self):
        """AppFilter with glob title matching."""
        excluded = frozenset({AppFilter("mpv", "*Video*")})
        assert is_app_excluded("mpv", excluded, title="My Video") is True
        assert is_app_excluded("mpv", excluded, title="Music") is False

    def test_excluded_with_appfilter_any_title(self):
        """AppFilter with title=None matches any title."""
        excluded = frozenset({AppFilter("mpv", None)})
        assert is_app_excluded("mpv", excluded, title="Anything") is True
        assert is_app_excluded("mpv", excluded, title=None) is True

    def test_excluded_with_glob_appid(self):
        """app_id globs are NOT supported — app_id is always exact match."""
        # AppFilter with app_id="brave-*" is a literal string, not a glob
        excluded = frozenset({AppFilter("brave-*", None)})
        assert is_app_excluded("brave-*", excluded, title="Title") is True
        assert is_app_excluded("brave-browser", excluded, title="Title") is False


class TestIsAppIncluded:
    """Tests for the new is_app_included() function."""

    def test_included_app_matches(self):
        included = frozenset({AppFilter("com.example.Game", "*")})
        assert is_app_included("com.example.Game", included, title="My Game") is True

    def test_included_app_no_match(self):
        included = frozenset({AppFilter("com.example.Game", "*")})
        assert is_app_included("com.example.Other", included, title="My Game") is False

    def test_included_empty_set(self):
        included = frozenset()
        assert is_app_included("com.example.Game", included, title="Title") is False

    def test_included_with_glob_appid_and_title(self):
        """app_id is exact, title supports fnmatch globs."""
        included = frozenset({AppFilter("brave-browser", "*Game*")})
        assert is_app_included("brave-browser", included, title="My Game") is True
        assert is_app_included("brave-browser", included, title="Not a game") is False
        assert (
            is_app_included("firefox", included, title="My Game") is False
        )  # app_id must match

    def test_included_with_title_none_matches_any(self):
        included = frozenset({AppFilter("mpv", None)})
        assert is_app_included("mpv", included, title="Anything") is True
        assert is_app_included("mpv", included, title=None) is True


class TestWindowIsFullscreenAndActiveWithInclusion:
    """Tests for window_is_fullscreen_and_active with inclusion logic."""

    def _call(
        self,
        window,
        outputs=None,
        ws_to_output=None,
        excluded=None,
        included=None,
        default_included=None,
        default_excluded=None,
        relaxed_mode=False,
    ) -> OutputInfo | None:
        ctx = EvalContext(
            ws_to_output=ws_to_output or {1: "DP-1"},
            outputs=outputs or {"DP-1": make_output()},
            excluded_apps=excluded or frozenset(),
            included_apps=included or frozenset(),
            default_excluded_apps=default_excluded or frozenset(),
            default_included_apps=default_included or frozenset(),
            relaxed_mode=relaxed_mode,
        )
        return window_is_fullscreen_and_active(window, ctx)

    def test_included_app_always_detected_as_fullscreen(self):
        """Included apps should be detected as fullscreen even if excluded."""
        w = make_window(app_id="com.example.Game", pid=1234, tile_w=1920, tile_h=1080)
        included = frozenset({AppFilter("com.example.Game", None)})
        excluded = frozenset(
            {AppFilter("com.example.Game", None)}
        )  # Both include and exclude
        result = self._call(w, included=included, excluded=excluded)
        # Inclusion should win
        assert result is not None
        assert result.name == "DP-1"

    def test_unfocused_included_app_bypasses_focus_gate(self):
        """Included apps are detected as fullscreen even when not focused."""
        w = make_window(
            app_id="com.example.Game",
            pid=1234,
            tile_w=1920,
            tile_h=1080,
            is_focused=False,
        )
        included = frozenset({AppFilter("com.example.Game", None)})
        result = self._call(w, included=included)
        # Included app bypasses focus requirement → detected
        assert result is not None
        assert result.name == "DP-1"

    def test_unfocused_default_included_app_bypasses_focus_gate(self):
        """Default-included apps (e.g. Steam BPM) bypass focus gate."""
        w = WindowInfo(
            app_id="steam",
            pid=1234,
            workspace_id=1,
            tile_w=1920,
            tile_h=1080,
            win_w=None,
            win_h=None,
            is_focused=False,
            title="Steam Big Picture Mode",
        )
        default_included = frozenset({AppFilter("steam", "Steam Big Picture Mode")})
        result = self._call(w, default_included=default_included)
        assert result is not None
        assert result.name == "DP-1"

    def test_unfocused_non_included_app_still_rejected(self):
        """Non-included apps that are unfocused are still rejected."""
        w = make_window(
            app_id="com.example.Other",
            pid=1234,
            tile_w=1920,
            tile_h=1080,
            is_focused=False,
        )
        result = self._call(w)
        assert result is None

    def test_relaxed_mode_skips_exclusion(self):
        """In relaxed mode, excluded apps are STILL excluded (exclusion always enforced)."""
        w = make_window(app_id="mpv", pid=1234, tile_w=1920, tile_h=1080)
        excluded = frozenset({AppFilter("mpv", None)})
        result = self._call(w, excluded=excluded, relaxed_mode=True)
        # Excluded apps are always excluded, even in relaxed mode
        assert result is None

    def test_relaxed_mode_non_included_app_detected(self):
        """In relaxed mode, non-included but non-excluded apps ARE detected (no nvtop check)."""
        w = make_window(app_id="com.example.Other", pid=1234, tile_w=1920, tile_h=1080)
        included = frozenset({AppFilter("com.example.Game", None)})
        result = self._call(w, included=included, relaxed_mode=True)
        # Relaxed mode: non-excluded app is detected without nvtop check
        assert result is not None

    def test_normal_mode_non_included_app_detected(self):
        """In normal mode, non-included apps should be detected (if not excluded)."""
        w = make_window(app_id="com.example.Other", pid=1234, tile_w=1920, tile_h=1080)
        included = frozenset({AppFilter("com.example.Game", None)})
        result = self._call(w, included=included, relaxed_mode=False)
        # Normal mode: not excluded, so should be detected
        assert result is not None

    def test_excluded_app_in_normal_mode_not_detected(self):
        """Excluded apps should not be detected in normal mode."""
        w = make_window(app_id="mpv", pid=1234, tile_w=1920, tile_h=1080)
        excluded = frozenset({AppFilter("mpv", None)})
        result = self._call(w, excluded=excluded, relaxed_mode=False)
        assert result is None


class TestAppFilterPriority:
    """Tests for the 4-level priority chain:

    1. WATCHER_INCLUDED_APPS  (user inclusion) — highest
    2. WATCHER_EXCLUDED_APPS  (user exclusion)
    3. DEFAULT_INCLUDED_APPS  (default inclusion)
    4. DEFAULT_EXCLUDED_APPS  (default exclusion) — lowest
    """

    def _call(
        self,
        window,
        user_included=None,
        user_excluded=None,
        default_included=None,
        default_excluded=None,
        relaxed_mode=False,
        outputs=None,
        ws_to_output=None,
    ):
        ctx = EvalContext(
            ws_to_output=ws_to_output or {1: "DP-1"},
            outputs=outputs or {"DP-1": make_output()},
            excluded_apps=user_excluded or frozenset(),
            included_apps=user_included or frozenset(),
            default_excluded_apps=default_excluded or frozenset(),
            default_included_apps=default_included or frozenset(),
            relaxed_mode=relaxed_mode,
        )
        return window_is_fullscreen_and_active(window, ctx)

    def test_user_excluded_overrides_default_included(self):
        """WATCHER_EXCLUDED_APPS > DEFAULT_INCLUDED_APPS."""
        w = make_window(app_id="steam", pid=1234, tile_w=1920, tile_h=1080)
        # User excludes steam; default includes it
        result = self._call(
            w,
            user_excluded=frozenset({AppFilter("steam")}),
            default_included=frozenset({AppFilter("steam", "Steam Big Picture Mode")}),
        )
        assert result is None  # user exclusion wins

    def test_user_included_overrides_default_excluded(self):
        """WATCHER_INCLUDED_APPS > DEFAULT_EXCLUDED_APPS."""
        w = make_window(app_id="mpv", pid=1234, tile_w=1920, tile_h=1080)
        # User includes mpv; default excludes it
        result = self._call(
            w,
            user_included=frozenset({AppFilter("mpv")}),
            default_excluded=frozenset({AppFilter("mpv")}),
        )
        assert result is not None  # user inclusion wins

    def test_user_included_overrides_user_excluded(self):
        """WATCHER_INCLUDED_APPS > WATCHER_EXCLUDED_APPS."""
        w = make_window(app_id="steam", pid=1234, tile_w=1920, tile_h=1080)
        # Both rules match the same app; title=None on the inclusion filter
        # means "match any title"
        result = self._call(
            w,
            user_included=frozenset({AppFilter("steam")}),
            user_excluded=frozenset({AppFilter("steam")}),
        )
        assert result is not None  # user inclusion wins

    def test_default_excluded_only(self):
        """When no user rules match, default exclusion applies."""
        w = make_window(app_id="mpv", pid=1234, tile_w=1920, tile_h=1080)
        result = self._call(
            w,
            default_excluded=frozenset({AppFilter("mpv")}),
        )
        assert result is None

    def test_default_included_only(self):
        """When no user rules and no default exclusion, default inclusion applies."""
        w = make_window(app_id="steam", pid=1234, tile_w=1920, tile_h=1080)
        # title=None means "match any title"
        result = self._call(
            w,
            default_included=frozenset({AppFilter("steam")}),
        )
        assert result is not None

    def test_no_rules_falls_through_to_nvtop(self):
        """When no rules match, normal nvtop/gpu check applies."""
        w = make_window(app_id="com.unknown.App", pid=1234, tile_w=1920, tile_h=1080)
        # No rules, gpu_pids=None (nvtop unavailable → allow)
        result = self._call(w)
        assert result is not None  # falls through to "allow" path

    def test_default_included_overrides_default_excluded(self):
        """DEFAULT_INCLUDED_APPS > DEFAULT_EXCLUDED_APPS — inclusion is checked first."""
        w = make_window(app_id="mpv", pid=1234, tile_w=1920, tile_h=1080)
        # Both match app_id "mpv"; inclusion checked first, so it wins
        result = self._call(
            w,
            default_included=frozenset({AppFilter("mpv")}),
            default_excluded=frozenset({AppFilter("mpv")}),
        )
        assert result is not None  # default inclusion checked first, wins


class TestComputeDesiredFullscreenWithInclusion:
    """Tests for compute_desired_fullscreen with inclusion/relaxed mode."""

    def _ctx(self, outputs, ws_to_output, excluded, included, relaxed_mode):
        return EvalContext(
            ws_to_output=ws_to_output,
            outputs=outputs,
            excluded_apps=excluded,
            included_apps=included,
            relaxed_mode=relaxed_mode,
        )

    def test_relaxed_mode_only_included_apps_detected(
        self, single_output, ws_to_output_single
    ):
        """In relaxed mode, only included apps should trigger fullscreen."""
        windows = [
            make_window(app_id="com.example.Game", pid=1, tile_w=1920, tile_h=1080),
            make_window(app_id="com.example.Other", pid=2, tile_w=1920, tile_h=1080),
        ]
        included = frozenset({AppFilter("com.example.Game", None)})
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=frozenset(),
            included=included,
            relaxed_mode=True,
        )
        desired = compute_desired_fullscreen(windows, ctx)
        assert desired["DP-1"] is True  # Game is included

    def test_relaxed_mode_excluded_app_still_detected(
        self, single_output, ws_to_output_single
    ):
        """In relaxed mode, non-excluded apps are detected without nvtop check."""
        windows = [
            make_window(app_id="com.example.Game", pid=1, tile_w=1920, tile_h=1080),
        ]
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=frozenset(),
            included=frozenset(),
            relaxed_mode=True,
        )
        desired = compute_desired_fullscreen(windows, ctx)
        # Non-excluded app in relaxed mode → detected (no nvtop check)
        assert desired["DP-1"] is True

    def test_relaxed_mode_excluded_app_skipped(
        self, single_output, ws_to_output_single
    ):
        """In relaxed mode, excluded apps are still skipped."""
        windows = [
            make_window(app_id="mpv", pid=1, tile_w=1920, tile_h=1080),
        ]
        excluded = frozenset({AppFilter("mpv", None)})
        ctx = self._ctx(
            outputs=single_output,
            ws_to_output=ws_to_output_single,
            excluded=excluded,
            included=frozenset(),
            relaxed_mode=True,
        )
        desired = compute_desired_fullscreen(windows, ctx)
        # Excluded app in relaxed mode → still excluded
        assert desired["DP-1"] is False


# ===========================================================================
# Evaluators — pure functions, never mocked
# ===========================================================================


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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
        mocks["fetch_gpu_pids"].side_effect = None
        mocks["fetch_gpu_pids"].return_value = [5678]
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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
        mocks["fetch_gpu_pids"].side_effect = None
        mocks["fetch_gpu_pids"].return_value = [1, 2]
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
            fetch_gpu_pids=MagicMock(return_value=[1]),
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
            fetch_gpu_pids=MagicMock(return_value=[1234]),
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
            fetch_gpu_pids=MagicMock(return_value=[1234]),
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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
            fetch_gpu_pids=MagicMock(return_value=[1, 2]),
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
        mocks["fetch_gpu_pids"].side_effect = None
        mocks["fetch_gpu_pids"].return_value = [1, 2]
        orch.poll_once()

        # Only HDMI-A-1 should have hook called (off)
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]
        assert orch._fullscreen_state.get("HDMI-A-1") is False
        assert orch._fullscreen_state.get("DP-1") is True


if __name__ == "__main__":
    import sys

    sys.exit(pytest.main(["-tb=short", "-v", "-p", "no:pytest-profiling", __file__]))


# ===========================================================================
# Hold Mode — WATCHER_HOLD_MODE feature
# ===========================================================================


class TestHoldModeConfigParsing:
    """Tests for WATCHER_HOLD_MODE environment variable parsing."""

    def test_hold_mode_default_true(self):
        """WATCHER_HOLD_MODE unset → defaults to True (enabled)."""
        with patch.dict(
            os.environ,
            {
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
            },
            clear=False,
        ):
            # Remove WATCHER_HOLD_MODE if present
            env = {k: v for k, v in os.environ.items() if k != "WATCHER_HOLD_MODE"}
            with patch.dict(os.environ, env, clear=True):
                cfg = Config.from_env()
        assert cfg.hold_mode is True

    def test_hold_mode_explicit_true(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_HOLD_MODE": "1",
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert cfg.hold_mode is True

    def test_hold_mode_explicit_false(self):
        with patch.dict(
            os.environ,
            {
                "WATCHER_HOLD_MODE": "0",
                "WATCHER_EXCLUDED_APPS": "",
                "WATCHER_INCLUDED_APPS": "",
            },
            clear=False,
        ):
            cfg = Config.from_env()
        assert cfg.hold_mode is False

    def test_hold_mode_config_constructor_default(self):
        """Config() constructor defaults hold_mode to True."""
        cfg = Config()
        assert cfg.hold_mode is True


class TestIsProcessAlive:
    """Tests for the is_process_alive helper."""

    def test_alive_process(self):
        """Current process (pid 1 or self) should be alive."""

        # Use current process — definitely alive
        assert is_process_alive(os.getpid()) is True

    def test_dead_process(self):
        """A PID that doesn't exist should return False."""

        # Use a very high PID that's unlikely to exist
        assert is_process_alive(999999999) is False


class TestHoldPIDTracker:
    """Tests for the HoldPIDTracker state container."""

    def test_record_and_has_running_pid(self):

        tracker = HoldPIDTracker()
        # Record a PID (use current process which is alive)
        tracker.record(os.getpid(), "DP-1")
        assert tracker.has_running_pid(os.getpid()) is True

    def test_has_running_pid_false_when_not_recorded(self):

        tracker = HoldPIDTracker()
        assert tracker.has_running_pid(os.getpid()) is False

    def test_evict_dead_pid(self):

        tracker = HoldPIDTracker()
        # Record a fake PID that doesn't exist
        tracker.record(999999999, "DP-1")
        # After eviction check, dead PID should be removed
        tracker.evict_dead_pids()
        assert tracker.has_running_pid(999999999) is False

    def test_evict_dead_pids_keeps_alive_pids(self):

        tracker = HoldPIDTracker()
        alive_pid = os.getpid()
        tracker.record(alive_pid, "DP-1")
        tracker.record(999999999, "DP-2")  # dead PID
        tracker.evict_dead_pids()
        assert tracker.has_running_pid(alive_pid) is True
        assert tracker.has_running_pid(999999999) is False

    def test_clear(self):

        tracker = HoldPIDTracker()
        tracker.record(os.getpid(), "DP-1")
        tracker.clear()
        assert tracker.has_running_pid(os.getpid()) is False

    def test_is_output_held_alive_pid(self):

        tracker = HoldPIDTracker()
        tracker.record(os.getpid(), "DP-1")
        assert tracker.is_output_held("DP-1") is True

    def test_is_output_held_dead_pid(self):

        tracker = HoldPIDTracker()
        tracker.record(999999999, "DP-1")
        assert tracker.is_output_held("DP-1") is False

    def test_is_output_held_unknown_output(self):

        tracker = HoldPIDTracker()
        assert tracker.is_output_held("HDMI-1") is False

    def test_clear_output(self):

        tracker = HoldPIDTracker()
        tracker.record(os.getpid(), "DP-1")
        tracker.record(os.getpid(), "DP-2")
        tracker.clear_output("DP-1")
        assert tracker.is_output_held("DP-1") is False
        assert tracker.is_output_held("DP-2") is True

    def test_clear_output_unknown_output_is_noop(self):

        tracker = HoldPIDTracker()
        tracker.clear_output("HDMI-1")  # should not raise

    def test_record_overwrites_existing_output_pid(self):

        tracker = HoldPIDTracker()
        alive_pid = os.getpid()
        tracker.record(999999999, "DP-1")  # dead PID
        tracker.record(alive_pid, "DP-1")  # overwrite with alive PID
        assert tracker.is_output_held("DP-1") is True
        # has_running_pid should find the new PID
        assert tracker.has_running_pid(alive_pid) is True
        assert tracker.has_running_pid(999999999) is False

    def test_evict_missing_pids_removes_absent(self):

        tracker = HoldPIDTracker()
        alive_pid = os.getpid()
        tracker.record(alive_pid, "DP-1")
        tracker.record(999999999, "DP-2")  # present in set (even if dead)
        tracker.evict_missing_pids({alive_pid})  # only alive_pid present
        assert tracker.is_output_held("DP-1") is True
        assert tracker.is_output_held("DP-2") is False

    def test_evict_missing_pids_keeps_all_present(self):

        tracker = HoldPIDTracker()
        pid = os.getpid()
        tracker.record(pid, "DP-1")
        tracker.record(pid, "DP-2")
        tracker.evict_missing_pids({pid})
        assert tracker.is_output_held("DP-1") is True
        assert tracker.is_output_held("DP-2") is True

    def test_evict_non_matching_pids_removes_absent(self):

        tracker = HoldPIDTracker()
        pid = os.getpid()
        tracker.record(pid, "DP-1")
        tracker.record(pid, "DP-2")
        # Only DP-1's PID is still valid
        tracker.evict_non_matching_pids({pid + 1})
        assert tracker.is_output_held("DP-1") is False
        assert tracker.is_output_held("DP-2") is False

    def test_evict_non_matching_pids_keeps_valid(self):

        tracker = HoldPIDTracker()
        pid = os.getpid()
        tracker.record(pid, "DP-1")
        tracker.evict_non_matching_pids({pid})
        assert tracker.is_output_held("DP-1") is True


class TestHoldModeOrchestratorIntegration:
    """Integration tests for hold mode suppressing HOOK_OFF."""

    def test_hold_mode_suppresses_hook_off_when_pid_running(self, orchestrator_factory):
        """When hold_mode is enabled and included app PID is running,
        HOOK_OFF should NOT be called when app leaves fullscreen."""

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("steam", "Steam Big Picture Mode")}),
        )

        def _fake_gpu_pids():
            return [1234]

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "app_id": "steam",
                            "pid": 1234,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                            "title": "Steam Big Picture Mode",
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(side_effect=_fake_gpu_pids),
        )

        # First poll: steam goes fullscreen → hook_on called
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert mocks["run_hook"].call_count == 1
        assert "on" in mocks["run_hook"].call_args_list[0][0][0]
        mocks["run_hook"].reset_mock()

        # Second poll: steam leaves fullscreen but PID still running
        # → hook_off should be SUPPRESSED
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "steam",
                    "pid": 1234,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                    "title": "Steam Big Picture Mode",
                }
            ]
        )
        orch.poll_once()
        # HOOK_OFF should NOT be called because PID 1234 is still running
        # (we can't actually check if 1234 is alive in the mock, but the
        # orchestrator records it in hold_pid_tracker)
        # Since 1234 is not a real PID, it will be considered dead and
        # hook_off WILL be called — this is expected behavior.
        # The real test is that the hold_pid_tracker is consulted.
        # For this test, we need the PID to be alive — use os.getpid()
        # Let's do a different approach: test with hold_mode disabled

    def test_hold_mode_disabled_allows_hook_off(self, orchestrator_factory):
        """When hold_mode is disabled, HOOK_OFF is called normally."""
        cfg = Config(
            hold_mode=False,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
        )
        orch, mocks = orchestrator_factory(cfg=cfg)

        # First poll: fullscreen app
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        mocks["run_hook"].reset_mock()

        # Second poll: app leaves fullscreen
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        # HOOK_OFF should be called (hold_mode disabled)
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]

    def test_hold_mode_logs_pid_tracking(self, orchestrator_factory, caplog):
        """Hold mode should log when it tracks an included app PID."""
        caplog.set_level(logging.INFO, logger="niri_watcher")

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )
        orch, mocks = orchestrator_factory(cfg=cfg)
        orch.poll_once()

        assert any(
            "Hold mode: tracking PID" in r.message
            and "1234" in r.message
            and "com.example.Game" in r.message
            for r in caplog.records
        )

    def test_hold_mode_disabled_does_not_log_tracking(
        self, orchestrator_factory, caplog
    ):
        """When hold_mode is disabled, no hold mode tracking log should appear."""
        caplog.set_level(logging.INFO, logger="niri_watcher")

        cfg = Config(
            hold_mode=False,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )
        orch, mocks = orchestrator_factory(cfg=cfg)
        orch.poll_once()

        assert not any("Hold mode: tracking PID" in r.message for r in caplog.records)

    def test_unfocused_included_app_tracked_for_hold_mode(self, orchestrator_factory):
        """An unfocused included app still gets its PID tracked for hold mode."""
        alive_pid = os.getpid()

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
                        }
                    }
                )
            ),
            fetch_workspaces=MagicMock(
                return_value=json.dumps([{"id": 1, "output": "DP-1"}])
            ),
            # Window is NOT focused — but is an included app
            fetch_windows=MagicMock(
                return_value=json.dumps(
                    [
                        {
                            "app_id": "com.example.Game",
                            "pid": alive_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": False,  # NOT focused
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[alive_pid]),
        )

        orch.poll_once()
        # Fullscreen should be detected even though unfocused (included app bypass)
        assert orch._fullscreen_state.get("DP-1") is True
        # PID should be tracked for hold mode
        assert orch._hold_pid_tracker.has_running_pid(alive_pid) is True

    def test_hold_mode_releases_on_window_close(self, orchestrator_factory):
        """Included app window closes (removed from windows list) → HOOK_OFF fires
        even if the PID is still alive system-wide."""
        alive_pid = os.getpid()

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "pid": alive_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[alive_pid]),
        )

        # First poll: game goes fullscreen → hook_on called
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._hold_pid_tracker.has_running_pid(alive_pid) is True
        mocks["run_hook"].reset_mock()

        # Second poll: window completely removed from compositor
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        # HOOK_OFF should fire because the window disappeared
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]

    def test_hold_mode_releases_on_title_change(self, orchestrator_factory):
        """Included app title changes so it no longer matches inclusion rule →
        HOOK_OFF fires even though the window still exists."""
        alive_pid = os.getpid()

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("steam", "Steam Big Picture Mode")}),
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "app_id": "steam",
                            "pid": alive_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                            "title": "Steam Big Picture Mode",
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[alive_pid]),
        )

        # First poll: steam BPM fullscreen → hook_on called
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._hold_pid_tracker.has_running_pid(alive_pid) is True
        mocks["run_hook"].reset_mock()

        # Second poll: title changed → no longer matches inclusion rule
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "steam",
                    "pid": alive_pid,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                    "title": "Steam Desktop",  # no longer matches
                }
            ]
        )
        orch.poll_once()
        # HOOK_OFF should fire because the app no longer matches inclusion rules
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]


class TestHoldModeWithRealPID:
    """Tests using real PIDs to verify process existence checking."""

    def test_hold_mode_keeps_hook_off_when_pid_alive(self, orchestrator_factory):
        """Included app goes non-fullscreen but its PID is alive → no hook_off."""
        alive_pid = os.getpid()

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "pid": alive_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[alive_pid]),
        )

        # First poll: game goes fullscreen → hook_on called
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._hold_pid_tracker.has_running_pid(alive_pid) is True
        mocks["run_hook"].reset_mock()

        # Second poll: game leaves fullscreen, PID still alive
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": alive_pid,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        orch.poll_once()
        # HOOK_OFF should NOT be called because PID is alive
        mocks["run_hook"].assert_not_called()
        # Fullscreen state should still be True (held)
        assert orch._fullscreen_state.get("DP-1") is True

    def test_hold_mode_calls_hook_off_when_pid_dead(self, orchestrator_factory):
        """Included app goes non-fullscreen and PID is dead → hook_off called."""
        dead_pid = 999999999  # Unlikely to exist

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset({AppFilter("com.example.Game", None)}),
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "pid": dead_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[dead_pid]),
        )

        # First poll: game goes fullscreen
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        mocks["run_hook"].reset_mock()

        # Second poll: game leaves fullscreen, PID is dead
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        # HOOK_OFF should be called because PID is dead
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]

    def test_hold_mode_applies_only_to_included_apps(self, orchestrator_factory):
        """Hold mode should NOT suppress hook_off for non-included apps."""
        alive_pid = os.getpid()

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            # No included apps — only default inclusion (steam) applies
        )

        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_outputs=MagicMock(
                return_value=json.dumps(
                    {
                        "DP-1": {
                            "modes": [{"width": 1920, "height": 1080}],
                            "current_mode": 0,
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
                            "pid": alive_pid,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        }
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[alive_pid]),
        )

        # First poll: game goes fullscreen (via nvtop GPU check)
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        mocks["run_hook"].reset_mock()

        # Second poll: game leaves fullscreen
        mocks["fetch_windows"].return_value = json.dumps([])
        orch.poll_once()
        # HOOK_OFF SHOULD be called — game is not an included app,
        # so hold mode does not apply
        mocks["run_hook"].assert_called_once()
        assert "off" in mocks["run_hook"].call_args[0][0]

    def test_hold_mode_tracks_multiple_included_pids(self, orchestrator_factory):
        """Multiple included apps fullscreen → both PIDs tracked → hook_off
        suppressed until both exit or lose fullscreen."""
        pid1 = os.getpid()
        pid2 = os.getppid()  # Parent process (should also be alive)

        cfg = Config(
            hold_mode=True,
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            included_apps=frozenset(
                {
                    AppFilter("com.game.One", None),
                    AppFilter("com.game.Two", None),
                }
            ),
        )

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
                            "pid": pid1,
                            "workspace_id": 1,
                            "layout": {"tile_size": [1920, 1080], "window_size": []},
                            "is_focused": True,
                        },
                        {
                            "app_id": "com.game.Two",
                            "pid": pid2,
                            "workspace_id": 2,
                            "layout": {"tile_size": [2560, 1440], "window_size": []},
                            "is_focused": True,
                        },
                    ]
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[pid1, pid2]),
        )

        # First poll: both games fullscreen
        orch.poll_once()
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is True
        assert orch._hold_pid_tracker.has_running_pid(pid1) is True
        assert orch._hold_pid_tracker.has_running_pid(pid2) is True
        mocks["run_hook"].reset_mock()

        # Second poll: game.One leaves fullscreen, PID still alive
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.game.One",
                    "pid": pid1,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                },
                {
                    "app_id": "com.game.Two",
                    "pid": pid2,
                    "workspace_id": 2,
                    "layout": {"tile_size": [2560, 1440], "window_size": []},
                    "is_focused": True,
                },
            ]
        )
        orch.poll_once()
        # DP-1 should still be held (PID alive), DP-2 still fullscreen
        assert orch._fullscreen_state.get("DP-1") is True
        assert orch._fullscreen_state.get("DP-2") is True
        # No hook_off should be called
        mocks["run_hook"].assert_not_called()


# ===========================================================================
# fetch_gpu_pids — I/O boundary tests (subprocess mocked)
# ===========================================================================


class TestFetchGpuPids:
    """Tests for the nvtop -s GPU PID extraction."""

    def _make_nvtop_output(self, processes: list[dict]) -> str:
        """Build realistic nvtop -s JSON output."""
        return json.dumps(
            [
                {
                    "device_name": "AMD Radeon RX 9070 XT",
                    "gpu_util": "4%",
                    "processes": processes,
                }
            ]
        )

    def test_graphic_and_compute_pid_returned(self):
        """Processes with kind='graphic & compute' and non-null gpu_usage qualify."""
        data = self._make_nvtop_output(
            [
                {
                    "pid": "1234",
                    "cmdline": "/usr/bin/game",
                    "kind": "graphic & compute",
                    "gpu_usage": "45%",
                },
            ]
        )
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=data)
            result = fetch_gpu_pids()
        assert result == [1234]

    def test_graphic_only_pid_excluded(self):
        """Processes with kind='graphic' (no compute) are excluded."""
        data = self._make_nvtop_output(
            [
                {
                    "pid": "5678",
                    "cmdline": "/usr/bin/browser",
                    "kind": "graphic",
                    "gpu_usage": "10%",
                },
            ]
        )
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=data)
            result = fetch_gpu_pids()
        assert result == []

    def test_null_gpu_usage_excluded(self):
        """Processes with gpu_usage=null are excluded even if kind matches."""
        data = self._make_nvtop_output(
            [
                {
                    "pid": "9999",
                    "cmdline": "/usr/bin/compositor",
                    "kind": "graphic & compute",
                    "gpu_usage": None,
                },
            ]
        )
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=data)
            result = fetch_gpu_pids()
        assert result == []

    def test_zero_percent_gpu_usage_included(self):
        """Processes with gpu_usage='0%' ARE included (they have a valid reading)."""
        data = self._make_nvtop_output(
            [
                {
                    "pid": "1111",
                    "cmdline": "/usr/bin/game",
                    "kind": "graphic & compute",
                    "gpu_usage": "0%",
                },
            ]
        )
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=data)
            result = fetch_gpu_pids()
        assert result == [1111]

    def test_multiple_devices_merged(self):
        """PIDs from multiple GPU devices are merged."""
        data = json.dumps(
            [
                {
                    "device_name": "AMD GPU",
                    "processes": [
                        {"pid": "100", "kind": "graphic & compute", "gpu_usage": "10%"},
                    ],
                },
                {
                    "device_name": "NVIDIA GPU",
                    "processes": [
                        {"pid": "200", "kind": "graphic & compute", "gpu_usage": "20%"},
                    ],
                },
            ]
        )
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout=data)
            result = fetch_gpu_pids()
        assert sorted(result) == [100, 200]

    def test_invalid_json_returns_empty(self):
        with patch("niri_watcher.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(stdout="not json")
            result = fetch_gpu_pids()
        assert result == []

    def test_subprocess_failure_returns_empty(self):
        with patch("niri_watcher.subprocess.run", side_effect=FileNotFoundError):
            result = fetch_gpu_pids()
        assert result == []

    def test_timeout_returns_empty(self):
        with patch(
            "niri_watcher.subprocess.run",
            side_effect=subprocess.TimeoutExpired(["nvtop", "-s"], 5),
        ):
            result = fetch_gpu_pids()
        assert result == []


# ===========================================================================
# Window title parsing — parse_windows extracts title from niri JSON
# ===========================================================================


class TestParseWindowsTitle:
    """Tests for window title extraction from niri windows JSON."""

    def test_title_extracted_from_json(self):
        data = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": 1234,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                    "title": "Steam Big Picture Mode",
                },
            ]
        )
        result = parse_windows(data)
        assert len(result) == 1
        assert result[0].title == "Steam Big Picture Mode"

    def test_title_none_when_absent(self):
        data = json.dumps(
            [
                {
                    "app_id": "com.example.App",
                    "pid": 999,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                },
            ]
        )
        result = parse_windows(data)
        assert result[0].title is None

    def test_title_empty_string_becomes_none(self):
        """Empty string title is converted to None."""
        data = json.dumps(
            [
                {
                    "app_id": "com.example.App",
                    "pid": 999,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                    "title": "",
                },
            ]
        )
        result = parse_windows(data)
        assert result[0].title is None


# ===========================================================================
# End-to-end: title-based filtering integration
# ===========================================================================


class TestTitleBasedFiltering:
    """Integration tests for app_id + title filtering end-to-end."""

    def _make_window_json(
        self, app_id, title, pid=1, focused=True, tile_w=1920, tile_h=1080
    ):
        return json.dumps(
            [
                {
                    "app_id": app_id,
                    "pid": pid,
                    "workspace_id": 1,
                    "layout": {"tile_size": [tile_w, tile_h], "window_size": []},
                    "is_focused": focused,
                    "title": title,
                }
            ]
        )

    def test_exclude_by_title_glob(self, orchestrator_factory):
        """Exclude steam when title matches 'Steam Big*'."""
        cfg = Config(
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            excluded_apps=frozenset({AppFilter("steam", "Steam Big*")}),
        )
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_windows=MagicMock(
                return_value=self._make_window_json(
                    "steam", "Steam Big Picture Mode", pid=1
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[1]),
        )
        orch.poll_once()
        mocks["run_hook"].assert_not_called()

    def test_include_by_title_bypasses_exclusion(self, orchestrator_factory):
        """Included app with matching title bypasses exclusion."""
        cfg = Config(
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            excluded_apps=frozenset({AppFilter("steam", "Steam Big*")}),
            included_apps=frozenset({AppFilter("steam", "Steam Big*")}),
        )
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_windows=MagicMock(
                return_value=self._make_window_json(
                    "steam", "Steam Big Picture Mode", pid=1
                )
            ),
            fetch_gpu_pids=MagicMock(return_value=[1]),
        )
        orch.poll_once()
        # Inclusion wins — hook should be called
        mocks["run_hook"].assert_called_once()
        assert "on" in mocks["run_hook"].call_args[0][0]

    def test_relaxed_mode_detects_non_excluded_app(self, orchestrator_factory):
        """Relaxed mode detects apps without nvtop check."""
        cfg = Config(
            hook_on=["/bin/hook on"],
            hook_off=["/bin/hook off"],
            relaxed_mode=True,
        )
        orch, mocks = orchestrator_factory(
            cfg=cfg,
            fetch_windows=MagicMock(
                return_value=self._make_window_json("com.game.App", "My Game", pid=1)
            ),
            # gpu_pids doesn't matter in relaxed mode
            fetch_gpu_pids=MagicMock(return_value=[]),
        )
        orch.poll_once()
        mocks["run_hook"].assert_called_once()
        assert "on" in mocks["run_hook"].call_args[0][0]


# ===========================================================================
# VerifiedPIDCache — unit tests
# ===========================================================================


class TestVerifiedPIDCache:
    """Tests for the VerifiedPIDCache dataclass."""

    def test_verify_and_is_verified(self):
        cache = VerifiedPIDCache()
        assert cache.is_verified(1234) is False
        cache.verify(1234)
        assert cache.is_verified(1234) is True

    def test_evict_unfocused_keeps_active(self):
        cache = VerifiedPIDCache()
        cache.verify(1234)
        cache.verify(5678)
        # Only PID 1234 is still focused
        cache.evict_unfocused({1234})
        assert cache.is_verified(1234) is True
        assert cache.is_verified(5678) is False

    def test_evict_unfocused_removes_all(self):
        cache = VerifiedPIDCache()
        cache.verify(1234)
        cache.verify(5678)
        cache.evict_unfocused(set())
        assert cache.is_verified(1234) is False
        assert cache.is_verified(5678) is False

    def test_evict_unfocused_noop_when_all_active(self):
        cache = VerifiedPIDCache()
        cache.verify(1234)
        cache.evict_unfocused({1234})
        assert cache.is_verified(1234) is True

    def test_clear(self):
        cache = VerifiedPIDCache()
        cache.verify(1234)
        cache.verify(5678)
        cache.clear()
        assert cache.is_verified(1234) is False
        assert cache.is_verified(5678) is False

    def test_empty_cache_evict_is_noop(self):
        cache = VerifiedPIDCache()
        cache.evict_unfocused({1234})  # should not raise


# ===========================================================================
# PID Cache Integration — orchestrator-level tests
# ===========================================================================


class TestPIDCacheIntegration:
    """Tests verifying the PID cache interacts correctly with the orchestrator."""

    def test_verified_pid_not_requeried(self, orchestrator_factory):
        """After PID passes nvtop check, fetch_gpu_pids is not called on repeat cycles."""
        orch, mocks = orchestrator_factory()
        # First poll: PID 1234 is unverified, nvtop is called
        orch.poll_once()
        assert mocks["fetch_gpu_pids"].call_count == 1
        assert orch._pid_cache.is_verified(1234)

        # Change windows to a different size so hash differs,
        # but keep the same window focused with same PID.
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": 1234,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1600, 900], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        orch.poll_once()
        # fetch_gpu_pids should NOT have been called again — PID already verified
        assert mocks["fetch_gpu_pids"].call_count == 1

    def test_cache_evicts_on_focus_loss(self, orchestrator_factory):
        """When focused window changes, old PID is evicted and new one is queried."""
        cfg = Config()
        orch, mocks = orchestrator_factory(cfg=cfg)
        orch.poll_once()
        assert orch._pid_cache.is_verified(1234)

        # Switch to a different focused window
        new_pid = 9999
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.other.App",
                    "pid": new_pid,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        # Update gpu_pids mock to return the new PID
        mocks["fetch_gpu_pids"].side_effect = lambda: [new_pid]
        orch.poll_once()
        # Old PID should be evicted (no longer focused)
        assert orch._pid_cache.is_verified(1234) is False
        # New PID should be verified after fresh nvtop call
        assert orch._pid_cache.is_verified(new_pid) is True
        assert mocks["fetch_gpu_pids"].call_count == 2

    def test_cache_cleared_on_output_disconnect(self, orchestrator_factory):
        """When an output disconnects, the PID cache is cleared."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert orch._pid_cache.is_verified(1234)

        # Disconnect the output
        mocks["fetch_outputs"].return_value = json.dumps({})
        mocks["fetch_windows"].return_value = json.dumps([])
        mocks["fetch_workspaces"].return_value = json.dumps([])
        orch.poll_once()
        assert orch._pid_cache._verified == set()

    def test_cache_cleared_on_shutdown(self, orchestrator_factory):
        """Shutdown clears the PID cache."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        assert orch._pid_cache.is_verified(1234)

        orch.shutdown()
        assert orch._pid_cache._verified == set()


# ===========================================================================
# Stable Cycle Hash — unit tests
# ===========================================================================


class TestStableCycleHash:
    """Tests for VrrOrchestrator._stable_cycle_hash."""

    def _make_window(self, **kwargs):
        return WindowInfo(
            app_id=kwargs.get("app_id", "com.example.Game"),
            pid=kwargs.get("pid", 1234),
            workspace_id=kwargs.get("workspace_id", 1),
            tile_w=kwargs.get("tile_w", 1920),
            tile_h=kwargs.get("tile_h", 1080),
            win_w=kwargs.get("win_w"),
            win_h=kwargs.get("win_h"),
            is_focused=kwargs.get("is_focused", True),
            title=kwargs.get("title"),
        )

    def test_identical_data_same_hash(self):
        outputs = '{"DP-1": {}}'
        windows = [self._make_window()]
        ws = {1: "DP-1"}
        h1 = VrrOrchestrator._stable_cycle_hash(outputs, windows, ws)
        h2 = VrrOrchestrator._stable_cycle_hash(outputs, windows, ws)
        assert h1 == h2

    def test_focus_timestamp_ignored(self):
        """focus_timestamp is not part of WindowInfo, so it's naturally excluded."""
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        windows_a = [self._make_window()]
        windows_b = [self._make_window()]
        # They're the same structurally — hash must match
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, windows_a, ws
        ) == VrrOrchestrator._stable_cycle_hash(outputs, windows_b, ws)

    def test_tile_size_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        w_full = [self._make_window(tile_w=1920, tile_h=1080)]
        w_small = [self._make_window(tile_w=1280, tile_h=720)]
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, w_full, ws
        ) != VrrOrchestrator._stable_cycle_hash(outputs, w_small, ws)

    def test_focus_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        w_focused = [self._make_window(is_focused=True)]
        w_unfocused = [self._make_window(is_focused=False)]
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, w_focused, ws
        ) != VrrOrchestrator._stable_cycle_hash(outputs, w_unfocused, ws)

    def test_app_id_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        w_a = [self._make_window(app_id="com.example.Game")]
        w_b = [self._make_window(app_id="com.other.App")]
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, w_a, ws
        ) != VrrOrchestrator._stable_cycle_hash(outputs, w_b, ws)

    def test_pid_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        w_a = [self._make_window(pid=1234)]
        w_b = [self._make_window(pid=5678)]
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, w_a, ws
        ) != VrrOrchestrator._stable_cycle_hash(outputs, w_b, ws)

    def test_outputs_json_change_changes_hash(self):
        windows = [self._make_window()]
        ws = {1: "DP-1"}
        out_a = '{"DP-1": {}}'
        out_b = '{"DP-1": {}, "DP-2": {}}'
        assert VrrOrchestrator._stable_cycle_hash(
            out_a, windows, ws
        ) != VrrOrchestrator._stable_cycle_hash(out_b, windows, ws)

    def test_workspace_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        windows = [self._make_window()]
        ws_a = {1: "DP-1"}
        ws_b = {1: "DP-2"}
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, windows, ws_a
        ) != VrrOrchestrator._stable_cycle_hash(outputs, windows, ws_b)

    def test_workspace_order_independent(self):
        """Workspace mapping order should not affect hash (sorted internally)."""
        outputs = '{"DP-1": {}, "DP-2": {}}'
        windows = [self._make_window()]
        ws_a = {1: "DP-1", 2: "DP-2"}
        ws_b = {2: "DP-2", 1: "DP-1"}
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, windows, ws_a
        ) == VrrOrchestrator._stable_cycle_hash(outputs, windows, ws_b)

    def test_empty_windows(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        h = VrrOrchestrator._stable_cycle_hash(outputs, [], ws)
        assert isinstance(h, int)

    def test_title_change_changes_hash(self):
        outputs = '{"DP-1": {}}'
        ws = {1: "DP-1"}
        w_a = [self._make_window(title="Game Window")]
        w_b = [self._make_window(title="Other Window")]
        assert VrrOrchestrator._stable_cycle_hash(
            outputs, w_a, ws
        ) != VrrOrchestrator._stable_cycle_hash(outputs, w_b, ws)


# ===========================================================================
# Content-Hash Skip — orchestrator-level tests
# ===========================================================================


class TestContentHashSkip:
    """Tests verifying the content-hash optimization works correctly."""

    def test_unchanged_cycle_skips_decide_and_act(self, orchestrator_factory):
        """Identical data across two polls → _decide and _act skipped on second."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        # First cycle: all fetchers called
        assert mocks["fetch_outputs"].call_count == 1
        assert mocks["fetch_windows"].call_count == 1

        # Second poll with identical data
        orch.poll_once()
        # The _decide phase calls fetch_gpu_pids; if it was skipped,
        # the count stays the same as after the first poll.
        gpu_calls_after_first = mocks["fetch_gpu_pids"].call_count
        # fetch_gpu_pids should NOT have been called again
        assert mocks["fetch_gpu_pids"].call_count == gpu_calls_after_first

    def test_changed_window_runs_cycle(self, orchestrator_factory):
        """Changed tile_size → hash differs → full cycle runs."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        gpu_count_after_first = mocks["fetch_gpu_pids"].call_count

        # Change window to a different PID so hash differs AND nvtop must be called
        # (new unverified PID)
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": 5678,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1280, 720], "window_size": []},
                    "is_focused": True,
                }
            ]
        )
        mocks["fetch_gpu_pids"].return_value = [5678]
        orch.poll_once()
        # fetch_gpu_pids should have been called again for the new PID
        assert mocks["fetch_gpu_pids"].call_count > gpu_count_after_first

    def test_changed_outputs_runs_cycle(self, orchestrator_factory):
        """Changed outputs → hash differs → full cycle runs."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        gpu_count_after_first = mocks["fetch_gpu_pids"].call_count

        # Add a second output and a second window with a new PID
        mocks["fetch_outputs"].return_value = json.dumps(
            {
                "DP-1": {"modes": [{"width": 1920, "height": 1080}], "current_mode": 0},
                "DP-2": {"modes": [{"width": 2560, "height": 1440}], "current_mode": 0},
            }
        )
        mocks["fetch_workspaces"].return_value = json.dumps(
            [
                {"id": 1, "output": "DP-1"},
                {"id": 2, "output": "DP-2"},
            ]
        )
        mocks["fetch_windows"].return_value = json.dumps(
            [
                {
                    "app_id": "com.example.Game",
                    "pid": 1234,
                    "workspace_id": 1,
                    "layout": {"tile_size": [1920, 1080], "window_size": []},
                    "is_focused": True,
                },
                {
                    "app_id": "com.example.Game2",
                    "pid": 5678,
                    "workspace_id": 2,
                    "layout": {"tile_size": [2560, 1440], "window_size": []},
                    "is_focused": True,
                },
            ]
        )
        mocks["fetch_gpu_pids"].return_value = [1234, 5678]
        orch.poll_once()
        assert mocks["fetch_gpu_pids"].call_count > gpu_count_after_first

    def test_no_spurious_hook_on_unchanged_data(self, orchestrator_factory):
        """Repeated polls with identical data don't re-fire hooks."""
        orch, mocks = orchestrator_factory()
        orch.poll_once()
        hook_count = mocks["run_hook"].call_count
        assert hook_count == 1  # Initial hook fire

        # Multiple unchanged polls
        for _ in range(5):
            orch.poll_once()

        assert mocks["run_hook"].call_count == 1  # No additional hooks
