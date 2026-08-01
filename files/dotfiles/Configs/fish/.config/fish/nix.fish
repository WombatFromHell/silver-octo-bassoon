if command -q nix-fast-build
    set -g NIX_MAX_JOBS (nproc | awk '{ j = int($1 * 0.75); print (j > 1 ? j : 1) }')

    set -g NFB_COMMON_OPTS \
        --max-jobs $NIX_MAX_JOBS \
        --option show-trace true \
        --option extra-deprecated-features or-as-identifier \
        --option extra-experimental-festures "nix-command flakes eval-cache"

    function nix_build
        if contains -- --sudo $argv
            set -l args (string match -v '--sudo' $argv)
            command sudo -i nix-fast-build $NFB_COMMON_OPTS $args
        else
            command nix-fast-build $NFB_COMMON_OPTS $argv
        end
    end
    function nix_eval
        set -lx GC_INITIAL_HEAP_SIZE 2G
        if contains -- --sudo $argv
            set -l args (string match -v '--sudo' $argv)
            command sudo -i nix-eval-jobs $NFB_COMMON_OPTS $args
        else
            command nix-eval-jobs $NFB_COMMON_OPTS $argv
        end
    end
    function hm_fswitch
        if test (count $argv) -lt 2
            echo "Error: Missing required arguments."
            echo "Usage: hm_fswitch <flake-path> <user@host> [extra nix-fast-build args]"
            return 1
        end

        set -l flake_path $argv[1]
        set -l target $argv[2]
        set -l extra_args $argv[3..-1]

        # Expand relative paths or environment variables safely
        nix_build \
            --flake "$flake_path#homeConfigurations.\"$target\".activationPackage" \
            --out-link /tmp/hm-result $extra_args
        and /tmp/hm-result-/activate
    end
    function nixos_fswitch
        if test (count $argv) -lt 2
            echo "Error: Missing required arguments."
            echo "Usage: nixos_fswitch <flake-path> <host> [switch|build|--dry-run] [--remote user@target] [extra args]"
            return 1
        end

        set -l flake_path $argv[1]
        set -l target_host $argv[2]
        set -l remaining $argv[3..-1]

        # Target attribute for NixOS top-level system closure
        set -l attr "$flake_path#nixosConfigurations.\"$target_host\".config.system.build.toplevel"

        # MODE 1: Dry-Run (Parallel Evaluation Only via nix-eval-jobs)
        if contains -- --dry-run $remaining
            set -l extra_args (string match -v '--dry-run' $remaining)
            echo "Evaluating $target_host via nix-eval-jobs..."
            nix_eval --flake $attr $extra_args
            return 0
        end

        # Parse action mode: 'switch' vs default 'build'
        set -l do_switch false
        if contains -- switch $remaining
            set do_switch true
            set remaining (string match -v 'switch' $remaining)
        else if contains -- build $remaining
            set remaining (string match -v 'build' $remaining)
        end

        # Parse --remote <user@host> if deploying over SSH
        set -l remote_target ""
        if contains -- --remote $remaining
            set -l remote_idx (contains -i -- --remote $remaining)
            set -l val_idx (math $remote_idx + 1)
            set remote_target $remaining[$val_idx]
            set remaining (string match -v -- "--remote" $remaining | string match -v -- "$remote_target")
        end

        # MODE 2: Build (Generates out-link at /tmp/nixos-result-)
        echo "Building NixOS configuration for '$target_host'..."
        nix_build \
            --flake $attr \
            --out-link /tmp/nixos-result \
            $remaining
        or return 1

        # Locate the built system closure path
        set -l build_out ""
        if test -e /tmp/nixos-result/result
            set build_out (realpath /tmp/nixos-result-/result)
        else if test -e /tmp/nixos-result/toplevel
            set build_out (realpath /tmp/nixos-result/toplevel)
        else
            echo "Error: Could not locate built store path in /tmp/nixos-result-"
            return 1
        end

        # Find the activation executable inside the output link
        set -l switch_bin ""
        if test -x "$build_out/bin/switch-to-configuration"
            set switch_bin "$build_out/bin/switch-to-configuration"
        else if test -x "$build_out/bin/switch"
            set switch_bin "$build_out/bin/switch"
        end

        # Stop here if only 'build' mode was intended
        if not $do_switch
            echo "Build successful! System closure available at: $build_out"
            return 0
        end

        # MODE 3: Switch (Runs activation script)
        if test -z "$switch_bin"
            echo "Error: Could not find switch-to-configuration executable in $build_out"
            return 1
        end

        if test -n "$remote_target"
            echo "Deploying and switching configuration on remote host '$remote_target'..."
            command nix copy --to "ssh://$remote_target" $build_out
            and command ssh -t $remote_target "sudo nix-env --profile /nix/var/nix/profiles/system --set $build_out && sudo $switch_bin switch"
        else
            echo "Switching local NixOS configuration..."
            command sudo nix-env --profile /nix/var/nix/profiles/system --set $build_out
            and command sudo $switch_bin switch
        end
    end
    function nixos_fdeploy
        if test (count $argv) -lt 2
            echo "Usage: nixos_fdeploy <flake-path> <host> [user@remote-ip] [extra nix args...]"
            return 1
        end

        set -l flake_path $argv[1]
        set -l target_host $argv[2]
        set -l remote_target $argv[3]

        # Default SSH target if omitted or passed as a flag
        if test -z "$remote_target"; or string match -q -- "--*" "$remote_target"
            set -l extra_args $argv[3..-1]
            set remote_target "deployer@$target_host"
            set -g _fdeploy_extra $extra_args
        else
            set -g _fdeploy_extra $argv[4..-1]
        end

        set -l attr "$flake_path#nixosConfigurations.\"$target_host\".config.system.build.toplevel"

        rm -rf /tmp/nixos-deploy-result

        echo "Building NixOS closure locally via nix-fast-build..."
        nix_build \
            --flake $attr \
            --out-link /tmp/nixos-deploy-result \
            $_fdeploy_extra
        or return 1

        set -l build_out ""
        if test -e /tmp/nixos-deploy-result-/result
            set build_out (realpath /tmp/nixos-deploy-result-/result)
        else if test -e /tmp/nixos-deploy-result-/toplevel
            set build_out (realpath /tmp/nixos-deploy-result-/toplevel)
        else if test -e /tmp/nixos-deploy-result-
            set build_out (realpath /tmp/nixos-deploy-result-)
        else
            echo "Error: Could not locate built closure in /tmp/nixos-deploy-result-"
            return 1
        end

        echo "Pushing store closure to target ($remote_target)..."
        command nix copy --to "ssh://$remote_target" $build_out
        or return 1

        set -l switch_bin "$build_out/bin/switch-to-configuration"
        if not test -x "$switch_bin"
            set switch_bin "$build_out/bin/switch"
        end

        echo "Activating new generation as 'deployer'..."
        command ssh -t $remote_target \
            "sudo nix-env --profile /nix/var/nix/profiles/system --set $build_out && sudo $switch_bin switch"
    end
    function nixos_deploy_nas
        set -l flake_root $HOME/Projects/nasty-config
        nixos_fdeploy $flake_root nasty homenas-deployer \
            --option extra-substituters "https://nasty.cachix.org" \
            --option extra-trusted-public-keys "nasty.cachix.org-1:s+X88yw6+asphCNphTId/RQZHfmDF4fQ0uyzEz5SxLc=" \
            $argv
    end
