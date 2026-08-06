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
set -q ZELLIJ_EXIT_ON_DETACH; or set -g ZELLIJ_EXIT_ON_DETACH false
set -q ZELLIJ_AUTO_ATTACH; or set -g ZELLIJ_AUTO_ATTACH false

# --- SSH nesting guard ---
# Same problem as tmux: SSH doesn't forward $ZELLIJ (or $ZELLIJ_SOCKET_DIR)
# to the remote shell, even when "remote" is the same host you're already
# in a zellij session on. Unlike tmux, zellij has no single always-on
# server shared by every session, so we can't stash state on "the server".
# Instead we use a fixed, $HOME-rooted file as shared out-of-band storage
# -- $HOME survives the SSH hop because it's the same user on the same
# host, even though no zellij-specific env var does.
#
# Right before running `ssh` from inside zellij, bump a depth counter in
# that file; right after `ssh` returns, decrement it. A shell that lost
# $ZELLIJ can still check the (same, filesystem-backed) counter to learn
# "is there an SSH hop in flight from a zellij pane on this host?".
#
# This is scoped correctly because the "am I nested" check below only
# ever matters when $ZELLIJ is *absent* locally -- a sibling pane that
# still has $ZELLIJ set is never affected by the shared counter file.

set -g __zj_guard_file "$HOME/.cache/zellij-fish/nested_ssh_depth"

function __zj_ssh_depth -d "Read the current nested-ssh depth from the guard file"
    if test -f "$__zj_guard_file"
        set -l val (cat "$__zj_guard_file" 2>/dev/null)
        if string match -qr '^[0-9]+$' -- "$val"
            echo $val
            return
        end
    end
    echo 0
end

function __zj_ssh_preexec -d "Mark an outgoing ssh hop for zellij nesting detection" --on-event fish_preexec
    set -q ZELLIJ; or return
    string match -qr '(^|[\s;&|]+)ssh($|\s)' -- "$argv[1]"; or return
    mkdir -p (dirname "$__zj_guard_file") 2>/dev/null
    math (__zj_ssh_depth) + 1 >"$__zj_guard_file" 2>/dev/null
end

function __zj_ssh_postexec -d "Clear the outgoing ssh hop marker" --on-event fish_postexec
    set -q ZELLIJ; or return
    string match -qr '(^|[\s;&|]+)ssh($|\s)' -- "$argv[1]"; or return
    set -l depth (math (__zj_ssh_depth) - 1)
    if test $depth -le 0
        rm -f "$__zj_guard_file" 2>/dev/null
    else
        echo $depth >"$__zj_guard_file" 2>/dev/null
    end
end

# Check if the *current* shell is a zellij pane that reached us over SSH
# and lost $ZELLIJ along the way. Only meaningful when $ZELLIJ is unset
# locally -- if it's set, we're a normal pane and are never "nested"
# regardless of what the shared guard file says.
function __zj_is_nested_ssh -d "Detect nested zellij over SSH"
    set -q ZELLIJ; and return 1
    # Same reasoning as tmux: only a shell that's itself reached via SSH
    # can be the nested case. A plain local shell is exempt even if the
    # shared guard file says an unrelated SSH session is in flight.
    set -q SSH_TTY; or set -q SSH_CONNECTION; or return 1
    test (__zj_ssh_depth) -gt 0
end

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
    # Block manual attachment if we're a zellij pane that reached this
    # shell over SSH without $ZELLIJ being forwarded (prevents broken
    # self-referential nesting).
    if __zj_is_nested_ssh
        echo "Error: Already inside a zellij session reached over SSH (\$ZELLIJ wasn't forwarded). Refusing to nest 'za' to avoid a broken attach." >&2
        return 1
    end

    set -l target (__zj_session_arg $argv[1] $ZELLIJ_DEFAULT_SESSION)

    zellij attach -c $target
end

function zd -d "Delete a session (default: current)"
    set -l target $argv[1]
    # Resolve current session natively even if $ZELLIJ_SESSION_NAME isn't forwarded
    if test -z "$target"
        if set -q ZELLIJ_SESSION_NAME
            set target $ZELLIJ_SESSION_NAME
        else
            set target (basename $PWD)
        end
    end
    zellij delete-session $target
end

function zk -d "Kill a session (default: current)"
    set -l target $argv[1]
    if test -z "$target"
        if set -q ZELLIJ_SESSION_NAME
            set target $ZELLIJ_SESSION_NAME
        else
            set target (basename $PWD)
        end
    end
    zellij kill-session $target
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
    # If we're a pane that reached this shell over SSH without $ZELLIJ
    # being forwarded, abort immediately -- don't auto-attach into ourselves.
    if __zj_is_nested_ssh
        return 0
    end

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
