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

# start_with_llm [-f/--fg] [-r] [-p] [-u] [-R runner] [-b llm|strata] [cmd [args...]]
# — start a server, run cmd, stop the server. No cmd: just serve. -f/--fg blocks the
# container. -r: ROCm (else $ENABLE_ROCM=1 decides). -p: pull the image first. -u:
# refresh pi's extensions first. -R: runner config name (llm.sh workspace/*.sh).
# -b chooses which dispatcher serves and stops (llm by default). The serve args are built
# the same way for both, so a word that backend does not own (-p/-r/-R on strata) is
# refused by that dispatcher — never dropped.
function start_with_llm
    argparse -s f/fg r/rocm p/pull u/update R/runner= b/backend= -- $argv
    or return
    set -l backend llm
    set -q _flag_backend; and set backend $_flag_backend
    # Declared outside the if: a set -l inside a block dies at `end` (fish block scoping).
    set -l serve_cmd _llm_serve_sh
    set -l stop_cmd llm_stop
    if test "$backend" = strata
        # run.sh defaults to "start", so the action is named here and nowhere else:
        # strata_start forwards argv untouched, so a caller's own action word cannot
        # trip run.sh's "only one action" rule.
        set serve_cmd _strata_sh
        set stop_cmd strata_stop
    else if test "$backend" != llm
        echo "start_with_llm: unknown backend '$backend' (llm, strata)" >&2
        return 1
    end
    if set -q _flag_u
        wpi --update
        or return
    end
    set -l serve start
    set -q _flag_p; and set serve pull
    set -q _flag_f; and set serve $serve --fg
    set -q _flag_r; and set serve $serve -r
    set -q _flag_runner; and set serve $serve $_flag_runner
    if set -q argv[1]
        # podman blocks in foreground; background it so cmd runs concurrently
        $serve_cmd $serve &
        $argv
        set -l rc $status
        $stop_cmd
        return $rc
    end
    $serve_cmd $serve
end

# llm-coder [-s/--serve] [start_with_llm flags] [cmd [args...]] — start_with_llm,
# but with no cmd it runs pi; --serve restores plain "just serve".
function llm-coder
    argparse -s f/fg r/rocm p/pull u/update s/serve R/runner= b/backend= -- $argv
    or return
    if not set -q _flag_s; and not set -q argv[1]
        # no pi, no point starting the server
        set -q _flag_u; or command -q pi; or return 1
        set argv wpi
    end
    set -q _flag_runner; and set argv -R $_flag_runner $argv
    set -q _flag_backend; and set argv -b $_flag_backend $argv
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

# wpi [--update] [args...] — run pi (the binary in PATH) under gamemode (VRR off,
# LACT LLM). --update runs `pi update --extensions`: extensions only, since the
# binary is nix-managed and cannot self-update.
function wpi
    if contains -- --update $argv
        command pi update --extensions
    else
        _gamemode_run pi $argv
    end
end

# wdsh [args...] — run dsh with the web profile.
# No args (or the serve_dsh --public-url shape): through gamemode (VRR off, LACT
# LLM). Other args: the dsh binary in PATH directly, no gamemode, so plugins
# and profiles can still be installed/removed.
function wdsh
    if set -q argv[1]; and not contains -- --public-url $argv
        # plugin/profile management: the binary in PATH, no gamemode.
        command dsh $argv
    else
        # A direct run and the serve_dsh --public-url shape: gamemode, web profile.
        _gamemode_run dsh --profile web $argv
    end
end
