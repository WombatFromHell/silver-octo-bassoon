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

    # Map only if this path on this HTTPS port doesn't already proxy to our URL.
    # Config, not live routing: the probe below still verifies it actually works.
    set -l mapped (tailscale serve status --json | jq -r \
        --arg p $mapped_path --arg port ":$_flag_port" --arg u $_flag_url \
        '[(.Web // {}) | to_entries[] | select(.key | endswith($port)) | .value.Handlers[$p].Proxy] | any(. == $u)')
    test "$mapped" = true; or tailscale serve --bg $serve_args $_flag_url; or return 1

    # Janitor: own session (Ctrl+C never reaches it), no traps. Waits for the
    # target to come up, then go away, then unmaps. Always spawned, even when the
    # route pre-existed, since that route may be a stale leak with no watcher.
    # ponytail: 60s startup grace, 1s poll; raise the grace for slow-starting apps.
    # Upgrade path if you need exact ownership: a flock-based refcount.
    setsid -f bash -c '
        host=$1 port=$2; shift 2
        alive() { (exec 3<>/dev/tcp/$host/$port) 2>/dev/null; }
        for _ in $(seq 60); do alive && break; sleep 1; done
        while alive; do sleep 1; done
        tailscale serve "$@" off
    ' ts_serve $host $tport $serve_args >/dev/null 2>&1 </dev/null

    # Unmapped => Serve's own "404 page not found" (19 bytes); a dead target is 502.
    set -l probe_root (string replace -r '/+$' '' -- $mapped_path)
    set -l probe (curl -sS -m 5 -o /dev/null -w '%{http_code} %{size_download}' \
        -- "https://"(ts_host)":$_flag_port$probe_root/")
    test -n "$probe"; or echo "ts_serve: routing of $probe_root not verified (curl failed)" >&2
    if test "$probe" = '404 19'
        echo "ts_serve: tailscale serve is not routing $probe_root, aborting" >&2
        tailscale serve $serve_args off
        return 1
    end

    $argv
end

function serve_dsh
    set -l PUBLIC_HOST (ts_host)
    ts_serve -u http://127.0.0.1:3080 -s /dsh \
        env ENABLE_VRR=0 gamemode -- dsh --profile web \
        --public-url "https://$PUBLIC_HOST/dsh" --trusted-host $PUBLIC_HOST
end
