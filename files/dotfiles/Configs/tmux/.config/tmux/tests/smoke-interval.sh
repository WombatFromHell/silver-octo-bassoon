#!/usr/bin/env bash
# smoke-interval.sh — smoketest for the statusbar `#()` spawn cadence.
#
# Starts a SCRATCH tmux server (private TMUX_TMPDIR + socket; TMUX/TMUX_PANE
# unset; every tmux call pinned to -S "$SOCK" via the test_helper wrapper, so
# the live server is unreachable), loads the real conf (status-interval 3),
# replaces statusbar.sh with an instrumented stand-in that logs its spawn
# time, attaches an observer client, and prints the intervals between
# consecutive spawns.
#
# Expected if F1 holds: ~1.0 s intervals (back-to-back), NOT ~3.0 s.
#
# Phase 2 probes how `#{opt}` values are strftime'd in status formats
# (needed to design the push-model fix): bare `%` vs `%%` in option values.
#
# Usage: bash tests/smoke-interval.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=test_helper.bash
source tests/test_helper.bash
export BATS_TEST_DIRNAME="$PWD/tests" # load_conf resolves the real conf from here

trap stop_scratch_server EXIT

start_scratch_server
load_conf

# --- Phase 1: spawn cadence -------------------------------------------------
LOG="$T/spawns.log"
cat >"$HOME/.config/tmux/scripts/statusbar.sh" <<EOF
#!/usr/bin/env bash
date +%s.%N >> "$LOG"
sleep 1
printf '42%% 15%% '
EOF
chmod +x "$HOME/.config/tmux/scripts/statusbar.sh"

tmux new-session -d -s obs -x 200 -y 20 'env -u TMUX tmux attach-session -t base'
sleep 13

echo "== Phase 1: spawn timestamps (epoch s) =="
cat "$LOG"
echo
echo "== intervals between consecutive spawns (s) =="
awk '{ t[NR] = $1 }
     END {
       n = NR - 1
       if (n <= 0) { print "need >= 2 spawns"; exit 1 }
       for (i = 1; i <= n; i++) {
         d = t[i + 1] - t[i]
         printf "%.2f\n", d
         sum += d
         if (i == 1 || d < min) min = d
         if (i == 1 || d > max) max = d
       }
       printf "min/max/mean: %.2f / %.2f / %.2f over %d intervals\n", min, max, sum / n, n
     }' "$LOG"
echo
echo "== conclusion =="
awk '{ t[NR] = $1 }
     END {
       n = NR - 1
       if (n <= 0) { print "inconclusive: need >= 2 spawns"; exit 1 }
       short = 0; ok = 0
       for (i = 1; i <= n; i++) {
         d = t[i + 1] - t[i]
         if (d < 2.0) short++
         if (d >= 2.5 && d <= 4.0) ok++
       }
       if (short > 0) print "F1 CONFIRMED: back-to-back spawns (~1s), status-interval NOT gating"
       else if (ok > 0) print "interval OK: spawns gated at ~status-interval"
       else print "inconclusive"
     }' "$LOG"

# --- Phase 2: strftime handling of % in #{opt} values ------------------------
tmux set -g @probe '50%|70% '
tmux set -g @probe2 '42%%'
tmux set -g status-right 'A#{@probe}B#{@probe2}C#[default]'
sleep 4
row="$(tmux capture-pane -p -t obs | head -1)"
echo
echo "== Phase 2: option-value percent rendering =="
echo "option @probe  = '50%|70% ' (bare %)"
echo "option @probe2 = '42%%'      (double %)"
echo "status-right   = 'A#{@probe}B#{@probe2}C#[default]'"
echo "rendered row   : $row"
