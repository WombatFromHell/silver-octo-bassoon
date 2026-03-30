#!/usr/bin/env bash
# agent – A generic wrapper to run AI agents in a sandboxed environment.
# Usage: cd /your/project && agent [arguments passed to client]

set -euo pipefail

# ==============================================================================
# Configuration
# ==============================================================================

# Sandbox home directory (can be overridden via JAILED_HOME environment variable)
# Example: export JAILED_HOME="$HOME/.jail"
readonly SANDBOX_HOME="${JAILED_HOME:-/tmp}"

# Tool configuration directories to search for in $HOME and bind mount.
# Formats: "source_dir_name" (e.g., ".qwen" binds $HOME/.qwen -> $SANDBOX_HOME/.qwen)
readonly TOOL_CONFIG_DIRS=(
  ".qwen"
  ".gemini"
  # Add other tools here as needed, e.g.:
  # ".config/claude"
)

# Environment variables for custom bind mounts:
#   JAILED_BIND_MOUNTS_RO  - Read-only mounts (format: "src:dst" or "src:dst,src2:dst2")
#   JAILED_BIND_MOUNTS_RW  - Read-write mounts (format: "src:dst" or "src:dst,src2:dst2")
# Example:
#   export JAILED_BIND_MOUNTS_RO="/etc/myconfig:/etc/myconfig,/usr/share/data:/data"
#   export JAILED_BIND_MOUNTS_RW="$HOME/projects:/projects,/var/run/docker.sock:/var/run/docker.sock"

# ==============================================================================
# Utilities
# ==============================================================================

log_info() { echo "[agent] $*"; }
log_err() { echo "[agent] Error: $*" >&2; }

die() {
  log_err "$@"
  exit 1
}

# Checks if a command exists
command_exists() {
  command -v "$1" &>/dev/null
}

# ==============================================================================
# Setup Functions
# ==============================================================================

# Verify environment safety and dependencies
check_prerequisites() {
  if [[ "$PWD" == "$HOME" ]]; then
    die "Refusing to run sandbox in \$HOME. 'cd' into a project directory first."
  fi

  if ! command_exists bwrap; then
    die "'bwrap' (bubblewrap) not found. Install it to use the sandbox."
  fi
}

