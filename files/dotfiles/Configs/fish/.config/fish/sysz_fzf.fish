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

# Determine appropriate pager and its arguments to avoid flag errors (e.g. bat vs less)
set -gx _SYSTEMD_FZF_PAGER_CMD ""
set -gx _SYSTEMD_FZF_PAGER_ARGS ""

if command -q less
    set -gx _SYSTEMD_FZF_PAGER_CMD less
    set -gx _SYSTEMD_FZF_PAGER_ARGS -R # -R preserves ANSI colors
else if command -q bat
    set -gx _SYSTEMD_FZF_PAGER_CMD bat
    set -gx _SYSTEMD_FZF_PAGER_ARGS "--paging=always"
else if command -q moar
    set -gx _SYSTEMD_FZF_PAGER_CMD moar
end

# =============================================================================
# Core Implementation
# =============================================================================

function __systemd_fzf_core -S -a user_flag query
    # Sudo is required for system-level modifications, but NOT for user-level
    set -l sudo_prefix ""
    if test -z "$user_flag"
        set sudo_prefix "sudo "
    end

    # Build base command safely, trimming to avoid double spaces
    set -l base_cmd "systemctl $user_flag"
    string trim $base_cmd | read -l base_cmd

    # Default list: manageable types. Excludes noisy kernel mounts/slices.
    set -l list_cmd "$base_cmd list-units --type=service,socket,target,timer,mount,swap --no-pager --no-legend"

    # Full raw list for Ctrl-a toggle
    set -l list_all_cmd "$base_cmd list-units --all --no-pager --no-legend"

    set -l journal_cmd "journalctl $user_flag"

    # Resolve pager command safely
    set -l pager_str "$_SYSTEMD_FZF_PAGER_CMD $_SYSTEMD_FZF_PAGER_ARGS"
    if test -z "$_SYSTEMD_FZF_PAGER_CMD"
        set pager_str cat
    end

    # Run fzf
    # Note: {1} is fzf's syntax to extract the first column (the unit name)
    set -l result (
        eval $list_cmd | fzf \
            --ansi \
            --no-mouse \
            --preview="$base_cmd status {1} 2>/dev/null" \
            --preview-window='right:65%:wrap:border-left:hidden' \
            --bind='?:toggle-preview' \
            --bind="enter:execute($base_cmd status {1} 2>/dev/null | $pager_str)+abort" \
            --bind="ctrl-s:execute($sudo_prefix$base_cmd start {1} 2>&1 && echo '✓ Started {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd)" \
            --bind="ctrl-x:execute($sudo_prefix$base_cmd stop {1} 2>&1 && echo '✓ Stopped {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd)" \
            --bind="ctrl-r:execute($sudo_prefix$base_cmd restart {1} 2>&1 && echo '✓ Restarted {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd)" \
            --bind="ctrl-e:execute($sudo_prefix$base_cmd enable {1} 2>&1 && echo '✓ Enabled {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd)" \
            --bind="ctrl-d:execute($sudo_prefix$base_cmd disable {1} 2>&1 && echo '✓ Disabled {1}' || echo '✗ Failed: {1}'; sleep 0.5)+reload($list_cmd)" \
            --bind="ctrl-l:execute($journal_cmd -u {1} -n 200 --no-pager 2>/dev/null | $pager_str)+abort" \
            --bind="ctrl-f:execute($journal_cmd -u {1} -f 2>/dev/null)+abort" \
            --bind="ctrl-t:reload($base_cmd list-timers --all --no-pager --no-legend)" \
            --bind="ctrl-a:reload($list_all_cmd)" \
            --header='Enter:status │ ?:preview │ s:start │ x:stop │ r:restart │ e:enable │ d:disable │ l:logs │ f:follow │ t:timers │ a:all units' \
            --border='rounded' \
            --border-label='systemctl' \
            --cycle \
            --pointer='→' \
            --marker='✓' \
            --layout='reverse' \
            --info='inline-right' \
            --tiebreak='index' \
            --query="$query" \
            2>/dev/null
    )

    # Fallback display if needed (normally caught by +abort on enter)
    if test -n "$result"
        set -l unit (string split -f1 ' ' -- $result | string trim)
        if test -n "$unit"
            $base_cmd status "$unit" | $pager_str
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
