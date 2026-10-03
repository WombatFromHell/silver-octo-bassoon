# Prints an abbreviated version of the given path to stdout.
# Home dir -> ~, long paths -> /v/h/j/.a/... (last @abbrev_keep components full).
# Used by fish_title for the terminal title inside tmux.

function _abbr_path
    set -l raw $argv[1]
    set -l home (realpath ~)

    # Read @abbrev_keep from tmux (default 2)
    set -l keep (tmux show-options -g -v @abbrev_keep 2>/dev/null | string split ' ' | string sub -s 2)
    if not string match -q '[0-9]+' -- "$keep"
        set keep 2
    end

    # Fast path: direct match against resolved home
    if test "$raw" = "$home"
        echo "~"
        return
    end
    if string replace -q "$home/" "" -- "$raw"
        set -l rest (string replace -- "$home/" "" "$raw")
        _abbr_parts "$rest" "~/" $keep
        return
    end

    # Slow path: path might reach home via a symlink (e.g. /home/josh -> /var/home/josh)
    if test -n $HOME
        set -l resolved (realpath "$raw" 2>/dev/null)
        if test "$resolved" = "$home"
            echo "~"
            return
        end
        if string replace -q "$home/" "" -- "$resolved"
            set -l rest (string replace -- "$home/" "" "$resolved")
            _abbr_parts "$rest" "~/" $keep
            return
        end
    end

    # Non-home absolute path
    if test (string sub -l 1 -- "$raw") = "/"
        set -l rest (string sub -s 2 -- "$raw")
        _abbr_parts "$rest" "/" $keep
        return
    end

    echo "$raw"
end

# _abbr_parts <rest> <prefix> <keep>
# Splits rest on /, abbreviates all but the last $keep components.
function _abbr_parts
    set -l rest $argv[1]
    set -l prefix $argv[2]
    set -l keep $argv[3]

    set -l parts (string split / -- "$rest")
    set -l n (count $parts)

    if test $n -le $keep
        echo "$prefix$rest"
        return
    end

    set -l out "$prefix"
    for i in (seq 1 (math $n - $keep))
        set -l p $parts[$i]
        if string match -q '.*' -- $p
            set out (printf "%s%s/" "$out" (string sub -l 2 -- $p))
        else
            set out (printf "%s%s/" "$out" (string sub -l 1 -- $p))
        end
    end
    for i in (math $n - $keep + 1) $n
        set out (printf "%s%s" "$out" $parts[$i])
        if test $i -lt $n
            set out (printf "%s/" "$out")
        end
    end
    echo $out
end
