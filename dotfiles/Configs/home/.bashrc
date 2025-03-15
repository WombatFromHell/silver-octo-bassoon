export PATH="$HOME/.local/bin:$HOME/.local/bin/scripts:$HOME/.nix-profile/bin:$HOME/.local/share/nvim/mason/bin:$HOME/.local/share/nvm/v23.6.1/bin:/usr/local/bin:$PATH"

function yy() {
	tmp=$(mktemp -t "yazi-cwd.XXXXXX")
	yazi "$@" --cwd-file="$tmp"
	if [[ $(cat "$tmp") =~ ([^\n]+) ]] && [ -n "${BASH_REMATCH[1]}" ] && [ "${BASH_REMATCH[1]}" != "$PWD" ]; then
		cd "${BASH_REMATCH[1]}" || exit 1
	fi
	rm -f "$tmp"
}

if [[ $- == *i* ]]; then
	# if command -v fish &>/dev/null &&
	# 	[[ $(ps -o comm= -p $PPID) != "fish" ]] &&
	# 	[[ "$CONTAINER_ID" == "devbox" ]]; then
	# fi

	EZA_STANDARD_OPTIONS="--group --header --group-directories-first --icons --color=auto -A"
	alias l='eza $EZA_STANDARD_OPTIONS'
	alias la='eza $EZA_STANDARD_OPTIONS --all'
	alias ll='eza $EZA_STANDARD_OPTIONS --long'
	alias ls='eza $EZA_STANDARD_OPTIONS'
	alias lt='eza $EZA_STANDARD_OPTIONS --tree'
	alias llt='eza $EZA_STANDARD_OPTIONS --long --tree'
	alias treed='eza $EZA_STANDARD_OPTIONS -DTA -L 1'
	alias tree='eza $EZA_STANDARD_OPTIONS -TA -L 1'
	#
	alias lg='lazygit'
	alias yz='yy'
	alias cat='bat'
	alias mkdir='mkdir -pv'
	alias tmls='tmux ls'
	#
	alias _rsync='rsync -avL --partial --update'
	alias _rsyncd='_rsync --dry-run'
	alias rsud='_rsync --delete'
	alias rsud_d='_rsyncd --delete'
	alias rsu='_rsync'
	alias rsu_d='_rsyncd'
	#
	_NIX_FLAKE_ROOT="$HOME/.nix"
	_HOST=$(hostname)
	_HMPATH=$(realpath "$_NIX_FLAKE_ROOT")
	_HMSUF="--flake $_HMPATH#$_HOST"
	alias _hmnix='nix run home-manager/master -- init'
	alias hmb='home-manager build --dry-run $_HMSUF'
	alias hms='home-manager switch $_HMSUF'
	alias hmls='home-manager generations'
	alias hmrm='home-manager remove-generations'
	#
	alias nixosopt='sudo nix-store --gc && sudo nix-store --optimize'
	alias nixopt='nix-store --gc && nix-store --optimize'
fi

CARGO_SRC="$HOME/.cargo/env"
if [ -r "$CARGO_SRC" ]; then
	source "$CARGO_SRC"
fi

if command -v direnv &>/dev/null; then
	export DIRENV_LOG_FORMAT=
	eval "$(direnv hook bash)"
fi
if command -v starship &>/dev/null; then
	eval "$(starship init bash)"
fi
if command -v zoxide &>/dev/null; then
	eval "$(zoxide init bash)"
	alias cd='z'
fi
