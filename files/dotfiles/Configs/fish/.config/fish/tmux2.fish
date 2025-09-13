# Helper function to check if a tmux session exists
function _tmux_session_exists -a session
    tmux has-session -t $session 2>/dev/null
end
# Helper function to create a new tmux session
function _tmux_create_session -a session
    if set -q TMUX
        tmux new-session -d -s $session
    else
        tmux new-session -s $session
    end
end
# Helper function to list all tmux sessions
function _tmux_list_sessions
    tmux list-sessions -F '#{session_name}' 2>/dev/null
end
# Helper function to connect to a tmux session
function _tmux_connect -a session
    if set -q TMUX
        tmux switch-client -t $session
    else
        tmux attach-session -t $session
    end
end
# Attach to a tmux session (using current directory name if no argument)
function tma
    set target (test (count $argv) -eq 0 && echo (basename (pwd)) || echo $argv[1])
    # Use main session if current directory session doesn't exist and no args
    if test (count $argv) -eq 0; and not _tmux_session_exists $target
        set target main
    end
    # Create session if needed
    if not _tmux_session_exists $target
        if not tmn $target >/dev/null # Create the session using tmn, suppressing output
            # If tmn failed, print an error message and return
            echo "Failed to create TMUX session: $target"
            return 1
        end
        # If not already in tmux, attach to the session and return
        if not set -q TMUX
            tmux attach-session -t $target
            return
        end
    end
    _tmux_connect $target
end
# Kill a tmux session (default: currently attached session)
function tmk
    if test (count $argv) -gt 0
        # Explicit session name provided
        set target $argv[1]
    else if set -q TMUX
        # No session name provided, but we're in tmux - get current session
        set target (tmux display-message -p '#{session_name}')
        if test -z "$target"
            echo "Failed to determine current tmux session"
            return 1
        end
    else
        # No session name provided and not in tmux
        echo "Not in a tmux session. Please specify a session name to kill."
        echo "Usage: tmk [session_name]"
        return 1
    end

    if _tmux_session_exists $target
        tmux kill-session -t $target
        # Special handling for main session
        test $target = main; and rm -f $_tmux_main_connected
        echo "Killed session '$target'"
    else
        echo "No session '$target' to kill"
        return 1
    end
end
# Create a session for the current directory and attach to it
function tmds
    set target (basename (pwd))

    if set -q TMUX
        # We're inside tmux
        if _tmux_session_exists $target
            # Session exists, just switch to it
            tmux switch-client -t $target
        else
            # Session doesn't exist, create it and switch to it
            tmux new-session -d -s $target
            tmux switch-client -t $target
        end
    else
        # We're not in tmux, use tma to create or attach
        tma $target
    end
end
# Switch to an existing session (only works inside tmux)
function tms
    if not set -q TMUX
        echo "Not inside a tmux session. Use 'tma <session>' to attach to a session."
        return 1
    end
    if test (count $argv) -eq 0
        echo "Usage: tms <session_name>"
        echo "Available sessions:"
        _tmux_list_sessions
        return 1
    end
    if _tmux_session_exists $argv[1]
        tmux switch-client -t $argv[1]
    else
        echo "Session '$argv[1]' does not exist"
        echo "Available sessions:"
        _tmux_list_sessions
    end
end
# Create a new detached session (optionally with a command)
function tmn
    if test (count $argv) -eq 0
        echo "Usage: tmn <session_name> [command]"
        return 1
    end
    if _tmux_session_exists $argv[1]
        echo "Session '$argv[1]' already exists"
        set -l cmd (set -q TMUX && echo tms || echo tma)
        set -l action (set -q TMUX && echo switch || echo attach)
        echo "Use '$cmd $argv[1]' to $action to it"
        return 1
    end
    tmux new-session -d -s $argv[1] $argv[2..-1]
    echo "Created detached session: $argv[1]"
end
# Detach from current session and attach to a named session (create if needed)
function tmsw
    if test (count $argv) -eq 0
        echo "Usage: tmsw <session_name>"
        echo "       tmsw -   # switch to last session"
        return 1
    end
    set target $argv[1]
    if test "$target" = -
        if set -q TMUX
            tmux switch-client -l
        else
            echo "Error: The '-' option is only available when inside a tmux session."
            return 1
        end
    else
        if set -q TMUX
            # We're inside tmux
            if _tmux_session_exists $target
                # Session exists, just switch to it
                tmux switch-client -t $target
            else
                # Session doesn't exist, create it and switch to it
                tmux new-session -d -s $target
                tmux switch-client -t $target
            end
        else
            # We're not in tmux, use tma to create or attach
            tma $target
        end
    end
end
# List all tmux sessions
alias tmls='tmux list-sessions'
# Auto-initialization
if status is-interactive; and command -q tmux; and test "$TERM_PROGRAM" != vscode; and not set -q _tmux2_loaded; and not set -q TMUX
    set -g _tmux2_loaded true
    set -g _tmux_main_connected /tmp/tmux_main_connected
    if not test -f $_tmux_main_connected
        if _tmux_session_exists main; and test (tmux display-message -p -t main '#{session_attached}' 2>/dev/null) = 0
            tmux attach -t main
        else if not _tmux_session_exists main
            tmux new-session -s main
        end
    end
    function tmux_cleanup --on-event fish_exit
        rm -f $_tmux_main_connected 2>/dev/null
        set -e _tmux2_loaded
    end
end
# Completions
complete -c tma -f -a "(_tmux_list_sessions)"
complete -c tmk -f -a "(_tmux_list_sessions)"
complete -c tms -f -a "(if set -q TMUX; _tmux_list_sessions; end)"
complete -c tmsw -f -a "(_tmux_list_sessions) -"
