if command -q trash
    alias rm='trash-put'
    alias rmd='trash-put'
    alias rmc='trash-empty'
    alias rmr='trash-restore'

    function rmls
        if not command -q fzf
            trash-list
            return
        end

        set -l selected (
                trash-list \
                | sort -r \
                | fzf --multi \
                      --prompt='Restore> ' \
                      --header='TAB to select, ENTER to restore, ESC to cancel' \
                      --preview-window=hidden \
                | awk '{print $3}'
            )

        if test -z "$selected"
            return
        end

        set -l paths (string split '\n' -- $selected)
        set -l count (count $paths)

        echo "Restoring $count file(s):"
        for p in $paths
            echo "  $p"
        end

        read -l -P "Confirm? [y/N] " confirm
        if string match -qi y -- $confirm
            for p in $paths
                echo $p | trash-restore --overwrite
            end
        else
            echo "Aborted."
        end
    end
end
