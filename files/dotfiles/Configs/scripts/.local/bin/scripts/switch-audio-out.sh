#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────
OUTPUT_A_NAME="${OUTPUT_A_NAME:-alsa_output.pci-0000_03_00.1.hdmi-stereo-extra3}"
OUTPUT_B_NAME="${OUTPUT_B_NAME:-alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game}"

# ── Deps ─────────────────────────────────────────────────────────────────────
command -v wpctl &>/dev/null || {
  echo "ERROR: 'wpctl' not found" >&2
  exit 1
}

# ── Core Functions (sourceable) ──────────────────────────────────────────────

# ponytail: wpctl status -n parsing consolidated here; single source of truth
# for ID resolution across all callers. Sed regex matches tree glyphs + optional
# asterisk + ID + name; awk filters by exact name match.
resolve_audio_id() {
  local name="$1"
  wpctl status -n 2>/dev/null |
    sed -nE 's/^[│ ]*\*?[[:space:]]*([0-9]+)\.[[:space:]]+([^[:space:]]+).*/\1 \2/p' |
    awk -v n="$name" '$2 == n {print $1; exit}'
}

current_default_audio_name() {
  wpctl status -n 2>/dev/null |
    sed -nE 's/^[│ ]*\*[[:space:]]*([0-9]+)\.[[:space:]]+([^[:space:]]+).*/\2/p' |
    head -n 1
}

switch_audio_to() {
  local target_name="$1"
  local target_id
  target_id="$(resolve_audio_id "$target_name")"

  if [[ -z $target_id ]]; then
    echo "WARN: audio output '$target_name' not found" >&2
    return 1
  fi

  wpctl set-default "$target_id" 2>/dev/null || {
    echo "WARN: failed to set default to '$target_name'" >&2
    return 1
  }
  echo "Switched to $target_name (ID: $target_id)" >&2
}

toggle_audio_output() {
  local current_name
  current_name="$(current_default_audio_name)"
  local target_name

  if [[ $current_name == "$OUTPUT_A_NAME" ]]; then
    target_name="$OUTPUT_B_NAME"
  else
    target_name="$OUTPUT_A_NAME"
  fi

  switch_audio_to "$target_name"
}

# ── CLI Entry Point (only when executed directly) ────────────────────────────
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
  case "${1:-}" in
  "") toggle_audio_output ;;
  output_a) switch_audio_to "$OUTPUT_A_NAME" ;;
  output_b) switch_audio_to "$OUTPUT_B_NAME" ;;
  -h | --help)
    echo "Usage: $(basename "$0") [ output_a | output_b | <sink-name> | -c]"
    exit 0
    ;;
  -c) wpctl clear-default ;;
  *) switch_audio_to "$1" ;;
  esac
fi
