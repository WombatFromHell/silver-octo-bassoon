# =============================================================================
# Git Worktree Management Functions
# =============================================================================

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function __gwt_list --description "List worktrees: path, commit, branch"
    git worktree list 2>/dev/null | string match -r '.*' | while read -l line
        if test -z "$line"
            continue
        end
        # Parse: /path/to/worktree <sha> [branch]
        set -l path (echo $line | awk '{print $1}')
        set -l commit (echo $line | awk '{print $2}')
        # Extract branch from brackets, or "(detached)" if none
        set -l branch
        if string match -q -- '*[*]*' "$line"
            set branch (echo $line | awk '{print $3}' | string trim -c '[]')
        else
            set branch "(detached)"
        end
        printf '%s\t%s\t%s\n' "$path" "$commit" "$branch"
    end
end

function __gwt_find_by_name --description "Find worktree path by name or branch pattern"
    if test (count $argv) -eq 0
        return 1
    end
    set -l pattern $argv[1]
    __gwt_list | while read -l line
        string split '\t' "$line" | read -l _path _commit _branch
        if string match -qi "*$pattern*" -- "$_path"
            echo "$_path"
            return 0
        end
        if string match -qi "*$pattern*" -- "$_branch"
            echo "$_path"
            return 0
        end
    end
    return 1
end

function __gwt_get_branch --description "Get the branch name for a worktree path"
    if test (count $argv) -eq 0
        return 1
    end
    set -l target $argv[1]
    __gwt_list | while read -l line
        string split '\t' "$line" | read -l _path _commit _branch
        if test "$_path" = "$target"
            echo "$_branch"
            return 0
        end
    end
    return 1
end

function __gwt_validate --description "Validate worktree exists and has no uncommitted changes"
    if test (count $argv) -eq 0
        echo "Error: No worktree specified" >&2
        return 1
    end
    set -l target $argv[1]

    if not test -d "$target"
        echo "Error: Worktree '$target' does not exist" >&2
        return 1
    end

    # Check for uncommitted changes
    set -l git_status (git -C "$target" status --porcelain 2>/dev/null)
    if test -n "$git_status"
        echo "Error: Worktree '$target' has uncommitted changes" >&2
        echo "  Stash or commit changes before removing" >&2
        return 1
    end

    return 0
end

function __gwt_fzf_check --description "Check if fzf is available"
    if not type -q fzf
        echo "Error: fzf is not installed" >&2
        return 1
    end
    return 0
end

function __gwt_complete_names --description "Completion: worktree names/paths"
    __gwt_list | while read -l line
        string split '\t' "$line" | read -l _path _commit _branch
        set -l name (basename "$_path")
        echo "$name"
    end
end

function __gwt_complete_branches --description "Completion: local branch names"
    git branch --format='%(refname:short)' 2>/dev/null
end

# -----------------------------------------------------------------------------
# Core Functions (existing, enhanced)
# -----------------------------------------------------------------------------

function gwt --description "Switch to a git worktree by name or branch"
    if test (count $argv) -eq 0
        echo "Usage: gwt <worktree-name-or-branch>"
        return 1
    end

    set -l path (__gwt_find_by_name $argv[1])

    if test -n "$path"
        cd $path
        echo "Switched to worktree: $path"
    else
        echo "Error: Worktree matching '$argv[1]' not found."
        return 1
    end
end

function gwts --description "Switch to a git worktree using fzf"
    __gwt_fzf_check || return 1

    set -l target (__gwt_list | fzf --header "Select worktree" | awk -F'\t' '{print $1}')

    if test -n "$target"
        cd $target
        echo "Switched to: $target"
    end
end

