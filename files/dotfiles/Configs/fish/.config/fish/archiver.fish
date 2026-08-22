# ---------------------------------------------------------
# archiver.fish — tar compression/extraction helpers
#
# fish has no `set -euo pipefail`; the equivalents used here:
#   - every fallible call is guarded with `... or return 1`
#   - pipelines end with the command whose failure matters
#     (fish only reports the last pipeline member's status)
# ---------------------------------------------------------

# ---------------------------------------------------------
# _tarchk COMP — resolve compressor, set global _tarchk_cmd
# COMP is always pigz or zstd (guaranteed by _tarpickcomp)
# ---------------------------------------------------------
function _tarchk
    switch "$argv[1]"
        case pigz
            if command -q pigz
                set -g _tarchk_cmd pigz -9 --processes 0
            else if command -q gzip
                set -g _tarchk_cmd gzip -9
            else
                echo "Error: neither pigz nor gzip found." >&2
                return 1
            end
        case zstd
            if not command -q zstd
                echo "Error: zstd not found." >&2
                return 1
            end
            set -g _tarchk_cmd zstd -15 --long=28 --threads=0
    end
end

# ---------------------------------------------------------
# _tarpickcomp [ARGS...] — if the first arg is a compressor
# name, strip it and set _tarcomp; otherwise default to pigz.
# Prints the remaining args.
# ponytail: an archive/output file literally named pigz/zstd would be
# misread as the compressor; don't name files like that
# ---------------------------------------------------------
function _tarpickcomp
    switch "$argv[1]"
        case pigz zstd
            set -g _tarcomp $argv[1]
            printf '%s\n' $argv[2..-1]
        case '*'
            set -g _tarcomp pigz
            printf '%s\n' $argv
    end
end

# ---------------------------------------------------------
# _tarcopen COMP ARCHIVE — decompress ARCHIVE to stdout
# ---------------------------------------------------------
function _tarcopen
    _tarchk "$argv[1]" or return 1
    $_tarchk_cmd -dc -- "$argv[2]"
end

# ---------------------------------------------------------
# _use_pv [FILES...] — progress bar over stdin, total = size of FILES
# (no FILES → indeterminate bar; no pv → silent passthrough)
# ---------------------------------------------------------
function _use_pv
    if not command -q pv
        echo ":: 'pv' not found. Processing silently..." >&2
        cat
        return
    end
    # ponytail: du errors on non-files (e.g. tar opts passed through) are
    # suppressed and simply don't contribute to the total
    set -l size 0
    if test (count $argv) -gt 0
        set size (du -sb -- $argv 2>/dev/null | awk '{s+=$1} END{print s+0}')
    end
    if test "$size" -gt 0
        pv -s $size -w 80 -B 1M
    else
        pv -w 80 -B 1M
    end
end

