function llm-rocm-env
    # -gx: global+exported so child processes (llm.sh) see it from the caller's scope
    set -gx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    set -gx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:server-rocm-10.0"
    # set -gx LLM_IMAGE "localhost/llama.cpp:server-rocm"
end
function start-llm
    /var/mnt/data1/vllm/llm.sh start
end
function _llm_unrocm
    set -e MODELS_PATH LLM_IMAGE
end
function pull-llm
    if contains -- --rocm $argv
        llm-rocm-env
        /var/mnt/data1/vllm/llm.sh pull
        _llm_unrocm
    else
        /var/mnt/data1/vllm/llm.sh pull
    end
end
function stop-llm
    /var/mnt/data1/vllm/llm.sh stop
end
function start-with-llm
    start-llm
    if set -q argv[1]
        $argv
        stop-llm
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

    test $mode = rocm; and llm-rocm-env

    if test $serve = 1
        start-llm
        test $mode = rocm; and _llm_unrocm
        return
    end

    set -l pi_path (command -s pi)

    if set -q rest[1]
        start-with-llm $rest
    else if test -n "$pi_path" -a -x "$pi_path"
        test $do_update -eq 1; and command pi update --extensions
        start-with-llm $pi_path
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
