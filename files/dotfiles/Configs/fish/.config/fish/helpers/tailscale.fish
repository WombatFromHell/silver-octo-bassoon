# tailscale.fish — ts_serve: run a command under a temporary `tailscale serve` mapping.

if not command -q tailscale
    return 0
end

function ts_serve --description "Run a command wrapped in a temporary tailscale serve mapping"
    argparse -s 'u/url=' 'p/port=' 's/path=' -- $argv; or return 2
    set -q _flag_url; or begin
        echo "usage: ts_serve -u URL [-p PORT] [-s PATH] command [args...]" >&2
        return 2
    end
    test (count $argv) -gt 0; or begin
        echo "ts_serve: no command given" >&2
        return 2
    end
    set -q _flag_port; or set _flag_port 443

    set -l serve_args --https=$_flag_port
    if set -q _flag_path
        set -a serve_args --set-path=(string replace -r '^/?' '/' -- $_flag_path)
    end

    tailscale serve --bg $serve_args $_flag_url; or return 1

    $argv
    set -l exit_code $status

    tailscale serve $serve_args off
    return $exit_code
end

# shortcut: Ctrl+C aborts the function body, so the mapping stays until the next
# ts_serve. Fish has no hook that fires on an aborted job or a signalled shell
# (--on-signal INT/TERM, --on-job-exit caller and fish_exit all verified dead for
# those cases), so a detached watcher process is the only upgrade.
