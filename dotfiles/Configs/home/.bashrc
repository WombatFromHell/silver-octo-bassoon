export PATH="$PATH:$HOME/.local/bin:$HOME/.local/bin/scripts:$HOME/.nix-profile/bin:$HOME/.local/share/nvim/mason/bin:$HOME/.local/share/nvm/v23.6.1/bin:/usr/local/bin"

if [[ $- == *i* ]]; then
	# if command -v fish &>/dev/null &&
	# 	[[ $(ps -o comm= -p $PPID) != "fish" ]] &&
	# 	[[ "$CONTAINER_ID" == "devbox" ]]; then
	# fi
	if command -v direnv &>/dev/null; then
		export DIRENV_LOG_FORMAT=
		eval "$(direnv hook bash)"
	fi
	if command -v zoxide &>/dev/null; then
		eval "$(zoxide init bash)"
	fi
	if command -v starship &>/dev/null; then
		eval "$(starship init bash)"
	fi
fi

CARGO_SRC="$HOME/.cargo/env"
if [ -r "$CARGO_SRC" ]; then
	source "$CARGO_SRC"
fi
