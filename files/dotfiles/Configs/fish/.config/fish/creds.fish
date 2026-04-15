# ── Encrypt a KEY=VALUE pair via TPM2 ─────────────────────────────
#   > cred_encrypt SOME_API_KEY
#   Value (hidden): ··············
#
# Fish has no built-in `read -s`, so we temporarily disable tty
# echo via stty, then re-enable it on every exit path.
function encrypt_cred -d "Encrypt a secret to systemd-creds storage"
    set -l key $argv[1]
    if test -z "$key"
        echo "Usage: cred_encrypt KEY" >&2
        return 1
    end

    # ── disable echo on the tty ────────────────────────────────────
    set -l tty /dev/tty
    if not test -c $tty
        echo "✘  no tty available for secure input" >&2
        return 1
    end
    set -l saved_stty (stty -g < $tty 2>/dev/null)
    stty -echo <$tty

    # ── prompt + read ──────────────────────────────────────────────
    printf 'Value (hidden): ' >$tty
    set -l value
    read value <$tty

    # ── restore echo immediately ───────────────────────────────────
    if test -n "$saved_stty"
        stty "$saved_stty" <$tty 2>/dev/null
    else
        stty echo <$tty 2>/dev/null
    end
    echo # newline after the hidden input

    # ── validate ───────────────────────────────────────────────────
    if test -z "$value"
        echo "✘  empty value — aborted" >&2
        return 1
    end
    if ! test -d "$CREDENTIALS_DIRECTORY/"
        mkdir -p "$CREDENTIALS_DIRECTORY"
    end

    # ── encrypt ────────────────────────────────────────────────────
    set -l out "$CREDENTIALS_DIRECTORY/$key.cred"
    printf '%s' "$value" \
        | systemd-creds encrypt --user --uid=$(id -u) --name="$key" - "$out" 2>&1 &&
        chmod 0600 "$out"

    if test $status -eq 0
        echo "✔  $key  →  $out"
    else
        echo "✘  encryption failed (TPM2?)" >&2
        return 1
    end
end

# ── Helper: resolve a single cred spec into key_name / env_var_name ──
#   Accepts "KEY"          → key_name=KEY  env_var_name=KEY
#           "KEY=ENV_VAR"  → key_name=KEY  env_var_name=ENV_VAR
function _cred_parse_spec -d "Parse a cred spec (KEY or KEY=ENV_VAR) into key and env var names"
    set -l spec $argv[1]
    if string match -q '*=*' $spec
        set -l parts (string split '=' --max=1 $spec)
        echo $parts[1]
        echo $parts[2]
    else
        echo $spec
        echo $spec
    end
end

function run_with_cred -d "Run a command with one or more decrypted credentials as env vars"
    # ── Single-cred backward-compatible mode (no "--" separator) ──
    #   run_with_cred <CRED_NAME> [ENV_VAR_NAME] <COMMAND...>
    #
    # ── Multi-cred mode (use "--" separator) ──────────────────────
    #   run_with_cred <CRED1> [CRED2=ENV2] ... -- <COMMAND...>
    #
    #   Each cred spec before "--" is either:
    #     KEY          – decrypts KEY.cred and exports env var KEY
    #     KEY=ENV_VAR  – decrypts KEY.cred and exports env var ENV_VAR
    #   Everything after "--" is the command and its arguments.

    # ── Check for the "--" separator ───────────────────────────────
    set -l sep_idx -1
    for i in (seq (count $argv))
        if test "$argv[$i]" = --
            set sep_idx $i
            break
        end
    end

    # ── Collect cred specs and command args ────────────────────────
    set -l cred_specs # list of "key_name env_var_name" pairs
    set -l cmd_args # the command to run

    if test $sep_idx -ge 2
        # Multi-cred mode: everything before "--" is cred specs
        set -l specs $argv[1..(math $sep_idx - 1)]
        for spec in $specs
            set -l parsed (_cred_parse_spec $spec)
            set -a cred_specs $parsed
        end
        set cmd_args $argv[(math $sep_idx + 1)..-1]

    else if test $sep_idx -eq 1
        # "--" with no creds before it — nothing to load
        echo "✘  no credential specs provided before --" >&2
        return 1

    else
        # No "--" found — fall back to original single-cred behavior
        set -l key_name $argv[1]
        set -l env_var_name

        if type -q $argv[2]
            set env_var_name $key_name
            set cmd_args $argv[2..-1]
        else
            set env_var_name $argv[2]
            set cmd_args $argv[3..-1]
        end

        set cred_specs $key_name $env_var_name
    end

    # ── Validate we have creds and a command ───────────────────────
    if test (count $cred_specs) -eq 0
        echo "✘  no credential specified" >&2
        return 1
    end
    if test (count $cmd_args) -eq 0
        echo "✘  no command provided" >&2
        return 1
    end

    # ── Resolve cred files and build systemd properties ────────────
    set -l load_creds_prop # "key:path key2:path2 ..."
    set -l export_stmts # "export VAR1=...; export VAR2=...;"

    set -l i 1
    while test $i -le (count $cred_specs)
        set -l key_name $cred_specs[$i]
        set -l env_var_name $cred_specs[(math $i + 1)]

        # Resolve the physical path to handle /var/home symlinks
        set -l cred_file (readlink -f "$CREDENTIALS_DIRECTORY/$key_name.cred")

        if not test -f "$cred_file"
            echo "✘ Credential not found: $key_name ($cred_file)" >&2
            return 1
        end

        # Accumulate LoadCredentialEncrypted entries (space-separated)
        if test -z "$load_creds_prop"
            set load_creds_prop "$key_name:$cred_file"
        else
            set load_creds_prop "$load_creds_prop $key_name:$cred_file"
        end

        # Accumulate export statements for the shell one-liner
        set export_stmts "$export_stmts export $env_var_name=\$(cat \"\$CREDENTIALS_DIRECTORY/$key_name\");"

        set i (math $i + 2)
    end

    # ── Run the transient service ──────────────────────────────────
    systemd-run --user --pipe --wait --quiet --same-dir --collect \
        -p LoadCredentialEncrypted="$load_creds_prop" \
        -p Environment="$(env | grep -E '^(WAYLAND_DISPLAY|NIRI_SOCKET|DISPLAY|PATH)=' | xargs)" \
        sh -c "$export_stmts exec $cmd_args"
end
