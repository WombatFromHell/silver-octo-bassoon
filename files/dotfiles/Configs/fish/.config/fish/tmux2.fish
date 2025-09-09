# Helper function for tmux operations
function _tmux_connect -a session
    if set -q TMUX
        tmux switch-client -t $session
    else
        tmux attach-session -t $session
    end
end

function tma
    set target (test (count $argv) -eq 0 && echo (basename (pwd)) || echo $argv[1])

    # Use main session if current directory session doesn't exist and no args
    if test (count $argv) -eq 0; and not tmux has-session -t $target 2>/dev/null
        set target main
    end

    # Create session if needed
    if not tmux has-session -t $target 2>/dev/null
        if set -q TMUX
            tmux new-session -d -s $target
        else
            tmux new-session -s $target
            return
        end
    end

    _tmux_connect $target
end
complete -c tma -f -a "(tmux list-sessions -F '#{session_name}' 2>/dev/null)"

function tmk
    set target (test (count $argv) -eq 0 && echo main || echo $argv[1])

    if tmux has-session -t $target 2>/dev/null
        tmux kill-session -t $target
        test $target = main; and rm -f $_tmux_main_connected
        echo "Killed session '$target'"
    else
        echo "No session '$target' to kill"
    end
end
complete -c tmk -f -a "(tmux list-sessions -F '#{session_name}' 2>/dev/null)"

function tmds
    set target (basename (pwd))

    if not tmux has-session -t $target 2>/dev/null
        if set -q TMUX
            tmux new-session -d -s $target
            tmux switch-client -t $target
        else
            tmux new-session -s $target
        end
        echo "Created TMUX session: $target"
    else
        _tmux_connect $target
        echo (set -q TMUX && echo "Switched to" || echo "Attached to")" existing TMUX session: $target"
    end
end

function tms
    if not set -q TMUX
        echo "Not inside a tmux session. Use 'tma <session>' to attach to a session."
        return 1
    end

    if test (count $argv) -eq 0
        echo "Usage: tms <session_name>\nAvailable sessions:"
        tmux list-sessions -F "#{session_name}"
        return 1
    end

    if tmux has-session -t $argv[1] 2>/dev/null
        tmux switch-client -t $argv[1]
    else
        echo "Session '$argv[1]' does not exist\nAvailable sessions:"
        tmux list-sessions -F "#{session_name}"
    end
end
complete -c tms -f -a "(if set -q TMUX; tmux list-sessions -F '#{session_name}' 2>/dev/null; end)"

function tmn
    if test (count $argv) -eq 0
        echo "Usage: tmn <session_name> [command]"
        return 1
    end

    if tmux has-session -t $argv[1] 2>/dev/null
        echo "Session '$argv[1]' already exists"
        echo "Use '"(set -q TMUX && echo tms || echo tma)" $argv[1]' to "(set -q TMUX && echo switch || echo attach)" to it"
        return 1
    end

    tmux new-session -d -s $argv[1] $argv[2..-1]
    echo "Created detached session: $argv[1]"
end

alias tmls='tmux list-sessions'

# Auto-initialization
if status is-interactive; and command -q tmux; and test "$TERM_PROGRAM" != vscode; and not set -q _tmux2_loaded; and not set -q TMUX
    set -g _tmux2_loaded true
    set -g _tmux_main_connected /tmp/tmux_main_connected

    if not test -f $_tmux_main_connected
        if tmux has-session -t main 2>/dev/null; and test (tmux display-message -p -t main '#{session_attached}' 2>/dev/null) = 0
            tmux attach -t main
        else if not tmux has-session -t main 2>/dev/null
            tmux new-session -s main
        end
    end

    function tmux_cleanup --on-event fish_exit
        rm -f $_tmux_main_connected 2>/dev/null
        set -e _tmux2_loaded
    end
end
