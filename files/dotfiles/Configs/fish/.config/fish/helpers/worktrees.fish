# =============================================================================
# Git Worktree Management Functions
# =============================================================================
# Convention: <gwtX> [opts] [worktree path]
#
#   A bare name (no '/') resolves to an existing worktree (matched by path
#   basename or branch); if none exists it defaults to ./.wt/<name>.
#   Arguments containing '/' are used verbatim.
#
#   gwta [opts] <name|path>      Add worktree (opts: -b <base>, -d, -f)
#   gwt  [name]                  Switch to worktree (no arg: fzf picker)
#   gwtl                         List worktrees
#   gwti                         Info for current worktree
#   gwtr [opts] <name|path>      Remove worktree (opts: -f, -B also delete branch)
#   gwtp                         Prune stale worktrees
#   gwtm <name|path> [target]    Merge worktree branch into target
#   gwtms <name|path> [target]   Squash-merge worktree branch into target
#   gwtcp <name|path>            Cherry-pick commits from worktree (fzf multi)
#
#   Legacy aliases: gwtc=gwta  gwts=gwt  gwtrm='gwtr -B'
#
#   Note: add `/.wt/` to .gitignore in repos that use the default path, so
#   the main worktree's `git status` stays clean.
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

function __gwt_resolve --description "Resolve a worktree name or path to a path"
    set -l arg $argv[1]
    if test -z "$arg"
        return 1
    end
    # Verbatim if it contains a slash (absolute, relative, ./x, ~/x)
    if string match -q -- '*/*' $arg
        echo $arg
        return 0
    end
    set -l found (__gwt_find_by_name $arg)
    if test -n "$found"
        echo $found
        return 0
    end
    echo ./.wt/$arg
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
# Core Functions
# -----------------------------------------------------------------------------

function gwta --description "Add a worktree: gwta [-b <base>] [-d] [-f] <name|path>"
    argparse -s b/base= d/detach f/force -- $argv; or return
    set -l name $argv[1]
    if test -z "$name"
        echo "Usage: gwta [-b <base>] [-d] [-f] <name|path>" >&2
        return 1
    end
    set -l path (__gwt_resolve $name)
    or return 1
    set -l cmd git worktree add
    set -q _flag_force; and set -a cmd -f
    set -q _flag_detach; and set -a cmd --detach
    if set -q _flag_base
        # -b <base>: new branch named after the path basename, branched from <base>
        set -a cmd -b (basename $path)
        set -a cmd $path $_flag_base
    else
        set -a cmd $path
    end
    command $cmd
end

function gwt --description "Switch to a worktree (no arg: fzf picker)"
    if set -q argv[1]
        set -l path (__gwt_resolve $argv[1])
        or return 1
        cd -- $path; or return 1
        echo "Switched to worktree: $path"
    else
        __gwt_fzf_check; or return 1
        set -l target (__gwt_list | fzf --header "Select worktree" | awk -F'\t' '{print $1}')
        if test -n "$target"
            cd -- $target
            echo "Switched to: $target"
        end
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