function gwtc --description "Create a new git worktree and branch"
    set -l show_help 0
    set -l detach_mode 0
    set -l branch_name ""
    set -l base_branch ""

    # Parse arguments
    while test (count $argv) -gt 0
        switch $argv[1]
            case -h --help
                set show_help 1
            case -d --detach
                set detach_mode 1
            case -b --branch
                set -e argv[1]
                set branch_name $argv[1]
            case '*'
                if test -z "$branch_name"
                    set branch_name $argv[1]
                end
        end
        set -e argv[1]
    end

    if test $show_help -eq 1
        echo "Usage: gwtc [-d|--detach] [-b <base-branch>] <new-branch-name>"
        echo ""
        echo "Create a new git worktree with a new branch."
        echo ""
        echo "Options:"
        echo "  -d, --detach     Create detached HEAD worktree"
        echo "  -b, --branch     Base branch for new branch (default: current branch)"
        echo "  -h, --help       Show this help"
        return 0
    end

    if test -z "$branch_name"
        echo "Usage: gwtc <new-branch-name>"
        echo "       gwtc -d <new-branch-name>"
        return 1
    end

    if test $detach_mode -eq 1
        # Create detached worktree
        git worktree add ../$branch_name --detach
    else if test -n "$base_branch"
        git worktree add ../$branch_name -b $branch_name $base_branch
    else
        git worktree add ../$branch_name -b $branch_name
    end
end

# -----------------------------------------------------------------------------
# List & Info Functions
# -----------------------------------------------------------------------------

function gwtl --description "List all git worktrees in a formatted table"
    echo (set_color cyan)"Git Worktrees"(set_color normal)
    echo ""

    set -l worktrees (__gwt_list | string collect)

    if test -z "$worktrees"
        echo "  No worktrees found"
        echo ""
        return 0
    end

    # Sort by branch name (3rd field) and display
    echo "$worktrees" | sort -t'	' -k3 | while read -l line
        if test -z "$line"
            continue
        end
        string split '\t' "$line" | read -l _path _commit _branch

        printf "  %-40s  %-12s  %s\n" "$_path" "$_commit" "$_branch"
    end
    echo ""
end

function gwti --description "Show info about current worktree"
    set -l current_path (git rev-parse --show-toplevel 2>/dev/null)

    if test -z "$current_path"
        echo "Not in a git repository"
        return 1
    end

    set -l current_branch (git branch --show-current 2>/dev/null)
    if test -z "$current_branch"
        set current_branch "(detached HEAD)"
    end

    set -l is_worktree 0
    set -l worktree_count (git worktree list 2>/dev/null | wc -l)

    if test "$worktree_count" -gt 1
        set is_worktree 1
    end

    echo (set_color cyan)"Current Worktree Info"(set_color normal)
    echo ""
    printf "  Path:   %s\n" "$current_path"
    printf "  Branch: %s\n" "$current_branch"
    printf "  Is worktree: %s\n" (test $is_worktree -eq 1; and echo "yes"; or echo "no (main)")
    printf "  Total worktrees: %s\n" "$worktree_count"
    echo ""
end

# -----------------------------------------------------------------------------
# Remove Functions
# -----------------------------------------------------------------------------

function gwtr --description "Remove a git worktree"
    if test (count $argv) -eq 0
        echo "Usage: gwtr <worktree-path-or-name>"
        echo "       gwtr -f <worktree-path-or-name>  (force)"
        return 1
    end

    set -l force_mode 0
    set -l target ""

    # Parse arguments
    if test "$argv[1]" = -f -o "$argv[1]" = --force
        set force_mode 1
        set target $argv[2]
    else
        set target $argv[1]
    end

    # Find the actual path if name/branch was given
    if not test -d "$target"
        set target (__gwt_find_by_name $target)
        if test -z "$target"
            echo "Error: Worktree not found"
            return 1
        end
    end

    if test $force_mode -eq 0
        __gwt_validate "$target" or return 1

        # Confirm with fzf if available
        if __gwt_fzf_check
            echo "About to remove: $target"
            set -l confirm (echo -e "yes\\nno" | fzf --prompt "Confirm removal: ")
            if test "$confirm" != yes
                echo Cancelled
                return 0
            end
        end
    end

    git worktree remove $target
    if test $status -eq 0
        echo "Removed worktree: $target"
    else
        return 1
    end
end

