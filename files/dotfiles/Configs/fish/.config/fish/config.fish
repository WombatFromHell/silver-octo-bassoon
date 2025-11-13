# if test -f $HOME/.profile
#     fenv "source $HOME/.profile"
# end

function update_fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher update
end

if status is-interactive && ! functions -q fisher
    update_fisher
end

# include our home-grown tmux helper
source $HOME/.config/fish/tmux2.fish

if status is-interactive
    set -Ux fish_greeting # disable initial fish greeting

    # respect system file descriptor limits
    ulimit -n (ulimit -Hn)

    # Commands to run in interactive sessions can go here
    function fish_title
        # Get the current working directory
        set current_dir (prompt_pwd --dir-length 2 --full-length-dirs=1)
        # Get the username and hostname
        set user_host (whoami)@(hostname)
        # Combine them to form the desired title
        echo "$user_host:$current_dir"
    end

    if command -q zoxide
        zoxide init fish | source
        alias cd='z'
    end
    if command -q direnv
        set -x DIRENV_LOG_FORMAT ""
        direnv hook fish | source
    end

    set -l cargo_fish_path "$HOME/.cargo/env.fish"
    if test -f "$cargo_fish_path"
        source "$cargo_fish_path"
    end
    set -gx SHELL $(command -v fish.sh || command -v fish)
end

