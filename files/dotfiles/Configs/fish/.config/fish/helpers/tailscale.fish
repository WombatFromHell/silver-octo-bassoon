# tailscale.fish — ts_serve: run a command behind a `tailscale serve` mapping
# that lives exactly as long as its target.
command -q tailscale; or return 0

function ts_host --description "This node's tailnet DNS name"
    tailscale status --json | jq -r '.Self.DNSName' | string trim -c .
end

function ts_serve --description "Run a command behind a tailscale serve mapping that dies with its target"
    argparse -s 'u/url=' 'p/port=' 's/path=' -- $argv; or return 2
    set -q _flag_url; and test (count $argv) -gt 0; or begin
        echo "usage: ts_serve -u http://HOST:PORT [-p HTTPS_PORT] [-s PATH] command [args...]" >&2
        return 2
    end
    string match -rq '^https?://(?<host>[^/:]+):(?<tport>\d+)' -- $_flag_url; or begin
        echo "ts_serve: -u must look like http(s)://host:port" >&2
        return 2
    end
    set -q _flag_port; or set _flag_port 443

    set -l serve_args --https=$_flag_port
    set -l mapped_path /
    if set -q _flag_path
        set mapped_path (string replace -r '^/?' '/' -- $_flag_path)
        set -a serve_args --set-path=$mapped_path
    end

    # Re-applying an identical mapping is a no-op (measured), so no pre-flight
    # dedup query here; only the probe below matters, because `serve status` is
    # persistent config rather than live routing.
    tailscale serve --bg $serve_args $_flag_url; or return 1

    # Janitor: own session (setsid -f), no signal traps. Waits for the target to
    # come up, then for it to go away, then unmaps. The grace loop also gives up
    # when the launching shell dies, so an aborted or fast-failing run loses its
    # route within one poll instead of holding it for the whole grace.
    # ponytail: 60s startup grace, 1s poll, and the janitor keys on host:port rather
    # than on this run, so it cannot tell our old mapping from a newer one on the
    # same path: a second run whose target boots later than the grace would get its
    # route torn down by the first run's janitor. Exact ownership needs a per-run
    # token (a state file per path plus an owner check in both teardown paths).
    # kill -0 on the shell pid also misreads a recycled pid; that falls back to
    # waiting out the grace, i.e. the old behaviour.
    if not command -q setsid bash
        echo "ts_serve: no setsid/bash, so an aborted run leaks $mapped_path" >&2
    else
        setsid -f bash -c '
            host=$1 port=$2 parent=$3; shift 3
            alive() { (exec 3<>/dev/tcp/$host/$port) 2>/dev/null; }
            for _ in $(seq 60); do alive && break; kill -0 "$parent" 2>/dev/null || break; sleep 1; done
            if alive; then while alive; do sleep 1; done; fi
            tailscale serve "$@" off
        ' ts_serve $host $tport $fish_pid $serve_args >/dev/null 2>&1 </dev/null
    end

    # Unmapped => Serve's own "404 page not found" (19 bytes); a dead target is 502.
    set -l probe_root (string replace -r '/+$' '' -- $mapped_path)
    set -l probe (curl -sS -m 5 -o /dev/null -w '%{http_code} %{size_download}' \
        -- "https://"(ts_host)":$_flag_port$probe_root/")
    test -n "$probe"; or echo "ts_serve: routing of $probe_root not verified (curl failed)" >&2
    if test "$probe" = '404 19'
        echo "ts_serve: tailscale serve is not routing $probe_root, aborting" >&2
        tailscale serve $serve_args off; or begin
            echo "ts_serve: abort cleanup failed; $mapped_path may still proxy $_flag_url" >&2
        end
        return 1
    end

    $argv
    set -l exit_code $status

    # Clean-path teardown, keyed on the target's own liveness — the same TCP test the
    # janitor uses, so the two paths cannot disagree about one target (curl would
    # misread a non-HTTP target as dead). dsh wraps env+gamemode, which can
    # return while the app still serves, so an answering target stays owned by its
    # janitor rather than being unmapped here.
    if not command -q bash
        echo "ts_serve: no bash; $mapped_path left to its janitor" >&2
    else if bash -c '(exec 3<>/dev/tcp/"$1"/"$2") 2>/dev/null' x "$host" "$tport"
        echo "ts_serve: $_flag_url still answering; $mapped_path left to its janitor" >&2
    else
        # The janitor may have unmapped first, and `off` on an unmapped path exits
        # 1 ("handler does not exist", measured) — check, do not treat that as a leak.
        set -l handler (tailscale serve status --json | jq -r --arg p $mapped_path \
            '.Web // {} | to_entries[] | .value.Handlers // {} | .[$p] // empty')
        test -n "$handler"; or return $exit_code
        tailscale serve $serve_args off
        test $status = 0; or begin
            # The janitor can win the race between our status check and `off` (1s poll
            # vs. a ~100ms window); only a handler still present is a real leak.
            set -l still (tailscale serve status --json | jq -r --arg p $mapped_path \
                '.Web // {} | to_entries[] | .value.Handlers // {} | .[$p] // empty')
            test -n "$still"; and echo "ts_serve: teardown failed; $mapped_path may still proxy $_flag_url" >&2
        end
    end
    return $exit_code
end

function serve_dsh
    set -l PUBLIC_HOST (ts_host)
    # wdsh is the target command itself: fish resolves the function before the
    # binary, and wdsh routes --public-url runs through gamemode (VRR off, LACT
    # LLM) like a direct run, so VRR/LACT stay in one place.
    ts_serve -u http://127.0.0.1:3080 -s /dsh \
        wdsh --public-url "https://$PUBLIC_HOST/dsh" --trusted-host $PUBLIC_HOST $argv
end
