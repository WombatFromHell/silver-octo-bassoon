# Title = user@host:<abbreviated pwd>, fitted to a column budget.
#   Path:  stdlib prompt_pwd (~ for home, /v/h/j/.a/... with the last
#          @abbrev_keep tmux option components kept full, default 2).
#   Fit:   keep head + tail, ellipsis the middle; the tail is the informative part.
# Width model: 1 column/char (fish counts chars, not display columns);
# ponytail: CJK/wide-char parity deferred — swap `string length` for `string length -V` /
# wcwidth-aware logic if it ever matters.

# Budget in columns; override in config.fish: set -g TITLE_TRUNC_WIDTH 80
set -q TITLE_TRUNC_WIDTH; or set -g TITLE_TRUNC_WIDTH 64

# title_truncate <title> [width] — budget: arg > $TITLE_TRUNC_WIDTH, clamped to $COLUMNS.
function title_truncate
    set -l s $argv[1]
    set -l w $TITLE_TRUNC_WIDTH
    set -q argv[2]; and set w $argv[2]
    set -q COLUMNS; and test $COLUMNS -lt $w; and set w $COLUMNS

    # Fits as-is -> untouched, host head included.
    if test (string length -- $s) -le $w
        echo $s
        return
    end

    # Only when truncating: drop the redundant 'user@host:' / 'user@host - ' head.
    set s (string replace -r '^[^/]*@[^/:]+( - |:)' '' -- $s)
    if test (string length -- $s) -le $w
        echo $s
        return
    end

    # Last two path components whole, if they fit: '…a/b'.
    set -l tail (string match -r '[^/]+/[^/]+$' -- $s)
    if test -n "$tail"; and test (string length -- $tail) -lt $w
        echo …$tail
        return
    end

    # Otherwise head + '…' + tail of the whole string.
    set -l half (math "max(1, floor(($w - 1) / 2))")
    echo (string sub -l $half -- $s)…(string sub -s -$half -- $s)
end

function fish_title
    # ponytail: no realpath/symlinked-$HOME fallback; fish's $PWD is already logical.
    # Add it back only if a title shows /var/home/... instead of ~.
    set -l keep 2
    if set -q TMUX
        set -l k (tmux show-options -gqv @abbrev_keep 2>/dev/null)
        string match -qr '^\d+$' -- $k; and set keep $k
    end
    title_truncate $USER@(hostname):(prompt_pwd -d 1 -D $keep)
end

# Self-check: `fish truncate.fish --test` (asserts, no framework).
if contains -- --test $argv
    function _eq
        test "$argv[1]" = "$argv[2]"; or begin
            echo "FAIL: got '$argv[1]' want '$argv[2]'"
            exit 1
        end
    end
    _eq (title_truncate short 10) short
    _eq (title_truncate me@h:~/a/b/c/d 7) …c/d
    _eq (title_truncate me@h:/aaaaaaaaaaaaaaaaaaaaaaaa 9) /aaa…aaaa
    _eq (title_truncate me@h:/aaaaaaaaaaaaaaaaaaaaaaaa 1) /…a
    _eq (string length (title_truncate me@h:/x/yyyyyyyyyyyy/zzzzzzzzzzzz 12)) 11
    echo ok
end