function yy
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    yazi $argv --cwd-file="$tmp"
    if set cwd (cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
        cd -- "$cwd"
    end
    rm -f -- "$tmp"
end

function to_clip
    $argv 2>&1 | tee /dev/tty | wl-copy
end

function custom_snap
    set -q argv[2]; or set argv[2] root
    set -q argv[1]; and test -n "$argv[1]"; or set argv[1] "hard snapshot"
    snapper -c "$argv[2]" create -c important --description "$argv[1]"
end
function custom_snap_clean
    set -q $argv[2]; or set $argv[2] timeline
    snapper -c "$argv[1]" cleanup "$argv[2]"
end
function snap_root
    custom_snap "$argv[1]" root
end
function snap_home
    custom_snap "$argv[1]" home
end
function snap_quick
    if set -q argv[1]; and test -n "$argv[1]"
        snap_root "$argv[1]"
        snap_home "$argv[1]"
    else
        snap_root
        snap_home
    end
end
function snap_ls
    snapper -c root ls && echo
    snapper -c home ls
end
function snap_clean_quick
    custom_snap_clean root
    custom_snap_clean home
end
function snap_clean_full
    custom_snap_clean root number
    custom_snap_clean home number
end

function set_editor
    if command -s nvim >/dev/null
        set -gx EDITOR nvim
        set -gx VISUAL nvim
    else if command -s nano >/dev/null
        set -gx EDITOR nano
        set -gx VISUAL nano
    else
        set --erase EDITOR ^/dev/null
        set --erase VISUAL ^/dev/null
    end
end

function setup_podman_sock
    if test -r "$XDG_RUNTIME_DIR"/podman/podman.sock
        set -Ux DOCKER_HOST unix:///run/user/$(id -u)/podman/podman.sock
    end
end

function nh_clean
    set cmd "nh clean all --ask"
    set args_provided 0

    # Iterate over all arguments to check for relevant flags
    for arg in $argv
        if contains -- -k --keep -K --keep-since $arg
            set args_provided 1
            break
        end
    end

    # Provide a default if no relevant args were provided
    if test $args_provided -eq 0
        set cmd "$cmd -k 3 -K 24h"
    end

    set cmd $cmd $argv
    eval $cmd
end

# Helper: Validate compressor and return full command with flags for best perf/compression
function _tarchk
    set -l comp (test -n "$argv[1]"; and echo $argv[1]; or echo pigz)

    switch $comp
        case pigz
            command -q pigz; or return 1
            set -g _tarchk_result pigz -9 --processes 0
        case zstd
            command -q zstd; or return 1
            set -g _tarchk_result zstd -15 --long=28 --threads=0
        case '*'
            echo "Error: unsupported compressor '$comp'" >&2
            return 1
    end
end

function _use_pv
    if command -q pv
        # Calculate total size of all paths passed as arguments
        set size (du -sb $argv 2>/dev/null | awk '{s+=$1} END{print s+0}')

        if test $size -gt 0
            pv -s $size -w 80 -B 1M
        else
            cat
        end
    else
        cat # pass-through if pv not installed
    end
end

function tarc
    if test (count $argv) -lt 3
        echo "Usage: tarc COMPRESSOR [TAR_OPTIONS...] OUTPUT_FILE PATHS..." >&2
        return 1
    end

    _tarchk $argv[1]; or return 1
    set comp_cmd $_tarchk_result
    set argv $argv[2..-1]

    # Find first non-option argument → output file
    set outfile_idx 0
    for i in (seq (count $argv))
        if not string match -q -- '-*' $argv[$i]
            set outfile_idx $i
            set outfile $argv[$i]
            break
        end
    end

    if test $outfile_idx -eq 0
        echo "Error: No output file specified" >&2
        return 1
    end

    # Extract tar options (only if they exist before outfile)
    set opts
    if test $outfile_idx -gt 1
        set opts $argv[1..(math $outfile_idx - 1)]
    end

    # Paths to archive (after outfile)
    set paths $argv[(math $outfile_idx + 1)..-1]
    if test (count $paths) -eq 0
        echo "Error: No paths to archive" >&2
        return 1
    end

    mkdir -p (dirname -- $outfile)
    tar $opts -cf - $paths | _use_pv $paths | $comp_cmd >$outfile
end

# Decompress: tarx COMPRESSOR ARCHIVE [TAR_EXTRA_ARGS...]
function tarx
    if test (count $argv) -lt 2
        echo "Usage: tarx COMPRESSOR ARCHIVE [TAR_ARGS...]" >&2
        return 1
    end

    set comp_cmd (_tarchk $argv[1]); or return 1
    set archive $argv[2]
    set tar_args $argv[3..-1]

    # Extract base compressor name for switch
    set comp_name (string split ' ' $comp_cmd)[1]
    set comp_name (basename $comp_name)

    # Decompress → pv → tar
    switch $comp_name
        case pigz gzip
            pigz -dc $archive | pv | tar -xvf - $tar_args
        case zstd
            zstd -dc $archive | pv | tar -xvf - $tar_args
        case '*'
            echo "Internal error: unknown compressor '$comp_name'" >&2
            return 1
    end
end

# List contents: tarv COMPRESSOR ARCHIVE
function tarv
    if test (count $argv) -ne 2
        echo "Usage: tarv COMPRESSOR ARCHIVE" >&2
        return 1
    end

    set comp_cmd (_tarchk $argv[1]); or return 1
    set archive $argv[2]

    set comp_name (string split ' ' $comp_cmd)[1]
    set comp_name (basename $comp_name)

    switch $comp_name
        case pigz gzip
            pigz -dc $archive | tar -tvf -
        case zstd
            zstd -dc $archive | tar -tvf -
        case '*'
            echo "Error: unsupported compressor '$comp_name'" >&2
            return 1
    end
end
alias tarzc='tarc pigz'
alias tarzx='tarx pigz'
alias tarzv='tarv pigz'
#
alias tarzsc='tarc zstd'
alias tarzsx='tarx zstd'
alias tarzsv='tarv zstd'

setup_podman_sock
set -x nvm_default_version v24.1.0
set -x GPG_TTY (tty)
set -x XDG_DATA_HOME $HOME/.local/share
set -x XDG_CONFIG_HOME $HOME/.config

set -x RUSTUP_HOME $HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin
set -x CARGO_HOME $HOME/.cargo
set -x MASON_BIN $HOME/.local/share/nvim/mason/bin

set --erase fish_user_paths
fish_add_path ~/.local/bin ~/.local/bin/scripts ~/.local/share/bob/nvim-bin ~/.rd/bin ~/.spicetify /usr/local/bin $RUSTUP_HOME $CARGO_HOME/bin $MASON_BIN

set pure_shorten_prompt_current_directory_length 1
set pure_truncate_prompt_current_directory_keeps 0
set fish_prompt_pwd_dir_length 3
# exclude some common cli tools from done notifications
set -U --erase __done_exclude
set -U __done_exclude '^git (?!push|pull|fetch)'
set -U --append __done_exclude '^(nvim|nano|bat|cat|less|lazygit|lg)'
set -U --append __done_exclude '^sudo (nvim|nano|bat|cat|less)'
set -U --append __done_exclude '^sedit'

if command -q eza
    set -g EZA_STANDARD_OPTIONS --group --header --group-directories-first --icons --color=auto -A
    alias l="eza $EZA_STANDARD_OPTIONS"
    alias la="eza $EZA_STANDARD_OPTIONS --all"
    alias ll="eza $EZA_STANDARD_OPTIONS --long"
    alias ls="eza $EZA_STANDARD_OPTIONS"
    alias lt="eza $EZA_STANDARD_OPTIONS --tree"
    alias llt="eza $EZA_STANDARD_OPTIONS --long --tree"
    alias treed="eza $EZA_STANDARD_OPTIONS -DTA -L 1"
    alias tree="eza $EZA_STANDARD_OPTIONS -TA -L 1"
end
#
alias vi='$EDITOR'
alias vim='$EDITOR'
alias lg='lazygit'
alias yz='yazi'
alias cat='bat'
alias edit='$EDITOR'
alias sedit='sudo -E $EDITOR'
alias mkdir='mkdir -pv'
# zellij shortcuts
alias zls='zellij ls'
alias zac='zellij attach -c'
alias zkill='zellij kill-session'
alias zka='zellij ka'
alias zda='zellij da'
alias zr='zellij run'
alias za='zellij attach'
alias zd='zellij detach'
# rsync shortcuts
alias _rsync='rsync -avL --partial --update'
alias _rsyncd='_rsync --dry-run'
#
alias rsud='_rsync --delete'
alias rsud_d='_rsyncd --delete'
alias rsu='_rsync'
alias rsu_d='_rsyncd'
alias rsfd='_rsync --delete --exclude="*/"'
alias rsfd_d='_rsyncd --delete --exclude="*/"'
alias rsf='_rsync --exclude="*/"'
alias rsf_d='_rsyncd --exclude="*/"'
#
alias reflect='sudo cachyos-rate-mirrors --sync-check --country "US"'
alias update-kitty='curl -L https://sw.kovidgoyal.net/kitty/installer.sh | sh /dev/stdin installer=nightly'
#
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
alias drbu='darwin-rebuild switch --flake $NIX_FLAKE_OS_ROOT#$_host'
alias drbb='darwin-rebuild build --dry-run --flake $NIX_FLAKE_OS_ROOT#$_host'
alias drbls='darwin-rebuild --list-generations'
#
alias nix_hist='sudo nix profile history --profile /nix/var/nix/profiles/system'
alias nix_rb='sudo nix profile rollback --profile /nix/var/nix/profile/system'
alias nix_act='sudo /nix/var/nix/profile/system/bin/switch-to-configuration switch'
alias nix_roots='nix-store --gc --print-roots'
#
alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
alias nixopt='nix-store --gc && nix-store --optimize'
#
alias gpgfix='gpgconf -K all && gpgconf --launch gpg-agent'
#
alias update_tmux='~/.config/tmux/plugins/tpm/bin/update_plugins all'
#
alias kclear="printf '\033[2J\033[3J\033[1;1H'"

source "$HOME/.config/fish/catppuccin-fzf-mocha.fish"

# keep this at the bottom
if command -q starship
    starship init fish | source
end
if command -q atuin
    atuin init fish --disable-up-arrow | source
end

set_editor

# pnpm
set -gx PNPM_HOME "$HOME/.local/share/pnpm"
if not string match -q -- $PNPM_HOME $PATH
    set -gx PATH "$PNPM_HOME" $PATH
end
# pnpm end