function gwtr --description "Remove a worktree: gwtr [-f] [-B] <name|path>"
    argparse -s f/force B/del-branch -- $argv; or return
    set -l name $argv[1]
    if test -z "$name"
        echo "Usage: gwtr [-f] [-B] <name|path>" >&2
        return 1
    end
    set -l path (__gwt_resolve $name)
    or return 1

    # Grab the branch before removal (for -B)
    set -l wt_branch (__gwt_get_branch $path)

    if not set -q _flag_force
        __gwt_validate $path; or return 1

        # Confirm with fzf if available
        if __gwt_fzf_check
            echo "About to remove: $path"
            set -l confirm (printf 'yes\nno' | fzf --prompt "Confirm removal: ")
            if test "$confirm" != yes
                echo "Cancelled"
                return 0
            end
        end
    end

    set -l cmd git worktree remove
    set -q _flag_force; and set -a cmd --force
    set -a cmd $path
    command $cmd; or return 1
    echo "Removed worktree: $path"

    if set -q _flag_B
        if test -n "$wt_branch" -a "$wt_branch" != "(detached)"
            git branch -D "$wt_branch"; and echo "Deleted branch: $wt_branch"
        end
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
    set -l worktree_name $argv[1]
    if test -z "$worktree_name"
        echo "Usage: gwtm <name|path> [target-branch]"
        echo ""
        echo "Merge the worktree's branch into target (default: main/master)"
        return 1
    end
    set -l target_branch $argv[2]

    # Find worktree
    set -l worktree_path (__gwt_resolve $worktree_name)
    or return 1

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch $worktree_path)
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
                echo "Usage: gwtm <name|path> <target-branch>"
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
            set -l cleanup (printf 'no\nyes' | fzf --prompt "Remove worktree '$worktree_path'? ")
            if test "$cleanup" = yes
                gwtr "$worktree_path"
            end
        else
            echo "Tip: Run 'gwtr $worktree_path' to remove the worktree"
        end
    end
end

function gwtms --description "Squash-merge a worktree's branch into a target branch"
    set -l worktree_name $argv[1]
    if test -z "$worktree_name"
        echo "Usage: gwtms <name|path> [target-branch]"
        echo ""
        echo "Squash-merge the worktree's branch into target (default: main/master)"
        return 1
    end
    set -l target_branch $argv[2]

    # Find worktree
    set -l worktree_path (__gwt_resolve $worktree_name)
    or return 1

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch $worktree_path)
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
    set -l worktree_name $argv[1]
    if test -z "$worktree_name"
        echo "Usage: gwtcp <name|path>"
        return 1
    end

    __gwt_fzf_check || return 1

    # Find worktree
    set -l worktree_path (__gwt_resolve $worktree_name)
    or return 1

    # Get the worktree's branch
    set -l source_branch (__gwt_get_branch $worktree_path)
    if test -z "$source_branch" -o "$source_branch" = "(detached)"
        echo "Error: Worktree is detached or branch unknown"
        return 1
    end

    echo "Select commits from '$source_branch' to cherry-pick:"
    echo ""

    # Get commits from the branch (excluding current branch; detached HEAD
    # has no branch to exclude, so show the branch's full history)
    set -l not_ref
    set -l current (git branch --show-current 2>/dev/null)
    if test -n "$current"
        set not_ref --not $current
    end
    set -l commits (git log --oneline "$source_branch" $not_ref 2>/dev/null | fzf --multi --preview "git show --stat {1}")

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
# Legacy Aliases
# -----------------------------------------------------------------------------
alias gwtc='gwta'
alias gwts='gwt'
alias gwtrm='gwtr -B'

# -----------------------------------------------------------------------------
# Fish Completions
# -----------------------------------------------------------------------------

complete -c gwta -d 'Add worktree'
complete -c gwta -s b -l base -d 'Base branch' -xa '(__gwt_complete_branches)'
complete -c gwta -s d -l detach -d 'Detached HEAD'
complete -c gwta -s f -l force -d 'Force'
complete -c gwt -xa '(__gwt_complete_names)' -d 'Switch to worktree'
complete -c gwtl -d 'List worktrees'
complete -c gwti -d 'Show worktree info'
complete -c gwtr -xa '(__gwt_complete_names)' -d 'Remove worktree'
complete -c gwtr -s f -l force -d 'Force removal'
complete -c gwtr -s B -l del-branch -d 'Also delete branch'
complete -c gwtp -d 'Prune stale worktrees'
complete -c gwtm -xa '(__gwt_complete_names)' -d 'Merge worktree'
complete -c gwtm -n __fish_use_subcommand -xa '(__gwt_complete_branches)' -d 'Target branch'
complete -c gwtms -xa '(__gwt_complete_names)' -d 'Squash-merge worktree'
complete -c gwtms -n __fish_use_subcommand -xa '(__gwt_complete_branches)' -d 'Target branch'
complete -c gwtcp -xa '(__gwt_complete_names)' -d 'Cherry-pick from worktree'
