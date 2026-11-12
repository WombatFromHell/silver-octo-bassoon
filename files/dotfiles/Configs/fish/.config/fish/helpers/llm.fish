# Path of the first installed command in $argv, else complain on stderr and
# print nothing. command -s ignores functions, so a wrapper never resolves itself.
function _first_cmd
    command -s $argv | read -l p
    or begin
        echo "none of ($argv) is installed" >&2
        return 1
    end
    echo $p
end

# Run $argv under gamemode with VRR off and the LACT "LLM" profile; restore "UV".
function _gamemode_run
    _lact profile set LLM
    command env ENABLE_VRR=0 gamemode -- $argv
    set -l rc $status
    _lact profile set UV
    return $rc
end

function _lact
    flatpak run --command=lact io.github.ilya_zlobintsev.LACT cli $argv
end

# Both dispatchers forward argv verbatim: llm.sh / run.sh own their vocabulary and
# refuse words they do not understand, so a typo never reaches them as a runner name.
function _llm_sh
    /var/mnt/data1/vllm/llm.sh $argv
end

# Serve (start/pull) with ROCm: -r/--rocm passes through, and $ENABLE_ROCM=1
# (config.fish) appends it. llm.sh pairs the image with the matching models.ini.
function _llm_serve_sh
    test "$ENABLE_ROCM" = 1
    and set argv $argv --rocm
    _llm_sh $argv
end

function llm_start
    _llm_serve_sh start $argv
end
function llm_pull
    _llm_serve_sh pull $argv
end # note: llm.sh pull = pull image AND start server
function llm_stop
    _llm_sh stop
end
function llm_logs
    _llm_sh logs
end
alias lcoder='llm_start --fg'

# start_with_llm [-f/--fg] [-r] [-p] [-u] [-R runner] [cmd [args...]] — start the
# server, run cmd, stop the server. No cmd: just serve. -f/--fg blocks the container.
# -r: ROCm (else $ENABLE_ROCM=1 decides). -p: pull the image first. -u: update
# pi-bolt + extensions first. -R: runner config name (llm.sh workspace/*.sh).
function start_with_llm
    argparse -s f/fg r/rocm p/pull u/update R/runner= -- $argv
    or return
    if set -q _flag_u
        _pi_update
        or return
    end
    set -l serve start
    set -q _flag_p; and set serve pull
    set -q _flag_f; and set serve $serve --fg
    set -q _flag_r; and set serve $serve -r
    set -q _flag_runner; and set serve $serve $_flag_runner
    if set -q argv[1]
        # podman blocks in foreground; background it so cmd runs concurrently
        _llm_serve_sh $serve &
        $argv
        set -l rc $status
        llm_stop
        return $rc
    end
    _llm_serve_sh $serve
end

# llm-coder [-s/--serve] [start_with_llm flags] [cmd [args...]] — start_with_llm,
# but with no cmd it runs pi; --serve restores plain "just serve".
function llm-coder
    argparse -s f/fg r/rocm p/pull u/update s/serve R/runner= -- $argv
    or return
    if not set -q _flag_s; and not set -q argv[1]
        # no pi, no point starting the server (-u may install it first)
        set -q _flag_u; or _pi_cmd >/dev/null; or return
        set argv pi
    end
    set -q _flag_runner; and set argv -R $_flag_runner $argv
    start_with_llm $_flag_f $_flag_r $_flag_p $_flag_u $argv
end

# The strata dispatcher, reusable by any caller (route wrappers etc.). run.sh
# defaults to "start", so strata_start forwards argv untouched — an explicit
# "start" next to a caller's own action word would trip its "only one action" rule.
function _strata_sh
    /var/mnt/data0/strata/run.sh $argv
end
function strata_start
    _strata_sh $argv
end
function strata_stop
    _strata_sh stop
end
function strata_logs
    _strata_sh logs
end
alias scoder='strata_start --fg'

# The pi binary to run: pi-bolt when installed, else pi.
function _pi_cmd
    _first_cmd pi-bolt pi
end

# Upgrade pi-bolt (pnpm preferred, else npm), then refresh its extensions on
# whatever binary ended up installed (resolved after, so a first install counts).
function _pi_update
    set -l pm (_first_cmd pnpm npm)
    or return
    $pm i -g pi-bolt@latest
    or return
    set -l cmd (_pi_cmd)
    or return
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
    or return
    _gamemode_run $cmd $argv
end

# Separate from dsh so a wrapper (ts_serve) can put it behind a route.
function _dsh_run
    _gamemode_run dsh $argv
end

# dsh [--update] [args...] — run dsh with the web profile. --update installs dsh
# and refreshes that plugin, without launching it. $argv is not passed to the
# plugin update: the extra words belong to dsh, not to the plugin.
function dsh
    contains -- --update $argv
    or begin
        _dsh_run --profile web $argv
        return
    end
    set -l pm (_first_cmd pnpm npm)
    or return
    $pm i -g @deepseek-ai/dsh
    or return
    command dsh plugin --profile web update
end
