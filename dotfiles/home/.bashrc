export PATH="$PATH:$HOME/.local/bin:$HOME/.local/bin/scripts:$HOME/.local/share/nvim/mason/bin:/usr/local/bin"

if [[ $- == *i* ]]; then
  # only if interactive
  if command -v fish &>/dev/null && [[ $(ps -o comm= -p $PPID) != "fish" ]]; then
    # only when we're not already inside fish
    # prevent recursive shells
    fish -l
    # exit bash when exiting fish
    exit 0
  fi
  if command -v direnv &>/dev/null; then
    export DIRENV_LOG_FORMAT=
    eval "$(direnv hook bash)"
  fi

fi

NIX_DAEMON="/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh"
if [ -r "$NIX_DAEMON" ]; then
  source /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi
HM_SRC="$HOME/.nix-profile/etc/profile.d/hm-session-vars.sh"
if [ -r "$HM_SRC" ]; then
  source "$HM_SRC"
fi
CARGO_SRC="$HOME/.cargo/env"
if [ -r "$CARGO_SRC" ]; then
  source "$CARGO_SRC"
fi