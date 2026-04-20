#!/usr/bin/env bats

bats_require_minimum_version 1.5.0
SOURCE_FILE="${BATS_TEST_DIRNAME}/spawn-browser.sh"

setup() {
  export HOME="$BATS_TMPDIR/home"
  mkdir -p "$HOME/.local/share/applications"
  mkdir -p "$HOME/.local/share/flatpak/exports/share/applications"
  mkdir -p "$HOME/.local/share/flatpak/exports/share/applications"
  mkdir -p "$HOME/.var/app/com.brave.Browser/data/applications"
  mkdir -p "$HOME/.var/app/com.firefox.Firefox/data/applications"

  export PATH="$BATS_TEST_DIRNAME:$PATH"
}

run_script() {
  run bash -c "HOME='$HOME' PATH='$PATH' '${SOURCE_FILE}' $(printf '%q ' "$@")"
}

teardown() {
  unset DESKTOP_FILE
  unset FLATPAK_APP_ID
  unset BROWSER_NAME
  unset LAUNCHER_TYPE
  unset DESKTOP_PATH
}

mock_xdg_settings() {
  local desktop_file="$1"
  printf '%s\n' "$desktop_file"
}

create_desktop_file() {
  local path="$1"
  local filename="$2"
  local exec_line="$3"
  mkdir -p "$(dirname "$path/$filename")"
  printf '[Desktop Entry]\nExec=%s\n' "$exec_line" >"$path/$filename"
}

@test "desktop file search: finds desktop file in user home first" {
  create_desktop_file "$HOME/.local/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser"
  create_desktop_file "$HOME/.local/share/flatpak/exports/share/applications" "com.brave.Browser.desktop" "flatpak run com.brave.Browser"

  DESKTOP_FILE="com.brave.Browser.desktop"

  run_script --helper-find-path <<<"$DESKTOP_FILE"
  [[ "$output" == "$HOME/.local/share/applications/com.brave.Browser.desktop" ]]
}

@test "desktop file search: native-first priority for standard desktop file" {
  create_desktop_file "$HOME/.local/share/applications" "firefox.desktop" "firefox --new-window"
  create_desktop_file "$HOME/.local/share/flatpak/exports/share/applications" "firefox.desktop" "firefox --new-window"

  DESKTOP_FILE="firefox.desktop"

  run_script --helper-find-path <<<"$DESKTOP_FILE"
  [[ "$output" == "$HOME/.local/share/applications/firefox.desktop" ]]
}

@test "desktop file search: returns empty when not found" {
  DESKTOP_FILE="nonexistent.desktop"

  run_script --helper-find-path <<<"$DESKTOP_FILE"
  [[ "$output" == "" ]]
}

@test "extract exec line: returns raw exec line" {
  create_desktop_file "$HOME/.local/share/applications" "brave.desktop" "chromium-flags.sh brave-browser %U"

  run_script --helper-extract-exec "$HOME/.local/share/applications/brave.desktop"
  [[ "$output" == "chromium-flags.sh brave-browser %U" ]]
}

@test "strip field codes: removes field codes" {
  run_script --helper-strip-field-codes "firefox -new-window -P default %u %U"
  [[ "$output" == "firefox -new-window -P default" ]]
}

@test "strip field codes: removes at markers" {
  run_script --helper-strip-field-codes "google-chrome-stable @@u %U"
  [[ "$output" == "google-chrome-stable" ]]
}

@test "detect launcher type: flatpak run" {
  run_script --helper-detect-launcher <<<"flatpak run com.brave.Browser"
  [[ "$output" == "flatpak" ]]
}

@test "detect launcher type: distrobox run" {
  run_script --helper-detect-launcher <<<"distrobox run bravebox -- brave-browser"
  [[ "$output" == "distrobox" ]]
}

@test "detect launcher type: native" {
  run_script --helper-detect-launcher <<<"/usr/bin/firefox --new-window"
  [[ "$output" == "native" ]]
}

@test "detect launcher type: unknown" {
  run_script --helper-detect-launcher <<<"unknown-command"
  [[ "$output" == "" ]]
}

