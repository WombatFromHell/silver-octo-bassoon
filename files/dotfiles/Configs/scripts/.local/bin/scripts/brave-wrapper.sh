#!/usr/bin/env bash

set -euo pipefail

# chromium-flags.sh is mandatory: the browser is always launched through it.
CHROMIUM_FLAGS_SCRIPT="$HOME/.local/bin/scripts/chromium-flags.sh"
[[ -x "$CHROMIUM_FLAGS_SCRIPT" ]] || CHROMIUM_FLAGS_SCRIPT="$(command -v chromium-flags.sh)"
[[ -x "$CHROMIUM_FLAGS_SCRIPT" ]] || { echo "Error: chromium-flags.sh not found" >&2; exit 1; }
readonly CHROMIUM_FLAGS_SCRIPT

readonly CONTAINER_NAME="bravebox"
readonly NOTIFY_APP="brave-wrapper"
readonly BROWSER_CANDIDATES=(brave brave-browser-beta brave-browser)
readonly FLATPAK_ID="com.brave.Browser"
# ponytail: fixed grace period, not PID/readiness polling — dnf's own
# resolve+download time dwarfs browser startup, so a flat sleep is enough.
# If browser startup ever regularly exceeds this, poll `kill -0 $browser_pid`.
readonly UPDATE_DEFER_SECONDS="${UPDATE_DEFER_SECONDS:-10}"
# Overridable for tests; only CONTAINER_ENV_FILE is (the others are root paths
# a test can't create). Keep minimal: no DI scaffolding beyond what tests use.
readonly CONTAINER_ENV_FILE="${CONTAINER_ENV_FILE:-/run/.containerenv}"
readonly DRM_SYS_PATH="${DRM_SYS_PATH:-/sys/class/drm}"

is_in_container() {
  [[ -n "${CONTAINER_ID:-}" ]] ||
    [[ -f "$CONTAINER_ENV_FILE" ]] ||
    [[ -f /.dockerenv ]] ||
    grep -q container /proc/1/cgroup 2>/dev/null
}

is_flatpak_installed() {
  command -v flatpak &>/dev/null &&
    (flatpak info "${FLATPAK_ID}" &>/dev/null || flatpak list --app 2>/dev/null | grep -q "${FLATPAK_ID}")
}

find_browser() {
  if is_flatpak_installed; then
    echo "flatpak"; return 0
  fi
  for b in "${BROWSER_CANDIDATES[@]}"; do
    command -v "$b" &>/dev/null && { echo "$b"; return 0; }
  done
  if command -v distrobox-enter &>/dev/null &&
    distrobox-enter -n "$CONTAINER_NAME" -- bash -c 'command -v brave-browser' &>/dev/null; then
    echo "brave-browser"; return 0
  fi
  return 1
}

# BRAVE_GPU=igpu|dgpu selects the GPU via --render-node-override: the only
# lever that moves Chromium's Wayland GL renderer (env vars / --gpu-* are
# ignored by the Wayland GL path). Match the render node by PCI id, then
# verify the resolved /dev node still exists and is bound to that GPU.
apply_gpu_selection() {
  local target=0x164e  # igpu: Raphael APU
  [[ "${BRAVE_GPU:-igpu}" == "dgpu" ]] && target=0x7550  # dgpu: RX 9070 XT
  GPU_FLAGS=()
  local rn v d dev
  for rn in /sys/class/drm/renderD[0-9]*; do
    [[ -r "$rn/device/vendor" && -r "$rn/device/device" ]] || continue
    v=$(cat "$rn/device/vendor"); d=$(cat "$rn/device/device")
    [[ "$v" == "0x1002" && "$d" == "$target" ]] || continue
    dev="/dev/dri/${rn##*/}"
    [[ -e "$dev" ]] || continue
    v=$(cat "/sys/class/drm/${rn##*/}/device/vendor" 2>/dev/null)
    d=$(cat "/sys/class/drm/${rn##*/}/device/device" 2>/dev/null)
    [[ "$v" == "0x1002" && "$d" == "$target" ]] || continue
    GPU_FLAGS=(--render-node-override="$dev")
    break
  done
}

