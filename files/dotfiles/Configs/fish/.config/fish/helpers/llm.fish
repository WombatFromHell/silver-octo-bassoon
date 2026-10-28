# Path of the first installed command in $argv; empty with a non-zero status
# if none is installed (command -s ignores functions, so a wrapper can never
# resolve itself). Callers check the value, not the status number.
function _first_cmd
    for cmd in $argv
        command -s $cmd
        and return
    end
end

function _llm_sh
    /var/mnt/data1/vllm/llm.sh $argv
end
function start_llm
    _llm_sh start $argv
end
function stop_llm
    _llm_sh stop
end
# Run $argv with the rocm env exported (llm.sh reads it), then clear it.
function _llm_rocm
    set -gx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    set -gx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:rocm-10.1"
    # set -gx LLM_IMAGE "localhost/llama.cpp:server-rocm"
    $argv
    set -l rc $status
    set -e MODELS_PATH LLM_IMAGE
    return $rc
end
function pull_llm # note: llm.sh pull = pull image AND start server
    argparse -s r/rocm -- $argv
    or return
    set -l cmd _llm_sh pull $argv
    if set -q _flag_r
        _llm_rocm $cmd
    else
        $cmd
    end
end
# start_with_llm [-f] cmd [args...] — start server, run cmd, stop server.
# No cmd: just start (-f blocks).
function start_with_llm
    argparse -s f/foreground -- $argv
    or return
    set -l flags
    set -q _flag_f; and set -a flags -f
    if set -q argv[1]
        # podman blocks in foreground; background it so cmd runs concurrently
        start_llm $flags &
        $argv
        stop_llm
    else
        start_llm $flags
    end
end
# llm-coder [--rocm] [--serve] [--update] [-f] [cmd [args...]]
# No cmd: serve if --serve, else run pi (--update runs `pi update --extensions` first).
function llm-coder
    argparse -s r/rocm s/serve u/update f/foreground -- $argv
    or return
    set -l flags
    set -q _flag_f; and set -a flags -f

    set -l cmd
    if set -q _flag_s
        set cmd start_with_llm $flags
    else if set -q argv[1]
        set cmd start_with_llm $flags $argv
    else
        # Resolve once; nothing to run means don't start the server.
        set -l pi_cmd (_pi_cmd)
        if test -z "$pi_cmd"
            return 1
        end
        set -q _flag_u; and $pi_cmd update --extensions
        set cmd start_with_llm $flags $pi_cmd
    end

    if set -q _flag_r
        _llm_rocm $cmd
    else
        $cmd
    end
end
alias coder='/var/mnt/data0/strata/run-gyro-gyro-s.sh'
function serve_dsh
    set -l PUBLIC_HOST (tailscale status --json | jq -r '.Self.DNSName' | string trim -c .)
    ts_serve -u http://127.0.0.1:3080 -s /dsh \
        env ENABLE_VRR=0 gamemode -- dsh --profile web \
        --public-url "https://$PUBLIC_HOST/dsh" --trusted-host $PUBLIC_HOST \
        --no-open
end

# The pi binary to run: pi-bolt when installed, else pi.
function _pi_cmd
    _first_cmd pi-bolt pi
end

# Install pi-bolt globally, pnpm preferred, npm fallback.
function _pi_install
    set -l pm (_first_cmd pnpm npm)
    if test -z "$pm"
        printf 'pi --update: neither pnpm nor npm is available\n' >&2
        return 1
    end
    command $pm i -g pi-bolt@latest
end

# Upgrade pi-bolt, then refresh its extensions on whatever binary ended up
# installed (resolved after the install, so a first-time install counts).
function _pi_update
    _pi_install
    or return
    set -l cmd (_pi_cmd)
    if test -z "$cmd"
        printf 'pi --update: nothing installed, cannot update extensions\n' >&2
        return 1
    end
    $cmd update --extensions
end

# pi [--update] [args...] — run pi-bolt, else pi. --update installs pi-bolt@latest
# and refreshes extensions, without launching pi.
function pi
    if contains -- --update $argv
        _pi_update
        return
    end
    set -l cmd (_pi_cmd)
    if test -z "$cmd"
        printf 'pi: neither pi-bolt nor pi is installed\n' >&2
        return 1
    end
    command $cmd $argv
end
