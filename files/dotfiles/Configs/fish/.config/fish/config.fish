# set PROFILE_CONF $HOME/.profile
# if test -f $PROFILE_CONF
#     fenv "source $PROFILE_CONF"
# end

# only run in an interactive shell
if status is-interactive
    # functions that should be loaded before anything else
    set FUNCS_FISH_SRC "$HOME/.config/fish/funcs.fish"
    if test -r "$FUNCS_FISH_SRC"
        source "$FUNCS_FISH_SRC"
    end

    set -g fish_greeting # disable initial fish greeting
    set -gx SHELL (command -v fish) # ensure fish can run inside multiplexers
    bootstrap_fisher # make sure fisher is installed

    set -g ZELLIJ_ENABLED false
    set -g TMUX_ENABLED true

    set -x GPG_TTY (tty)
    set -x XDG_DATA_HOME $HOME/.local/share
    set -x XDG_CONFIG_HOME $HOME/.config

    set -x RUSTUP_HOME $HOME/.rustup/toolchains/stable-x86_64-unknown-linux-gnu/bin
    set -x CARGO_HOME $HOME/.cargo
    set -x MISE_SHIMS $HOME/.local/share/mise/shims

    set -x LLAMA_API_KEY llama-cpp
    set -gx CREDENTIALS_DIRECTORY "$HOME/.local/share/credentials"

    set --erase fish_user_paths
    fish_add_path ~/.local/bin ~/.local/bin/scripts /usr/local/bin $RUSTUP_HOME $CARGO_HOME/bin $MISE_SHIMS

    set pure_shorten_prompt_current_directory_length 1
    set pure_truncate_prompt_current_directory_keeps 0
    set fish_prompt_pwd_dir_length 3
    # exclude some common cli tools from done notifications
    set -U --erase __done_exclude
    set -g __done_exclude '^git (?!push|pull|fetch)'
    set -g --append __done_exclude '^(nvim|nano|bat|cat|less|lazygit|lg)'
    set -g --append __done_exclude '^sudo (nvim|nano|bat|cat|less|qwen|gemini)'
    set -g --append __done_exclude '^sedit'

    set_editor
    setup_podman_sock
    update_wayland_env_vars

    # functions and evals that can be loaded after everything else
    set SOURCES_FISH_SRC "$HOME/.config/fish/sources.fish"
    if test -r "$SOURCES_FISH_SRC"
        source "$SOURCES_FISH_SRC"
    end
end
