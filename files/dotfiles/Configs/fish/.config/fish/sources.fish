set TMUX_HELPER $HOME/.config/fish/tmux.fish
if test -f $TMUX_HELPER
    source $TMUX_HELPER
end

set ZELLIJ_HELPER $HOME/.config/fish/zellij.fish
if test -f $ZELLIJ_HELPER
    source $ZELLIJ_HELPER
end

set ARCHIVE_HELPER $HOME/.config/fish/archiver.fish
if test -f $ARCHIVE_HELPER
    source $ARCHIVE_HELPER
end

set WORKTREES_HELPER $HOME/.config/fish/worktrees.fish
if test -f $WORKTREES_HELPER
    source $WORKTREES_HELPER
end

# include pwd abbreviation helper
set PWD_HELPER $HOME/.config/fish/pwd.fish
if test -f $PWD_HELPER
    source $PWD_HELPER
end

set ALIASES_FISH_SRC "$HOME/.config/fish/aliases.fish"
if test -r "$ALIASES_FISH_SRC"
    source "$ALIASES_FISH_SRC"
end

set TRASH_FISH_SRC $HOME/.config/fish/trash.fish
if test -r "$TRASH_FISH_SRC"
    source "$TRASH_FISH_SRC"
end

set NIX_DAEMON_FISH_SRC /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
if test -r "$NIX_DAEMON_FISH_SRC"
    source "$NIX_DAEMON_FISH_SRC"
end
set NIX_SESSION_VARS $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
if test -r "$NIX_SESSION_VARS"
    fenv source "$NIX_SESSION_VARS"
end

set CATPPUCCIN_MOCHA_FISH_SRC "$HOME/.config/fish/catppuccin-fzf-mocha.fish"
if test -r "$CATPPUCCIN_MOCHA_FISH_SRC"
    source "$CATPPUCCIN_MOCHA_FISH_SRC"
end

set SYS_FZF_HELPER $HOME/.config/fish/sysz_fzf.fish
if test -f $SYS_FZF_HELPER; and command -q fzf
    source $SYS_FZF_HELPER
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
