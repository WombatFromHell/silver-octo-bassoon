function _llm_sh
    /var/mnt/data1/vllm/llm.sh $argv
end
function start_llm
    _llm_sh start $argv
end
function stop_llm
    _llm_sh stop
end
# Exported so child processes (llm.sh) see them from the caller's scope
function llm_rocm_env
    set -gx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    set -gx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:server-rocm-10.0"
    # set -gx LLM_IMAGE "localhost/llama.cpp:server-rocm"
end
# Run $argv under the rocm env, then restore
function _llm_rocm
    llm_rocm_env
    $argv
    set -q MODELS_PATH; and set -e MODELS_PATH
    set -q LLM_IMAGE; and set -e LLM_IMAGE
end
function pull_llm  # note: llm.sh pull = pull image AND start server
    argparse -s 'r/rocm' -- $argv
    or return
    if set -q _flag_r
        _llm_rocm _llm_sh pull $argv
    else
        _llm_sh pull $argv
    end
end
# start_with_llm [-f] cmd [args...] — start server, run cmd, stop server.
# No cmd: just start (-f blocks).
function start_with_llm
    argparse -s 'f/foreground' -- $argv
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
    argparse -s 'r/rocm' 's/serve' 'u/update' 'f/foreground' -- $argv
    or return
    set -l flags
    set -q _flag_f; and set -a flags -f
    if set -q _flag_s
        set -a cmd start_with_llm $flags
    else if set -q argv[1]
        set -a cmd start_with_llm $flags $argv
    else
        set -l pi_path (command -s pi)
        if test -n "$pi_path" -a -x "$pi_path"
            set -q _flag_u; and command pi update --extensions
            set -a cmd start_with_llm $flags $pi_path
        end
    end
    if set -q cmd[1]
        if set -q _flag_r
            _llm_rocm $cmd
        else
            $cmd
        end
    end
end
alias coder='llm-coder'
alias rcoder='llm-coder --rocm'
function wcoder
    ts_serve -u http://localhost:8787 start-with-llm env \
        PI_WEB_HOST=0.0.0.0 \
        PI_WEB_TOKEN=wcoder \
        pi-web-ui --no-browser
end
