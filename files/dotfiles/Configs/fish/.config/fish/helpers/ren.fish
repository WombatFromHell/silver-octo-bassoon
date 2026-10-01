function ren --description 'Regex batch rename; preview by default, atomic'
    argparse -s a/apply f/force i/interactive all ignore-case -- $argv; or return 2

    # split argv into pairs (before first --) and files (after); no -- = single pair
    set -l pairs
    set -l files
    set -l sep_idx
    for i in (seq (count $argv))
        if test "$argv[$i]" = --
            set sep_idx $i
            break
        end
    end
    if test -n "$sep_idx"
        set -l fstart (math "$sep_idx + 1")
        set files $argv[$fstart..-1]
        if test $sep_idx -gt 1
            set -l pend (math "$sep_idx - 1")
            set pairs $argv[1..$pend]
        end
    else
        set pairs $argv[1..2]
        set files $argv[3..-1]
    end

    # validate: at least one pair (even count) and at least one file
    set -l pc (count $pairs)
    if test $pc -lt 2; or test (math "$pc % 2") -ne 0; or test (count $files) -lt 1
        echo "usage: ren [--apply] [--force] [--interactive] [--all] [--ignore-case] R1 P1 [R2 P2 ...] [--] FILE..."
        echo "  ren foo bar *.txt                # preview: prints mv, renames nothing"
        echo "  ren --apply foo bar *.txt        # rename for real; any error aborts the whole batch"
        echo "  ren --apply '^(.*)\.txt\$' '\$1.md' *.txt  # regex + capture group"
        echo "  ren --apply foo bar baz qux -- a.txt b.txt  # chained pairs, in sequence"
        echo "  find . -name '*.txt' | ren --apply '\.txt\$' '.md' -  # file list from stdin"
        return 2
    end

    # stdin file list: a '-' among the files reads names from stdin (newline-separated)
    # (cat - > file: a command substitution (cat -) does NOT inherit the pipe's stdin)
    if contains -- - $files
        set -l tf (mktemp)
        command cat - >$tf
        set -l stdin_files (string split \n < $tf)
        rm -f $tf
        set -l expanded
        for f in $files
            if test "$f" = -
                set -a expanded $stdin_files
            else
                set -a expanded $f
            end
        end
        set files $expanded
    end

    # string replace flags: -r always, -a for --all, -i for --ignore-case
    set -l sr -r
    if set -q _flag_all
        set -a sr -a
    end
    if set -q _flag_ignore_case
        set -a sr -i
    end

    # pass 1: compute all mappings (apply each pair in sequence), collect errors
    set -l npairs (math "$pc / 2")
    set -l srcs
    set -l dsts
    set -l errs
    set -l new
    for f in $files
        set new $f
        for n in (seq $npairs)
            set -l ri (math "2 * $n - 1")
            set -l pi (math "2 * $n")
            set new (string replace $sr -- $pairs[$ri] $pairs[$pi] $new)
        end
        if test "$f" = "$new"
            echo "skip (unchanged): $f"
        else if test -z "$new"
            set -a errs "empty result for: $f"
        else if test -e "$new"; and not set -q _flag_force
            set -a errs "target exists: $new"
        else
            set -a srcs $f
            set -a dsts $new
        end
    end

    # clash: two sources -> same target (sort-based; fish assoc keys can't hold spaces)
    set -l sorted (printf '%s\n' $dsts | sort)
    set -l last
    for i in (seq 2 (count $sorted))
        set -l j (math "$i - 1")
        if test "$sorted[$i]" = "$sorted[$j]" -a "$sorted[$i]" != "$last"
            set -a errs "clash: multiple files -> $sorted[$i]"
            set last $sorted[$i]
        end
    end

    if test (count $errs) -gt 0
        for e in $errs
            echo "ren: $e" >&2
        end
        echo "ren: aborted, nothing renamed" >&2
        return 1
    end

    # pass 2: execute (apply/interactive) or preview
    for i in (seq (count $srcs))
        set -l src $srcs[$i]
        set -l dst $dsts[$i]
        if set -q _flag_interactive
            printf 'mv -- %s %s? [y/N]\n' $src $dst
            set -l resp
            read -l resp
            if not string match -q -r '^[yY]' -- $resp
                continue
            end
            mv -- $src $dst
        else if set -q _flag_apply
            mv -- $src $dst
        else
            echo mv -- $src $dst
        end
    end
end
