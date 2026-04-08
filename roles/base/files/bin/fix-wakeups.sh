#!/usr/bin/env bash
set -uo pipefail

# ==========================================
# Configuration
# ==========================================
disable_devices=(
  GPP0
  XH00
)                 # Prevent ghost wakes
enable_devices=() # Allow intended wakes

PROC_FILE="/proc/acpi/wakeup"

# ==========================================
# Prerequisites
# ==========================================
if [[ $EUID -ne 0 ]]; then
  echo "ERROR: Root privileges required." >&2
  exit 1
fi

if [[ ! -f "$PROC_FILE" ]]; then
  echo "ERROR: $PROC_FILE not found. ACPI may not be enabled." >&2
  exit 1
fi

# ==========================================
# Core Logic
# ==========================================
get_state() {
  local line
  # Safely read current state for the target device
  line=$(grep -m1 "^${1}[[:space:]]" "$PROC_FILE" 2>/dev/null) || true
  if [[ -z "$line" ]]; then
    echo "missing"
  elif [[ "$line" == *enabled* ]]; then
    echo "enabled"
  else
    echo "disabled"
  fi
}

apply_state() {
  local dev="$1" desired="$2"
  local current
  current=$(get_state "$dev")

  # 1. Already matches target → no-op (idempotent)
  if [[ "$current" == "$desired" ]]; then
    echo "OK: $dev is already $desired"
    return 0
  fi

  # 2. Device doesn't exist in ACPI table
  if [[ "$current" == "missing" ]]; then
    echo "SKIP: $dev not found in ACPI table"
    return 1
  fi

  # 3. Toggle to achieve desired state
  if echo "$dev" >"$PROC_FILE" 2>/dev/null; then
    echo "FIXED: $dev toggled to $desired"
    return 0
  else
    echo "ERROR: Failed to toggle $dev" >&2
    return 1
  fi
}

# ==========================================
# Direct Execution
# ==========================================
echo "--- Applying ACPI wakeup states ---"
errors=0

for dev in "${disable_devices[@]}"; do
  apply_state "$dev" "disabled" || errors=$((errors + 1))
done

for dev in "${enable_devices[@]}"; do
  apply_state "$dev" "enabled" || errors=$((errors + 1))
done

echo "--- Finished with $errors error(s) ---"
exit "$errors"
