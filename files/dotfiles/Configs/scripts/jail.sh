#!/usr/bin/env bash
set -euo pipefail

#
# This is a modified version of: https://github.com/entershdev/entersh
#
# Dev container launcher for AI coding agents
#
readonly SCRIPT_NAME=$(basename "$0")

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS]

Create or attach to a rootless Podman development container.

Options:
  --force    Remove existing container before creating (keeps image)
  --rebuild  Rebuild image from Containerfile.dev, then recreate container
  --verbose  Show full podman output (no spinner)
  --help     Show this help message

The script uses the current working directory as the project directory.
Containerfile.dev and .container-home/ are created in the project directory.
EOF
  exit 0
}

run_with_spinner() {
  local label="$1"
  shift

  if [ "$VERBOSE" = true ]; then
    echo "$label..."
    "$@"
    return
  fi

  local log pid spin last_step step i
  log=$(mktemp)

  "$@" >"$log" 2>&1 &
  pid=$!
  spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
  last_step=""

  while kill -0 "$pid" 2>/dev/null; do
    step=$(grep -o 'STEP [0-9]*/[0-9]*:.*' "$log" 2>/dev/null | tail -1 || true)
    if [ -n "${step:-}" ]; then
      last_step="${step:0:60}"
    fi

    for ((i = 0; i < ${#spin}; i++)); do
      if ! kill -0 "$pid" 2>/dev/null; then break; fi
      if [ -n "${last_step:-}" ]; then
        printf "\r  %s %s  " "${spin:$i:1}" "$last_step"
      else
        printf "\r  %s %s  " "${spin:$i:1}" "$label"
      fi
      sleep 0.1
    done
  done

  if wait "$pid"; then
    printf "\r  ✓ %-70s\n" "$label — done."
    rm -f "$log"
  else
    printf "\r  ✗ %-70s\n" "$label — failed!"
    echo ""
    echo "Last 20 lines of output:"
    tail -20 "$log"
    rm -f "$log"
    exit 1
  fi
}

if ! command -v podman &>/dev/null; then
  echo "Error: podman is not installed."
  echo ""
  echo "Install podman for your Linux distribution:"
  echo "  Fedora:       sudo dnf install podman"
  echo "  Ubuntu/Debian: sudo apt install podman"
  echo "  Arch:          sudo pacman -S podman"
  echo "  openSUSE:      sudo zypper install podman"
  exit 1
fi

OS="$(uname -s)"
if [ "$OS" != "Linux" ]; then
  echo "Warning: this script is designed for native Linux."
  echo "You are running on $OS."
  echo ""
  echo "Use ./enter-machine.sh instead - it uses podman machine (VM) which"
  echo "is required for macOS and Windows."
  exit 1
fi

PROJECT_DIR="$(pwd)"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
IMAGE_NAME="${PROJECT_NAME}-dev"
CONTAINER_NAME="$PROJECT_NAME"

FORCE=false
REBUILD=false
VERBOSE=false
for arg in "$@"; do
  case "$arg" in
  --force) FORCE=true ;;
  --rebuild)
    REBUILD=true
    FORCE=true
    ;;
  --verbose) VERBOSE=true ;;
  --help) usage ;;
  esac
done

