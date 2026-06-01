if command -q nix
    alias nixconf='$EDITOR $FLAKE_ROOT'
    #
    alias nhmb='nh home switch -n $FLAKE_ROOT'
    alias nhms='nh home switch $FLAKE_ROOT'
    alias nhmu='nh home switch -u $FLAKE_ROOT'
    alias nhcu='nh clean user'
    alias nhca='nh clean all'
    #
    alias hmb='home-manager build --flake $FLAKE_ROOT --dry-run'
    alias hms='home-manager switch --flake $FLAKE_ROOT'
    alias hmls='home-manager generations'
    alias hmrm='home-manager remove-generations'
    alias hmrb='home-manager switch --rollback'
    #
    alias nhb='nh os switch -n $FLAKE_ROOT'
    alias nhs='nh os switch $FLAKE_ROOT'
    alias nls='nh os info'
    alias nrb='nh os rollback'
    #
    alias drb='sudo darwin-rebuild build --flake $FLAKE_ROOT'
    alias drs='sudo darwin-rebuild switch --flake $FLAKE_ROOT'
    alias drls='sudo darwin-rebuild --list-generations'
    alias drrm='sudo nix-env -p /nix/var/nix/profiles/system --delete-generations'
    #
    alias nhdb='nh darwin switch -n $FLAKE_ROOT'
    alias nhds='nh darwin switch $FLAKE_ROOT'
    alias nhdls='drls'
    alias nhdrm='drrm'
    #
    alias nix_hist='sudo -i nix profile history --profile /nix/var/nix/profiles/system'
    alias nix_rb='sudo -i nix profile rollback --profile /nix/var/nix/profile/system'
    alias nix_act='sudo /nix/var/nix/profile/system/bin/switch-to-configuration switch'
    alias nix_roots='nix-store --gc --print-roots'
    alias nix_flake_paths='nix path-info --derivation --recursive'
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
    alias pcat='cat -P'
end

alias vi='$EDITOR'
alias vim='$EDITOR'
alias lg='lazygit'
alias lpod='lazydocker'
alias edit='$EDITOR'
alias sedit='sudo -E $EDITOR'
alias mkdir='mkdir -pv'

alias update-kitty='curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin installer=nightly'
alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'
alias kclear="printf '\033[2J\033[3J\033[1;1H'"

alias reload='source $HOME/.config/fish/config.fish'
alias editconf='$EDITOR $HOME/.config/fish/'
