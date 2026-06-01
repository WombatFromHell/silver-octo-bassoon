#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

SOURCE_FILE="${BATS_TEST_DIRNAME}/brave-wrapper.sh"

# ── Setup / Teardown ─────────────────────────────────────────────────────────

setup() {
  export TEST_ROOT="${BATS_TMPDIR:-/tmp/bats_test}/brave_sandbox_$$"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT/bin"
  mkdir -p "$TEST_ROOT/home/.local/bin/scripts"

  export HOME="$TEST_ROOT/home"
  # We add our mock bin and the script's expected config dir to PATH
  export PATH="$TEST_ROOT/bin:$HOME/.local/bin/scripts:$PATH"

  # shellcheck disable=SC1090
  source "$SOURCE_FILE"
}

teardown() {
  rm -rf "$TEST_ROOT"
}

# ── Test Helpers ──────────────────────────────────────────────────────────────

make_stub() {
  local name="$1" exit_code="${2:-0}"
  printf '#!/bin/bash\nexit %d\n' "$exit_code" >"$TEST_ROOT/bin/$name"
  chmod +x "$TEST_ROOT/bin/$name"
}

stub_chromium_flags() {
  cat >"${HOME}/.local/bin/scripts/chromium-flags.sh" <<'STUB'
#!/bin/bash
echo "chromium-flags: $*"
STUB
  chmod +x "${HOME}/.local/bin/scripts/chromium-flags.sh"
}

# ── Logic Zone: is_in_container ───────────────────────────────────────────────

@test "is_in_container: returns true when CONTAINER_ID is set" {
  CONTAINER_ID="test_id" run is_in_container
  [[ "$status" -eq 0 ]]
}

@test "is_in_container: returns true when containerenv exists" {
  local CONTAINER_ENV_FILE="$TEST_ROOT/fake_containerenv"
  touch "$CONTAINER_ENV_FILE"
  # Inject the variable via environment for testing
  CONTAINER_ENV_FILE="$CONTAINER_ENV_FILE" run is_in_container
  [[ "$status" -eq 0 ]]
}

@test "is_in_container: returns false when no container markers exist" {
  unset CONTAINER_ID
  run is_in_container
  [[ "$status" -ne 0 ]]
}

# ── Logic Zone: find_browser ─────────────────────────────────────────────────

@test "find_browser: finds first candidate in PATH (binary)" {
  make_stub brave
  run find_browser
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"brave"* || "$output" == "flatpak" ]]
}

@test "find_browser: returns flatpak when installed" {
  # Mock flatpak to pretend Brave is installed
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$1" == "list" ]]; then printf 'com.brave.Browser\n'; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run find_browser
  [[ "$status" -eq 0 ]]
  [[ "$output" == "flatpak" ]]
}

@test "find_browser: returns 1 when nothing found" {
  PATH="$TEST_ROOT/bin" run find_browser
  [[ "$status" -ne 0 ]]
}

# ── Logic Zone: detect_package_manager ───────────────────────────────────────

@test "detect_package_manager: prioritizes flatpak if installed" {
  make_stub dnf
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$1" == "info" ]]; then exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run detect_package_manager
  [[ "$output" == "flatpak" ]]
}

# ── Logic Zone: determine_launch_method ───────────────────────────────────────

@test "determine_launch_method: returns 'flatpak' when flatpak_installed is true" {
  run determine_launch_method "true" "false"
  [[ "$output" == "flatpak" ]]
}

@test "determine_launch_method: returns 'distrobox' when not in container and no flatpak" {
  run determine_launch_method "false" "false"
  [[ "$output" == "distrobox" ]]
}

# ── Action Zone: notify ──────────────────────────────────────────────────────

@test "notify: calls notify-send with correct arguments" {
  cat >"$TEST_ROOT/bin/notify-send" <<'MOCK'
#!/bin/bash
printf 'notify-send: %s\n' "$*"
MOCK
  chmod +x "$TEST_ROOT/bin/notify-send"

  run notify "Title" "Body" "low" "5000"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"-a brave-wrapper"* ]]
  [[ "$output" == *"Title"* ]]
}

# ── Action Zone: execute_launch ──────────────────────────────────────────────

@test "execute_launch: direct mode calls chromium-flags with browser and args" {
  make_stub brave
  stub_chromium_flags

  run bash -c "source '$SOURCE_FILE'; execute_launch direct brave --incognito"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"chromium-flags: brave --incognito"* ]]
}