generate_containerfile() {
  echo "No Containerfile.dev found, generating default..."
  cat >"$PROJECT_DIR/Containerfile.dev" <<'CONTAINERFILE'
FROM fedora:latest
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG USER_NAME=dev
RUN dnf install -y \
    git curl wget make gcc gcc-c++ findutils tar gzip unzip \
    which procps-ng htop tmux bash-completion libatomic && \
    dnf clean all
RUN groupadd -g $GROUP_ID $USER_NAME 2>/dev/null || true && \
    useradd -m -u $USER_ID -g $GROUP_ID -s /bin/bash $USER_NAME

# Setup direnv integration in bashrc (evaluated at runtime, not build time)
RUN cat >> /home/$USER_NAME/.bashrc <<'BASHRC_EOF'
# Direnv integration (if available from host nix store)
if command -v direnv &>/dev/null; then
    eval "$(direnv hook bash)"
fi

# Fallback: auto-activate .venv if direnv is not available
# (For direnv users, run 'venv-direnv.sh' to integrate .venv with direnv)
if ! command -v direnv &>/dev/null && [ -f ".venv/bin/activate" ]; then
    source .venv/bin/activate
fi
BASHRC_EOF

# Create a helper script to setup .envrc for uv/pip venv
RUN mkdir -p /home/$USER_NAME/bin && cat > /home/$USER_NAME/bin/venv-direnv.sh <<'SCRIPT_EOF'
#!/bin/bash
# Helper to create/update .envrc for virtual environment
if [ ! -d ".venv" ]; then
    echo "Error: .venv directory not found. Run 'uv venv' first."
    exit 1
fi

if [ ! -f ".envrc" ]; then
    # Create new .envrc
    echo "source .venv/bin/activate" > .envrc
    if command -v direnv &>/dev/null; then
        direnv allow
    fi
    echo "Created .envrc for .venv"
else
    # Append to existing .envrc if not already present
    if ! grep -q "source .venv/bin/activate" .envrc; then
        echo "" >> .envrc
        echo "# Activate uv/pip virtual environment" >> .envrc
        echo "source .venv/bin/activate" >> .envrc
        if command -v direnv &>/dev/null; then
            direnv allow
        fi
        echo "Updated .envrc to include .venv activation"
    else
        echo ".envrc already includes .venv activation"
    fi
fi
SCRIPT_EOF
RUN chmod +x /home/$USER_NAME/bin/venv-direnv.sh

# ============================================================================
# TODO: Add your project's environment and AI agent below.
#
# 1. Add your project's language/runtime and dependencies:
#    RUN dnf install -y golang nodejs python3 rust cargo ...
#
# 2. Install your AI coding agent (pick one):
#    RUN npm install -g @anthropic-ai/claude-code
#    RUN curl -fsSL https://opencode.ai/install | bash
#    RUN npm install -g @anthropic-ai/amp
#    RUN pip install aider-chat
#    RUN npm install -g @openai/codex
#
# 3. IMPORTANT: Also update this script to mount agent configs from host.
#    Each agent needs its auth/config directory passed through.
#
#    Example — Claude Code:
#      Containerfile.dev:
#        RUN npm install -g @anthropic-ai/claude-code
#      $SCRIPT_NAME (add to OPTIONAL_MOUNTS section):
#        if [ -d "$HOME/.claude" ]; then
#          OPTIONAL_MOUNTS+=(-v "$HOME/.claude:/home/$(whoami)/.claude")
#        fi
#      $SCRIPT_NAME (add to podman run -e flags):
#        -e ANTHROPIC_API_KEY (if you use an API key instead of OAuth)
#
#    Example — Aider:
#      Containerfile.dev:
#        RUN pip install aider-chat
#      edit this script (add to podman run -e flags):
#        -e OPENAI_API_KEY
#        -e ANTHROPIC_API_KEY
#
# 4. Rebuild the container: $SCRIPT_NAME --rebuild
# ============================================================================

USER $USER_NAME
WORKDIR /home/$USER_NAME

# Python/uv tooling optimizations (set after USER so paths resolve correctly)
# Prevents hardlink warnings when cache and project are on different mount points
ENV UV_LINK_MODE=copy
# Ensure uv cache is in a writable, persistent location
ENV UV_CACHE_DIR=/home/$USER_NAME/.cache/uv

CMD ["/bin/bash"]
CONTAINERFILE
}

save_checksums() {
  local checksums_file="$PROJECT_DIR/.container-home/.checksums"
  {
    if [ -f "$PROJECT_DIR/Containerfile.dev" ]; then
      echo "containerfile=$(sha256sum "$PROJECT_DIR/Containerfile.dev" | cut -d' ' -f1)"
    fi
    echo "script=$(sha256sum "$0" | cut -d' ' -f1)"
  } >"$checksums_file"
}

check_for_changes() {
  local checksums_file="$PROJECT_DIR/.container-home/.checksums"
  if [ ! -f "$checksums_file" ]; then
    return
  fi

  local changed=false
  local containerfile_changed=false

  if [ -f "$PROJECT_DIR/Containerfile.dev" ]; then
    local current_cf
    current_cf="$(sha256sum "$PROJECT_DIR/Containerfile.dev" | cut -d' ' -f1)"
    local saved_cf
    saved_cf="$(grep '^containerfile=' "$checksums_file" 2>/dev/null | cut -d= -f2)"
    if [ -n "$saved_cf" ] && [ "$current_cf" != "$saved_cf" ]; then
      changed=true
      containerfile_changed=true
    fi
  fi

  local current_script
  current_script="$(sha256sum "$0" | cut -d' ' -f1)"
  local saved_script
  saved_script="$(grep '^script=' "$checksums_file" 2>/dev/null | cut -d= -f2)"
  if [ -n "$saved_script" ] && [ "$current_script" != "$saved_script" ]; then
    changed=true
  fi

  if [ "$changed" = true ]; then
    echo ""
    echo "=== Changes detected since container was created ==="
    if [ "$containerfile_changed" = true ]; then
      echo "  Containerfile.dev has changed  -> run: ./$SCRIPT_NAME --rebuild"
    else
      echo "  $SCRIPT_NAME has changed           -> run: ./$SCRIPT_NAME --force"
    fi
    echo "==================================================="
    echo ""
  fi
}

