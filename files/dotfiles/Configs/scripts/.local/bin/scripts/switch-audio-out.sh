#!/usr/bin/env bash
set -euo pipefail

# ── Configuration ─────────────────────────────────────────────────────────────

# Find these via `wpctl status -n`
OUTPUT_A_NAME="alsa_output.pci-0000_03_00.1.hdmi-stereo-extra3"
OUTPUT_B_NAME="alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"

usage() {
  echo "Usage: $(basename "$0") [output_a|output_b|<wpctl-sink-name>]" >&2
  echo "  (no arg)     toggle between the two outputs" >&2
  echo "  output_a     switch to $OUTPUT_A_NAME" >&2
  echo "  output_b     switch to $OUTPUT_B_NAME" >&2
  echo "  <sink-name>  switch to an arbitrary sink (see 'wpctl status -n')" >&2
  exit 1
}

# ── Deps ─────────────────────────────────────────────────────────────────────

command -v wpctl &>/dev/null || {
  echo "ERROR: 'wpctl' not found" >&2
  exit 1
}

# ── wpctl status parsing ─────────────────────────────────────────────────────
# ponytail: `wpctl status -n` lines look like " │  *   51. <name> [vol: 1.00]"
# — id and name are the first two space-separated tokens after the optional
# tree glyphs/asterisk; volume info in brackets is irrelevant here.

# Look up a sink's wpctl ID by its exact node name.
resolve_id() {
  local name="$1"
  wpctl status -n 2>/dev/null |
    sed -nE 's/^[│ ]*\*?[[:space:]]*([0-9]+)\.[[:space:]]+([^[:space:]]+).*/\1 \2/p' |
    awk -v n="$name" '$2 == n {print $1; exit}'
}

# Name of the current default sink (first '*'-marked line — Sinks precede
# Sources in wpctl's output, so this won't accidentally pick up a source).
current_default_name() {
  wpctl status -n 2>/dev/null |
    sed -nE 's/^[│ ]*\*[[:space:]]*([0-9]+)\.[[:space:]]+([^[:space:]]+).*/\2/p' |
    head -n 1
}

# ── Determine target ─────────────────────────────────────────────────────────

case "${1:-}" in
"")
  current_name="$(current_default_name)"
  if [[ "$current_name" == "$OUTPUT_A_NAME" ]]; then
    target_name="$OUTPUT_B_NAME"
  else
    target_name="$OUTPUT_A_NAME"
  fi
  ;;
output_a)
  target_name="$OUTPUT_A_NAME"
  ;;
output_b)
  target_name="$OUTPUT_B_NAME"
  ;;
*)
  # ponytail: unknown args are passed straight to resolve_id as raw sink names
  target_name="$1"
  ;;
esac

# ── Resolve target's wpctl ID and switch ────────────────────────────────────

target_id="$(resolve_id "$target_name")"

if [[ -z "$target_id" ]]; then
  echo "ERROR: audio output '$target_name' not found (check names via 'wpctl status -n')" >&2
  exit 1
fi

wpctl set-default "$target_id"
echo "Switched to $target_name (ID: $target_id)"