# Hybrid graphics is "in use" (not merely enabled) only when ≥2 distinct GPU
# devices each drive a connected output — i.e. the desktop actually spans GPUs.
# ponytail: counts distinct PCI devices with a connected connector via sysfs;
# no drm library needed. Prints the active-GPU count, returns 0 if hybrid.
detect_hybrid_graphics() {
  local card gpu count=0
  local -A seen
  for card in "$DRM_SYS_PATH"/card[0-9]*; do
    [[ -d "$card/device" ]] || continue
    gpu=$(readlink -f "$card/device"); gpu=${gpu##*/}
    [[ -n "${seen[$gpu]:-}" ]] && continue
    for status in "$card"/*/status; do
      [[ -f "$status" ]] && grep -q '^connected$' "$status" || continue
      seen[$gpu]=1
      count=$((count + 1))
      break
    done
  done
  echo "$count"
  (( count >= 2 ))
}

# Hybrid graphics: when ≥2 GPUs each drive an output, pick one explicitly.
# Default to the iGPU; only BRAVE_GPU=dgpu overrides that. Single-GPU systems
# leave BRAVE_GPU unset and let apply_gpu_selection's own default handle it.
resolve_gpu_flags() {
  if [[ -z "${BRAVE_GPU:-}" ]] && detect_hybrid_graphics &>/dev/null; then
    BRAVE_GPU=igpu
  fi
  apply_gpu_selection
}

notify() {
  local title="$1" body="$2" urgency="${3:-normal}" timeout="${4:-3000}"
  [[ -z "$title" || -z "$body" ]] && return 0
  command -v notify-send &>/dev/null &&
    notify-send -a "$NOTIFY_APP" -u "$urgency" -t "$timeout" "$title" "$body" 2>/dev/null || true
}

run_command_or_fail() {
  local cmd="$1"; shift
  command -v "$cmd" &>/dev/null || { echo "Error: $cmd command not found" >&2; return 1; }
  "$@"
}

# Flatpak updates via flatpak; everything else (dnf / distrobox) via dnf. For
# distrobox, prefix the dnf/sudo calls with a distrobox-enter wrapper.
# ponytail: applying can still race a browser launched from the same container;
# safe only because dnf/rpm renames into place and a running inode stays valid.
_check_update() {
  if [[ "$1" == "flatpak" ]]; then
    local probe; probe=$(flatpak update --no-deploy -y "$2" 2>&1) || true
    [[ "$probe" != *"Nothing to do"* ]]
    return
  fi
  local prefix=()
  [[ "$1" == "distrobox" ]] && prefix=(distrobox-enter -n "$CONTAINER_NAME" --)
  "${prefix[@]}" dnf check-update "$2" &>/dev/null
  [[ $? -eq 100 ]]   # 100 = updates available; 0 = none; anything else = error
}

_apply_update() {
  local strategy="$1" target="$2" out rc=0 prefix=()
  if [[ "$strategy" == "flatpak" ]]; then
    out=$(flatpak update -y "$target" 2>&1) || rc=$?
    if [[ $rc -eq 0 ]] && [[ "$out" == *"Updates complete"* ]]; then
      echo "$out"; notify "Brave Updated" "Restart the browser to finish updating."
      return 0
    fi
    echo "Flatpak update failed." >&2
    notify "Update Failed" "Failed to update Brave." critical
    return "$rc"
  fi
  [[ "$strategy" == "distrobox" ]] && prefix=(distrobox-enter -n "$CONTAINER_NAME" --)
  if ! "${prefix[@]}" sudo -n true &>/dev/null; then
    echo "Skipping update: passwordless sudo not configured${prefix[*]:+ in ${CONTAINER_NAME}}." >&2
    return 0
  fi
  out=$("${prefix[@]}" sudo dnf upgrade -y "$target" </dev/null 2>&1) || rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "$out"; notify "Update Available" "${target} was upgraded. Restart the browser to apply updates."
    return 0
  fi
  echo "$out" >&2
  notify "Upgrade Failed" "Failed to upgrade ${target}." critical
  return "$rc"
}

perform_browser_update() {
  local strategy="$1" target="$2"
  echo "Checking for ${target} updates (${strategy})..."
  if ! _check_update "$strategy" "$target"; then
    echo "No updates found."
    return 0
  fi
  echo "Update available — deferring install until the browser is up."
  sleep "$UPDATE_DEFER_SECONDS"
  _apply_update "$strategy" "$target"
}

execute_launch() {
  local method="$1" browser="$2"; shift 2
  case "$method" in
  flatpak)
    run_command_or_fail flatpak "$CHROMIUM_FLAGS_SCRIPT" flatpak run "${FLATPAK_ID}" "$@"
    ;;
  distrobox)
    run_command_or_fail distrobox-enter "$CHROMIUM_FLAGS_SCRIPT" \
      distrobox-enter -n "$CONTAINER_NAME" -- "$browser" "$@"
    ;;
  direct)
    exec "$CHROMIUM_FLAGS_SCRIPT" "$browser" "$@"
    ;;
  esac
}

_dispatch() {
  local cmd="$1"; shift
  case "$cmd" in
  in-container) is_in_container ;;
  find-browser) find_browser ;;
  flatpak-installed) is_flatpak_installed ;;
  detect-hybrid) detect_hybrid_graphics ;;
  notify) notify "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
  launch-flatpak) execute_launch flatpak brave "$@" ;;
  launch-distrobox) execute_launch distrobox "${1:-brave}" "${@:2}" ;;
  launch-direct) execute_launch direct "${1:-brave}" "${@:2}" ;;
  bg-update) perform_browser_update "${1:-direct}" "${2:-brave}" ;;
  flatpak-update-check) perform_browser_update flatpak "$FLATPAK_ID" ;;
  *)
    echo "Unknown helper: $cmd" >&2
    exit 1
    ;;
  esac
}

main() {
  local flatpak_installed=false container=false
  is_flatpak_installed && flatpak_installed=true
  is_in_container && container=true

  local browser
  browser=$(find_browser) || { echo "Error: no brave found." >&2; exit 1; }

  local launch_method update_target pkg_method
  if [[ "$flatpak_installed" == true ]]; then
    launch_method=flatpak; update_target="$FLATPAK_ID"; pkg_method=flatpak
  elif [[ "$container" == false ]]; then
    launch_method=distrobox; update_target="$browser"; pkg_method=distrobox
  else
    launch_method=direct; update_target="$browser"; pkg_method=dnf
  fi

  if [[ "$launch_method" != "direct" ]]; then
    perform_browser_update "$pkg_method" "$update_target" </dev/null &
    disown || true
  fi

  resolve_gpu_flags
  execute_launch "$launch_method" "$browser" "${GPU_FLAGS[@]}" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  if [[ "${1:-}" == --helper-* ]]; then
    _dispatch "${1#--helper-}" "${@:2}"
  else
    main "$@"
  fi
fi
