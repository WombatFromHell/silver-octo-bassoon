function start-llm
    /var/mnt/data1/vllm/llm.sh start
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

    test $mode = rocm; and set -lx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    test $mode = rocm; and set -lx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:server-rocm-10.0"

    if test $serve = 1
        start-llm
        return
    end

    set -l pi_path (command -s pi)

    if set -q rest[1]
        start-with-llm $rest
    else if test -n "$pi_path" -a -x "$pi_path"
        test $do_update -eq 1; and command pi update --extensions
        start-with-llm $pi_path
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
