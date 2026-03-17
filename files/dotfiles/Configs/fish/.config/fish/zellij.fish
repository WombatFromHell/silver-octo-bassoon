#!/usr/bin/env fish

# Abort if zellij is not installed or already loaded.
command -q zellij; or return 0
set -q __zellij_loaded; and return 0
set -g __zellij_loaded
# Abort if ZELLIJ_ENABLED is false
set -q ZELLIJ_ENABLED; or set -g ZELLIJ_ENABLED true
if not string match -qir '^(1|true|yes|on)$' "$ZELLIJ_ENABLED"
    return 0
end

# --- Configuration ---
set -q ZELLIJ_DEFAULT_SESSION; or set -g ZELLIJ_DEFAULT_SESSION main
set -q ZELLIJ_ON_SSH; or set -g ZELLIJ_ON_SSH true
set -q EXIT_SHELL_ON_ZELLIJ_EXIT; or set -g EXIT_SHELL_ON_ZELLIJ_EXIT false

# --- Helpers ---
function __zj_sessions -d "List session names for completions"
    zellij list-sessions 2>/dev/null \
        | string replace -ra '\x1b\[[0-9;]*m' '' \
        | string replace -r '^(\S+)\s+\[(.+)\].*$' '$1\t$2'
end

# --- Completions ---
for cmd in za zd zk
    complete -c $cmd -a "(__zj_sessions)"
end

# --- Public API ---

function za -d "Attach to session, creating it if missing (default: \$ZELLIJ_DEFAULT_SESSION)"
    zellij attach -c (test -n "$argv[1]"; and echo $argv[1]; or echo $ZELLIJ_DEFAULT_SESSION)
end

function zda -d "Delete all sessions"
    zellij delete-all-sessions
end

function zd -d "Delete a session (default: current)"
    zellij delete-session (test -n "$argv[1]"; and echo $argv[1]; or echo $ZELLIJ_SESSION_NAME)
end

function zka -d "Kill all sessions"
    zellij kill-all-sessions
end

function zk -d "Kill a session (default: current)"
    zellij kill-session (test -n "$argv[1]"; and echo $argv[1]; or echo $ZELLIJ_SESSION_NAME)
end

function zls -d "List all sessions"
    zellij list-sessions
end

# --- Auto-Start ---
if status is-interactive; and not set -q ZELLIJ
    if test "$TERM_PROGRAM" = vscode
        return 0
    else if test -n "$SSH_TTY"; and not string match -qir '^(1|true|yes|on)$' $ZELLIJ_ON_SSH
        return 0
    end

    zellij attach -c $ZELLIJ_DEFAULT_SESSION

    string match -qir '^(1|true|yes|on)$' $EXIT_SHELL_ON_ZELLIJ_EXIT; and exit
end
