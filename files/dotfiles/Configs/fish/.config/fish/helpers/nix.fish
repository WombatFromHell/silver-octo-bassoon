if command -q nix
    set -x FLAKE_ROOT "$HOME/.config/flakeroot"
    if command -q nh
        set -x NH_FLAKE "$FLAKE_ROOT"
    end

    set -l NIX_DAEMON_FISH_SRC /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.fish
    if test -r "$NIX_DAEMON_FISH_SRC"
        source "$NIX_DAEMON_FISH_SRC"
    end
    function _nix_load_session_vars
        set -l vars $HOME/.nix-profile/etc/profile.d/hm-session-vars.sh
        if test -r "$vars"
            fenv source "$vars"
        end
    end
    _nix_load_session_vars

    if command -q nix-fast-build
        set -g NIX_MAX_JOBS (nproc | awk '{ j = int($1 * 0.75); print (j > 1 ? j : 1) }')

        set -g NFB_COMMON_OPTS \
            --max-jobs $NIX_MAX_JOBS \
            --option show-trace true \
            --option connect-timeout 5 \
            --option extra-deprecated-features or-as-identifier \
            --option extra-experimental-features "nix-command flakes eval-cache"

        function _nfb
            # Run a nix-fast-build program with common opts, honoring --sudo
            set -l prog $argv[1]
            set -l args $argv[2..-1]
            if contains -- --sudo $args
                set args (string match -v -- --sudo $args)
                command sudo -i $prog $NFB_COMMON_OPTS $args
            else
                command $prog $NFB_COMMON_OPTS $args
            end
        end
        function _nix_dry_run
            # If --dry-run is in the extra args, evaluate via nix-eval-jobs and stop.
            # Returns 1 when a dry-run was performed (or failed), 0 to continue.
            # Usage: _nix_dry_run <attr> <name> [extra args...]
            set -l args $argv[3..-1]
            if not contains -- --dry-run $args
                return 0
            end
            echo "Evaluating $argv[2] via nix-eval-jobs..."
            nix_eval --flake $argv[1] (string match -v -- '--dry-run' $args)
            or return 1
            return 1
        end
        function nix_build
            _nfb nix-fast-build $argv
        end
        function _nix_find_closure
            # Resolve a --out-link result to its real store path.
            # Usage: _nix_find_closure <out-link>  (e.g. /tmp/nixos-result)
            set -l out_link $argv[1]
            if test -e "$out_link-"/result
                realpath "$out_link-"/result
            else if test -e "$out_link-"/toplevel
                realpath "$out_link-"/toplevel
            else if test -e "$out_link-"
                realpath "$out_link-"
            else
                echo "Error: Could not locate built closure at $out_link-" >&2
                return 1
            end
        end
        function nix_eval
            set -lx GC_INITIAL_HEAP_SIZE 2G
            _nfb nix-eval-jobs $argv
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

            # Target attribute for HM closure
            set -l attr "$flake_path#homeConfigurations.\"$target\".activationPackage"

            if _nix_dry_run $attr $target $extra_args
                return 0
            end

            # Expand relative paths or environment variables safely
            nix_build \
                --flake $attr \
                --out-link /tmp/hm-result $extra_args
            and /tmp/hm-result-/activate
        end
        function _nix_switch_bin
            # Resolve a closure's switch binary (switch-to-configuration, fallback switch).
            set -l bin "$argv[1]/bin/switch-to-configuration"
            if not test -x "$bin"
                set bin "$argv[1]/bin/switch"
            end
            echo $bin
        end
        function _nix_remote_deploy
            # Push a closure to a remote host and activate it.
            # Usage: _nix_remote_deploy <closure> <user@host> <action>
            set -l closure $argv[1]
            set -l target $argv[2]
            set -l action $argv[3]

            set -l switch_bin (_nix_switch_bin $closure)

            echo "Deploying to $target (action: $action)..."
            command nix copy --to "ssh://$target" $closure
            or return 1
            command ssh -t $target \
                "sudo nix-env --profile /nix/var/nix/profiles/system --set $closure && sudo $switch_bin $action"
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

            set -l attr "$flake_path#nixosConfigurations.\"$target_host\".config.system.build.toplevel"

            if _nix_dry_run $attr $target_host $remaining
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

            # Parse --remote <user@host>
            set -l remote_target ""
            if contains -- --remote $remaining
                set -l remote_idx (contains -i -- --remote $remaining)
                set -l val_idx (math $remote_idx + 1)
                set remote_target $remaining[$val_idx]
                set remaining (string match -v -- "--remote" $remaining | string match -v -- "$remote_target")
            end

            echo "Building NixOS configuration for '$target_host'..."
            nix_build \
                --flake $attr \
                --out-link /tmp/nixos-result \
                $remaining
            or return 1

            set -l build_out (_nix_find_closure /tmp/nixos-result)
            or return 1

            if not $do_switch
                echo "Build successful! System closure available at: $build_out"
                return 0
            end

            if test -n "$remote_target"
                _nix_remote_deploy $build_out $remote_target switch
            else
                echo "Switching local NixOS configuration..."
                set -l switch_bin (_nix_switch_bin $build_out)
                command sudo nix-env --profile /nix/var/nix/profiles/system --set $build_out
                and command sudo $switch_bin switch
            end
        end
        function nixos_fdeploy
            if test (count $argv) -lt 2
                echo "Usage: nixos_fdeploy <flake-path> <host> [user@remote-ip] [--switch] [extra nix args...]"
                return 1
            end

            set -l action (if contains -- --switch $argv; echo switch; else; echo boot; end)
            set argv (string match -v -- --switch $argv)

            set -l flake_path $argv[1]
            set -l target_host $argv[2]
            set -l remote_target $argv[3]

            # Default SSH target if omitted or a flag was passed in its place
            set -l _fdeploy_extra
            if test -z "$remote_target"; or string match -q -- "--*" "$remote_target"
                set remote_target "deployer@$target_host"
                set _fdeploy_extra $argv[3..-1]
            else
                set _fdeploy_extra $argv[4..-1]
            end

            set -l attr "$flake_path#nixosConfigurations.\"$target_host\".config.system.build.toplevel"

            if _nix_dry_run $attr $target_host $_fdeploy_extra
                return 0
            end

            rm -rf /tmp/nixos-deploy-result

            echo "Building NixOS closure locally via nix-fast-build..."
            nix_build \
                --flake $attr \
                --out-link /tmp/nixos-deploy-result \
                $_fdeploy_extra
            or return 1

            set -l build_out (_nix_find_closure /tmp/nixos-deploy-result)
            or return 1

            echo "Pushing store closure to target ($remote_target)..."
            _nix_remote_deploy $build_out $remote_target $action
            and echo "System closure available at: $build_out"
            and echo "  Manual switch on target: ssh $remote_target sudo $build_out/bin/switch-to-configuration switch"
        end
        function nixos_deploy_nas
            set -l args $argv
            set args (string match -v -- --with-nasty $args)
            set args $args \
                --option extra-substituters "https://nasty.cachix.org" \
                --option extra-trusted-public-keys "nasty.cachix.org-1:s+X88yw6+asphCNphTId/RQZHfmDF4fQ0uyzEz5SxLc="

            nixos_fdeploy $HOME/Projects/nasty-config nasty homenas-deployer $args
        end
    end

    function nix_collect_garbage
        if contains -- --sudo $argv
            # strip '--sudo' from argv
            set -l args (string match -v -- --sudo $argv)
            command sudo -i nix-collect-garbage $args
            command sudo -i nix store optimise
        else
            command nix-collect-garbage $argv
            command nix store optimise
        end
    end

    function nixenv
        # Usage: nixenv <list-generations|delete-generations> [--sudo] [args...]
        set -l subcmd $argv[1]
        set -l rest $argv[2..-1]
        if contains -- --sudo $rest
            sudoe nix-env $subcmd (string match -v -- --sudo $rest)
        else
            nix-env $subcmd $rest
        end
    end

    function nix_hm_init
        if ! command -q home-manager
            rm -rf "$HOME/.config/home-manager/"
            nix run github:nix-community/home-manager -- init
            nix run github:nix-community/home-manager -- switch
        end
        _nix_load_session_vars
    end

    if command -q nh
        function nh_clean
            if test (count $argv) -lt 1
                echo "Usage: nh_clean <user|all> [--sudo] [nh clean options...]" >&2
                return 1
            end

            set -l scope $argv[1]
            set -l args $argv[2..-1]

            set -l use_sudo false
            if contains -- --sudo $args
                set use_sudo true
                set args (string match -v -- --sudo $args)
            end

            set -l cmd nh clean $scope --ask

            set -l keep_given false
            for arg in $args
                if contains -- $arg -k --keep -K --keep-since
                    set keep_given true
                    break
                end
            end
            if not $keep_given
                set -a cmd -k 3 -K 6h
            end

            set -a cmd $args

            if $use_sudo
                if functions -q sudoe
                    sudoe $cmd
                else
                    command sudo -E $cmd
                end
            else
                command $cmd
            end
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
            set -l xilo_secrets /run/agenix/xilo
            set -l push_creds_mode ""

            if test -f "$xilo_secrets"
                set push_creds_mode agenix
            else
                set -l creds (ls_creds)
                if test -n $creds \
                        and string match -q '*XILO_URL*' $creds \
                        and string match -q '*XILO_TOKEN*' $creds \
                        and string match -q '*XILO_CACHE*' $creds
                    set push_creds_mode creds
                else
                    echo "Error: no xilo credentials found (checked $xilo_secrets and ls_creds)" >&2
                    return 1
                end
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
        function xilo-push-hm
            # Pushes the last hm_fswitch build (out-link: /tmp/hm-result)
            if test -r /tmp/hm-result-
                unlock_creds XILO_TOKEN XILO_CACHE XILO_URL
                xilo push /tmp/hm-result-
            end
        end
    end

    # ALIASES
    alias nixconf='cd $FLAKE_ROOT && $EDITOR $FLAKE_ROOT'
    #
    alias nhmb='nh home switch -n $FLAKE_ROOT'
    alias nhms='nh home switch $FLAKE_ROOT'
    alias nhmu='nh home switch -u $FLAKE_ROOT'
    #
    alias nhccu='nh_clean user'
    alias nhcu='nh_clean user --no-gcroots --no-direnv --no-gc'
    alias nhcuo='nh_clean user --optimise'
    #
    alias nhcca='nh_clean all'
    alias nhca='nh_clean all --no-gcroots --no-direnv --no-gc'
    alias nhcao='nh_clean all --optimise'
    #
    alias hmb='home-manager build --flake $FLAKE_ROOT --dry-run'
    alias hms='home-manager switch --flake $FLAKE_ROOT'
    alias hmls='home-manager generations'
    alias hmrm='home-manager remove-generations'
    alias hmrb='home-manager switch --rollback'
    #
    alias hmfs="hm_fswitch $FLAKE_ROOT $(whoami)@$(hostname)"
    alias hmfsb="hm_fswitch $FLAKE_ROOT $(whoami)@$(hostname) --dry-run"
    #
    alias nhb='nh os switch -n $FLAKE_ROOT'
    alias nhs='nh os switch $FLAKE_ROOT'
    alias nls='nh os info'
    alias nrb='nh os rollback'
    #
    alias drb='sudo darwin-rebuild build --flake $FLAKE_ROOT'
    alias drs='sudo darwin-rebuild switch --flake $FLAKE_ROOT'
    #
    alias nhdb='nh darwin switch -n $FLAKE_ROOT'
    alias nhds='nh darwin switch $FLAKE_ROOT'
    alias nhdls='sudo darwin-rebuild --list-generations'
    alias nhdrm='sudo nix-env -p /nix/var/nix/profiles/system --delete-generations'
    #
    alias nix_hist='sudo -i nix profile history --profile /nix/var/nix/profiles/system'
    alias nix_rb='sudo -i nix profile rollback --profile /nix/var/nix/profile/system'
    alias nix_act='sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch'
    alias nix_roots='nix-store --gc --print-roots'
    alias nix_flake_paths='nix path-info --derivation --recursive'
    #
    alias nixopt='nix_collect_garbage'
    alias nixopts='nix_collect_garbage --sudo'
end
