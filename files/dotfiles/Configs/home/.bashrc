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

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=

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

# run only in interactive terminal mode
if [[ $- == *i* ]]; then
  # Check if fish is available and we're not already inside it
  if command -v fish &>/dev/null; then
    # Safely get parent process name, fallback to empty string on failure
    _parent_cmd=$(ps -p "$PPID" -o comm= 2>/dev/null || true)
    # Only attempt exec if NOT in tmux/zellij and parent isn't fish
    if [[ -z "$TMUX" && -z "$ZELLIJ" && "$_parent_cmd" != "fish" ]]; then
      exec fish -l
    else
      export SHELL_INDICATOR="bash"
    fi
  fi
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
  #
  alias lg='lazygit'
  alias yz='yazi'
  if command -v bat &>/dev/null; then
    alias cat='bat'
    alias ccat='bat -pP'
  fi
  alias mkdir='mkdir -pv'
  alias tma='tmux attach-session -t "main"'
  alias tmls='tmux ls'
  #
  alias _rsync='rsync -avL --partial --update'
  alias _rsyncd='_rsync --dry-run'
  alias rsud='_rsync --delete'
  alias rsud_d='_rsyncd --delete'
  alias rsu='_rsync'
  alias rsu_d='_rsyncd'
  #
  _NIX_FLAKE_ROOT="$HOME/.nix"
  _HOST=$(hostname)
  _HMPATH=$(realpath "$_NIX_FLAKE_ROOT")
  _HMSUF="--flake $_HMPATH#$_HOST"
  alias _hmnix='nix run home-manager/master -- init'
  alias hmb='home-manager build --dry-run $_HMSUF'
  alias hms='home-manager switch $_HMSUF'
  alias hmls='home-manager generations'
  alias hmrm='home-manager remove-generations'
  #
  alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
  alias nixopt='nix-store --gc && nix-store --optimize'
  #
  alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'

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
  #
  if command -v starship &>/dev/null; then
    # Save preexec framework state
    _starship_saved_preexec="${preexec_functions[*]-}"
    _starship_saved_precmd="${precmd_functions[*]-}"
    _starship_saved_imported="${bash_preexec_imported-}${__bp_imported-}"
    # Force starship into native PROMPT_COMMAND/PS0 mode
    unset preexec_functions precmd_functions bash_preexec_imported __bp_imported
    eval "$(starship init bash)"
    # Restore framework state for other tools (atuin, ble.sh, etc.)
    [[ -n "$_starship_saved_preexec" ]] && preexec_functions=("$_starship_saved_preexec")
    [[ -n "$_starship_saved_precmd" ]] && precmd_functions=("$_starship_saved_precmd")
    [[ -n "$_starship_saved_imported" ]] && bash_preexec_imported=1
    # Clean up temp vars
    unset _starship_saved_preexec _starship_saved_precmd _starship_saved_imported
  fi
fi
