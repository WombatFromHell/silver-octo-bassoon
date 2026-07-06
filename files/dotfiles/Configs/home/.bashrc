# Source global definitions
if [ -f /etc/bashrc ]; then
  . /etc/bashrc
fi

# User specific environment
if [[ ":$PATH:" != *":$HOME/.local/bin:$HOME/bin:"* ]]; then
  PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

# --- Functions -------------------------------------------------------------

# Yazi file manager: cd into last directory on exit
yy() {
  local tmp
  tmp=$(mktemp -t "yazi-cwd.XXXXXX")
  env YAZI_NO_SESSION=1 yazi "$@" --cwd-file="$tmp"
  if [[ $(cat "$tmp") =~ ([^\n]+) ]] && [ -n "${BASH_REMATCH[1]}" ] && [ "${BASH_REMATCH[1]}" != "$PWD" ]; then
    cd "${BASH_REMATCH[1]}" || exit 1
  fi
  rm -f "$tmp"
}

# Yazi without session integration
yz() {
  if [ $# -eq 0 ]; then
    command yazi
  else
    command env YAZI_NO_SESSION=1 yazi "$@"
  fi
}

# sudo that preserves PATH, including the Nix profile
sudoe() {
  local new_path="$HOME/.nix-profile/bin"
  local dir path_dirs
  IFS=':' read -ra path_dirs <<<"$PATH"
  for dir in "${path_dirs[@]}"; do
    [[ ":$new_path:" != *":$dir:"* ]] && new_path="$new_path:$dir"
  done
  sudo -E env PATH="$new_path" "$@"
}

# Attach to (or create) a tmux session, defaulting to "main"
tma() {
  local session="${1:-main}"
  tmux new-session -d -s "$session" 2>/dev/null
  if [ -n "$TMUX" ]; then
    tmux switch-client -t "$session"
  else
    tmux attach -t "$session"
    exit
  fi
}

# --- Everything below only matters for interactive shells -----------------
if [[ $- == *i* ]]; then
  # Shell handoff: prefer fish, but never re-exec into it from inside fish,
  # tmux, or zellij (those already own the terminal / would loop).
  if [ -z "$ZED_TERM" ] && [ -z "$TMUX" ] && [ -z "$ZELLIJ" ] && command -v fish &>/dev/null; then
    # ponytail: the `ps` call costs a fork+exec on every shell start. If startup
    # latency matters more than portability, set `shell fish` in kitty.conf
    # instead and delete this block entirely.
    if [ "$(ps -p "$PPID" -o comm=)" != "fish" ]; then
      exec fish -l
    else
      export SHELL_INDICATOR="bash"
    fi
  fi

  # Tool hooks (order matters: starship must init last to own the prompt)
  if command -v direnv &>/dev/null && [ -z "$ZED_TERM" ]; then
    export DIRENV_LOG_FORMAT=
    eval "$(direnv hook bash)"
  fi

  if command -v zoxide &>/dev/null; then
    eval "$(zoxide init bash)"
    alias cd='z'
  fi

  if command -v atuin &>/dev/null; then
    eval "$(atuin init bash --disable-up-arrow)"
  fi

  if command -v starship &>/dev/null; then
    eval "$(starship init bash)"
    PROMPT_COMMAND="starship_precmd"
  fi

  # Aliases
  if command -v eza &>/dev/null; then
    EZA_STANDARD_OPTIONS="--group --header --group-directories-first --icons --color=auto -A"
    alias l="eza \$EZA_STANDARD_OPTIONS"
    alias la="eza \$EZA_STANDARD_OPTIONS --all"
    alias ll="eza \$EZA_STANDARD_OPTIONS --long"
    alias ls="eza \$EZA_STANDARD_OPTIONS"
    alias lt="eza \$EZA_STANDARD_OPTIONS --tree"
    alias llt="eza \$EZA_STANDARD_OPTIONS --long --tree"
    alias tree="eza \$EZA_STANDARD_OPTIONS -TA -L 1"
    alias treed="eza \$EZA_STANDARD_OPTIONS -DTA -L 1"
  fi

  if command -v bat &>/dev/null; then
    alias cat='bat'
    alias ccat='bat -pP'
  fi

  alias lg='lazygit'
  alias mkdir='mkdir -pv'
  alias tmls='tmux ls'

  alias _rsync='rsync -avL --partial --update'
  alias rsu='_rsync'
  alias rsu_d='_rsync --dry-run'
  alias rsud='_rsync --delete'
  alias rsud_d='_rsync --dry-run --delete'

  if [ -d "$HOME/.nix" ]; then
    _HMSUF="--flake $(realpath "$HOME/.nix")#$(hostname)"
    alias _hmnix='nix run home-manager/master -- init'
    alias hmb="home-manager build --dry-run \$_HMSUF"
    alias hms="home-manager switch \$_HMSUF"
    alias hmls='home-manager generations'
    alias hmrm='home-manager remove-generations'
  fi

  alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
  alias nixopt='nix-store --gc && nix-store --optimize'
  alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'

fi