if [ "$FORCE" = true ]; then
  echo "Removing container..."
  podman rm -f "$CONTAINER_NAME" 2>/dev/null || true
  if [ "$REBUILD" = true ]; then
    if [ ! -f "$PROJECT_DIR/Containerfile.dev" ]; then
      generate_containerfile
    fi
    echo "Rebuilding image..."
    podman build \
      --build-arg USER_ID="$(id -u)" \
      --build-arg GROUP_ID="$(id -g)" \
      --build-arg USER_NAME="$(whoami)" \
      -t "$IMAGE_NAME" \
      -f "$PROJECT_DIR/Containerfile.dev" \
      "$PROJECT_DIR"
    podman image prune -f >/dev/null 2>&1 || true
  fi
fi

if podman container exists "$CONTAINER_NAME" 2>/dev/null; then
  check_for_changes
  if podman inspect --format '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null | grep -q true; then
    echo "Container '$CONTAINER_NAME' is running, attaching..."
    podman exec -it -w "/home/$(whoami)/$PROJECT_NAME" "$CONTAINER_NAME" /bin/bash
  else
    echo "Container '$CONTAINER_NAME' exists but stopped, starting..."
    podman start "$CONTAINER_NAME"
    podman exec -it -w "/home/$(whoami)/$PROJECT_NAME" "$CONTAINER_NAME" /bin/bash
  fi
