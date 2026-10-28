function __is_truthy -d "Check if argument is truthy (1, true, yes, on)"
    string match -qir '^(1|true|yes|on)$' $argv[1]
end

# Ensures the fisher.fish file exists in conf.d/. It does NOT run `fisher update`.
function bootstrap_fisher
    set -l fisher_dir "$HOME/.config/fish/conf.d"
    set -l fisher_cache "$fisher_dir/fisher.fish"

    # If the cache already exists and is non-empty, we are good.
    test -s "$fisher_cache"; and return 0

    # Download fisher (conf.d/ is the download target; fisher creates
    # functions/ itself on update). curl fails on network errors;
    # test -s catches both network failure and empty response.
    mkdir -p "$fisher_dir"
    curl -sL --max-time 5 \
        https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish >"$fisher_cache"

    test -s "$fisher_cache"; or begin
        echo "Error: Failed to download fisher (network?)." >&2
        return 1
    end
    return 0
end

alias yazi='env YAZI_NO_SESSION=1 command yazi'
alias yz='yazi'

function yy -d "Yazi with cwd tracking on exit"
    set -l tmp (mktemp -t "yazi-cwd.XXXXXX")
    yz --cwd-file=$tmp $argv
    set cwd (cat -- $tmp)
    if test -n "$cwd" -a "$cwd" != "$PWD"
        cd -- "$cwd"
    end
    rm -f -- $tmp
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
    for e in edit.sh nvim hx nano
        if command -s $e >/dev/null
            set -gx EDITOR $e
            set -gx VISUAL $e
            return
        end
    end
    set --erase EDITOR >/dev/null
    set --erase VISUAL >/dev/null
end

function setup_podman_sock
    if test -r "$XDG_RUNTIME_DIR"/podman/podman.sock
        set -gx DOCKER_HOST "unix://$XDG_RUNTIME_DIR/podman/podman.sock"
    end
end

function __ts_cleanup
    tailscale serve reset
    functions -e __ts_cleanup __ts_int __ts_term
end

function __ts_int --on-signal INT
    __ts_cleanup
    exit 130
end
function __ts_term --on-signal TERM
    __ts_cleanup
    exit 143
end

function ts_serve --description "Run a command wrapped in a temporary tailscale serve mapping"
    argparse -s 'u/url=' 'p/port=' 's/path=' -- $argv; or return 2
    set -q _flag_url; or begin
        echo "usage: ts_serve -u URL [-p PORT] [-s PATH] command [args...]" >&2
        return 2
    end
    test (count $argv) -gt 0; or begin
        echo "ts_serve: no command given" >&2
        return 2
    end
    set -q _flag_port; or set _flag_port 443

    set -l serve_args --https=$_flag_port
    if set -q _flag_path
        set -a serve_args --set-path=(string replace -r '^/?' '/' -- $_flag_path)
    end

    tailscale serve --bg $serve_args $_flag_url; or return 1

    $argv
    set -l exit_code $status

    tailscale serve $serve_args off
    return $exit_code
end

function lactd_reset
    flatpak run io.github.ilya_zlobintsev.LACT cli profile set Default
end
function lactd_uv
    flatpak run io.github.ilya_zlobintsev.LACT cli profile set UV
end

function clean_fish
    set -l FISH_HOME "$HOME/.config/fish"

    # Nuke only what fisher/fish regenerate. Critical files
    # (config.fish, fish_plugins, helpers/) are untouched.
    rm -rf "$FISH_HOME"/{completions,conf.d,functions,themes} \
        "$FISH_HOME"/fish_variables

    # bootstrap_fisher handles the offline check and downloads fisher.fish
    # into conf.d/, which a fresh (non-interactive) fish shell loads
    # automatically before running "fisher update".
    bootstrap_fisher; or return 1
    echo "Running fisher update..."
    fish -c "fisher update"; or return 1
end

