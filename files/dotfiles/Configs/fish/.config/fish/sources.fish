set CREDS_FISH_SRC $HOME/.config/fish/creds.fish
if test -r "$CREDS_FISH_SRC"
    source "$CREDS_FISH_SRC"
end

set ARCHIVE_HELPER $HOME/.config/fish/archiver.fish
if test -r $ARCHIVE_HELPER
    source $ARCHIVE_HELPER
end

set WORKTREES_HELPER $HOME/.config/fish/worktrees.fish
if test -r $WORKTREES_HELPER
    source $WORKTREES_HELPER
end

# include pwd abbreviation helper
set PWD_HELPER $HOME/.config/fish/pwd.fish
if test -r $PWD_HELPER
    source $PWD_HELPER
end

set TMUX_HELPER $HOME/.config/fish/tmux.fish
if test -r $TMUX_HELPER
    source $TMUX_HELPER
end

set ZELLIJ_HELPER $HOME/.config/fish/zellij.fish
if test -r $ZELLIJ_HELPER
    source $ZELLIJ_HELPER
end

set TRASH_FISH_SRC $HOME/.config/fish/trash.fish
if test -r "$TRASH_FISH_SRC"
    source "$TRASH_FISH_SRC"
end

if command -q nix
    set -x FLAKE_ROOT "$HOME/.config/flakeroot"
    if command -q nh
        set -x NH_FLAKE "$FLAKE_ROOT"
    end

    set NIX_DAEMON_FISH_SRC /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
    if test -r "$NIX_DAEMON_FISH_SRC"
        source "$NIX_DAEMON_FISH_SRC"
    end
    set NIX_SESSION_VARS $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
    if test -r "$NIX_SESSION_VARS"
        fenv source "$NIX_SESSION_VARS"
    end
end

set CATPPUCCIN_MOCHA_FISH_SRC $HOME/.config/fish/catppuccin-fzf-mocha.fish
if test -r "$CATPPUCCIN_MOCHA_FISH_SRC"
    source "$CATPPUCCIN_MOCHA_FISH_SRC"
end

set SYS_FZF_HELPER $HOME/.config/fish/sysz_fzf.fish
if test -r $SYS_FZF_HELPER; and command -q fzf
    source $SYS_FZF_HELPER
end

set ALIASES_FISH_SRC $HOME/.config/fish/aliases.fish
if test -r "$ALIASES_FISH_SRC"
    source "$ALIASES_FISH_SRC"
end

if command -q atuin
    atuin init fish --disable-up-arrow | source
end
if command -q zoxide
    zoxide init fish | source
    alias cd="z"
end

if command -q direnv
    direnv hook fish | source
end

# keep this at the bottom
if command -q starship
    starship init fish | source
end
