function llm_rocm_env
    # -gx: global+exported so child processes (llm.sh) see it from the caller's scope
    set -gx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    set -gx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:server-rocm-10.0"
    # set -gx LLM_IMAGE "localhost/llama.cpp:server-rocm"
end
function _llm_unrocm
    set -e MODELS_PATH LLM_IMAGE
end
function pull_llm
    if contains -- --rocm $argv
        llm_rocm_env
        /var/mnt/data1/vllm/llm.sh pull
        _llm_unrocm
    else
        /var/mnt/data1/vllm/llm.sh pull
    end
end
alias start_llm="/var/mnt/data1/vllm/llm.sh start"
alias stop_llm="/var/mnt/data1/vllm/llm.sh stop"
function start_with_llm
    start_llm
    if set -q argv[1]
        $argv
        stop_llm
    end
end
function llm-coder
    set -l mode vulkan
    set -l serve 0
    set -l do_update 0
    set -l rest

    for arg in $argv
        switch $arg
            case --rocm
                set mode rocm
            case --serve
                set serve 1
            case --update
                set do_update 1
            case '*'
                set -a rest $arg
        end
    end

    test $mode = rocm; and llm_rocm_env

    if test $serve = 1
        start_llm
        test $mode = rocm; and _llm_unrocm
        return
    end

    set -l pi_path (command -s pi)

    if set -q rest[1]
        start_with_llm $rest
    else if test -n "$pi_path" -a -x "$pi_path"
        test $do_update -eq 1; and command pi update --extensions
        start_with_llm $pi_path
    end
    test $mode = rocm; and _llm_unrocm
end
alias coder='llm-coder'
alias rcoder='llm-coder --rocm'
function wcoder
    ts_serve -u http://localhost:8787 start-with-llm env \
        PI_WEB_HOST=0.0.0.0 \
        PI_WEB_TOKEN=wcoder \
        pi-web-ui --no-browser
end
