# zz-init.fish — shell inits that must run after all other helpers.
# The zz- prefix keeps this last in the helpers/ glob order.

if command -q atuin
    atuin init fish --disable-up-arrow | source
end
if command -q zoxide
    zoxide init fish | source
    alias cd="z"
end

if command -q direnv
    direnv hook fish | source
end

if command -q mise
    mise activate fish | source
end

if command -q starship
    starship init fish | source
end
