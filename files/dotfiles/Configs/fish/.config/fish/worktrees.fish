function gwt --description "Switch to a git worktree by name"
    # Check if an argument was provided
    if test (count $argv) -eq 0
        echo "Usage: gwt <worktree-name>"
        return 1
    end

    # Get the path.
    # 1. List worktrees
    # 2. Grep for the argument
    # 3. Use awk to grab the first column (the path)
    # 4. Use head to grab the first match if multiple exist
    set -l path (git worktree list | grep $argv[1] | awk '{print $1}' | head -n 1)

    if test -n "$path"
        cd $path
        echo "Switched to worktree: $path"
    else
        echo "Error: Worktree matching '$argv[1]' not found."
    end
end

function gwts --description "Switch to a git worktree using fzf"
    # Check if fzf exists
    if not type -q fzf
        echo "Error: fzf is not installed."
        return 1
    end

    # Capture the selection
    # 1. List worktrees
    # 2. Pipe to fzf for selection
    # 3. awk extracts the path (column 1)
    set -l target (git worktree list | fzf | awk '{print $1}')

    # If a target was selected (user didn't press Esc/Ctrl-C), cd into it
    if test -n "$target"
        cd $target
    end
end

function gwtc --description "Create a new git worktree and branch"
    if test (count $argv) -eq 0
        echo "Usage: wtc <new-branch-name>"
        return 1
    end

    set -l branch_name $argv[1]
    # Creates a sibling directory ../branch_name
    git worktree add ../$branch_name -b $branch_name
end