end

function nix_collect_garbage
    if contains -- --sudo $argv
        # strip '--sudo' from argv
        set args (string match -v '--sudo' $argv)
        command sudo -i nix-collect-garbage $argv
        command sudo -i nix store optimise
    else
        command nix-collect-garbage $argv
        command nix store optimise
    end
end

function nixenv_ls
    if test "$argv[1]" = -r -o "$argv[1]" = --sudo
        sudoe nix-env --list-generations
    else
        nix-env --list-generations
    end
end

function nixenv_rm
    if test "$argv[1]" = -r -o "$argv[1]" = --sudo
        sudoe nix-env --delete-generations
    else
        nix-env --delete-generations
    end
end

function nix_hm_init
    if ! command -q home-manager
        rm -rf "$HOME/.config/home-manager/"
        nix run github:nix-community/home-manager -- init
        nix run github:nix-community/home-manager -- switch
    end
    if command -q home-manager
        set NIX_SESSION_VARS $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
        if test -r "$NIX_SESSION_VARS"
            fenv source "$NIX_SESSION_VARS"
        end
    end
end

if command -q nh
    function nh_clean
        set cmd "nh clean all --ask"
        set args_provided 0

        # Iterate over all arguments to check for relevant flags
        for arg in $argv
            if contains -- -k --keep -K --keep-since $arg
                set args_provided 1
                break
            end
        end

        # Provide a default if no relevant args were provided
        if test $args_provided -eq 0
            set cmd "$cmd -k 3 -K 24h"
        end

        set cmd $cmd $argv
        eval $cmd
    end
end

if command -q xilo
    function xilo-push --description "Build and push a closure to xilo"
        set -l flake_path $argv[1]
        set -l target (test -n "$argv[2]"; and echo $argv[2]; or hostname)

        if string match -q '*@*' -- "$target"
            set target "homeConfigurations.\"$target\".activationPackage"
        else
            set target "nixosConfigurations.$target.config.system.build.toplevel"
        end

        set -l xilo_bin (command -v xilo)
        if test -z "$xilo_bin"
            echo "Error: 'xilo' not found or not installed!" >&2
            return 1
        end

        set -l xilo_secrets /run/agenix/xilo
        set -l push_creds_mode ""

        if test -f "$xilo_secrets"
            set push_creds_mode agenix
        else if ls_creds | string match -q '*XILO_URL*'; and ls_creds | string match -q '*XILO_TOKEN*'; and ls_creds | string match -q '*XILO_CACHE*'
            set push_creds_mode creds
        else
            echo "Error: no xilo credentials found (checked $xilo_secrets and ls_creds)" >&2
            return 1
        end

        set -l flake_target "$flake_path#$target"
        set -l out_paths (nix build "$flake_target" -L --print-out-paths --no-link)
        if test $status -ne 0
            echo "Error: nix build failed" >&2
            return 1
        end

        if test "$push_creds_mode" = agenix
            printf '%s\n' $out_paths | sudo env XILO_BIN="$xilo_bin" sh -c '
                    set -a
                    . "'"$xilo_secrets"'"
                    set +a
                    "$XILO_BIN" push default/xilopkgs - --quiet
                '
        else
            unlock_creds XILO_URL XILO_TOKEN XILO_CACHE
            printf '%s\n' $out_paths | $xilo_bin push default/xilopkgs -
        end
    end
end
