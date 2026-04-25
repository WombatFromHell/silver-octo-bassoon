# ── TPM2-encrypted credential store (unlock/lock) ────────────────
#   Stored as systemd-creds encrypted .cred files in $CREDENTIALS_DIRECTORY
#
#   store_cred (alias) / encrypt_cred KEY     – encrypt & store a new credential
#   unlock_creds KEY1 [KEY2=ENV2] ...         – decrypt all → export as env vars
#   lock_creds                                – unset the exported env vars
#
#   Unlocked credentials are tracked in a marker file at:
#     $XDG_RUNTIME_DIR/credentials/creds.lock
#   (one env var name per line) so lock_creds works across shell sessions.

# ══════════════════════════════════════════════════════════════════
# encrypt_cred  – store a new encrypted credential
# ══════════════════════════════════════════════════════════════════
function encrypt_cred -d "Encrypt a secret to systemd-creds storage"
    set -l key $argv[1]
    if test -z "$key"
        echo "Usage: cred_encrypt KEY" >&2
        return 1
    end

    # ── hidden input via stty ────────────────────────────────────
    set -l tty /dev/tty
    if not test -c $tty
        echo "✘  no tty available for secure input" >&2
        return 1
    end
    set -l saved_stty (stty -g < $tty 2>/dev/null)
    stty -echo <$tty

    printf 'Value (hidden): ' >$tty
    set -l value
    read value <$tty

    if test -n "$saved_stty"
        stty "$saved_stty" <$tty 2>/dev/null
    else
        stty echo <$tty 2>/dev/null
    end
    echo

    if test -z "$value"
        echo "✘  empty value — aborted" >&2
        return 1
    end

    if ! test -d "$CREDENTIALS_DIRECTORY/"
        mkdir -p "$CREDENTIALS_DIRECTORY"
    end

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

# ══════════════════════════════════════════════════════════════════
# _cred_marker_path – path to the tracking marker file
# ══════════════════════════════════════════════════════════════════
function _cred_marker_path -d "Return the marker file path"
    echo "$XDG_RUNTIME_DIR/credentials/creds.lock"
end

# ══════════════════════════════════════════════════════════════════
# unlock_creds  – decrypt all specified credentials, export as env vars
#   unlock_creds KEY1 [KEY2=ENV2] ...
#     KEY           → exports env var KEY (value from KEY.cred)
#     KEY=ENV_VAR   → exports env var ENV_VAR (value from KEY.cred)
#   Writes each env var name to the marker file for lock_creds.
# ══════════════════════════════════════════════════════════════════
function unlock_creds -d "Decrypt and export credentials as environment variables"
    set -l specs $argv

    if test (count $specs) -eq 0
        echo "Usage: unlock_creds KEY1 [KEY2=ENV2] ..." >&2
        return 1
    end

    # Ensure marker directory exists
    mkdir -p "$XDG_RUNTIME_DIR/credentials" 2>/dev/null
    set -l marker (_cred_marker_path)

    for spec in $specs
        # Parse KEY or KEY=ENV_VAR
        set -l key_name env_var_name
        if string match -q '*=*' $spec
            set -l parts (string split '=' --max=1 $spec)
            set key_name $parts[1]
            set env_var_name $parts[2]
        else
            set key_name $spec
            set env_var_name $spec
        end

        # Resolve path
        set -l cred_file (readlink -f "$CREDENTIALS_DIRECTORY/$key_name.cred")
        if not test -f "$cred_file"
            echo "✘ Credential not found: $key_name ($cred_file)" >&2
            return 1
        end

        # Decrypt (one TPM2 roundtrip per credential, batched in one shell session)
        set -l decrypted
        set decrypted (systemd-creds decrypt --user --name "$key_name" "$cred_file" 2>/dev/null)
        if test $status -ne 0
            echo "✘ Failed to decrypt: $key_name" >&2
            return 1
        end

        # Export as global env var (survives exec of child commands)
        set -gx $env_var_name $decrypted

        # Track in marker file (append, dedup)
        if not grep -qxF "$env_var_name" "$marker" 2>/dev/null
            echo "$env_var_name" >>"$marker"
        end

        echo "✔  $key_name → $env_var_name"
    end
end

# ══════════════════════════════════════════════════════════════════
# rm_cred  – remove a stored credential from disk
#   rm_cred KEY                             – delete KEY.cred
# ══════════════════════════════════════════════════════════════════
function rm_cred -d "Remove an encrypted credential file"
    set -l key $argv[1]
    if test -z "$key"
        echo "Usage: rm_cred KEY" >&2
        return 1
    end

    set -l cred_file "$CREDENTIALS_DIRECTORY/$key.cred"
    if not test -f "$cred_file"
        # Also try resolved path in case of symlinks
        set -l resolved (readlink -f "$cred_file" 2>/dev/null)
        if test -f "$resolved"
            set cred_file "$resolved"
        else
            echo "✘ Credential not found: $key" >&2
            return 1
        end
    end

    rm -f "$cred_file"
    echo "✔  removed  $key.cred"
end

# ══════════════════════════════════════════════════════════════════
# unlock_all_creds  – unlock every credential listed by ls_creds
#   Parses the NAME column from systemd-creds --user list output
#   and unlocks all of them in a single session.
# ══════════════════════════════════════════════════════════════════
function unlock_all_creds -d "Unlock all credentials found on disk"
    set -l names
    # Parse first column from systemd-creds --user list, skip header.
    # Output includes .cred extension — strip it so unlock_creds can append it.
    for line in (string split '\n' (systemd-creds --user list 2>/dev/null))
        if string match -q 'NAME*' $line
            continue
        end
        set -l name (string replace -r '\s+' ' ' $line | string split ' ')[1]
        # Skip empty lines (e.g. trailing newline in output)
        if test -z "$name"
            continue
        end
        # Strip trailing .cred suffix
        if string match -q '*.cred' $name
            set name (string replace -r '\.cred$' '' $name)
        end
        set -a names $name
    end

    if test (count $names) -eq 0
        echo "ℹ  No credentials found on disk" >&2
        return 0
    end

    # Unlock one at a time so a single failure doesn't abort the rest
    for name in $names
        if not unlock_creds $name
            echo "⚠  Skipping $name (decrypt failed)" >&2
        end
    end
end

# ══════════════════════════════════════════════════════════════════
# lock_creds  – unset all env vars exported by unlock_creds
#   Reads the marker file, unsets each tracked env var, then
#   removes the marker file.
# ══════════════════════════════════════════════════════════════════
function lock_creds -d "Unset all previously unlocked credential env vars"
    set -l marker (_cred_marker_path)
    if not test -f "$marker"
        echo "ℹ  No credentials are currently unlocked" >&2
        return 0
    end

    for var in (cat "$marker")
        if set -q $var
            set -e $var
            echo "✔  unset  $var"
        else
            echo "⚠  already gone  $var"
        end
    end

    rm -f "$marker"
end

alias store_cred=encrypt_cred
alias ls_creds='systemd-creds --user list'
