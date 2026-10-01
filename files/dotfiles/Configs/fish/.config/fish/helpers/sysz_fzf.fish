#!/usr/bin/env fish
# =============================================================================
# sysz_fzf.fish - Interactive systemctl with fzf for fish shell
# =============================================================================
#
# Installation:
#   Save to: ~/.config/fish/conf.d/systemd_fzf.fish
#   Or source from config.fish: source path/to/systemd_fzf.fish
#
# Usage:
#   sls [query]  - Browse system-level systemd units interactively
#   uls [query]  - Browse user-level systemd units interactively
#
# FZF Keybindings:
#   Enter    - Show full status (then exit)
#   Ctrl-s   - Start unit (reloads list)
#   Ctrl-x   - Stop unit (reloads list)
#   Ctrl-r   - Restart unit (reloads list)
#   Ctrl-e   - Enable unit (reloads list)
#   Ctrl-d   - Disable unit (reloads list)
#   Ctrl-l   - Show last 200 log lines
#   Ctrl-f   - Follow logs live
#   Esc/q    - Cancel
#
# Shell Keybindings (terminal-dependent - see notes below):
#   Ctrl+Alt+Y  - Launch sls
#   Ctrl+Alt+U  - Launch uls
#
# =============================================================================

# Guard: only load if fzf is available
if not command -q fzf
    return 0
end

# =============================================================================
# Core Implementation
# =============================================================================

function __systemd_fzf_core -S -a user_flag query
    set -l sudo_prefix ""
    if test -z "$user_flag"
        set sudo_prefix "sudo "
    end

    set -l base_cmd systemctl
    if test -n "$user_flag"
        set base_cmd $base_cmd $user_flag
    end
    set -l base_cmd_str "$base_cmd"

    set -l list_cmd_str "$base_cmd_str list-units --type=service,socket,target,timer,mount,swap --no-pager --no-legend"
    set -l list_all_cmd_str "$base_cmd_str list-units --all --no-pager --no-legend"

    set -l journal_cmd journalctl
    if test -n "$user_flag"
        set journal_cmd $journal_cmd $user_flag
    end
    set -l journal_cmd_str "$journal_cmd"

    set -l pager_cmd
    if command -q less
        set pager_cmd less -R
    else if command -q bat
        set pager_cmd bat "--paging=always"
    else if command -q moar
        set pager_cmd moar
    else
        set pager_cmd cat
    end
    set -l pager_str "$pager_cmd"

    # Use tmux new-window to isolate journalctl from fzf's terminal state,
    # preventing tmux pane-switching bindings from breaking. Fall back to
    # plain execute() outside of tmux.
    set -l bind_logs
    set -l bind_follow
    if set -q TMUX
        set bind_logs "ctrl-l:execute(tmux new-window '$journal_cmd_str -r -u {1} -n 200 --no-pager 2>/dev/null | $pager_str')"
        set bind_follow "ctrl-f:execute(tmux new-window '$journal_cmd_str -u {1} -f 2>/dev/null')"
    else
        set bind_logs "ctrl-l:execute($journal_cmd_str -u {1} -r -n 200 --no-pager 2>/dev/null | $pager_str)"
        set bind_follow "ctrl-f:execute($journal_cmd_str -u {1} -f 2>/dev/null)"
    end

    set -l border_label systemctl
    if test -n "$user_flag"
        set border_label "$border_label --user"
    end

    set -l result (
        eval $list_cmd_str | fzf \
            --ansi \
            --no-mouse \
            --preview="$base_cmd_str status {1} 2>/dev/null" \
            --preview-window='right:65%:wrap:border-left:hidden' \
            --bind='?:toggle-preview' \
            --bind="enter:execute($base_cmd_str status {1} 2>/dev/null | $pager_str)+abort" \
            --bind="ctrl-s:execute($sudo_prefix$base_cmd_str start {1} 2>&1 && echo '✓ Started {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd_str)" \
            --bind="ctrl-x:execute($sudo_prefix$base_cmd_str stop {1} 2>&1 && echo '✓ Stopped {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd_str)" \
            --bind="ctrl-r:execute($sudo_prefix$base_cmd_str restart {1} 2>&1 && echo '✓ Restarted {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd_str)" \
            --bind="ctrl-e:execute($sudo_prefix$base_cmd_str enable {1} 2>&1 && echo '✓ Enabled {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd_str)" \
            --bind="ctrl-d:execute($sudo_prefix$base_cmd_str disable {1} 2>&1 && echo '✓ Disabled {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd_str)" \
            --bind="$bind_logs" \
            --bind="$bind_follow" \
            --bind="ctrl-t:reload($base_cmd_str list-timers --all --no-pager --no-legend)" \
            --bind="ctrl-a:reload($list_all_cmd_str)" \
            --header='Enter:status │ ?:preview │ s:start │ x:stop │ r:restart │ e:enable │ d:disable │ l:logs │ f:follow │ t:timers │ a:all units' \
            --border='rounded' \
            --border-label="$border_label" \
            --cycle \
            --pointer='→' \
            --marker='✓' \
            --layout='reverse' \
            --info='inline-right' \
            --tiebreak='index' \
            --query="$query" \
            2>/dev/null
    )

    if test -n "$result"
        set -l unit (string split -f1 ' ' -- $result | string trim)
        if test -n "$unit"
            $base_cmd status "$unit" | $pager_cmd
        end
    end
end

# =============================================================================
# Public Functions
# =============================================================================

function sls -d "Interactive systemctl list with fzf (system level)"
    # Browse and manage system-level systemd units interactively.
    #
    # Usage:
    #   sls           - Show active manageable units
    #   sls nginx     - Pre-filter with 'nginx'
    #   sls *.service - Filter by pattern
    __systemd_fzf_core "" (string join " " $argv)
end

function uls -d "Interactive systemctl list with fzf (user level)"
    # Browse and manage user-level systemd units interactively.
    #
    # Usage:
    #   uls           - Show active manageable user units
    #   uls pipewire  - Pre-filter with 'pipewire'
    __systemd_fzf_core --user (string join " " $argv)
end

# =============================================================================
# Key Bindings
# =============================================================================

function __systemd_fzf_sls_handler
    commandline -f execute
    sls
    commandline -f repaint
end

function __systemd_fzf_uls_handler
    commandline -f execute
    uls
    commandline -f repaint
end

bind ctrl-alt-y __systemd_fzf_sls_handler
bind ctrl-alt-u __systemd_fzf_uls_handler

# =============================================================================
# Completions (minimal - functions are self-documenting)
# =============================================================================

complete -c sls -f -d "Interactive systemctl browser (system)"
complete -c uls -f -d "Interactive systemctl browser (user)"
