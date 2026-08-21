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

if command -q mise
    alias mpi='PI_LOCAL_MODELS=1 mise run pi'
end

alias e='edit.sh'
alias edit='$EDITOR'
alias vi='$EDITOR'
alias vim='$EDITOR'
alias nv='$EDITOR'
alias lg='lazygit'
alias lpod='lazydocker'
alias mkdir='mkdir -pv'

alias update-kitty='curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin installer=nightly'
alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'
alias kclear="printf '\033[2J\033[3J\033[1;1H'"

alias reload='source $HOME/.config/fish/config.fish'
alias editconf='$EDITOR $HOME/.config/fish/'