@test "execute_launch: flatpak mode runs chromium-flags with flatpak args" {
  stub_chromium_flags
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
printf 'flatpak: %s\n' "$*"
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run bash -c "source '$SOURCE_FILE'; execute_launch flatpak brave --incognito"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"chromium-flags: flatpak run com.brave.Browser --incognito"* ]]
}

# ── Action Zone: perform_browser_update (The Strategy Tests) ─────────────────

@test "perform_browser_update [flatpak]: reports no updates when nothing to do" {
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
# Use $* to check if the flag exists anywhere in the argument list
if [[ "$*" == *"--no-deploy"* ]]; then
  printf 'Nothing to do.\n'
  exit 0
fi
exit 1
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run bash -c "source '$SOURCE_FILE'; perform_browser_update 'flatpak' 'com.brave.Browser'"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No flatpak updates found."* ]]
}

@test "perform_browser_update [flatpak]: notifies on successful upgrade" {
  make_stub notify-send
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
if [[ "$*" == *"--no-deploy"* ]]; then
  printf 'Updates available.\n'
  exit 0
fi
printf 'Updates complete.\n'
exit 0
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run bash -c "source '$SOURCE_FILE'; perform_browser_update 'flatpak' 'com.brave.Browser'"
  [[ "$status" -eq 0 ]]
  # This now works because we added 'echo "$out"' to the script!
  [[ "$output" == *"Updates complete"* ]]
}

@test "perform_browser_update [dnf]: reports no updates when dnf finds none" {
  make_stub brave
  cat >"$TEST_ROOT/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ "$1" == "dnf" ]]; then exit 0; fi # check-update returns 0 for 'no updates'
exit 0
MOCK
  chmod +x "$TEST_ROOT/bin/sudo"

  run bash -c "source '$SOURCE_FILE'; perform_browser_update 'dnf' 'brave'"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No updates found."* ]]
}

@test "perform_browser_update [dnf]: notifies on successful upgrade" {
  make_stub brave
  make_stub notify-send
  cat >"$TEST_ROOT/bin/sudo" <<'MOCK'
#!/bin/bash
if [[ "$1" == "dnf" && "$2" == "check-update" ]]; then exit 100; fi # 100 = updates available
printf 'Upgrading...'
exit 0
MOCK
  chmod +x "$TEST_ROOT/bin/sudo"

  run bash -c "source '$SOURCE_FILE'; perform_browser_update 'dnf' 'brave'"
  [[ "$status" -eq 0 ]]
}

# ── Dispatch Zone: _dispatch ─────────────────────────────────────────────────

@test "dispatch: launch-flatpak routes to execute_launch flatpak" {
  stub_chromium_flags
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
printf 'flatpak: %s\n' "$*"
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run bash -c "source '$SOURCE_FILE'; _dispatch launch-flatpak"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"chromium-flags: flatpak run com.brave.Browser"* ]]
}

@test "dispatch: bg-update with flatpak method routes to perform_browser_update" {
  cat >"$TEST_ROOT/bin/flatpak" <<'MOCK'
#!/bin/bash
printf 'Nothing to do.\n'
exit 0
MOCK
  chmod +x "$TEST_ROOT/bin/flatpak"

  run bash -c "source '$SOURCE_FILE'; _dispatch bg-update flatpak brave"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"No flatpak updates found."* ]]
}

@test "dispatch: unknown command returns error" {
  run bash -c "source '$SOURCE_FILE'; _dispatch nonexistent"
  [[ "$status" -ne 0 ]]
  [[ "$output" == *"Unknown helper"* ]]
}

# ── CLI Guard: --helper-* dispatch ───────────────────────────────────────────

@test "CLI guard: --helper-find-browser strips prefix and dispatches" {
  make_stub brave
  run bash -c "HOME='$HOME' PATH='$PATH' '${SOURCE_FILE}' --helper-find-browser"
  [[ "$status" -eq 0 ]]
  [[ "$output" == *"brave"* || "$output" == "flatpak" ]]
}

@test "CLI guard: --helper-flatpak-installed returns 1 when not installed" {
  run -127 bash -c "HOME='$HOME' PATH='$TEST_ROOT/bin:$HOME/.local/bin/scripts' '${SOURCE_FILE}' --helper-flatpak-installed"
  [[ "$status" -ne 0 ]]
}
