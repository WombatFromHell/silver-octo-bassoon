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



# Abort if ZELLIJ_ENABLED is false
set -q ZELLIJ_ENABLED; or set -g ZELLIJ_ENABLED true
if not __is_truthy "$ZELLIJ_ENABLED"
    return 0
end

# --- Configuration ---
set -q ZELLIJ_DEFAULT_SESSION; or set -g ZELLIJ_DEFAULT_SESSION main
set -q ZELLIJ_ON_SSH; or set -g ZELLIJ_ON_SSH false
set -q ZELLIJ_EXIT_ON_DETACH; or set -g ZELLIJ_EXIT_ON_DETACH false
set -q ZELLIJ_AUTO_ATTACH; or set -g ZELLIJ_AUTO_ATTACH false

# --- SSH nesting guard (shared core: 00-mux-common.fish) ---
# Same problem as tmux: SSH doesn't forward $ZELLIJ to the remote shell.
# The full rationale and shared depth-counter logic live in
# 00-mux-common.fish; a $HOME-rooted file is the storage backend here.
set -g __zj_guard_file "$HOME/.cache/zellij-fish/nested_ssh_depth"

function __zj_ssh_preexec -d "Mark an outgoing ssh hop for zellij nesting detection" --on-event fish_preexec
    __mux_ssh_preexec ZELLIJ file $__zj_guard_file $argv[1]
end

function __zj_ssh_postexec -d "Clear the outgoing ssh hop marker" --on-event fish_postexec
    __mux_ssh_postexec ZELLIJ file $__zj_guard_file $argv[1]
end

# Check if the *current* shell is a zellij pane that reached us over SSH
# and lost $ZELLIJ along the way. Only meaningful when $ZELLIJ is unset.
function __zj_is_nested_ssh -d "Detect nested zellij over SSH"
    __mux_is_nested_ssh ZELLIJ file $__zj_guard_file
end

# --- Helpers ---
function __zj_sessions -d "List session names for completions"
    zellij list-sessions 2>/dev/null \
        | string replace -ra '\x1b\[[0-9;]*m' '' \
        | string replace -r '^(\S+)\s+\[(.+)\].*$' '$1'
end

function __zj_session_arg -d "Resolve session name: arg, else fallback"
    test -n "$argv[1]"; and echo $argv[1]; or echo $argv[2]
end

function __zj_current_session -d "Name of the session we're currently in, or CWD basename as fallback"
    if set -q ZELLIJ_SESSION_NAME
        echo $ZELLIJ_SESSION_NAME
    else
        basename $PWD
    end
end

# --- Attach marker (Option B: auto-attach only for the first client) ---
# zellij exposes no "is this session attached" query, so track it locally
# via the shared marker in 00-mux-common.fish: claimed atomically when a
# client attaches, released on detach. $XDG_RUNTIME_DIR resets each login,
# so any leaked marker (exec/exit-on-detach) still re-arms next boot.
set -g __zj_attached_dir (__mux_attach_dir zellij-fish)

# --- Completions ---
complete -c za -a "(__zj_sessions)"
complete -c zd -a "(__zj_sessions)"
complete -c zk -a "(__zj_sessions)"

# --- Public API ---
function za -d "Attach to session, creating it if missing (default: \$ZELLIJ_DEFAULT_SESSION)"
    if __zj_is_nested_ssh
        echo "Error: Already inside a zellij session reached over SSH (\$ZELLIJ wasn't forwarded). Refusing to nest 'za' to avoid a broken attach." >&2
        return 1
    end
    set -l target (__zj_session_arg $argv[1] $ZELLIJ_DEFAULT_SESSION)
    # ponytail: manual attach must not touch the first-client-only marker
    # (auto-start's claim/release owns it) -- matches herdr's hrd/hrda.
    zellij attach -c $target
end

function zd -d "Delete a session (default: current)"
    zellij delete-session (__zj_session_arg $argv[1] (__zj_current_session))
end

function zk -d "Kill a session (default: current)"
    zellij kill-session (__zj_session_arg $argv[1] (__zj_current_session))
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
    __mux_in_other_mux ZELLIJ; and return 0
    if not __is_truthy "$ZELLIJ_AUTO_ATTACH"
        return 0
    else if string match -qir '^(vscode|cursor|windsurf|zed|hyper)$' "$TERM_PROGRAM"; or set -q INSIDE_EMACS; or set -q JETBRAINS_IDE
        return 0
    else if test -n "$SSH_TTY"; and not __is_truthy "$ZELLIJ_ON_SSH"
        return 0
    end
    # ponytail: atomic claim, so simultaneous terminals can't both pass a
    # check-then-set race -- exactly one wins the mkdir and auto-attaches,
    # the rest stay plain shells. Released when the attach returns.
    if not __mux_claim_attach $__zj_attached_dir $ZELLIJ_DEFAULT_SESSION
        return 0
    end
    if __is_truthy "$ZELLIJ_EXIT_ON_DETACH"
        # ponytail: exec replaces this shell, so the marker clears only on
        # next login ($XDG_RUNTIME_DIR reset), not on detach.
        exec zellij attach -c $ZELLIJ_DEFAULT_SESSION
    else
        zellij attach -c $ZELLIJ_DEFAULT_SESSION
        __mux_release_attach $__zj_attached_dir $ZELLIJ_DEFAULT_SESSION
    end
end