else
  if [ ! -f "$PROJECT_DIR/Containerfile.dev" ]; then
    generate_containerfile
  fi

  if ! podman image exists "$IMAGE_NAME" 2>/dev/null; then
    run_with_spinner "Building image '$IMAGE_NAME'" \
      podman build \
      --build-arg USER_ID="$(id -u)" \
      --build-arg GROUP_ID="$(id -g)" \
      --build-arg USER_NAME="$(whoami)" \
      -t "$IMAGE_NAME" \
      -f "$PROJECT_DIR/Containerfile.dev" \
      "$PROJECT_DIR"
  fi

  mkdir -p "$PROJECT_DIR/.container-home"/{bash,local,cache}
  mkdir -p "$PROJECT_DIR/.container-home/local/share/direnv"

  PODMAN_SOCK="${XDG_RUNTIME_DIR}/podman/podman.sock"
  if [ ! -S "$PODMAN_SOCK" ]; then
    echo "Starting podman socket..."
    systemctl --user start podman.socket
  fi

  OPTIONAL_MOUNTS=()
  PATH_ENTRIES=()

  if [[ -d /nix/store ]]; then
    OPTIONAL_MOUNTS+=(-v "/nix/store:/nix/store:ro")
  fi

  if [[ -d /nix/var/nix ]]; then
    OPTIONAL_MOUNTS+=(-v "/nix/var/nix:/nix/var/nix")
  fi

  USER_NIX_PROFILE=""
  for candidate in "$HOME/.nix-profile" "$HOME/.local/state/nix/profiles/profile" "/home/$USER/.nix-profile" "/var/home/$USER/.nix-profile" "/nix/profile"; do
    if [[ -d "$candidate" ]]; then
      USER_NIX_PROFILE=$(realpath "$candidate")
      break
    fi
  done

  if [[ -n "$USER_NIX_PROFILE" ]]; then
    OPTIONAL_MOUNTS+=(-v "$USER_NIX_PROFILE:$USER_NIX_PROFILE:ro")

    if [[ "$USER_NIX_PROFILE" == /oldroot/* ]]; then
      HOST_USER_NIX_PROFILE="${USER_NIX_PROFILE#/oldroot}"
      OPTIONAL_MOUNTS+=(-v "$HOST_USER_NIX_PROFILE:$USER_NIX_PROFILE:ro")
    fi

    PATH_ENTRIES+=("$USER_NIX_PROFILE/bin")

    if [[ "$USER_NIX_PROFILE" == /var/home/* ]]; then
      alt_path="/home${USER_NIX_PROFILE#/var/home}"
      OPTIONAL_MOUNTS+=(-v "$USER_NIX_PROFILE:$alt_path:ro")
    elif [[ "$USER_NIX_PROFILE" == /home/* ]]; then
      alt_path="/var/home${USER_NIX_PROFILE#/home}"
      OPTIONAL_MOUNTS+=(-v "$USER_NIX_PROFILE:$alt_path:ro")
    fi

    if [[ "$USER_NIX_PROFILE" == /var/nix/* ]]; then
      alt_nix="/nix${USER_NIX_PROFILE#/var/nix}"
      OPTIONAL_MOUNTS+=(-v "$USER_NIX_PROFILE:$alt_nix:ro")
    elif [[ "$USER_NIX_PROFILE" == /nix/* ]]; then
      alt_nix="/var/nix${USER_NIX_PROFILE#/nix}"
      OPTIONAL_MOUNTS+=(-v "$USER_NIX_PROFILE:$alt_nix:ro")
    fi
  fi

  if [[ -d /nix/var/nix/profiles/default ]]; then
    OPTIONAL_MOUNTS+=(-v "/nix/var/nix/profiles/default:/nix/profile:ro")
    PATH_ENTRIES+=("/nix/profile/bin")
  fi

  # mise (rtx) version manager support
  # Mount the installs directory directly since shims point to host paths
  MISE_INSTALLS_DIR="$HOME/.local/share/mise/installs"
  if [[ -d "$MISE_INSTALLS_DIR" ]]; then
    OPTIONAL_MOUNTS+=(-v "$MISE_INSTALLS_DIR:$MISE_INSTALLS_DIR:ro")
    # Add all tool bin directories to PATH
    for tool_bin in "$MISE_INSTALLS_DIR"/*//*/bin; do
      if [[ -d "$tool_bin" ]]; then
        PATH_ENTRIES+=("$tool_bin")
      fi
    done
  fi

  if [[ -f /etc/nix/nix.conf ]]; then
    OPTIONAL_MOUNTS+=(-v "/etc/nix/nix.conf:/etc/nix/nix.conf:ro")
  fi

  if [ -f "$HOME/.tmux.conf" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.tmux.conf:/home/$(whoami)/.tmux.conf:ro")
  fi
  if [ -d "$HOME/.config" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.config:/home/$(whoami)/.config:ro")
  fi
  if [ -d "$HOME/.claude" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.claude:/home/$(whoami)/.claude")
  fi
  if [ -d "$HOME/.qwen" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.qwen:/home/$(whoami)/.qwen")
  fi
  if [ -d "$HOME/.gnupg" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.gnupg:/home/$(whoami)/.gnupg")
  fi
  if [ -f "$HOME/.gitconfig" ]; then
    OPTIONAL_MOUNTS+=(-v "$HOME/.gitconfig:/home/$(whoami)/.gitconfig:ro")
  fi

  DEFAULT_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
  if [ ${#PATH_ENTRIES[@]} -gt 0 ]; then
    CUSTOM_PATH=$(
      IFS=:
      echo "${PATH_ENTRIES[*]}"
    )
    NIX_PATH="$CUSTOM_PATH:$DEFAULT_PATH"
  fi

  save_checksums

  run_with_spinner "Creating container (first run may take 30-60s for UID remapping)" \
    podman create \
    --name "$CONTAINER_NAME" \
    --hostname "$CONTAINER_NAME" \
    --userns=keep-id \
    --network=host \
    --security-opt label=disable \
    --security-opt no-new-privileges \
    --cap-drop=all \
    --read-only \
    --tmpfs /tmp --tmpfs /var/tmp \
    -v "$PODMAN_SOCK:$PODMAN_SOCK" \
    -e DOCKER_HOST=unix://"$PODMAN_SOCK" \
    -v "$PROJECT_DIR:/home/$(whoami)/$PROJECT_NAME" \
    -v "$PROJECT_DIR/.container-home/bash:/home/$(whoami)/.bash_history_dir" \
    -v "$PROJECT_DIR/.container-home/local:/home/$(whoami)/.local" \
    -v "$PROJECT_DIR/.container-home/cache:/home/$(whoami)/.cache" \
    -e HISTFILE="/home/$(whoami)/.bash_history_dir/.bash_history" \
    ${NIX_PATH:+"-e" "PATH=$NIX_PATH"} \
    "${OPTIONAL_MOUNTS[@]}" \
    -w "/home/$(whoami)/$PROJECT_NAME" \
    "$IMAGE_NAME" \
    sleep infinity

  podman start "$CONTAINER_NAME" >/dev/null
  podman wait --condition=running "$CONTAINER_NAME" >/dev/null

  # Fix .gnupg permissions if mounted
  if [ -d "$HOME/.gnupg" ]; then
    podman exec "$CONTAINER_NAME" chmod 0700 "/home/$(whoami)/.gnupg" 2>/dev/null || true
  fi

  # Fix direnv directory permissions
  podman exec "$CONTAINER_NAME" chown "$(whoami):$(whoami)" "/home/$(whoami)/.local/share/direnv" 2>/dev/null || true

  podman exec -it -w "/home/$(whoami)/$PROJECT_NAME" "$CONTAINER_NAME" /bin/bash
fi
