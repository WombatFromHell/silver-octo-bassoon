#!/usr/bin/env bats
# shellcheck disable=SC2329,SC2034

bats_require_minimum_version 1.5.0

SOURCE_FILE="${BATS_TEST_DIRNAME}/install-neovim.sh"

setup() {
  TEST_ROOT="${BATS_TMPDIR:-/tmp/bats_test}/nvim_sandbox_$$"
  rm -rf "$TEST_ROOT"
  mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/home/AppImages"

  export HOME="$TEST_ROOT/home"
  export INSTALL_DIR="$HOME/AppImages"
  export PATH="$TEST_ROOT/bin:$PATH"

  # shellcheck source=/dev/null
  source "$SOURCE_FILE"

  MOCK_LOG="$TEST_ROOT/mock_calls.log"
  rm -f "$MOCK_LOG"

  export CURL_CMD="mock_curl"
  export MKDIR_CMD="mock_mkdir"
  export RM_CMD="mock_rm"
  export CHMOD_CMD="mock_chmod"
  export LN_CMD="mock_ln"
  export FUSER_CMD="mock_fuser"
  export MKTEMP_CMD="mock_mktemp"
  export SUDO_CMD="mock_sudo"

  mock_curl() {
    echo "curl $* " >>"$MOCK_LOG"
    return 0
  }
  mock_mkdir() {
    echo "mkdir $* " >>"$MOCK_LOG"
    return 0
  }
  mock_rm() {
    echo "rm $* " >>"$MOCK_LOG"
    return 0
  }
  mock_chmod() {
    echo "chmod $* " >>"$MOCK_LOG"
    return 0
  }
  mock_ln() {
    echo "ln $* " >>"$MOCK_LOG"
    return 0
  }
  mock_fuser() {
    echo "fuser $* " >>"$MOCK_LOG"
    return 1
  }
  mock_mktemp() { echo "$TEST_ROOT/home/tmp_$$"; }
  mock_sudo() {
    echo "sudo $* " >>"$MOCK_LOG"
    return 0
  }
}

teardown() { rm -rf "$TEST_ROOT"; }

log_contains() { grep -qF "$1" "$MOCK_LOG"; }

@test "constants: default to user-local paths" {
  [[ "$LOCAL_BIN" == "$HOME/.local/bin" ]]
  [[ "$SYMLINK_PATH" == "$HOME/.local/bin/nvim" ]]
}

@test "get_version: defaults to stable" {
  run get_version "" ""
  [[ "$output" == "stable" ]]
}

@test "get_version: returns provided version" {
  run get_version "--install" "v0.12.0"
  [[ "$output" == "v0.12.0" ]]
}

@test "get_path: builds correct paths" {
  run get_path "/tmp/nvim" "v0.12.0" "appimage"
  [[ "$output" == "/tmp/nvim/nvim-v0.12.0.appimage" ]]
}

@test "ensure_install_dir: delegates to mkdir" {
  run ensure_install_dir "$INSTALL_DIR"
  log_contains "mkdir -p $INSTALL_DIR"
}

@test "download_appimage: downloads and sets permissions" {
  run download_appimage "http://example.com/v1" "$INSTALL_DIR/nvim.appimage"
  [[ "$status" -eq 0 ]]
  log_contains "curl -fLR"
  log_contains "chmod 0755"
}

@test "download_appimage: fails on curl error" {
  mock_curl() { return 1; }
  run download_appimage "http://example.com/v1" "$INSTALL_DIR/nvim.appimage"
  [[ "$status" -eq 1 ]]
}

@test "download_appimage: captures metadata for nightly" {
  mock_mktemp() { echo "$TEST_ROOT/home/tmp_hdr"; }
  mock_curl() {
    local dump_hdr=""
    for arg; do [[ "$arg" == "--dump-header" ]] && dump_hdr=1; done
    [[ -n "$dump_hdr" ]] && { echo "etag: test-etag"; } >"$TEST_ROOT/home/tmp_hdr"
    echo "curl $*"
  } >>"$MOCK_LOG"

  run download_appimage "http://example.com/nightly" "$INSTALL_DIR/nvim-nightly.appimage" "$INSTALL_DIR/nvim-nightly.meta"
  [[ "$status" -eq 0 ]]
  grep -q "etag=test-etag" "$INSTALL_DIR/nvim-nightly.meta"
}

@test "is_file_busy: detects busy files" {
  mock_fuser() { return 0; }
  run is_file_busy "/path"
  [[ "$status" -eq 0 ]]
}

