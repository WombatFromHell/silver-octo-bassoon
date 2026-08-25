#!/usr/bin/env bash
set -euo pipefail

prog="${0##*/}"

dms_list_profiles() {
  dms ipc outputs listProfiles
}

profile_exists() {
  grep -q "^${1}[[:space:]]" <<<"$2"
}

profile_is_active() {
  grep -q "^${1}[[:space:]].*\[active\]" <<<"$2"
}

active_profile() {
  local p
  p="$(awk '/\[active\]/ { print $1; exit }' <<<"$1")"
  [[ -n $p ]] || return 1
  echo "$p"
}

set_profile() {
  dms ipc outputs setProfile "$1"
}

switch_and_run() {
  local target="$1"
  restore_profile="$2"
  shift 2
  [[ $# -gt 0 ]] || {
    echo "no command to run" >&2
    exit 1
  }
  # ponytail: EXIT+INT/TERM trap, double-restore on signals is harmless
  trap 'set_profile "$restore_profile"' EXIT INT TERM
  set_profile "$target"
  sleep 2
  "$@"
}

run_self_test() {
  local mock profiles calls rc
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  calls="$tmp/calls"
  mock="$tmp/dms"
  cat >"$mock" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == "ipc outputs listProfiles" ]]; then
  printf 'desktop [matched] -> ["a"]\nmain [active] -> ["a"]\n'
else
  echo "\$*" >>"$calls"
fi
EOF
  chmod +x "$mock"
  export PATH="$tmp:$PATH"

  profiles="$(dms_list_profiles)"
  profile_exists main "$profiles"
  profile_exists nope "$profiles" && exit 1
  profile_is_active main "$profiles"
  profile_is_active desktop "$profiles" && exit 1
  [[ "$(active_profile "$profiles")" == "main" ]]
  active_profile "desktop [matched] -> [a]" && exit 1
  set_profile desktop

  set +e
  (main desktop main -- /bin/false) 2>/dev/null
  rc=$?
  (main desktop -- /bin/false) 2>/dev/null
  [[ $? -eq 1 ]]
  set -e
  [[ $rc -eq 1 ]]
  grep -q '^ipc outputs setProfile desktop$' "$calls"
  grep -q '^ipc outputs setProfile main$' "$calls"
  echo "self-test ok"
}

main() {
  case "${1:-}" in
  --self-test) run_self_test ;;
  --help)
    cat <<EOF
usage: $prog [--list | <profile>]
       $prog <profile> <restore-profile> -- <command>...
       $prog <profile> -- <command>...

  --list                          show saved output profiles (default)
  <profile>                       switch to a saved output profile
  <profile> <restore> -- <cmd>..  switch to <profile>, run <cmd>, restore
                                  <restore-profile> however <cmd> exits
  <profile> -- <cmd>..            as above, restoring the profile that was
                                  active (errors if none is active)
EOF
    ;;
  --list | "") dms_list_profiles ;;
  *)
    if [[ ${2:-} == "--" ]]; then
      local profiles target="$1" restore
      profiles="$(dms_list_profiles)"
      profile_exists "$target" "$profiles" || {
        echo "unknown profile: $target" >&2
        exit 1
      }
      restore="$(active_profile "$profiles")" || {
        echo "no active profile to restore to; pass an explicit restore profile" >&2
        exit 1
      }
      shift 2
      switch_and_run "$target" "$restore" "$@"
    elif [[ ${3:-} == "--" ]]; then
      local profiles target="$1" restore="$2"
      profiles="$(dms_list_profiles)"
      profile_exists "$target" "$profiles" || {
        echo "unknown profile: $target" >&2
        exit 1
      }
      profile_exists "$restore" "$profiles" || {
        echo "unknown profile: $restore" >&2
        exit 1
      }
      shift 3
      switch_and_run "$target" "$restore" "$@"
    else
      local profiles
      profiles="$(dms_list_profiles)"
      profile_exists "$1" "$profiles" || {
        echo "unknown profile: $1" >&2
        exit 1
      }
      profile_is_active "$1" "$profiles" || set_profile "$1"
    fi
    ;;
  esac
}

main "$@"
