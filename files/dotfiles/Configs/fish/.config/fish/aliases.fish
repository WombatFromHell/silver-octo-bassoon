if command -q nix
    set NIX_FLAKE_OS_ROOT $HOME/.nix
    alias nixconf='$EDITOR $NIX_FLAKE_OS_ROOT'
    #
    set _host (hostname)
    alias _nhos='nh os switch -H $_host'
    alias nhu='_nhos $NIX_FLAKE_OS_ROOT'
    alias nhb='nh os build -H $_host --dry $NIX_FLAKE_OS_ROOT'
    alias nhuu='_nh -u $NIX_FLAKE_OS_ROOT'
    alias nhc='nh_clean'
    alias nls='sudo nixos-rebuild list-generations'
    alias nrbb='sudo nixos-rebuild boot --flake $NIX_FLAKE_OS_ROOT#$_host'
    alias nrrb='sudo nixos-rebuild switch --rollback'
    alias ncg='sudo nix-collect-garbage'
    #
    set _hmpath (realpath $NIX_FLAKE_OS_ROOT)
    set _hmsuf --flake $_hmpath#$_host
    alias _hmnix='nix run home-manager/master -- init'
    alias hmb='home-manager build --dry-run $_hmsuf'
    alias hms='home-manager switch $_hmsuf'
    alias hmls='home-manager generations'
    alias hmrm='home-manager remove-generations'
    #
    alias drbu='sudo darwin-rebuild switch --flake $NIX_FLAKE_OS_ROOT#$_host'
    alias drbb='sudo darwin-rebuild build --dry-run --flake $NIX_FLAKE_OS_ROOT#$_host'
    alias drbls='sudo darwin-rebuild --list-generations'
    alias drbrm='sudo nix-env -p /nix/var/nix/profiles/system --delete-generations'
    #
    alias nix_hist='sudo nix profile history --profile /nix/var/nix/profiles/system'
    alias nix_rb='sudo nix profile rollback --profile /nix/var/nix/profile/system'
    alias nix_act='sudo /nix/var/nix/profile/system/bin/switch-to-configuration switch'
    alias nix_roots='nix-store --gc --print-roots'
    #
    alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
    alias nixopt='nix-store --gc && nix-store --optimize'
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
alias sudoe='sudo -E env PATH=(string join ':' $PATH)'

alias update-kitty='curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin installer=nightly'
alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'
alias kclear="printf '\033[2J\033[3J\033[1;1H'"