@test "substitute url: replaces %U and %u" {
  run_script --helper-substitute-url "chromium-flags.sh %U" "https://example.com"
  [[ "$output" == "chromium-flags.sh https://example.com" ]]
}

@test "substitute url: strips remaining field codes" {
  run_script --helper-substitute-url "chromium-flags.sh %U %f %F" "https://example.com"
  [[ "$output" == "chromium-flags.sh https://example.com" ]]
}

@test "substitute url: handles empty url" {
  run_script --helper-substitute-url "chromium-flags.sh %U" ""
  [[ "$output" == "chromium-flags.sh" ]]
}

@test "error: no default browser" {
  run_script --helper-find-desktop-file <<<""
  [[ "$output" == *"could not determine"* ]]
}

@test "build spawn command: flatpak with --new-window" {
  run_script --helper-build-cmd "flatpak" "com.brave.Browser" "brave"
  [[ "$output" == "flatpak run com.brave.Browser --new-window" ]]
}

@test "build spawn command: distrobox with --new-window" {
  run_script --helper-build-cmd "distrobox" "bravebox" "brave-browser"
  [[ "$output" == "distrobox run bravebox -- --new-window" ]]
}

@test "build spawn command: native with --new-window" {
  run_script --helper-build-cmd "native" "/usr/bin/firefox" "firefox"
  [[ "$output" == "/usr/bin/firefox --new-window" ]]
}

@test "build spawn command: flatpak without --new-window for unknown browser" {
  run_script --helper-build-cmd "flatpak" "com.unknown.App" "unknown-browser"
  [[ "$output" == "flatpak run com.unknown.App" ]]
}

@test "build spawn command: distrobox without --new-window for unknown browser" {
  run_script --helper-build-cmd "distrobox" "testbox" "unknown-bin"
  [[ "$output" == "distrobox run testbox --" ]]
}

@test "build spawn command: native without --new-window for unknown browser" {
  run_script --helper-build-cmd "native" "/usr/bin/unknown" "unknown"
  [[ "$output" == "/usr/bin/unknown" ]]
}

@test "integration: flatpak Desktop Entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "com.firefox.Firefox.desktop" "flatpak run org.mozilla.firefox --new-window %u"

  DESKTOP_FILE="com.firefox.Firefox.desktop"
  run_script --helper-find-path <<<"$DESKTOP_FILE"

  run_script --helper-extract-exec "$output"
  run_script --helper-detect-launcher <<<"$output"
  [[ "$output" == "flatpak" ]]

  run_script --helper-build-cmd "flatpak" "org.mozilla.firefox" "firefox"
  [[ "$output" == "flatpak run org.mozilla.firefox --new-window" ]]
}

@test "integration: distrobox Desktop Entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "bravebox.desktop" "distrobox run bravebox -- brave-browser %U"

  DESKTOP_FILE="bravebox.desktop"
  run_script --helper-find-path <<<"$DESKTOP_FILE"

  run_script --helper-extract-exec "$output"
  run_script --helper-detect-launcher <<<"$output"
  [[ "$output" == "distrobox" ]]

  run_script --helper-build-cmd "distrobox" "bravebox" "brave-browser"
  [[ "$output" == "distrobox run bravebox -- --new-window" ]]
}

@test "integration: native Desktop Entry to spawn command" {
  create_desktop_file "$HOME/.local/share/applications" "firefox.desktop" "firefox %u"

  DESKTOP_FILE="firefox.desktop"
  run_script --helper-find-path <<<"$DESKTOP_FILE"

  run_script --helper-extract-exec "$output"
  [[ "$output" == "firefox %u" ]]

  run_script --helper-strip-field-codes "$output"
  [[ "$output" == "firefox" ]]

  run_script --helper-build-cmd "native" "firefox" "firefox"
  [[ "$output" == "firefox --new-window" ]]
}

@test "integration: url substitution in wrapper scripts" {
  run_script --helper-substitute-url "chromium-flags.sh brave-browser %U" "https://example.com/page"
  [[ "$output" == "chromium-flags.sh brave-browser https://example.com/page" ]]
}
