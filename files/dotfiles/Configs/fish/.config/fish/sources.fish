# Source every helper in helpers/ (alphabetical order).
# Adding a helper = drop a file in helpers/. No edits needed here.
# zz-init.fish (shell inits) sorts last by name.
for f in $HOME/.config/fish/helpers/*.fish
    source $f
end
