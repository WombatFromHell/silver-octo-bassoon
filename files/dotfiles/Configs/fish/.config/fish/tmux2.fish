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
            tmux attach-session -t main
            touch $_tmux_main_connected # Mark as connected
        else
            tmux new-session -s main
            touch $_tmux_main_connected # Mark as connected
        end
    end

    # Define convenient functions for tmux operations
    function tma
        # Prevent nesting - check if already inside tmux
        if set -q TMUX
            echo "Already inside a tmux session. Use 'tmux switch-client -t <session>' to switch sessions."
            return 1
        end

        if test (count $argv) -eq 0
            # No arguments provided, attach to 'main' session
            if not tmux has-session -t main 2>/dev/null
                tmux new-session -s main
            end
            tmux attach-session -t main
        else
            # Session name provided as argument
            set session_name $argv[1]
            if not tmux has-session -t $session_name 2>/dev/null
                tmux new-session -s $session_name
            end
            tmux attach-session -t $session_name
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

    alias tmls='tmux list-sessions'

    # New function to create a session named after current directory
    function tmux_new_dir_session
        # Prevent nesting - check if already inside tmux
        if set -q TMUX
            echo "Already inside a tmux session. Use 'tmux new-session -d -s <name>' to create detached sessions."
            return 1
        end

        set dir_name (basename (pwd))
        if not tmux has-session -t $dir_name 2>/dev/null
            tmux new-session -s $dir_name
            echo "Created TMUX session: $dir_name"
        else
            echo "TMUX session '$dir_name' already exists"
            tmux attach-session -t $dir_name
        end
    end
    alias tmds=tmux_new_dir_session

    # Function to switch between sessions from within tmux
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

    # Function to create new detached sessions from within tmux
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

    # Clean up function
    function tmux_cleanup
        if test -f $_tmux_main_connected
            rm -f $_tmux_main_connected
        end
        set -e _tmux2_loaded
    end

    # Set up cleanup on fish exit
    function __tmux_cleanup_on_exit --on-event fish_exit
        tmux_cleanup
    end
end
