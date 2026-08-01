function is_online
    ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1
    return $status
end

# Renamed for clarity: This function ONLY ensures the fisher.fish file exists.
# It does NOT run `fisher update`.
function bootstrap_fisher
    set -l fisher_dir "$HOME/.config/fish/conf.d"
    set -l fisher_cache "$fisher_dir/fisher.fish"

    # If the cache already exists and is non-empty, we are good.
    test -s "$fisher_cache"; and return 0

    if is_online
        # CRITICAL: Ensure the directories exist after clean_fish deleted them.
        mkdir -p "$fisher_dir"
        mkdir -p "$HOME/.config/fish/functions"

        # Download fisher
        curl -sL --max-time 5 \
            https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish >"$fisher_cache"

        # Verify the download actually wrote something
        if test -s "$fisher_cache"
            return 0
        else
            echo "Error: Something went wrong during 'bootstrap_fisher'!"
            return 1
        end
    else
        echo "Error: Must have a working internet connection for this!"
        return 1
    end
end

function yy -d "Yazi with cwd tracking on exit"
    set -l tmp (mktemp -t "yazi-cwd.XXXXXX")
    command env YAZI_NO_SESSION=1 yazi $argv --cwd-file=$tmp
    set cwd (cat -- $tmp)
    if test -n "$cwd" -a "$cwd" != "$PWD"
        cd -- "$cwd"
    end
    rm -f -- $tmp
end
function yz -d "Smarter session handling for Yazi"
    if test (count $argv) -eq 0
        command yazi
    else
        command env YAZI_NO_SESSION=1 yazi $argv
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

function set_editor
    if command -s nvim >/dev/null
        set -gx EDITOR nvim
        set -gx VISUAL nvim
    else if command -s hx >/dev/null
        set -gx EDITOR hx
        set -gx VISUAL hx
    else if command -s nano >/dev/null
        set -gx EDITOR nano
        set -gx VISUAL nano
    else
        set --erase EDITOR >/dev/null
        set --erase VISUAL >/dev/null
    end
end

function setup_podman_sock
    if test -r "$XDG_RUNTIME_DIR"/podman/podman.sock
        set -gx DOCKER_HOST unix:///run/user/$(id -u)/podman/podman.sock
    end
end

function lactd_reset
    flatpak run io.github.ilya_zlobintsev.LACT cli profile set Default
end
function lactd_uv
    flatpak run io.github.ilya_zlobintsev.LACT cli profile set UV
end
function start-llm
    # lactd_reset
    set -l model $argv[1]
    if test -z "$model"
        set model "qwen3.6_35b.sh"
    end
    /var/mnt/data/vllm/llm.sh start $model
end
function __fish_complete_start-llm
    for s in /var/mnt/data/vllm/workspace/*.sh
        basename "$s"
    end
end
complete -c start-llm -f -a "(__fish_complete_start-llm)"

function stop-llm
    /var/mnt/data/vllm/llm.sh stop
    # lactd_uv
end
function start-with-llm
    start-llm $argv[1]
    eval $argv[2..-1]
    if set -q argv[2] # only if <cmd> args exist
        stop-llm
    end
end
complete -c start-with-llm -f -a "(__fish_complete_start-llm)"
function planner
    start-with-llm qwen3.6_27b.sh $argv
end
function coder
    start-with-llm qwen3.6_35b_t.sh $argv
end

function fish_title
    # Get the current working directory
    set current_dir (prompt_pwd --dir-length 2 --full-length-dirs=1)
    # Get the username and hostname
    set user_host (whoami)@(hostname)
    # Combine them to form the desired title
    echo "$user_host:$current_dir"
end

function clean_fish
    set FISH_HOME "$HOME/.config/fish"

    if not is_online
        echo "Error: Must have a working internet connection for this!"
        return 1
    end

    if test -f "$FISH_HOME/fish_plugins"
        cp -f "$FISH_HOME/fish_plugins" "$FISH_HOME/fish_plugins.bak"
    end

    # Nuke existing setup
    rm -rf \
        "$FISH_HOME"/completions \
        "$FISH_HOME"/conf.d \
        "$FISH_HOME"/functions \
        "$FISH_HOME"/themes \
        "$FISH_HOME"/fish_variables

    # 1. Synchronously download/setup fisher (NO backgrounding '&')
    if not bootstrap_fisher
        echo "Error: Failed to bootstrap fisher. Check your internet connection."
        return 1
    end

    # 2. Run fisher update in a fresh subshell.
    # Because we put fisher.fish inside conf.d/, the new `fish` shell
    # will automatically load it before executing "fisher update".
    echo "Running fisher update..."
    if not fish -c "fisher update"
        echo "Error: 'fisher update' failed."
        return 1
    end
    # clean up if we have a valid 'fish_plugins'
    if test -f "$FISH_HOME"/fish_plugins
        rm -f "$FISH_HOME"/fish_plugins.bak
    end
end

function update_wayland_env_vars -d "Update NIRI_SOCKET and WAYLAND_DISPLAY to match current session"
    test "$XDG_CURRENT_DESKTOP" = niri -a -n "$XDG_RUNTIME_DIR"; or return

    # NOTE: fish doesn't expand globs inside variables — must glob directly
    set -l new_socket (command ls -t $XDG_RUNTIME_DIR/niri.*.sock 2>/dev/null)[1]
    test -n "$new_socket" -a "$new_socket" != "$NIRI_SOCKET"; or return

    set -gx NIRI_SOCKET $new_socket
    set -gx WAYLAND_DISPLAY (string replace -r '^niri\.(.*)\.[0-9]+\.sock$' '$1' -- (basename $new_socket))

    if test -z "$SUDO_USER"
        dbus-update-activation-environment --systemd WAYLAND_DISPLAY XDG_CURRENT_DESKTOP NIRI_SOCKET
    end
end

function update_gpg_env
    set -l current_tty (tty 2>/dev/null); or return
    command -q gpg-connect-agent; or return

    set -l agent_alive (gpg-connect-agent /bye 2>&1)
    if test "$current_tty" = "$GPG_TTY"; and test -z "$agent_alive"
        return
    end

    set -gx GPG_TTY $current_tty
    gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1
end

function sudoe --description "sudo with preserved PATH and Fish function support"
    # Build a PATH that ensures Nix binaries come first, then deduplicate
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

    # Split argv into sudo options vs. command args on the "--" delimiter.
    # If no "--" is present, treat everything as the command (no sudo options).
    set -l sudo_opts
    set -l cmd_args
    set -l past_delimiter false
    for arg in $argv
        if test "$arg" = --
            set past_delimiter true
            continue
        end
        if $past_delimiter
            set -a cmd_args $arg
        else
            set -a sudo_opts $arg
        end
    end
    if not $past_delimiter
        set cmd_args $sudo_opts
        set sudo_opts
    end

    # -E preserves the caller's environment; we override PATH explicitly so
    # Nix and the current shell's PATH are visible to the privileged process.
    set -l sudo_prefix sudo -E $sudo_opts env PATH=$env_path

    # If the command is a Fish function/alias it won't exist as a binary, so
    # we must re-enter Fish to expand it. Otherwise exec it directly (safer,
    # no quoting edge-cases).
    if functions -q -- $cmd_args[1]
        # Escape each argument individually so spaces/special chars survive
        # the transition from a list into a -c string.
        set -l escaped (string escape -- $cmd_args)
        set -l fish_cmd (string join ' ' $escaped)
        command $sudo_prefix fish -c $fish_cmd
    else
        command $sudo_prefix $cmd_args
    end
end
