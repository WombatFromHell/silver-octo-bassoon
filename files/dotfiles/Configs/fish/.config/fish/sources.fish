# Source every helper recursively (alphabetical by full path).
# Adding a helper = drop a file in helpers/ (or a subdirectory). No edits needed here.
# Load-order contract:
#   - shell/funcs.fish is sourced first by config.fish (before this glob).
#   - mux/00-mux-common.fish sorts first within mux/ (wrappers call it at source time).
#   - zz-init.fish stays top-level, so it sorts after all subdirectories (runs last).
for f in $HOME/.config/fish/helpers/**/*.fish
    source $f
end
