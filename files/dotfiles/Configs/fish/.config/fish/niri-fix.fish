function update_wayland_env_vars -d "Safely sync GUI env vars into this shell and the tmux server"
    # Guard: Ensure runtime dir exists
    set -q XDG_RUNTIME_DIR; or set -gx XDG_RUNTIME_DIR "/run/user/"(id -u)
    test -d "$XDG_RUNTIME_DIR"; or return

    # 1. Source of truth: the systemd user session (bulk parse, one subprocess).
    # Anchored ^...= so e.g. ^DISPLAY= doesn't also match inside WAYLAND_DISPLAY=.
    set -l sys_env (systemctl --user show-environment 2>/dev/null)
    set -l target_wayland (string match -r '^WAYLAND_DISPLAY=(.*)' -- $sys_env)[2]
    set -l target_display (string match -r '^DISPLAY=(.*)' -- $sys_env)[2]
    set -l target_desktop (string match -r '^XDG_CURRENT_DESKTOP=(.*)' -- $sys_env)[2]
    set -l target_niri (string match -r '^NIRI_SOCKET=(.*)' -- $sys_env)[2]

    # 2. Only the live socket for our desktop, else leave systemd values alone.
    # NIRI_SOCKET: only managed when niri is the active desktop; else cleared.
    # `ls` is not a nullglob command in fish, so globbing it directly fails on
    # no-match. We list the runtime dir and filter with `string match` instead
    # (nullglob-safe); `ls -t` preserves most-recent-first ordering.
    if string match -qr niri -- "$target_desktop"
        # Live socket wins (most-recent-first). Also derives WAYLAND_DISPLAY if missing.
        if set -l niri_sock (command ls -t "$XDG_RUNTIME_DIR" 2>/dev/null | string match -r '^niri\..*\.sock$')[1]
            and test -S "$XDG_RUNTIME_DIR/$niri_sock"
            set target_niri "$XDG_RUNTIME_DIR/$niri_sock"
            set -q target_wayland[1]; or set target_wayland \
                (string replace -r '^niri\.(.*)\.[0-9]+\.sock$' '$1' -- "$niri_sock")
        end
    else
        set target_niri ""
    end

    # Generic Wayland socket, when systemd has none or it no longer exists.
    if not set -q target_wayland[1]; or not test -S "$XDG_RUNTIME_DIR/$target_wayland"
        if set -l wl_sock (command ls -t "$XDG_RUNTIME_DIR" 2>/dev/null | string match -r '^wayland-')[1]
            set wl_sock "$XDG_RUNTIME_DIR/$wl_sock"
            test -S "$wl_sock"; and set target_wayland (basename "$wl_sock")
        end
    end

    # Xwayland DISPLAY, when systemd has none.
    if not set -q target_display[1]
        if set -l x_sock (command ls -t /tmp/.X11-unix 2>/dev/null | string match -r '^X[0-9]+$')[1]
            set x_sock "/tmp/.X11-unix/$x_sock"
            test -S "$x_sock"; and set target_display ":"(string replace -r '.*/X' '' -- "$x_sock")
        end
    end

    # 3. Sync shell + tmux server global env. Only act when a value differs,
    # so the function is a no-op on unchanged state (idempotent per prompt).
    set -l tmux_env 0
    set -q TMUX; and set tmux_env 1

    # switch (not a flat list) so an empty target still resolves correctly.
    for var in WAYLAND_DISPLAY DISPLAY XDG_CURRENT_DESKTOP NIRI_SOCKET
        set -l tg ""
        switch $var
            case WAYLAND_DISPLAY
                set tg "$target_wayland"
            case DISPLAY
                set tg "$target_display"
            case XDG_CURRENT_DESKTOP
                set tg "$target_desktop"
            case NIRI_SOCKET
                set tg "$target_niri"
        end

        set -q $var; and set -l cur $$var; or set -l cur ""

        if test "$cur" != "$tg"
            if test -n "$tg"
                set -gx $var "$tg"
                test $tmux_env -eq 1; and tmux set-environment -g $var "$tg" 2>/dev/null
            else if test -n "$cur"
                set -e $var
                test $tmux_env -eq 1; and tmux unset-environment -g $var 2>/dev/null
            end
        end
    end
end
