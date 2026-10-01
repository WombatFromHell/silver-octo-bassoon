# 00-mux-common.fish — shared safety logic for the tmux/zellij/herdr helpers.
#
# The 00- prefix forces this to load FIRST in the helpers/ glob (cf. the
# zz- "sorts last" convention in zz-init.fish): herdr.fish's top-level
# auto-start block calls the guard at source time, so the shared module
# must exist before any mux helper is sourced.
#
# Sections:
#   1. SSH nesting guard   (used by all three muxes)
#   2. Attach marker       (used by zellij + herdr)

# --- 1. SSH nesting guard ---
# SSH does not forward the mux's own env var ($TMUX/$ZELLIJ/$HERDR_ENV) to
# the remote shell, even when "remote" is the same host. A shell reached
# via `ssh <same host>` from inside a mux pane therefore looks like a
# fresh login; if it auto-attaches it re-attaches the session it's already
# a pane of (self-referential attach + resize feedback loop).
#
# Fix: right before running `ssh` from inside the mux, bump a depth
# counter in shared out-of-band storage (tmux server global env for tmux;
# a $HOME-rooted file for zellij/herdr -- $HOME survives the SSH hop);
# decrement when `ssh` returns. A shell that lost the mux env var can then
# ask "is there an SSH hop in flight from a mux pane on this host?" and
# get a truthful answer. The check only ever matters when the mux env var
# is *absent* locally, so sibling panes are never affected.

# True if $argv[1] is a command line that runs a whole-word `ssh`.
function __mux_ssh_cmd_match
    string match -qr '(^|[\s;&|]+)ssh($|\s)' -- "$argv[1]"
end

# --- file backend (zellij + herdr) ---
function __mux_file_ssh_depth --description "Read nested-ssh depth from a guard file (0 if missing/invalid)"
    set -l file $argv[1]
    if test -f "$file"
        set -l val (cat "$file" 2>/dev/null)
        if string match -qr '^[0-9]+$' -- "$val"
            echo $val
            return
        end
    end
    echo 0
end

function __mux_file_ssh_write --description "Write nested-ssh depth to a guard file (<=0 removes it)"
    set -l file $argv[1]
    set -l depth $argv[2]
    mkdir -p (dirname "$file") 2>/dev/null
    if test $depth -le 0
        rm -f "$file" 2>/dev/null
    else
        echo $depth >"$file" 2>/dev/null
    end
end

# --- tmux server backend (tmux) ---
function __mux_tmux_ssh_depth --description "Read nested-ssh depth from the tmux server env"
    set -l line (tmux show-environment -g TMUX_NESTED_SSH_DEPTH 2>/dev/null)
    set -l val (string replace -r '^TMUX_NESTED_SSH_DEPTH=' '' -- $line)
    if test -z "$val"
        echo 0
    else
        echo $val
    end
end

function __mux_tmux_ssh_write --description "Write nested-ssh depth to the tmux server env (<=0 unsets it)"
    set -l depth $argv[1]
    if test $depth -le 0
        tmux set-environment -gu TMUX_NESTED_SSH_DEPTH 2>/dev/null
    else
        tmux set-environment -g TMUX_NESTED_SSH_DEPTH $depth 2>/dev/null
    end
end

# --- core (shared by all three muxes) ---
# $argv: envvar backend backend-arg cmdline
# backend: file (backend-arg = guard file) | tmux (backend-arg ignored)
function __mux_ssh_preexec --description "Bump nested-ssh depth before an outgoing ssh"
    set -q $argv[1]; or return
    __mux_ssh_cmd_match $argv[4]; or return
    if test "$argv[2]" = file
        __mux_file_ssh_write $argv[3] (math (__mux_file_ssh_depth $argv[3]) + 1)
    else
        __mux_tmux_ssh_write (math (__mux_tmux_ssh_depth) + 1)
    end
end

function __mux_ssh_postexec --description "Drop nested-ssh depth after a returned ssh"
    set -q $argv[1]; or return
    __mux_ssh_cmd_match $argv[4]; or return
    if test "$argv[2]" = file
        __mux_file_ssh_write $argv[3] (math (__mux_file_ssh_depth $argv[3]) - 1)
    else
        __mux_tmux_ssh_write (math (__mux_tmux_ssh_depth) - 1)
    end
end

# $argv: envvar backend backend-arg
# True (0) only when: mux env var absent, this shell reached via SSH, depth > 0.
function __mux_is_nested_ssh --description "Detect a mux pane reached over SSH"
    set -q $argv[1]; and return 1
    set -q SSH_TTY; or set -q SSH_CONNECTION; or return 1
    if test "$argv[2]" = file
        test (__mux_file_ssh_depth $argv[3]) -gt 0
    else
        test (__mux_tmux_ssh_depth) -gt 0
    end
end

# $argv: own mux env var (TMUX | ZELLIJ | HERDR_ENV)
# True if we're inside another multiplexer.
function __mux_in_other_mux --description "True if inside another mux"
    for var in TMUX ZELLIJ HERDR_ENV
        test "$var" = "$argv[1]"; and continue
        set -q $var; and return 0
    end
    return 1
end

# --- 2. Attach marker (first-client-only auto-attach; zellij + herdr) ---
# Neither mux exposes an "is this session attached" query, so track it
# locally: a marker dir per session, claimed atomically when a client
# attaches, released on detach. $XDG_RUNTIME_DIR resets each login, so a
# leaked marker (exec/exit-on-detach) still re-arms next boot.

# $argv: muxdir name (zellij-fish | herdr-fish)
function __mux_attach_dir --description "Attach-marker base dir for a mux"
    set -l dir /tmp/$argv[1]
    test -n "$XDG_RUNTIME_DIR"; and set dir "$XDG_RUNTIME_DIR/$argv[1]"
    echo $dir
end

# $argv: dir session
function __mux_marker --description "Attach-marker path for a session"
    echo "$argv[1]/attached_$argv[2]"
end

# $argv: dir session
# Atomically claim the marker; succeeds only for the first live caller.
function __mux_claim_attach --description "Atomically claim the attach marker"
    set -l marker (__mux_marker $argv[1] $argv[2])
    mkdir -p "$argv[1]" 2>/dev/null
    if mkdir $marker 2>/dev/null
        # we won the race -- stamp ownership so a future caller can tell
        # if we're actually still alive
        echo $fish_pid >$marker/pid
        return 0
    end
    # ponytail: someone already holds it -- but if that someone is dead
    # (killed terminal, crash, OOM), the marker is just litter. Check the
    # stamped pid; if it's gone, the lock is stale, clear it and retry
    # once. This is the only new logic -- no session-tracking, no polling.
    set -l owner_file $marker/pid
    if test -f "$owner_file"
        set -l owner_pid (cat "$owner_file" 2>/dev/null)
        if test -n "$owner_pid"; and not kill -0 $owner_pid 2>/dev/null
            rm -rf $marker 2>/dev/null
            mkdir -p "$argv[1]" 2>/dev/null
            if mkdir $marker 2>/dev/null
                echo $fish_pid >$marker/pid
                return 0
            end
        end
    end
    return 1
end

# $argv: dir session
function __mux_release_attach --description "Release the attach marker"
    rm -rf (__mux_marker $argv[1] $argv[2]) 2>/dev/null
end
