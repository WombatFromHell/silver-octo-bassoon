# ---------------------------------------------------------
# 1. Helper: Check Compressor & Determine Flags
# ---------------------------------------------------------
function _tarchk
    # Default to pigz if no argument provided, otherwise use argument
    set -l input_comp (test -n "$argv[1]"; and echo $argv[1]; or echo pigz)

    switch $input_comp
        case pigz gzip
            if command -q pigz
                # Best case: pigz exists
                echo "pigz -9 --processes 0"
            else if command -q gzip
                # Fallback: standard gzip
                echo "gzip -9"
            else
                # Critical failure: neither exists
                return 1
            end
        case zstd
            if command -q zstd
                echo "zstd -15 --long=28 --threads=0"
            else
                return 1
            end
        case '*'
            # Unknown compressor requested
            return 1
    end
end

# ---------------------------------------------------------
# 2. Helper: PV Wrapper (Progress Bar)
# ---------------------------------------------------------
function _use_pv
    # Check if pv is installed
    if command -q pv
        # Calculate total size of all paths passed as arguments
        # Use 'du' to sum up bytes
        set -l size (du -sb $argv 2>/dev/null | awk '{s+=$1} END{print s+0}')

        if test "$size" -gt 0
            pv -s $size -w 80 -B 1M
        else
            # Size unknown/0, use pv without size estimate
            pv -w 80 -B 1M
        end
    else
        # Fallback: pv not installed
        echo ":: 'pv' not found. Processing silently..." >&2
        cat
    end
end

# ---------------------------------------------------------
# 3. Compress: tarc
# Usage: tarc [pigz|zstd] [TAR_OPTS] OUTPUT_FILE PATHS...
# ---------------------------------------------------------
function tarc
    if test (count $argv) -lt 3
        echo "Usage: tarc COMPRESSOR [TAR_OPTIONS...] OUTPUT_FILE PATHS..." >&2
        return 1
    end

    # Resolve compressor command string (e.g., "pigz -9...")
    set -l comp_cmd_str (_tarchk $argv[1])

    if test $status -ne 0
        echo "Error: Compressor '$argv[1]' (or fallback) not found." >&2
        return 1
    end

    # Shift args to remove compressor name
    set argv $argv[2..-1]

    # Logic to separate Output File from Input Paths
    set -l outfile_idx 0
    set -l outfile ""

    for i in (seq (count $argv))
        # The first argument that doesn't start with '-' is our output file
        if not string match -q -- '-*' $argv[$i]
            set outfile_idx $i
            set outfile $argv[$i]
            break
        end
    end

    if test $outfile_idx -eq 0
        echo "Error: No output file specified" >&2
        return 1
    end

    # Extract tar options (everything before the output file)
    set -l opts
    if test $outfile_idx -gt 1
        set opts $argv[1..(math $outfile_idx - 1)]
    end

    # Paths to archive (everything after the output file)
    set -l paths $argv[(math $outfile_idx + 1)..-1]
    if test (count $paths) -eq 0
        echo "Error: No paths to archive" >&2
        return 1
    end

    # Create directory for output file if it doesn't exist
    mkdir -p (dirname -- $outfile)

    # 1. Split the command string into a list variable FIRST
    set -l cmd_parts (string split " " -- $comp_cmd_str)

    # 2. Run: tar -> pv -> compressor (using the list variable) -> file
    tar $opts -cf - $paths | _use_pv $paths | $cmd_parts >$outfile
end

# ---------------------------------------------------------
# 4. Extract: tarx
# Usage: tarx [pigz|zstd] ARCHIVE [TAR_ARGS...]
# ---------------------------------------------------------
function tarx
    if test (count $argv) -lt 2
        echo "Usage: tarx COMPRESSOR ARCHIVE [TAR_ARGS...]" >&2
        return 1
    end

    set -l comp_input $argv[1]
    set -l archive $argv[2]
    set -l tar_args $argv[3..-1]

    # Resolve compressor string (e.g. "zstd -15 ...")
    set -l comp_cmd_str (_tarchk $comp_input)

    if test $status -ne 0; or test -z "$comp_cmd_str"
        echo "Error: Compressor '$comp_input' not found." >&2
        return 1
    end

    # Split the string into a list: (zstd) (-15) (--long=28) ...
    set -l cmd_parts (string split " " -- $comp_cmd_str)

    # The first item in the list is the binary name (e.g., "zstd")
    switch $cmd_parts[1]
        case pigz gzip zstd
            # Execute the list directly. Fish expands list items as arguments.
            # We append -dc to ensure decompression happens.
            $cmd_parts -dc $archive | _use_pv | tar -xvf - $tar_args
        case '*'
            echo "Internal error: unknown compressor binary '$cmd_parts[1]'" >&2
            return 1
    end
end

# ---------------------------------------------------------
# 5. List: tarv
# Usage: tarv [pigz|zstd] ARCHIVE
# ---------------------------------------------------------
function tarv
    if test (count $argv) -ne 2
        echo "Usage: tarv COMPRESSOR ARCHIVE" >&2
        return 1
    end

    set -l comp_input $argv[1]
    set -l archive $argv[2]

    set -l comp_cmd_str (_tarchk $comp_input)
    if test $status -ne 0
        echo "Error: Compressor '$comp_input' not found." >&2
        return 1
    end

    # Split string into list
    set -l cmd_parts (string split " " -- $comp_cmd_str)

    # Execute decompression piped to tar list
    $cmd_parts -dc $archive | tar -tvf -
end

alias tarzc='tarc pigz'
alias tarzx='tarx pigz'
alias tarzv='tarv pigz'
#
alias tarzsc='tarc zstd'
alias tarzsx='tarx zstd'
alias tarzsv='tarv zstd'

# 1. Base Command Completions
# When typing 'tarx', suggest compressors for the first argument
complete -c tarc -n "test (count (commandline -opc)) -eq 1" -a "pigz zstd" -d "Compressor Type"
complete -c tarx -n "test (count (commandline -opc)) -eq 1" -a "pigz zstd" -d "Compressor Type"
complete -c tarv -n "test (count (commandline -opc)) -eq 1" -a "pigz zstd" -d "Compressor Type"

# Zstd: Only show .tar.zst or .tzst files
complete -c tarzsx -k -a "(__fish_complete_suffix .tar.zst .tzst)"
complete -c tarzsv -k -a "(__fish_complete_suffix .tar.zst .tzst)"

# Gzip: Only show .tar.gz or .tgz files
complete -c tarzx -k -a "(__fish_complete_suffix .tar.gz .tgz)"
complete -c tarzv -k -a "(__fish_complete_suffix .tar.gz .tgz)"

# 3. Alias Completions (Compression)
# Force standard file completion (for input paths)
complete -c tarzc -F
complete -c tarzsc -F

# Simple 7z support
alias 7zac='7z a -m0=lzma2 -mx3'
