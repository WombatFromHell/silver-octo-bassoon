#!/usr/bin/env fish

# ==============================================================================
# TMUX HELPER (Minimal & Unified)
# ------------------------------------------------------------------------------
# Usage:
#   tma [session] - Attach to session (Create if missing, defaults to dir)
#   tmr [session] - Reattach/switch to existing session (Fails if missing)
#   tmr -         - Switch to last session (inside tmux only)
#   tmk [session] - Kill session
#   tmls          - List sessions
# ==============================================================================

# --- Configuration ---
set -q TMUX_ON_SSH; or set -g TMUX_ON_SSH true
set -q EXIT_SHELL_ON_TMUX_EXIT; or set -g EXIT_SHELL_ON_TMUX_EXIT false
set -q TMUX_DEFAULT_SESSION; or set -g TMUX_DEFAULT_SESSION main

# --- Gatekeeper ---
# Do not load anything if tmux is not installed
if not command -q tmux
    return
end

# --- Helpers ---
function __tmux_is_truthy
    string match -q -r '^(1|true|yes|on)$' $argv[1]
end

function __tmux_session_exists -a session
    tmux has-session -t $session 2>/dev/null
end

# Internal helper used for completions (Names only)
function __tmux_list_sessions
    tmux list-sessions -F '#{session_name}' 2>/dev/null
end

function __tmux_connect -a session
    if set -q TMUX
        tmux switch-client -t $session
    else
        tmux attach-session -t $session
    end
end

function __tmux_ensure -a session
    # Create session detached if missing
    __tmux_session_exists $session; or tmux new-session -d -s $session
end

# --- Public API ---

# tma: Attach to session (Create if missing)
# Defaults to current directory if no argument provided.
function tma
    set -l target $argv[1]
    if test -z "$target"
        set target (basename (pwd))
    end

    __tmux_ensure $target
    __tmux_connect $target
end

# tmr: Reconnect/switch to existing session
# Defaults to current directory if no argument provided.
# Use '-' to switch to the previous session.
function tmr
    set -l target $argv[1]

    # Handle dash '-' for last session (inside tmux only)
    if test "$target" = -
        if set -q TMUX
            tmux switch-client -l
        else
            echo "Error: '-' (last session) only works inside tmux." >&2
            return 1
        end
        return
    end

    # Default to directory if no arg
    if test -z "$target"
        set target (basename (pwd))
    end

    # Connect only if exists
    if __tmux_session_exists $target
        __tmux_connect $target
    else
        echo "Session '$target' does not exist." >&2
        return 1
    end
end

# tmk: Kill session
function tmk
    set -l target $argv[1]
    if test -z "$target"
        if set -q TMUX
            set target (tmux display-message -p '#{session_name}')
        else
            echo "Please specify a session name." >&2
            return 1
        end
    end
    __tmux_session_exists $target; and tmux kill-session -t $target; or echo "No session '$target'"
end

# tmls: List sessions
# Calls raw tmux command for full details (unlike __tmux_list_sessions helper)
function tmls
    tmux list-sessions
end

# --- Auto-Start ---
# (Removed redundant 'command -q tmux' check because of top-level gatekeeper)
if status is-interactive; and not set -q TMUX
    if test "$TERM_PROGRAM" != vscode; and test -z "$SSH_TTY"; or __tmux_is_truthy "$TMUX_ON_SSH"
        set s $TMUX_DEFAULT_SESSION
        __tmux_ensure $s
        __tmux_connect $s

        if __tmux_is_truthy "$EXIT_SHELL_ON_TMUX_EXIT"
            if not __tmux_session_exists $s 2>/dev/null
                exit
            end
        end
    end
end

# --- Completions ---
complete -c tma -f -a "(__tmux_list_sessions)"
complete -c tmr -f -a "(__tmux_list_sessions) -"
complete -c tmk -f -a "(__tmux_list_sessions)"
