#!/usr/bin/env fish
# Abort if zellij is not installed or already loaded.
command -q zellij; or return 0
set -q __zellij_loaded; and return 0
set -g __zellij_loaded
# Abort if ZELLIJ_ENABLED is false
set -q ZELLIJ_ENABLED; or set -g ZELLIJ_ENABLED true
string match -qir '^(1|true|yes|on)$' "$ZELLIJ_ENABLED"; or return 0

# --- Configuration ---
set -q ZELLIJ_DEFAULT_SESSION; or set -g ZELLIJ_DEFAULT_SESSION main
set -q ZELLIJ_ON_SSH; or set -g ZELLIJ_ON_SSH true
set -q EXIT_SHELL_ON_ZELLIJ_EXIT; or set -g EXIT_SHELL_ON_ZELLIJ_EXIT false
# Master switch for auto-attach on shell start. Set to false to require `za`.
set -q ZELLIJ_AUTO_ATTACH; or set -g ZELLIJ_AUTO_ATTACH true

# --- Helpers ---
function __zj_sessions -d "List session names for completions"
    zellij list-sessions 2>/dev/null \
        | string replace -ra '\x1b\[[0-9;]*m' '' \
        | string replace -r '^(\S+)\s+\[(.+)\].*$' '$1\t$2'
end

function __zj_session_arg -d "Resolve session name: arg, else fallback"
    test -n "$argv[1]"; and echo $argv[1]; or echo $argv[2]
end

# --- Completions ---
complete -c za -a "(__zj_sessions)"
complete -c zd -a "(__zj_sessions)"
complete -c zk -a "(__zj_sessions)"

# --- Public API ---
function za -d "Attach to session, creating it if missing (default: \$ZELLIJ_DEFAULT_SESSION)"
    zellij attach -c (__zj_session_arg $argv[1] $ZELLIJ_DEFAULT_SESSION)
end
function zd -d "Delete a session (default: current)"
    zellij delete-session (__zj_session_arg $argv[1] $ZELLIJ_SESSION_NAME)
end
function zk -d "Kill a session (default: current)"
    zellij kill-session (__zj_session_arg $argv[1] $ZELLIJ_SESSION_NAME)
end
function zda -d "Delete all sessions"
    zellij delete-all-sessions
end
function zka -d "Kill all sessions"
    zellij kill-all-sessions
end
function zls -d "List all sessions"
    zellij list-sessions
end

# --- Auto-Start ---
if status is-interactive; and not set -q ZELLIJ
    if not string match -qir '^(1|true|yes|on)$' $ZELLIJ_AUTO_ATTACH
        return 0
    else if string match -qir '^(vscode|cursor|windsurf|zed|hyper)$' "$TERM_PROGRAM"; or set -q INSIDE_EMACS; or set -q JETBRAINS_IDE
        return 0
    else if test -n "$SSH_TTY"; and not string match -qir '^(1|true|yes|on)$' $ZELLIJ_ON_SSH
        return 0
    end
    zellij attach -c $ZELLIJ_DEFAULT_SESSION
    string match -qir '^(1|true|yes|on)$' $EXIT_SHELL_ON_ZELLIJ_EXIT; and exit
end
