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
function coder
    start-with-llm $argv
end
function rcoder
    set -lx MODELS_PATH "/var/mnt/data1/vllm/models/models-rocm.ini"
    set -lx LLM_IMAGE "ghcr.io/stew675/llama-cpp-rdna-boosts:server-rocm-10.0"
    set -l pi_path (command -s pi)

    set -l do_update 0
    if set -l update_idx (contains -i -- --update $argv)
        set -e argv[$update_idx]
        set do_update 1
    end

    if set -q argv[1]
        start-with-llm $argv
    else if test -n "$pi_path" -a -x "$pi_path"
        test $do_update -eq 1; and command pi update --extensions
        start-with-llm $pi_path
    end
end
function wcoder
    ts_serve -u http://localhost:8787 start-with-llm env \
        PI_WEB_HOST=0.0.0.0 \
        PI_WEB_TOKEN=wcoder \
        pi-web-ui --no-browser
end
