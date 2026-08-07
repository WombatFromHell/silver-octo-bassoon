#!/usr/bin/env fish

# ==============================================================================
# HERDR HELPER
# ------------------------------------------------------------------------------
# A unified wrapper for herdr session management.
#
# Commands:
#   hrd [session]    Attach to session (defaults to HERDR_DEFAULT_SESSION).
#   hrdssh <target>  Attach to a remote herdr server through SSH
#                    (defaults to HERDR_DEFAULT_SESSION).
#   hrdr             Reload the server config.
#   hrdk             Stop the running server.
#   hrdl             List all sessions.
#
# Environment:
#   HERDR_DEFAULT_SESSION  Session used by default (default: main).
#   HERDR_AUTO_ATTACH      Auto-launch/attach on interactive shell start.
#   HERDR_EXIT_ON_DETACH   exec herdr so detaching exits the shell.
#   HERDR_ON_SSH           Auto-attach over SSH too (default: false).
# ==============================================================================

# --- Gatekeeper ---
# Abort silently if herdr is not installed.
if not command -q herdr
    return 0
end

# --- Configuration ---
set -q HERDR_DEFAULT_SESSION; or set -g HERDR_DEFAULT_SESSION main
set -q HERDR_AUTO_ATTACH; or set -g HERDR_AUTO_ATTACH false
set -q HERDR_EXIT_ON_DETACH; or set -g HERDR_EXIT_ON_DETACH false
set -q HERDR_ON_SSH; or set -g HERDR_ON_SSH false

# Check if a string represents a truthy value (1, true, yes, on).
function __herdr_is_truthy -d "Check if argument is truthy"
    string match -qir '^(1|true|yes|on)$' $argv[1]
end

# --- Helper Functions ---

# List session names (used for completions).
function __herdr_list_session_names -d "List session names"
    herdr session list 2>/dev/null | string match -r '^[^ ]+' | string match -rv '^name$'
end

# --- Public API ---

function hrd -d "Attach to a session"
    set -l name $HERDR_DEFAULT_SESSION
    test -n "$argv[1]"; and set name $argv[1]
    herdr session attach $name
end

function hrdssh -d "Attach to a remote herdr server through SSH"
    # ponytail: first arg = target, rest pass through to herdr (e.g. --session <name>)
    test -n "$argv[1]"; or begin
        echo "usage: hrdssh <ssh-target> [--session <name>]" >&2
        return 1
    end
    set -l rest $argv[2..-1]
    if not string match -q -- '--session*' $rest
        set rest --session $HERDR_DEFAULT_SESSION $rest
    end
    herdr --remote $argv[1] $rest
end

function hrdr -d "Reload herdr server config"
    herdr server reload-config
end

function hrdk -d "Stop the herdr server"
    if test -n "$argv[1]"
        herdr session stop $argv[1]
    else
        herdr server stop
    end
end

function hrdl -d "List herdr sessions"
    herdr session list
end

# --- Completions ---
complete -c hrd -f -a "(__herdr_list_session_names)"
complete -c hrdssh -f -l session -a "(__herdr_list_session_names)"

# --- Auto-Start Logic ---
# Only runs in interactive shells not currently inside herdr.
if status is-interactive; and not set -q HERDR_ENV
    # Conditions to skip auto-start:
    set -l skip_autostart false
    if not __herdr_is_truthy "$HERDR_AUTO_ATTACH"
        set skip_autostart true
    end

    if test "$TERM_PROGRAM" = vscode
        set skip_autostart true
    else if test "$ZED_TERM" = true
        set skip_autostart true
    else if test -n "$SSH_TTY"; and not __herdr_is_truthy "$HERDR_ON_SSH"
        set skip_autostart true
    end

    if not $skip_autostart
        # ponytail: create-or-attach + exec on detach, mirroring tmux new-session -A.
        if __herdr_is_truthy "$HERDR_EXIT_ON_DETACH"
            exec herdr --session $HERDR_DEFAULT_SESSION
        else
            herdr --session $HERDR_DEFAULT_SESSION
        end
    end
end
