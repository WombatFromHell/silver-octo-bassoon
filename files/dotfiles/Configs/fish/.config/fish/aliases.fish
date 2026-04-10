if command -q nix
    set _host (hostname)
    set NIX_FLAKE_OS_ROOT $HOME/.nix
    set FLAKE_ROOT "$NIX_FLAKE_OS_ROOT#$_host"
    alias nixconf='$EDITOR $NIX_FLAKE_OS_ROOT'
    #
    alias hmb='nh home build --dry $FLAKE_ROOT'
    alias hms='nh home switch $FLAKE_ROOT'
    alias hcu='nh clean user'
    alias hca='nh clean all'
    #
    alias hmnix='nix run home-manager/master -- init'
    alias hmls='home-manager generations'
    alias hmrm='home-manager remove-generations'
    #
    alias nhb='nh os build --dry $FLAKE_ROOT'
    alias nhs='nh os switch $FLAKE_ROOT'
    alias nls='nh os info'
    alias nrb='nh os rollback'
    #
    alias drb='nh darwin build --dry-run $FLAKE_ROOT'
    alias drs='nh darwin switch $FLAKE_ROOT'
    alias drbls='sudo darwin-rebuild --list-generations'
    alias drbrm='sudo nix-env -p /nix/var/nix/profiles/system --delete-generations'
    #
    alias nix_hist='sudo -i nix profile history --profile /nix/var/nix/profiles/system'
    alias nix_rb='sudo -i nix profile rollback --profile /nix/var/nix/profile/system'
    alias nix_act='sudo /nix/var/nix/profile/system/bin/switch-to-configuration switch'
    alias nix_roots='nix-store --gc --print-roots'
    #
    alias nixopt='nix_collect_garbage'
    alias nixopts='nix_collect_garbage --sudo'
end

if command -q eza
    set -g EZA_STANDARD_OPTIONS --group --header --group-directories-first --icons --color=auto -A
    alias l="eza $EZA_STANDARD_OPTIONS"
    alias la="eza $EZA_STANDARD_OPTIONS --all"
    alias ll="eza $EZA_STANDARD_OPTIONS --long"
    alias ls="eza $EZA_STANDARD_OPTIONS"
    alias lt="eza $EZA_STANDARD_OPTIONS --tree"
    alias llt="eza $EZA_STANDARD_OPTIONS --long --tree"
    alias treed="eza $EZA_STANDARD_OPTIONS -DTA"
    alias tree="eza $EZA_STANDARD_OPTIONS -TA"
    alias treei="eza $EZA_STANDARD_OPTIONS -TA --git-ignore"
end

# rsync shortcuts
if command -q rsync
    alias _rsync='rsync -avL --partial --update'
    alias _rsyncd='_rsync --dry-run'
    alias rsud='_rsync --delete'
    alias rsud_d='_rsyncd --delete'
    alias rsu='_rsync'
    alias rsu_d='_rsyncd'
    alias rsfd='_rsync --delete --exclude="*/"'
    alias rsfd_d='_rsyncd --delete --exclude="*/"'
    alias rsf='_rsync --exclude="*/"'
    alias rsf_d='_rsyncd --exclude="*/"'
end

if command -q cachyos-rate-mirrors
    alias reflect='sudo cachyos-rate-mirrors --sync-check --country "US"'
end

if command -q tmux
    alias update_tmux='~/.config/tmux/plugins/tpm/bin/update_plugins all'
end

if command -q khal
    alias khall='khal list --format '{start-time}-{end-time}-{start}-{end}-{title}' now 7d'
    alias khalm='khal list --format '{start-time}-{end-time}-{start}-{end}-{title}' now 30d'
end

if command -q bat
    alias cat='bat'
    alias ccat='cat -pP'
end

alias vi='$EDITOR'
alias vim='$EDITOR'
alias lg='lazygit'
alias lpod='lazydocker'
alias yz='yazi'
alias edit='$EDITOR'
alias sedit='sudo -E $EDITOR'
alias mkdir='mkdir -pv'
alias sudoe='sudo -E env PATH=$PATH'

alias update-kitty='curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin installer=nightly'
alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'
alias kclear="printf '\033[2J\033[3J\033[1;1H'"
