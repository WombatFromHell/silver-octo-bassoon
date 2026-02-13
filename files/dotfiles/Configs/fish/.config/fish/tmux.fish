#!/usr/bin/env fish

# ==============================================================================
# TMUX HELPER
# ------------------------------------------------------------------------------
# A unified wrapper for tmux session management.
#
# Commands:
#   tma [session]  Attach to session (creates if missing, defaults to 'main').
#   tmr [session]  Switch to existing session (defaults to current directory).
#   tmr -          Switch to the last session (inside tmux only).
#   tmk [session]  Kill session (defaults to current session).
#   tmls           List all sessions.
# ==============================================================================

# --- Gatekeeper ---
# Abort silently if tmux is not installed.
if not command -q tmux
    return 0
end

# --- Configuration ---
set -q TMUX_DEFAULT_SESSION; or set -g TMUX_DEFAULT_SESSION main
set -q TMUX_ON_SSH; or set -g TMUX_ON_SSH true
set -q EXIT_SHELL_ON_TMUX_EXIT; or set -g EXIT_SHELL_ON_TMUX_EXIT false

# --- Helper Functions ---

# Check if a string represents a truthy value (1, true, yes, on).
function __tmux_is_truthy -d "Check if argument is truthy"
    string match -qir '^(1|true|yes|on)$' $argv[1]
end

# Check if a tmux session exists.
function __tmux_session_exists -d "Check if session exists"
    tmux has-session -t $argv[1] 2>/dev/null
end

# Internal helper to list session names (used for completions).
function __tmux_list_session_names -d "List session names"
    tmux list-sessions -F '#{session_name}' 2>/dev/null
end

# Attach to a session, or switch-client if already inside tmux.
function __tmux_attach -d "Attach or switch to a session"
    if set -q TMUX
        tmux switch-client -t $argv[1]
    else
        tmux attach-session -t $argv[1]
    end
end

# Ensure a session exists, creating it detached if missing.
function __tmux_ensure_session -d "Create session if it does not exist"
    __tmux_session_exists $argv[1]; or tmux new-session -d -s $argv[1]
end

# --- Public API ---

function tma -d "Attach to session (create if missing)"
    set -l target $argv[1]
    # Default to configured main session if no argument
    test -z "$target"; and set target $TMUX_DEFAULT_SESSION

    __tmux_ensure_session $target
    __tmux_attach $target
end

function tmr -d "Reattach/switch to existing session"
    set -l target $argv[1]

    # Handle '-' to switch to last session (requires active tmux)
    if test "$target" = -
        if set -q TMUX
            tmux switch-client -l
            return 0
        else
            echo "Error: '-' (last session) only works inside tmux." >&2
            return 1
        end
    end

    # Default to current directory name if no argument
    test -z "$target"; and set target (basename $PWD)

    if __tmux_session_exists $target
        __tmux_attach $target
    else
        echo "Session '$target' does not exist." >&2
        return 1
    end
end

function tmk -d "Kill session"
    set -l target $argv[1]

    # Default to current session if inside tmux and no argument
    if test -z "$target"
        if set -q TMUX
            set target (tmux display-message -p '#{session_name}')
        else
            echo "Error: Please specify a session name." >&2
            return 1
        end
    end

    if __tmux_session_exists $target
        tmux kill-session -t $target
    else
        echo "No session named '$target'." >&2
        return 1
    end
end

function tmls -d "List sessions"
    tmux list-sessions
end

# --- Auto-Start Logic ---
# Only runs in interactive shells not currently in tmux.
if status is-interactive; and not set -q TMUX
    # Conditions to skip auto-start:
    # 1. Inside VS Code terminal
    # 2. Inside SSH (unless TMUX_ON_SSH is true)
    set -l skip_autostart false

    if test "$TERM_PROGRAM" = vscode
        set skip_autostart true
    else if test -n "$SSH_TTY"; and not __tmux_is_truthy "$TMUX_ON_SSH"
        set skip_autostart true
    end

    if not $skip_autostart
        set -l target $TMUX_DEFAULT_SESSION
        __tmux_ensure_session $target

        # Only attach if the session is not currently attached elsewhere.
        # This prevents "stealing" the session from another window/term.
        set -l clients (tmux list-clients -F '#{session_name}' 2>/dev/null)
        if not string match -q -- $target $clients
            __tmux_attach $target

            # Optional: Exit the shell if the tmux session was killed during the session
            if __tmux_is_truthy "$EXIT_SHELL_ON_TMUX_EXIT"
                if not __tmux_session_exists $target 2>/dev/null
                    exit
                end
            end
        end
    end
end

# --- Completions ---
complete -c tma -f -a "(__tmux_list_session_names)"
complete -c tmr -f -a "(__tmux_list_session_names) -"
complete -c tmk -f -a "(__tmux_list_session_names)"
