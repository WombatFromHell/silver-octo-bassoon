function tma
    # Determine target session
    if test (count $argv) -eq 0
        set dir_name (basename (pwd))
        set target_session (tmux has-session -t $dir_name 2>/dev/null && echo $dir_name || echo main)
    else
        set target_session $argv[1]
    end

    # Create session if it doesn't exist
    if not tmux has-session -t $target_session 2>/dev/null
        if set -q TMUX
            tmux new-session -d -s $target_session
        else
            tmux new-session -s $target_session
            return
        end
    end

    # Attach or switch to session
    if set -q TMUX
        tmux switch-client -t $target_session
    else
        tmux attach-session -t $target_session
    end
end

function tmk
    if test (count $argv) -eq 0
        # No arguments provided, kill 'main' session
        if tmux has-session -t main 2>/dev/null
            tmux kill-session -t main
            rm -f $_tmux_main_connected
            echo "Killed 'main' session"
        else
            echo "No 'main' session to kill"
        end
    else
        # Session name provided as argument
        set session_name $argv[1]
        if tmux has-session -t $session_name 2>/dev/null
            tmux kill-session -t $session_name
            echo "Killed session '$session_name'"
        else
            echo "No session '$session_name' to kill"
        end
    end
end

function tmds
    set dir_name (basename (pwd))

    if not tmux has-session -t $dir_name 2>/dev/null
        # Session doesn't exist, create it
        if set -q TMUX
            # Inside tmux - create detached session and switch to it
            tmux new-session -d -s $dir_name
            tmux switch-client -t $dir_name
            echo "Created and switched to TMUX session: $dir_name"
        else
            # Outside tmux - create and attach normally
            tmux new-session -s $dir_name
            echo "Created TMUX session: $dir_name"
        end
    else
        # Session already exists
        if set -q TMUX
            # Inside tmux - switch to existing session
            tmux switch-client -t $dir_name
            echo "Switched to existing TMUX session: $dir_name"
        else
            # Outside tmux - attach to existing session
            tmux attach-session -t $dir_name
            echo "Attached to existing TMUX session: $dir_name"
        end
    end
end

function tms
    if not set -q TMUX
        echo "Not inside a tmux session. Use 'tma <session>' to attach to a session."
        return 1
    end

    if test (count $argv) -eq 0
        echo "Usage: tms <session_name>"
        echo "Available sessions:"
        tmux list-sessions -F "#{session_name}"
        return 1
    end

    set session_name $argv[1]
    if tmux has-session -t $session_name 2>/dev/null
        tmux switch-client -t $session_name
    else
        echo "Session '$session_name' does not exist"
        echo "Available sessions:"
        tmux list-sessions -F "#{session_name}"
    end
end

function tmn
    if test (count $argv) -eq 0
        echo "Usage: tmn <session_name> [command]"
        return 1
    end

    set session_name $argv[1]
    if tmux has-session -t $session_name 2>/dev/null
        echo "Session '$session_name' already exists"
        if set -q TMUX
            echo "Use 'tms $session_name' to switch to it"
        else
            echo "Use 'tma $session_name' to attach to it"
        end
        return 1
    end

    if test (count $argv) -gt 1
        # Create session with specific command
        tmux new-session -d -s $session_name $argv[2..-1]
    else
        # Create session with default shell
        tmux new-session -d -s $session_name
    end
    echo "Created detached session: $session_name"
end
alias tmls='tmux list-sessions'

if status is-interactive; and command -q tmux; and test "$TERM_PROGRAM" != vscode
    # Prevent multiple loading and tmux nesting
    if set -q _tmux2_loaded; or set -q TMUX
        # Already loaded or inside tmux, skip initialization
        return
    end

    # Mark as loaded to prevent re-initialization
    set -g _tmux2_loaded true

    # Define a flag file to track if we've connected before
    set -g _tmux_main_connected /tmp/tmux_main_connected

    # First-time connection check - only if not already inside tmux
    if not test -f $_tmux_main_connected
        if tmux has-session -t main 2>/dev/null
            set -l attached (tmux display-message -p -t main '#{session_attached}' 2>/dev/null)
            if test "$attached" = 0
                tmux attach -t main
            end
        else
            tmux new-session -s main
        end
    end

    # Clean up function
    function tmux_cleanup --on-event fish_exit
        if test -f $_tmux_main_connected
            rm -f $_tmux_main_connected
        end
        set -e _tmux2_loaded
    end
end