if command -q gpg-connect-agent
    function reload_gpg_agent
        pkill -x ssh-agent
        gpgconf --kill gpg-agent
        gpg-connect-agent /bye >/dev/null 2>&1
    end
    function update_gpg_env
        # In SSH sessions, prefer $SSH_TTY over `tty` for reliability
        if test -n "$SSH_CLIENT"
            set -l ssh_tty "$SSH_TTY"
            if test -z "$ssh_tty"; or not test -w "$ssh_tty"
                set ssh_tty (tty 2>/dev/null); or return
            end
            set -l current_tty "$ssh_tty"
        else
            set -l current_tty (tty 2>/dev/null); or return
        end

        command -q gpg-connect-agent; or return

        # Always update in SSH: agent cache is often stale across sessions
        # For local sessions, skip if TTY unchanged (existing optimization)
        if test -z "$SSH_CLIENT"; and test "$current_tty" = "$GPG_TTY"
            return
        end

        set -gx GPG_TTY "$current_tty"
        gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1

        # Fix SSH agent socket when in SSH session
        if test -n "$SSH_CLIENT"
            set -l sock (gpgconf --list-dirs agent-ssh-socket 2>/dev/null)
            if test -n "$sock"; and test -S "$sock"
                set -gx SSH_AUTH_SOCK "$sock"
            end
        end
    end
    function __update_pinentry_env --on-event fish_prompt
        if test -n "$TMUX"
            set -gx PINENTRY_USER_DATA tmux
        else if test -n "$ZELLIJ"
            set -gx PINENTRY_USER_DATA zellij
        else
            set -e PINENTRY_USER_DATA
        end
    end

    if not set -q __gpg_agent_initialized
        set -g __gpg_agent_initialized
        if test -z "$SSH_AUTH_SOCK"; or not ssh-add -l >/dev/null 2>&1
            eval (ssh-agent -c | string match -v 'echo Agent pid*')
        end
    end
end

function sudoe --description "sudo with preserved PATH and Fish function support"
    # Build a PATH that ensures Nix binaries come first, then deduplicate.
    # Preserves the caller's user PATH so user scripts/binaries resolve as root.
    set -l nix_bin $HOME/.nix-profile/bin
    set -l merged_path $nix_bin
    for dir in (string split : $PATH)
        if not contains -- $dir $merged_path
            set -a merged_path $dir
        end
    end
    set -l env_path (string join : $merged_path)

    # No arguments → drop into an interactive root shell in the current directory
    if test (count $argv) -eq 0
        command sudo -EH env PATH=$env_path fish -l
        return
    end

    # ponytail: no sudo-opts parsing; call sudo directly for non-root targets.
    # -E preserves the caller's environment; we override PATH explicitly so
    # Nix and the current shell's PATH are visible to the privileged process.
    set -l sudo_prefix sudo -E env PATH=$env_path

    # If the command is a Fish function/alias it won't exist as a binary, so
    # we must re-enter Fish to expand it. Otherwise exec it directly (safer,
    # no quoting edge-cases).
    if functions -q -- $argv[1]
        set -l fish_cmd (string join ' ' (string escape -- $argv))
        command $sudo_prefix fish -c $fish_cmd
    else
        command $sudo_prefix $argv
    end
end

function sedit
    sudoe $EDITOR $argv
end

function fview --description "Walk paths/globs with fd/find and feed to bat/cat"
    set -l viewer cat
    if type -q bat
        set viewer bat -P
    end

    for arg in $argv
        if test -f "$arg"
            echo "$arg"
        else if test -d "$arg"
            if type -q fd
                fd --type f . "$arg"
            else if type -q fdfind
                fdfind --type f . "$arg"
            else
                find "$arg" -type f 2>/dev/null
            end
        else
            if type -q fd
                fd --type f -g "$arg"
            else if type -q fdfind
                fdfind --type f -g "$arg"
            else
                find . -name "$arg" -type f 2>/dev/null
            end
        end
    end | xargs -r $viewer
end
