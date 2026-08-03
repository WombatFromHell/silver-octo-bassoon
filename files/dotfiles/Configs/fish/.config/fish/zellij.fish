#!/usr/bin/env fish

# ==============================================================================
# ZELLIJ HELPER
# ------------------------------------------------------------------------------
# A unified wrapper for zellij session management.
#
# Commands:
#   za [session]  Attach to session (creates if missing, defaults to 'main').
#   zd [session]  Delete session (defaults to current session).
#   zk [session]  Kill session (defaults to current session).
#   zda           Delete all sessions.
#   zka           Kill all sessions.
#   zls           List all sessions.
# ==============================================================================

# --- Gatekeeper ---
# Abort silently if zellij is not installed or already loaded.
command -q zellij; or return 0
set -q __zellij_loaded; and return 0
set -g __zellij_loaded

# Check if a string represents a truthy value (1, true, yes, on).
function __zj_is_truthy -d "Check if argument is truthy"
    string match -qir '^(1|true|yes|on)$' $argv[1]
end

# Abort if ZELLIJ_ENABLED is false
set -q ZELLIJ_ENABLED; or set -g ZELLIJ_ENABLED true
if not __zj_is_truthy "$ZELLIJ_ENABLED"
    return 0
end

# --- Configuration ---
set -q ZELLIJ_DEFAULT_SESSION; or set -g ZELLIJ_DEFAULT_SESSION main
set -q ZELLIJ_ON_SSH; or set -g ZELLIJ_ON_SSH false
set -q ZELLIJ_EXIT_ON_DETACH; or set -g ZELLIJ_EXIT_ON_DETACH true
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
    # Don't start zellij inside a tmux session that has auto-attach enabled
    if set -q TMUX
        and __zj_is_truthy "$TMUX_ENABLED"
        and __zj_is_truthy "$TMUX_AUTO_ATTACH"
        echo "Error: Cannot attach to zellij while inside tmux with TMUX_AUTO_ATTACH enabled. Detach from tmux first (prefix d)." >&2
        return 1
    end
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
    if not __zj_is_truthy "$ZELLIJ_AUTO_ATTACH"
        return 0
    else if string match -qir '^(vscode|cursor|windsurf|zed|hyper)$' "$TERM_PROGRAM"; or set -q INSIDE_EMACS; or set -q JETBRAINS_IDE
        return 0
    else if test -n "$SSH_TTY"; and not __zj_is_truthy "$ZELLIJ_ON_SSH"
        return 0
    end
    if __zj_is_truthy "$ZELLIJ_EXIT_ON_DETACH"
        exec zellij attach -c $ZELLIJ_DEFAULT_SESSION
    else
        zellij attach -c $ZELLIJ_DEFAULT_SESSION
    end
end

# --- GPG pinentry TTY sync ---
# Same purpose as the tmux equivalent: keeps gpg-agent pointed at the
# current pane's TTY, since zellij has no server-side focus hook to do
# this automatically the way tmux's set-hook can.
function __zellij_update_gpg_tty --on-event fish_prompt
    command -q gpg-connect-agent; or return 0

    set -l current_tty (tty 2>/dev/null); or return 0
    if test "$current_tty" != "$GPG_TTY"
        set -gx GPG_TTY "$current_tty"
        gpg-connect-agent updatestartuptty /bye >/dev/null 2>&1
    end
end
