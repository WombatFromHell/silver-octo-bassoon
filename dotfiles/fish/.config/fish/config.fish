if test -f ~/.profile
    # fenv "source ~/.profile"
end

if status is-interactive && ! functions -q fisher
    curl -sL https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish | source && fisher update
end

if status is-interactive
    # Commands to run in interactive sessions can go here
    function fish_title
        # Get the current working directory
        set current_dir (prompt_pwd --dir-length 2 --full-length-dirs=1)
        # Get the username and hostname
        set user_host (whoami)@(hostname)
        # Combine them to form the desired title
        echo "$user_host:$current_dir"
    end

    # enable zellij integration
    if not set -q SSH_TTY
        set ZELLIJ_AUTO_ATTACH true
        set ZELLIJ_AUTO_EXIT false
        eval (zellij setup --generate-auto-start fish | string collect)
    end
end

function yy
    set tmp (mktemp -t "yazi-cwd.XXXXXX")
    yazi $argv --cwd-file="$tmp"
    if set cwd (cat -- "$tmp"); and [ -n "$cwd" ]; and [ "$cwd" != "$PWD" ]
        cd -- "$cwd"
    end
    rm -f -- "$tmp"
end

function view_tarzst
    if test -z "$argv[1]"
        echo "Usage: $(status current-function) <file.tar.zst>"
        return 1
    end
    if command -v unzstd &>/dev/null
        unzstd -c "$argv[1]" | tar tv
    else
        echo "Error: zstd must be accessible in path for $(status current-function) to work!"
        return 1
    end
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

function update_neovim
    set -l appimage_path "$HOME/AppImages/neovim.AppImage"
    set -l local_sha_path "$appimage_path.sha256sum"
    set -l remote_url "https://github.com/neovim/neovim/releases/download/nightly/nvim.appimage"
    set -l remote_sha_url "$remote_url.sha256sum"

    if not set -l remote_sha (curl -s "$remote_sha_url")
        echo "Error: Failed to fetch remote SHA256 sum"
        return 1
    end

    set remote_sha (echo "$remote_sha" | awk '{print $1}')

    if not test -f "$local_sha_path"
        set -l local_sha ""
    else
        set -l local_sha (cat "$local_sha_path")
    end

    if test "$remote_sha" != "$local_sha"
        echo "New Neovim nightly version available. Updating..."

        if test -f "$appimage_path"
            mv "$appimage_path" "$appimage_path.bak"
        end

        if not curl -L "$remote_url" -o "$appimage_path"
            echo "Error: Failed to download Neovim AppImage"
            # Restore backup if download fails
            if test -f "$appimage_path.bak"
                mv "$appimage_path.bak" "$appimage_path"
            end
            return 1
        end

        chmod +x "$appimage_path"
        ln -sf "$appimage_path" "$HOME/.local/bin/nvim"
        rsync -vh "$appimage_path" "$local_sha_path" "$HOME/Backups/linux-config/backups/support/appimages/"

        echo "$remote_sha" >"$local_sha_path"

        echo "Neovim nightly updated successfully"
    else
        echo "Neovim nightly is already up to date"
    end
end

function set_editor
    set editor (command -v nvim || /usr/local/bin/nvim)
    set fallback (command -v nano)
    if test -n "$editor"
        set -gx EDITOR $editor[1]
        set -gx VISUAL $editor[1]
    else if test -n "$fallback"
        set -gx EDITOR $fallback[1]
        set -gx VISUAL $fallback[1]
    else
        set --erase EDITOR
        set --erase VISUAL
    end
end

set_editor
set -x nvm_default_version v23.6.1
set -x GPG_TTY (tty)
set -x XDG_DATA_HOME $HOME/.local/share

set --erase fish_user_paths
fish_add_path ~/.local/bin ~/.local/bin/scripts ~/.local/share/nvim/mason/bin /usr/local/bin ~/.rd/bin ~/.nix-profile/bin

set EZA_STANDARD_OPTIONS --group --header --group-directories-first --icons --color=auto -A
set pure_shorten_prompt_current_directory_length 1
set pure_truncate_prompt_current_directory_keeps 0
set fish_prompt_pwd_dir_length 3
set fish_tmux_autostart false
# exclude some common cli tools from done notifications
set -U --erase __done_exclude
set -U __done_exclude '^git (?!push|pull|fetch)'
set -U --append __done_exclude '^(nvim|nano|bat|cat|less|lazygit|lg)'
set -U --append __done_exclude '^sudo (nvim|nano|bat|cat|less)'
set -U --append __done_exclude '^sedit'

alias l='eza $EZA_STANDARD_OPTIONS'
alias la='eza $EZA_STANDARD_OPTIONS --all'
alias ll='eza $EZA_STANDARD_OPTIONS --long'
alias ls='eza $EZA_STANDARD_OPTIONS'
alias lt='eza $EZA_STANDARD_OPTIONS --tree'
alias llt='eza $EZA_STANDARD_OPTIONS --long --tree'
#
alias lg='lazygit'
alias yz='yazi'
alias cat='bat'
alias edit='$EDITOR'
alias sedit='sudo -E $EDITOR'
alias mkdir='mkdir -pv'
# zellij shortcuts
alias zls='zellij ls'
alias zkill='zellij kill-session'
alias zka='zellij ka'
alias zda='zellij da'
alias zr='zellij run'
alias za='zellij attach'
alias zd='zellij detach'
# rsync shortcuts
alias _rsync='rsync -avzL --partial --info=progress2 --update'
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
set NIX_FLAKE_ROOT $HOME/.dotfiles/nix
alias nixconf='$EDITOR $NIX_FLAKE_ROOT'
alias nhu_d='nh home switch -H methyl $NIX_FLAKE_ROOT'
alias nhc='nh clean'

# only when not already inside fish
if command -q zoxide
    zoxide init fish | source
end
if command -q direnv
    set -x DIRENV_LOG_FORMAT ""
    direnv hook fish | source
end
set -l cargo_fish_path "$HOME/.cargo/env.fish"
if test -f "$cargo_fish_path"
    source "$cargo_fish_path"
end
# if test (ps -o comm= -p $fish_pid) != fish
#     # do things here only when NOT already inside fish
# end
