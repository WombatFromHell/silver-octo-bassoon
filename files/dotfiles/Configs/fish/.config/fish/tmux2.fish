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
        _tmux_create_session $target
        # If not already in tmux, we're done after creating
        if not set -q TMUX
            return
        end
    end

    _tmux_connect $target
end

# Kill a tmux session (default: main)
function tmk
    set target (test (count $argv) -eq 0 && echo main || echo $argv[1])

    if _tmux_session_exists $target
        tmux kill-session -t $target
        test $target = main; and rm -f $_tmux_main_connected
        echo "Killed session '$target'"
    else
        echo "No session '$target' to kill"
    end
end

# Create a session for the current directory and attach to it
function tmds
    set target (basename (pwd))

    if not _tmux_session_exists $target
        _tmux_create_session $target
        echo "Created TMUX session: $target"
    else
        _tmux_connect $target
        set -l action (set -q TMUX && echo "Switched to" || echo "Attached to")
        echo "$action existing TMUX session: $target"
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