@test "is_file_busy: detects free files" {
  mock_fuser() { return 1; }
  run is_file_busy "/path"
  [[ "$status" -ne 0 ]]
}

@test "get_download_url: nightly vs tagged" {
  run get_download_url "nightly"
  [[ "$output" == "$NIGHTLY_URL" ]]

  run get_download_url "v0.12.0"
  [[ "$output" == "${BASE_URL}/v0.12.0/nvim-linux-x86_64.appimage" ]]
}

@test "get_stable_version: extracts tag from URL" {
  mock_curl() {
    [[ "$*" == *"%{url_effective}"* ]] && echo "https://github.com/neovim/neovim/releases/tag/v0.12.0"
  }
  run get_stable_version
  [[ "$output" == "v0.12.0" ]]
}

@test "update_symlink: creates new symlink" {
  run update_symlink "$TEST_ROOT/bin/nvim" "$INSTALL_DIR/nvim-stable.appimage"
  [[ "$status" -eq 0 ]]
  log_contains "sudo ln"
}

@test "update_symlink: updates existing" {
  ln -s "/old" "$TEST_ROOT/bin/nvim"
  run update_symlink "$TEST_ROOT/bin/nvim" "$INSTALL_DIR/nvim-stable.appimage"
  [[ "$status" -eq 0 ]]
  log_contains "sudo rm"
}

@test "update_symlink: skips if already correct" {
  ln -s "$INSTALL_DIR/nvim-stable.appimage" "$TEST_ROOT/bin/nvim"
  run update_symlink "$TEST_ROOT/bin/nvim" "$INSTALL_DIR/nvim-stable.appimage"
  [[ "$status" -eq 1 ]]
}

@test "remove_version: removes files and meta" {
  touch "$INSTALL_DIR/nvim-stable.appimage" "$INSTALL_DIR/nvim-stable.meta"
  run remove_version "$INSTALL_DIR" "/tmp/nvim" "stable"
  [[ "$status" -eq 0 ]]
}

@test "check_nightly_update: detects changes" {
  echo "etag=old" >"$INSTALL_DIR/nvim-nightly.meta"
  mock_curl() { echo "etag: new"; }
  run check_nightly_update "http://example.com/nightly" "$INSTALL_DIR/nvim-nightly.meta"
  [[ "$status" -eq 0 ]]
}

@test "check_nightly_update: detects up to date" {
  echo "etag=same" >"$INSTALL_DIR/nvim-nightly.meta"
  mock_curl() { echo "etag: same"; }
  run check_nightly_update "http://example.com/nightly" "$INSTALL_DIR/nvim-nightly.meta"
  [[ "$status" -eq 1 ]]
}

@test "check_nightly_update: falls back to last-modified" {
  echo "last-modified=Thu, 01 Jan 2026 00:00:00 GMT" >"$INSTALL_DIR/nvim-nightly.meta"
  mock_curl() { echo "last-modified: Thu, 01 Jan 2026 00:00:00 GMT"; }
  run check_nightly_update "http://example.com/nightly" "$INSTALL_DIR/nvim-nightly.meta"
  [[ "$status" -eq 1 ]]
}

@test "download_version: skips existing tagged" {
  touch "$INSTALL_DIR/nvim-v0.12.0.appimage"
  run download_version "$INSTALL_DIR" "v0.12.0" "$INSTALL_DIR/nvim-v0.12.0.appimage" "http://example.com/v1"
  [[ "$status" -eq 1 ]]
}

@test "download_version: downloads missing tagged" {
  run download_version "$INSTALL_DIR" "v0.12.0" "$INSTALL_DIR/nvim-v0.12.0.appimage" "http://example.com/v1"
  [[ "$status" -eq 0 ]]
}

@test "download_version: blocks when busy" {
  touch "$INSTALL_DIR/nvim-nightly.appimage"
  mock_fuser() { return 0; }
  run download_version "$INSTALL_DIR" "nightly" "$INSTALL_DIR/nvim-nightly.appimage" "http://example.com/nightly"
  [[ "$status" -eq 1 ]]
}

@test "download_version: updates nightly when needed" {
  echo "etag=old" >"$INSTALL_DIR/nvim-nightly.meta"
  mock_curl() { echo "etag: new"; }
  run download_version "$INSTALL_DIR" "nightly" "$INSTALL_DIR/nvim-nightly.appimage" "http://example.com/nightly"
  [[ "$status" -eq 0 ]]
}