# ---------------------------------------------------------
# Compress: tarc
# Usage: tarc [pigz|zstd] OUTPUT_FILE [--gitignore] [TAR_OPTIONS...] PATHS...
# Compressor is optional (defaults to pigz). Everything after
# OUTPUT_FILE is passed straight to tar, so --exclude, --exclude-from,
# --transform etc. work anywhere tar's own parser accepts them.
#
# --gitignore: the file list comes from git instead of tar's path args.
# Archives exactly the files git tracks or would add (i.e. .gitignore is
# honored by git itself — no --exclude-from needed). Requires a git
# working tree in cwd and exactly one PATH, which names that cwd from
# tar's point of view (e.g. -C ../ with PATH ./vllm).
# ---------------------------------------------------------
function tarc
    set -l use_gitignore 0
    # ponytail: fish's `set --erase NAME` removes a variable, not a list
    # element — an index lookup is the only way to drop one argv slot
    for i in (seq (count $argv))
        if test "$argv[$i]" = --gitignore
            set use_gitignore 1
            set --erase argv[$i]
            break
        end
    end
    set -l rest (_tarpickcomp $argv)
    if test (count $rest) -lt 2
        echo "Usage: tarc [pigz|zstd] OUTPUT_FILE [TAR_OPTIONS...] PATHS..." >&2
        return 1
    end
    _tarchk $_tarcomp or return 1
    set -l outfile $rest[1]
    set -l args $rest[2..-1]
    mkdir -p -- (dirname -- $outfile)
    # ponytail: fish reports only the last pipeline member's status, so a tar
    # failure (e.g. zero members) still leaves a truncated $outfile; tar's
    # stderr is visible on the terminal — delete and re-run if it errors
    if test $use_gitignore = 1
        # ponytail: -C/--directory is the only value-taking tar option we
        # skip over when splitting $args; filenames with newlines are not
        # supported (newline-based list, not --nullfiles)
        command -q git or { echo "Error: git not found." >&2; return 1 }
        git rev-parse --is-inside-work-tree >/dev/null 2>&1 or {
            echo "Error: --gitignore must be run inside a git working tree." >&2
            return 1
        }
        set -l gopts
        set -l paths
        set -l skip_next 0
        for a in $args
            if test $skip_next = 1
                set skip_next 0
                set gopts $gopts $a
            else if test "$a" = -C -o "$a" = --directory
                set skip_next 1
                set gopts $gopts $a
            else if string match -q -- '-*' $a
                set gopts $gopts $a
            else
                set paths $paths $a
            end
        end
        test (count $paths) = 1; or {
            echo "Error: --gitignore takes exactly one path (the directory to archive)." >&2
            return 1
        }
        # ponytail: no file list for _use_pv to du here (paths are relative
        # to tar's -C, not cwd) — indeterminate bar
        git ls-files --cached --others --exclude-standard |
            sed "s|^|$paths[1]/|" |
            tar -cf - $gopts --no-recursion -T - |
            _use_pv |
            $_tarchk_cmd > $outfile
    else
        tar -cf - $args | _use_pv $args | $_tarchk_cmd > $outfile
    end
end

# ---------------------------------------------------------
# Extract: tarx
# Usage: tarx [pigz|zstd] ARCHIVE [TAR_OPTIONS...]
# (e.g. tarx foo.tgz --exclude='*.log' -C /tmp)
# ---------------------------------------------------------
function tarx
    set -l rest (_tarpickcomp $argv)
    if test (count $rest) -lt 1
        echo "Usage: tarx [pigz|zstd] ARCHIVE [TAR_OPTIONS...]" >&2
        return 1
    end
    _tarcopen $_tarcomp "$rest[1]" | _use_pv "$rest[1]" | tar -xvf - $rest[2..-1]
end

# ---------------------------------------------------------
# List: tarvit
# Usage: tarvit [pigz|zstd] ARCHIVE [TAR_OPTIONS...]
# (e.g. tarvit zstd foo.tar.zst --exclude='*.log')
# ---------------------------------------------------------
function tarvit
    set -l rest (_tarpickcomp $argv)
    if test (count $rest) -lt 1
        echo "Usage: tarvit [pigz|zstd] ARCHIVE [TAR_OPTIONS...]" >&2
        return 1
    end
    _tarcopen $_tarcomp "$rest[1]" | tar -tvf - $rest[2..-1]
end

# Compressor defaults to pigz, so only the zstd variants need aliases
alias tarzsc='tarc zstd'
alias tarzsx='tarx zstd'

# ---------------------------------------------------------
# Completions
# ---------------------------------------------------------
# Compressor prompt for the base commands' first argument
for cmd in tarc tarx tarvit
    complete -c $cmd -n "test (count (commandline -opc)) -eq 1" -a pigz -a zstd -d "Compressor Type"
end

# Suffix-filtered archive completion for the zstd alias
complete -c tarzsx -k -a "(__fish_complete_suffix .tar.zst .tzst)"

# Force plain file completion
complete -c tarzsc -F
complete -c tarc -l gitignore -d "Archive only files git tracks or would add"

# Simple 7z support
alias 7zac='7z a -m0=lzma2 -mx3'
