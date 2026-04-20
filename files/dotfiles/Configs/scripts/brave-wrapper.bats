#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
SOURCE_FILE="${BATS_TEST_DIRNAME}/brave-wrapper.sh"

setup() {
  export HOME="${BATS_TMPDIR:-/tmp/bats_test}/home"
  mkdir -p "${HOME}/.local/bin/scripts"
  mkdir -p "${HOME}/bin"
  export PATH="${HOME}/bin:/usr/bin:/bin"
  export CONTAINER_ID="test"
}

teardown() {
  unset CONTAINER_ID
}

make_stub() {
  local name="$1"
  local exit_code="${2:-0}"
  printf '#!/bin/bash\nexit %d\n' "$exit_code" >"${HOME}/bin/$name"
  chmod +x "${HOME}/bin/$name"
}

stub_chromium_flags() {
  cat >"${HOME}/.local/bin/scripts/chromium-flags.sh" <<'STUB'
#!/bin/bash
echo "chromium-flags: $*"
exit 0
STUB
  chmod +x "${HOME}/.local/bin/scripts/chromium-flags.sh"
}

stub_brave() {
  make_stub brave 0
  stub_chromium_flags
}

run_script() {
  run bash -c "HOME='$HOME' PATH='$PATH' CONTAINER_ID='${CONTAINER_ID:-}' '${SOURCE_FILE}' $(printf '%q ' "$@")"
}

@test "in_container returns true when CONTAINER_ID is set" {
  stub_brave
  run_script --helper-in-container
  [[ $status -eq 0 ]]
}

@test "in_container returns false outside container" {
  unset CONTAINER_ID
  stub_chromium_flags
  run_script --helper-in-container
  [[ $status -ne 0 ]]
}

@test "find_browser returns first available browser" {
  make_stub brave 0
  stub_chromium_flags
  run_script --helper-find-browser
  [[ $status -eq 0 ]]
  [[ $output == "brave" ]]
}

@test "find_browser returns 1 when no browser found" {
  rm -f "${HOME}/bin/brave" "${HOME}/bin/brave-browser" "${HOME}/bin/brave-browser-beta"
  rm -f "${HOME}/bin/flatpak"
  stub_chromium_flags
  run_script --helper-find-browser
  [[ $status -eq 1 ]]
}

@test "brave_flatpak_installed returns 0 when flatpak available and installed" {
  make_stub flatpak 0
  stub_chromium_flags
  run_script --helper-flatpak-installed
  [[ $status -eq 0 ]]
}

@test "brave_flatpak_installed returns 1 when flatpak not found" {
  rm -f "${HOME}/bin/flatpak"
  stub_chromium_flags
  run_script --helper-flatpak-installed
  [[ $status -ne 0 ]]
}

@test "brave_flatpak_installed returns 1 when brave not installed" {
  make_stub flatpak 1
  stub_chromium_flags
  run_script --helper-flatpak-installed
  [[ $status -ne 0 ]]
}

@test "notify silently succeeds when notify-send missing" {
  rm -f "${HOME}/bin/notify-send"
  stub_chromium_flags
  run_script --helper-notify "Test" "body"
  [[ $status -eq 0 ]]
  [[ $output == "" ]]
}

@test "launch_flatpak uses flatpak when available" {
  make_stub flatpak 0
  stub_chromium_flags
  run_script --helper-launch-flatpak
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags:"* ]]
}

@test "launch_distrobox uses distrobox when available" {
  make_stub distrobox-enter 0
  stub_chromium_flags
  run_script --helper-launch-distrobox brave
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags:"* ]]
}

@test "launch_direct invokes chromium-flags with browser" {
  make_stub brave 0
  stub_chromium_flags
  run_script --helper-launch-direct brave
  [[ $status -eq 0 ]]
  [[ $output == *"chromium-flags:"* ]]
}

stub_flatpak() {
  local check_output="${1:-"Nothing to do."}"
  local update_output="${2:-"Updates complete."}"
  cat >"${HOME}/bin/flatpak" <<STUB
#!/bin/bash
case "\$1" in
  info) exit 0 ;;
  list) [[ "\$2" == "--app" ]] && echo "com.brave.Browser"; exit 0 ;;
  update)
    if [[ "\$2" == "--no-deploy" ]]; then
      echo "$check_output"
    else
      echo "$update_output"
    fi
    exit 0 ;;
  *) echo "unknown: \$*"; exit 1 ;;
esac
STUB
  chmod +x "${HOME}/bin/flatpak"
}

stub_notify_send() {
  cat >"${HOME}/bin/notify-send" <<'STUB'
#!/bin/bash
exit 0
STUB
  chmod +x "${HOME}/bin/notify-send"
}

@test "flatpak_update_check detects no updates" {
  stub_flatpak "Nothing to do." "Updates complete."
  stub_notify_send
  run_script --helper-flatpak-update-check
  [[ $status -eq 0 ]]
  [[ $output == *"No flatpak updates"* ]] || [[ $output == *"flatpak update"* ]]
}

@test "flatpak_update_check detects updates available" {
  stub_flatpak "Pulling updates..." "Updates complete."
  stub_chromium_flags
  stub_notify_send
  run_script --helper-flatpak-update-check
  [[ $status -eq 0 ]]
  [[ "$output" != *"No flatpak updates"* ]]
}

@test "background_update uses flatpak when flatpak_installed" {
  stub_flatpak "Nothing to do." "Updates complete."
  stub_notify_send
  stub_chromium_flags
  run_script --helper-bg-update flatpak brave
  [[ $status -eq 0 ]]
  [[ "$output" == *"flatpak"* ]] || [[ "$output" == *"Checking"* ]]
}

@test "background_update skips dnf when browser not in PATH" {
  rm -f "${HOME}/bin/brave"
  run_script --helper-bg-update direct brave
  [[ $status -eq 0 ]]
  [[ $output != *"sudo dnf"* ]]
  make_stub brave 0
}