# Detects Linuxbrew installation and returns real path
# Output: "real_path" (e.g., /home/linuxbrew/.linuxbrew)
find_homebrew() {
  local candidates=(
    "/home/linuxbrew/.linuxbrew"
    "/var/home/linuxbrew/.linuxbrew"
    "/linuxbrew/.linuxbrew"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      realpath "$dir"
      return 0
    fi
  done
}

# Builds arguments for Homebrew (handling /home vs /var/home symlink issues)
# Args: $1 = real_homebrew_path
build_homebrew_args() {
  local prefix="$1"
  local args=()

  if [[ -z "$prefix" ]]; then
    echo ""
    return
  fi

  # Always bind the real prefix path
  args+=(--ro-bind "$prefix" "$prefix")

  # Handle Fedora Silverblue /home -> /var/home symlink mapping
  # This ensures binaries with hardcoded RPATHs work regardless of how they reference home
  if [[ "$prefix" == /var/home/* ]]; then
    local alt_path="/home${prefix#/var/home}"
    args+=(--ro-bind "$prefix" "$alt_path")
  elif [[ "$prefix" == /home/* ]]; then
    # If real path is /home, bind to /var/home just in case
    local alt_path="/var/home${prefix#/home}"
    args+=(--ro-bind "$prefix" "$alt_path")
  fi

  printf '%s\n' "${args[@]}"
}

# Detects Nix profile path
find_nix_profile() {
  local candidates=(
    "$HOME/.nix-profile"
    "/home/$USER/.nix-profile"
    "/var/home/$USER/.nix-profile"
    "/nix/profile"
  )

  for dir in "${candidates[@]}"; do
    if [[ -d "$dir" ]]; then
      realpath "$dir"
      return 0
    fi
  done
}

# Builds arguments for Nix profile
# Args: $1 = nix_profile_path
build_nix_args() {
  local profile="$1"

  if [[ -z "$profile" ]]; then
    echo ""
    return
  fi

  # Handle nested bwrap environments (/oldroot prefix)
  if [[ "$profile" == /oldroot/* ]]; then
    echo "--ro-bind /oldroot${profile#/oldroot} $profile"
  else
    echo "--ro-bind $profile $profile"
  fi
}

# Resolves the current working directory source path for bind mounting
# Returns: "source_path"
resolve_pwd_source() {
  if [[ "$PWD" == /oldroot/* ]]; then
    # Nested bwrap: strip prefix, resolve, add back
    local stripped="${PWD#/oldroot}"
    realpath -m "$stripped" 2>/dev/null || echo "$stripped"
  else
    realpath -m "$PWD" 2>/dev/null || echo "$PWD"
  fi
}

# Builds arguments for tool configuration directories (e.g., ~/.qwen, ~/.gemini)
build_tool_config_args() {
  local args=()
  local src_path

  for dir_name in "${TOOL_CONFIG_DIRS[@]}"; do
    # Check standard location
    if [[ -d "$HOME/$dir_name" ]]; then
      src_path=$(realpath "$HOME/$dir_name")
    # Check for nested bwrap /oldroot prefix
    elif [[ "$HOME" == /oldroot/* && -d "${HOME#/oldroot}/$dir_name" ]]; then
      src_path=$(realpath "${HOME#/oldroot}/$dir_name")
    else
      continue
    fi

    # Mount config dir into the sandbox's HOME
    # Note: This is applied AFTER --tmpfs /tmp in the final command
    args+=(--bind-try "$src_path" "$SANDBOX_HOME/$dir_name")
  done

  printf '%s\n' "${args[@]}"
}

# Parses bind mount environment variable and adds to bwrap args
# Args: $1 = env var value, $2 = mount type ("ro" or "rw")
# Format: "src:dst,src2:dst2"
build_custom_bind_args() {
  local mounts="$1"
  local mount_type="$2"
  local args=()

  if [[ -z "$mounts" ]]; then
    printf '%s\n' "${args[@]}"
    return
  fi

  # Split by comma
  IFS=',' read -ra mount_pairs <<< "$mounts"
  for pair in "${mount_pairs[@]}"; do
    # Skip empty entries
    [[ -z "$pair" ]] && continue

    # Split by colon
    IFS=':' read -r src dst <<< "$pair"

    # Validate both source and destination are present
    if [[ -z "$src" || -z "$dst" ]]; then
      log_err "Invalid bind mount format: '$pair' (expected 'src:dst')"
      continue
    fi

    # Expand tilde in source path
    if [[ "$src" == ~* ]]; then
      src="${src/#\~/$HOME}"
    fi

    # Check source exists (warn but continue if not)
    if [[ ! -e "$src" ]]; then
      log_err "Bind mount source does not exist: '$src'"
      continue
    fi

    if [[ "$mount_type" == "ro" ]]; then
      args+=(--ro-bind "$src" "$dst")
    else
      args+=(--bind "$src" "$dst")
    fi
  done

  printf '%s\n' "${args[@]}"
}

# ==============================================================================
# Main Execution
# ==============================================================================

main() {
  check_prerequisites

  # 1. Resolve Paths
  local homebrew_prefix nix_profile pwd_source
  homebrew_prefix=$(find_homebrew)
  nix_profile=$(find_nix_profile)
  pwd_source=$(resolve_pwd_source)

  # 2. Build Bwrap Arguments
  local bwrap_args=()

  # -- Base System Sandbox --
  bwrap_args+=(
    --unshare-all
    --share-net
    --die-with-parent
    --new-session
    --ro-bind /usr/bin /usr/bin
    --ro-bind /usr/lib /usr/lib
    --ro-bind-try /usr/lib64 /usr/lib64
    --ro-bind /lib64 /lib64
    --symlink usr/lib /lib
    --ro-bind /etc/passwd /etc/passwd
    --ro-bind /etc/group /etc/group
    --ro-bind /etc/resolv.conf /etc/resolv.conf
    --ro-bind /etc/hosts /etc/hosts
    --ro-bind /etc/ssl /etc/ssl
    --ro-bind-try /etc/pki /etc/pki
    --proc /proc
    --dev /dev
  )

  # -- Project Directory --
  bwrap_args+=(--bind-try "$pwd_source" "$PWD")

  # -- Nix Store (Static) --
  if [[ -d /nix/store ]]; then
    bwrap_args+=(--ro-bind /nix/store /nix/store)
  fi

  # -- Homebrew (Dynamic) --
  if [[ -n "$homebrew_prefix" ]]; then
    # shellcheck disable=SC2207
    local homebrew_args=($(build_homebrew_args "$homebrew_prefix"))
    bwrap_args+=("${homebrew_args[@]}")
  fi

  # -- Nix Profile (Dynamic) --
  if [[ -n "$nix_profile" ]]; then
    # shellcheck disable=SC2207
    local nix_args=($(build_nix_args "$nix_profile"))
    bwrap_args+=("${nix_args[@]}")
  fi

  # -- Sandbox Home & Tool Configs --
  bwrap_args+=(--tmpfs "$SANDBOX_HOME")

  # Mount tool configs (qwen, gemini, etc.)
  # shellcheck disable=SC2207
  local tool_args=($(build_tool_config_args))
  bwrap_args+=("${tool_args[@]}")

  # -- Custom Bind Mounts (from environment variables) --
  # shellcheck disable=SC2207
  local ro_mounts=($(build_custom_bind_args "${JAILED_BIND_MOUNTS_RO:-}" "ro"))
  bwrap_args+=("${ro_mounts[@]}")

  # shellcheck disable=SC2207
  local rw_mounts=($(build_custom_bind_args "${JAILED_BIND_MOUNTS_RW:-}" "rw"))
  bwrap_args+=("${rw_mounts[@]}")

  # -- Environment Variables --
  local path_env="/usr/bin:/bin"
  [[ -n "$nix_profile" ]] && path_env="$nix_profile/bin:$path_env"
  [[ -n "$homebrew_prefix" ]] && path_env="$homebrew_prefix/bin:$path_env"

  bwrap_args+=(
    --setenv HOME "$SANDBOX_HOME"
    --setenv PATH "$path_env"
  )

  # Set SSL certificate paths for Python/urllib (fixes CERTIFICATE_VERIFY_FAILED)
  if [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
    bwrap_args+=(--setenv SSL_CERT_FILE /etc/pki/tls/certs/ca-bundle.crt)
  fi
  if [[ -d /etc/pki/tls/certs ]]; then
    bwrap_args+=(--setenv SSL_CERT_DIR /etc/pki/tls/certs)
  fi

  # Set NODE_PATH for Homebrew Node modules if present
  if [[ -n "$homebrew_prefix" && -d "$homebrew_prefix/lib/node_modules" ]]; then
    bwrap_args+=(--setenv NODE_PATH "$homebrew_prefix/lib/node_modules")
  fi

  # 3. Execute
  exec bwrap "${bwrap_args[@]}" "$@"
}

main "$@"
