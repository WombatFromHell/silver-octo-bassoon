#!/usr/bin/env bash
set -euo pipefail
#
# framelimit.sh — wrap a command with frame-rate limiting.
#
# Usage: framelimit.sh [FLAGS] [<fps>] -- <command> [args...]
#   FLAGS: --dry-run|-n, --vkd3d, --dxvk, --help   (flags always come first)
#   <fps>: optional integer frame cap (default 60)
#   --:    required delimiter before the runnable command
#
# Behavior:
#   - No engine flags  -> run `mangohud` with MANGOHUD env vars.
#   - --vkd3d/--dxvk   -> run the command directly (no mangohud) with the
#     engine frame-rate env vars set.
#
# All env vars are set non-destructively: a pre-existing value is preserved.

# Print usage to stderr.
usage() {
	echo "Usage: ${0##*/} [--dry-run|-n] [--vkd3d] [--dxvk] [<fps>] -- <command> [args...]" >&2
}

# Print an error message, then usage, and exit 1.
die() {
	echo "framelimit: $1" >&2
	usage
	exit 1
}

# Print the full help/usage and exit 0.
help() {
	cat <<EOF
framelimit.sh — wrap a command with frame-rate limiting.

Usage: ${0##*/} [FLAGS] [<fps>] -- <command> [args...]

FLAGS (always come first):
  --dry-run, -n   Print the exact env vars and command, then exit (no exec).
  --vkd3d         Set VKD3D_CONFIG + VKD3D_FRAME_RATE; run the command directly.
  --dxvk          Set DXVK_CONFIG; run the command directly.
  --help          Show this help and exit.

<fps>  Optional integer frame cap (default 60).
--     Required delimiter separating our args from the runnable command.

Default: MangoHUD mode. With no --vkd3d/--dxvk, the command is wrapped by
'mangohud' with MANGOHUD env vars. Giving --vkd3d and/or --dxvk disables
mangohud and runs the command directly with the dxvk/vkd3d frame-rate env vars.
EOF
}

# Non-destructively append a fragment to a list-like env var that may already
# be set. Reusable + composable: pass any (var name, separator, fragment).
#   - var unset  -> created with the fragment.
#   - var set    -> fragment appended via bash's += append.
#   - fragment already present -> no-op (idempotent), so a user's pre-existing
#     config is never clobbered.
# $1 = env var name, $2 = separator, $3 = fragment to add
append_cfg() {
	local -n _ref=$1
	local sep=$2 frag=$3
	if [[ -n ${_ref+x} ]]; then
		case "$_ref" in
		*"$frag"*) : ;;
		*) _ref+="$sep$frag" ;;
		esac
	else
		_ref=$frag
	fi
	# $1 is a variable name, exported by name (shellcheck can't see through it).
	# shellcheck disable=SC2163
	export "$1"
}

# Set a scalar env var only if it is not already set (non-destructive).
# $1 = env var name, $2 = value
set_if_unset() {
	local -n _ref=$1
	local val=$2
	[[ -n ${_ref+x} ]] || _ref=$val
	# $1 is a variable name, exported by name (shellcheck can't see through it).
	# shellcheck disable=SC2163
	export "$1"
}

main() {
	local dry_run=false
	local vkd3d=false dxvk=false
	local fps=60

	# Flags come first: consume every leading -<flag> / --<flag> arg.
	while [[ ${1:-} == -* && ${1:-} != "--" ]]; do
		case "$1" in
		--dry-run | -n) dry_run=true ;;
		--vkd3d) vkd3d=true ;;
		--dxvk) dxvk=true ;;
		--help)
			help
			exit 0
			;;
		*) die "Unknown flag: $1" ;;
		esac
		shift
	done

	# fps: optional integer, after the flags.
	if [[ -n ${1:-} && ${1:-} != "--" ]]; then
		[[ ${1:-} =~ ^[0-9]+$ ]] || die "Invalid fps: $1"
		fps=$1
		shift
	fi

	# '--' is required to separate our args from the runnable command.
	[[ ${1:-} == "--" ]] || die "Missing required '--' delimiter"
	shift

	# A runnable command is required after '--'.
	[[ -n ${1:-} ]] || die "Missing command after '--'"

	# Build the env args for the wrapped process. Each flag contributes its own
	# vars (composable). mangohud runs only when no engine flag is given.
	local env_args=()
	if [[ $vkd3d == true ]]; then
		append_cfg VKD3D_CONFIG , "frame_rate_limit=$fps"
		set_if_unset VKD3D_FRAME_RATE "$fps"
		env_args+=("VKD3D_CONFIG=$VKD3D_CONFIG" "VKD3D_FRAME_RATE=$VKD3D_FRAME_RATE")
	fi
	if [[ $dxvk == true ]]; then
		append_cfg DXVK_CONFIG ";" "dxgi.maxFrameRate=$fps;d3d9.maxFrameRate=$fps"
		env_args+=("DXVK_CONFIG=$DXVK_CONFIG")
	fi
	local cmd=()
	if [[ $vkd3d == false && $dxvk == false ]]; then
		local cfg="vsync=3,fps_limit_method=early,fps_limit=$fps"
		[[ -n ${MANGOHUD_CONFIG:-} ]] && cfg="${MANGOHUD_CONFIG},${cfg}" || cfg="read_cfg,${cfg}"
		env_args+=("MANGOHUD=1" "MANGOHUD_CONFIG=$cfg")
		cmd=(mangohud)
	fi
	local full_cmd=("${cmd[@]}" "$@")

	# The exact command we run: env <vars> <command>. Built once, shared by
	# dry-run (printed) and exec (run), so --dry-run shows exactly what runs.
	local cmdline=(env "${env_args[@]}" "${full_cmd[@]}")

	# Dry-run: print the exact command as a single runnable line, then exit.
	if [[ $dry_run == true ]]; then
		printf '%s\n' "${cmdline[*]}"
		exit 0
	fi

	# Exec the wrapped process with our env vars.
	exec "${cmdline[@]}"
}

main "$@"
