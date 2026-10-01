#!/usr/bin/env fish

# ==============================================================================
# HERDR HELPER
# ------------------------------------------------------------------------------
# Thin wrappers over the herdr CLI.
#
# Commands:
#   hrd              Launch/attach the persistent session (native herdr).
#   hrd <session>    Attach to a named session (herdr session attach).
#   hrda [session]   Attach to a session (defaults to HERDR_DEFAULT_SESSION).
#   hrdssh <target>  Attach to a remote herdr server through SSH.
#   hrdr             Reload the server config.
#   hrdk [session]   Stop and delete a session (default: HERDR_DEFAULT_SESSION;
#                    stops the server if the deleted session was the last one).
#   hrdl             List all sessions.
#   hrdw [label]     Create a workspace for the current dir (label = basename).
#   hrdwt [args]     Create a worktree for the current git repo.
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

# --- SSH nesting guard (shared core: 00-mux-common.fish) ---
# Same problem as tmux/zellij: SSH does not forward $HERDR_ENV to the remote
# shell. The full rationale and shared depth-counter logic live in
# 00-mux-common.fish; a $HOME-rooted file is the storage backend here.

set -g __herdr_guard_file "$HOME/.cache/herdr-fish/nested_ssh_depth"

function __herdr_ssh_preexec -d "Mark an outgoing ssh hop for herdr nesting detection" --on-event fish_preexec
    __mux_ssh_preexec HERDR_ENV file $__herdr_guard_file $argv[1]
end

function __herdr_ssh_postexec -d "Clear the outgoing ssh hop marker" --on-event fish_postexec
    __mux_ssh_postexec HERDR_ENV file $__herdr_guard_file $argv[1]
end

# Check if the *current* shell is a herdr pane that reached us over SSH and
# lost $HERDR_ENV along the way. Only meaningful when $HERDR_ENV is unset
# locally.
function __herdr_is_nested_ssh -d "Detect nested herdr over SSH"
    __mux_is_nested_ssh HERDR_ENV file $__herdr_guard_file
end

# Shared guard used by hrd/hrda: print the error and fail if nested-SSH.
function __herdr_guard_nested_ssh -d "Abort with an error if this shell is a nested-SSH herdr pane"
    __herdr_is_nested_ssh; or return 0
    echo "Error: Already inside a herdr session reached over SSH (\$HERDR_ENV wasn't forwarded). Refusing to nest '$argv[1]' to avoid a broken attach." >&2
    return 1
end

# --- Shared Helpers ---



# Session names (for completions and hrdk).
function __herdr_list_session_names -d "List session names"
    herdr session list 2>/dev/null | string match -r '^[^ ]+' | string match -rv '^name$'
end

# First arg, or the default session.
function __herdr_session -d "Resolve session name from arg or default"
    if set -q argv[1]
        echo $argv[1]
    else
        echo $HERDR_DEFAULT_SESSION
    end
end

# --- Attach marker (first-client-only auto-attach) ---
# Mirrors the zellij helper: herdr exposes no "is this session already
# attached" query we key auto-attach off of, so track it locally via the
# shared marker in 00-mux-common.fish. $XDG_RUNTIME_DIR resets each login, so
# a leaked marker (exec/exit-on-detach) still re-arms next boot.
set -g __herdr_attached_dir (__mux_attach_dir herdr-fish)

# --- Public API ---

function hrd -d "Launch/attach herdr, or attach to a named session"
    __herdr_guard_nested_ssh hrd; or return 1
    if set -q argv[1]
        herdr session attach $argv[1]
    else
        herdr
    end
end

function hrda -d "Attach to a herdr session"
    __herdr_guard_nested_ssh hrda; or return 1
    herdr session attach (__herdr_session $argv)
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

function hrdk -d "Stop and delete a herdr session"
    set -l session (__herdr_session $argv)
    herdr session stop $session
    herdr session delete $session
    set -l rest (__herdr_list_session_names)
    # ponytail: stop the server only when the deleted session leaves nothing
    # but 'default' (or nothing at all) behind.
    test (count $rest) -le 1; or return
    test (count $rest) -eq 0; or test "$rest[1]" = default; or return
    herdr server stop
end

function hrdl -d "List herdr sessions"
    herdr session list
end

function hrdw -d "Create a herdr workspace for the current directory"
    set -l label (basename $PWD)
    test -n "$argv[1]"; and set label $argv[1]
    herdr workspace create --label $label --cwd $PWD
end

function hrdwt -d "Create a herdr worktree for the current repo"
    herdr worktree create --cwd $PWD $argv
end

# --- Completions ---
complete -c hrd -f -a "(__herdr_list_session_names)"
complete -c hrda -f -a "(__herdr_list_session_names)"
complete -c hrdssh -f -l session -a "(__herdr_list_session_names)"
complete -c hrdk -f -a "(__herdr_list_session_names)"

# --- Auto-Start Logic ---
# Only runs in interactive shells not currently inside herdr (HERDR_ENV is set
# by herdr once a session is running).
if status is-interactive; and not set -q HERDR_ENV
    # If we're a pane that reached this shell over SSH without $HERDR_ENV being
    # forwarded, abort immediately -- don't auto-attach into ourselves.
    if __herdr_is_nested_ssh
        return 0
    end
    __mux_in_other_mux HERDR_ENV; and return 0

    # IDE list kept in sync with zellij.fish:
    set -l auto $HERDR_AUTO_ATTACH
    string match -qir '^(vscode|cursor|windsurf|zed|hyper)$' "$TERM_PROGRAM"; and set auto false
    set -q INSIDE_EMACS; and set auto false
    set -q JETBRAINS_IDE; and set auto false
    test -n "$SSH_TTY"; and not __is_truthy "$HERDR_ON_SSH"; and set auto false
    if __is_truthy "$auto"
        # ponytail: atomic claim, so simultaneous terminals can't both pass a
        # check-then-set race -- exactly one wins the mkdir and auto-attaches,
        # the rest stay plain shells. Released when the attach returns.
        if __mux_claim_attach $__herdr_attached_dir $HERDR_DEFAULT_SESSION
            if __is_truthy "$HERDR_EXIT_ON_DETACH"
                # ponytail: exec replaces this shell, so the marker clears only
                # on next login ($XDG_RUNTIME_DIR reset), not on detach.
                exec herdr --session $HERDR_DEFAULT_SESSION
            else
                herdr --session $HERDR_DEFAULT_SESSION
                __mux_release_attach $__herdr_attached_dir $HERDR_DEFAULT_SESSION
            end
        end
    end
end