function gwtrm --description "Remove worktree and delete its branch"
    if test (count $argv) -eq 0
        echo "Usage: gwtrm <worktree-path-or-name> [--force]"
        return 1
    end

    set -l force_mode 0
    set -l target $argv[1]

    # Check for --force flag
    if test (count $argv) -gt 1
        if test "$argv[2]" = -f -o "$argv[2]" = --force
            set force_mode 1
        end
    end

    # Find the actual path if name/branch was given
    if not test -d "$target"
        set target (__gwt_find_by_name $target)
        if test -z "$target"
            echo "Error: Worktree not found"
            return 1
        end
    end

    # Get the branch name before removing
    set -l wt_branch (__gwt_get_branch "$target")

    if test -z "$wt_branch" -o "$wt_branch" = "(detached)"
        echo "Error: Cannot determine branch for '$target'"
        return 1
    end

    # Validate and remove worktree (skip validation if --force)
    if test $force_mode -eq 0
        __gwt_validate "$target" or return 1
    end

    echo "Removing worktree and deleting branch '$wt_branch'..."

    if test $force_mode -eq 1
        git worktree remove --force $target
    else
        git worktree remove $target
    end
    if test $status -ne 0
        return 1
    end
    echo "Removed worktree: $target"

    # Delete the branch
    git branch -D "$wt_branch"
    if test $status -eq 0
        echo "Deleted branch: $wt_branch"
    else
        echo "Warning: Could not delete branch '$wt_branch'"
    end
end

function gwtp --description "Prune stale/missing worktrees"
    echo "Pruning stale worktrees..."
    git worktree prune
    echo "Done. Remaining worktrees:"
    gwtl
end

# -----------------------------------------------------------------------------
# Merge Functions
# -----------------------------------------------------------------------------

function gwtm --description "Merge a worktree's branch into a target branch"
    if test (count $argv) -eq 0
        echo "Usage: gwtm <worktree> [target-branch]"
        echo ""
        echo "Merge the worktree's branch into target (default: main/master)"
        return 1
    end

    set -l worktree_name $argv[1]
    set -l target_branch (test (count $argv) -gt 1; and echo $argv[2]; or echo "")

    # Find worktree
    set -l worktree_path (__gwt_find_by_name $worktree_name)
    if test -z "$worktree_path"
        echo "Error: Worktree '$worktree_name' not found"
        return 1
    end

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch "$worktree_path")
    if test -z "$source_branch" -o "$source_branch" = "(detached)"
        echo "Error: Worktree is detached or branch unknown"
        return 1
    end

    # Determine target branch
    if test -z "$target_branch"
        set -l current (git branch --show-current)
        if test "$current" = main -o "$current" = master -o "$current" = develop
            set target_branch $current
        else
            # Try main, then master
            if git show-ref --verify --quiet refs/heads/main
                set target_branch main
            else if git show-ref --verify --quiet refs/heads/master
                set target_branch master
            else
                echo "Error: No target branch specified and couldn't determine default"
                echo "Usage: gwtm <worktree> <target-branch>"
                return 1
            end
        end
    end

    # Check for uncommitted changes in worktree
    set -l git_status (git -C "$worktree_path" status --porcelain 2>/dev/null)
    if test -n "$git_status"
        echo "Error: Worktree has uncommitted changes"
        echo "  Commit or stash changes in '$worktree_path' before merging"
        return 1
    end

    echo "Merging '$source_branch' (from $worktree_path) into '$target_branch'..."
    echo ""

    # Switch to target branch
    git checkout "$target_branch" || return 1

    # Merge
    git merge "$source_branch" -m "Merge branch '$source_branch' into '$target_branch'"

    if test $status -eq 0
        echo ""
        echo (set_color green)"Merge successful!"(set_color normal)

        # Offer to remove worktree
        if __gwt_fzf_check
            set -l cleanup (echo -e "no\\nyes" | fzf --prompt "Remove worktree '$worktree_path'? ")
            if test "$cleanup" = yes
                gwtr "$worktree_path"
            end
        else
            echo "Tip: Run 'gwtr $worktree_path' to remove the worktree"
        end
    end
end

