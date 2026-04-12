# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
  . /etc/bashrc
fi

# User specific environment
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]; then
  PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

# User specific aliases and functions
if [ -d ~/.bashrc.d ]; then
  for rc in ~/.bashrc.d/*; do
    if [ -f "$rc" ]; then
      . "$rc"
    fi
  done
fi
unset rc

function yy() {
  tmp=$(mktemp -t "yazi-cwd.XXXXXX")
  env YAZI_NO_SESSION=1 yazi "$@" --cwd-file="$tmp"
  if [[ $(cat "$tmp") =~ ([^\n]+) ]] && [ -n "${BASH_REMATCH[1]}" ] && [ "${BASH_REMATCH[1]}" != "$PWD" ]; then
    cd "${BASH_REMATCH[1]}" || exit 1
  fi
  rm -f "$tmp"
}

function update_wayland_env_vars() {
  if [[ -n "$XDG_RUNTIME_DIR" ]]; then
    # Find the most recent niri socket (sorted by modification time)
    # NOTE: Use 'command ls' to bypass eza alias; unquoted glob for shell expansion
    local niri_socket
    niri_socket=$(command ls -t "$XDG_RUNTIME_DIR"/niri.*.sock 2>/dev/null | head -n1)
    if [[ -n "$niri_socket" ]]; then
      export NIRI_SOCKET="$niri_socket"

      # Extract WAYLAND_DISPLAY from the socket filename
      # Format: niri.{WAYLAND_DISPLAY}.{PID}.sock (e.g., niri.wayland-1.35831.sock)
      local filename
      filename=$(basename "$niri_socket")
      # Single regex: strip 'niri.' prefix, '.{PID}.sock' suffix, keep middle
      local display_name="${filename#niri.}"
      display_name="${display_name%.[0-9]*.sock}"

      if [[ -n "$display_name" && "$display_name" != "$filename" ]]; then
        export WAYLAND_DISPLAY="$display_name"
      fi
    fi
  fi
}

# run only in interactive terminal mode
if [[ $- == *i* ]]; then
  # Check if fish is available and we're not already inside it
  if command -v fish &>/dev/null; then
    _parent_cmd=$(ps -p "$PPID" -o comm= 2>/dev/null || true)
    if [[ -z "$TMUX" && -z "$ZELLIJ" && "$_parent_cmd" != "fish" ]]; then
      exec fish -l
    else
      export SHELL_INDICATOR="bash"
    fi
  fi

  # --- Tool initializations (order matters) ---
  update_wayland_env_vars

  if command -v direnv &>/dev/null; then
    export DIRENV_LOG_FORMAT=
    eval "$(direnv hook bash)"
  fi

  if command -v zoxide &>/dev/null; then
    eval "$(zoxide init bash)"
    alias cd="z"
  fi

  if command -v atuin &>/dev/null; then
    eval "$(atuin init bash --disable-up-arrow)"
  fi

  # Starship MUST be initialized LAST to own the prompt
  if command -v starship &>/dev/null; then
    eval "$(starship init bash)"
    # overriding any system/other tool prompt setup
    PROMPT_COMMAND="starship_precmd"
  fi

  # --- Aliases (after tool init) ---
  if command -v eza &>/dev/null; then
    EZA_STANDARD_OPTIONS="--group --header --group-directories-first --icons --color=auto -A"
    alias l='eza $EZA_STANDARD_OPTIONS'
    alias la='eza $EZA_STANDARD_OPTIONS --all'
    alias ll='eza $EZA_STANDARD_OPTIONS --long'
    alias ls='eza $EZA_STANDARD_OPTIONS'
    alias lt='eza $EZA_STANDARD_OPTIONS --tree'
    alias llt='eza $EZA_STANDARD_OPTIONS --long --tree'
    alias treed='eza $EZA_STANDARD_OPTIONS -DTA -L 1'
    alias tree='eza $EZA_STANDARD_OPTIONS -TA -L 1'
  fi

  alias lg='lazygit'
  alias yz='yazi'

  if command -v bat &>/dev/null; then
    alias cat='bat'
    alias ccat='bat -pP'
  fi

  alias mkdir='mkdir -pv'
  alias tmls='tmux ls'

  function tma() {
    # Update env vars BEFORE attaching so tmux captures the current values
    update_wayland_env_vars
    tmux attach-session -t "main"
  }

  alias _rsync='rsync -avL --partial --update'
  alias _rsyncd='_rsync --dry-run'
  alias rsud='_rsync --delete'
  alias rsud_d='_rsyncd --delete'
  alias rsu='_rsync'
  alias rsu_d='_rsyncd'

  _NIX_FLAKE_ROOT="$HOME/.nix"
  _HOST=$(hostname)
  _HMPATH=$(realpath "$_NIX_FLAKE_ROOT")
  _HMSUF="--flake $_HMPATH#$_HOST"
  alias _hmnix='nix run home-manager/master -- init'
  alias hmb='home-manager build --dry-run $_HMSUF'
  alias hms='home-manager switch $_HMSUF'
  alias hmls='home-manager generations'
  alias hmrm='home-manager remove-generations'

  alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
  alias nixopt='nix-store --gc && nix-store --optimize'

  alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'

  function sudoe() {
    local nix_path="$HOME/.nix-profile/bin"
    local new_path="$nix_path"
    IFS=':' read -ra path_dirs <<<"$PATH"
    for dir in "${path_dirs[@]}"; do
      if [[ ":$new_path:" != *":$dir:"* ]]; then
        new_path="$new_path:$dir"
      fi
    done
    sudo -E env PATH="$new_path" "$@"
  }
fi