function gwtms --description "Squash-merge a worktree's branch into a target branch"
    if test (count $argv) -eq 0
        echo "Usage: gwtms <worktree> [target-branch]"
        echo ""
        echo "Squash-merge the worktree's branch into target (default: main/master)"
        return 1
    end

    set -l worktree_name $argv[1]
    set -l target_branch (test (count $argv) -gt 1; and echo $argv[2]; or echo "")

    # Find worktree
    set -l worktree_path (__gwt_find_by_name $worktree_name)
    if test -z "$worktree_path"
        echo "Error: Worktree '$worktree_name' not found"
        return 1
    end

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch "$worktree_path")
    if test -z "$source_branch" -o "$source_branch" = "(detached)"
        echo "Error: Worktree is detached or branch unknown"
        return 1
    end

    # Determine target branch
    if test -z "$target_branch"
        if git show-ref --verify --quiet refs/heads/main
            set target_branch main
        else if git show-ref --verify --quiet refs/heads/master
            set target_branch master
        else
            echo "Error: No target branch specified and couldn't determine default"
            return 1
        end
    end

    echo "Squash-merging '$source_branch' into '$target_branch'..."
    echo ""

    # Switch to target branch
    git checkout "$target_branch" || return 1

    # Squash merge (no commit)
    git merge --squash "$source_branch" || return 1

    echo ""
    echo (set_color yellow)"Squash merge staged. Review and commit manually."(set_color normal)
    echo "  git status     # Review changes"
    echo "  git commit     # Commit when ready"
end

function gwtcp --description "Cherry-pick commits from a worktree (interactive)"
    if test (count $argv) -eq 0
        echo "Usage: gwtcp <worktree>"
        return 1
    end

    __gwt_fzf_check || return 1

    set -l worktree_name $argv[1]

    # Find worktree
    set -l worktree_path (__gwt_find_by_name $worktree_name)
    if test -z "$worktree_path"
        echo "Error: Worktree '$worktree_name' not found"
        return 1
    end

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch "$worktree_path")
    if test -z "$source_branch" -o "$source_branch" = "(detached)"
        echo "Error: Worktree is detached or branch unknown"
        return 1
    end

    echo "Select commits from '$source_branch' to cherry-pick:"
    echo ""

    # Get commits from the branch (excluding current branch)
    set -l commits (git log --oneline "$source_branch" --not $(git branch --show-current) 2>/dev/null | fzf --multi --preview "git show --stat {1}")

    if test -z "$commits"
        echo "No commits selected"
        return 0
    end

    echo ""
    echo "Cherry-picking selected commits..."

    for commit in $commits
        set -l hash (echo $commit | awk '{print $1}')
        echo "Picking $hash..."
        git cherry-pick $hash
        if test $status -ne 0
            echo (set_color red)"Conflict! Resolve and continue."(set_color normal)
            echo "  git cherry-pick --continue  # After resolving"
            echo "  git cherry-pick --abort     # To abort"
            return 1
        end
    end

    echo (set_color green)"All commits cherry-picked successfully!"(set_color normal)
end

# -----------------------------------------------------------------------------
# Fish Completions
# -----------------------------------------------------------------------------

complete -c gwt -xa '(__gwt_complete_names)' -d 'Switch to worktree'
complete -c gwts -d 'Switch to worktree (fzf)'
complete -c gwtc -d 'Create worktree'
complete -c gwtc -s d -l detach -d 'Create detached HEAD'
complete -c gwtc -s b -l branch -d 'Base branch' -xa '(__gwt_complete_branches)'
complete -c gwtl -d 'List worktrees'
complete -c gwti -d 'Show worktree info'
complete -c gwtr -xa '(__gwt_complete_names)' -d 'Remove worktree'
complete -c gwtr -s f -l force -d 'Force removal'
complete -c gwtrm -xa '(__gwt_complete_names)' -d 'Remove worktree + branch'
complete -c gwtrm -s f -l force -d 'Force removal'
complete -c gwtp -d 'Prune stale worktrees'
complete -c gwtm -xa '(__gwt_complete_names)' -d 'Merge worktree'
complete -c gwtm -n __fish_use_subcommand -xa '(__gwt_complete_branches)' -d 'Target branch'
complete -c gwtms -xa '(__gwt_complete_names)' -d 'Squash-merge worktree'
complete -c gwtms -n __fish_use_subcommand -xa '(__gwt_complete_branches)' -d 'Target branch'
complete -c gwtcp -xa '(__gwt_complete_names)' -d 'Cherry-pick from worktree'
