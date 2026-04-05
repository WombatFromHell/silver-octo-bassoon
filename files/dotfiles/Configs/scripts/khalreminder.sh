#!/usr/bin/env bash
# khalreminder.sh — schedule desktop notifications for today's khal events
# Uses 'systemd-run --user' for one-shot transient timers.
# Recommended: run at login and after each vdirsyncer sync.
#
# Requires: khal, systemd (systemd-run), libnotify (notify-send)

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment or edit here
# ---------------------------------------------------------------------------
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"
NOTIFY_URGENCY="${NOTIFY_URGENCY:-normal}" # low | normal | critical
WARN_MINUTES="${WARN_MINUTES:-30}"
ALLDAY_START="${ALLDAY_START:-08:00}" # assumed start time for all-day events
RANGE_FROM="${RANGE_FROM:-now}"       # start of range passed to khal list
RANGE_TO="${RANGE_TO:-72h}"           # end of range passed to khal list
UNIT_PREFIX="calremind"

TIME_PATTERN='^([0-9]{2}:[0-9]{2})-([0-9]{2}:[0-9]{2}) (.+)'
ALLDAY_PATTERN='^([0-9]{2}/[0-9]{2}/[0-9]{4})-([0-9]{2}/[0-9]{2}/[0-9]{4}) (.+)'
HEADER_PATTERN='^[A-Z][a-z]+,'

# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --from      TIME   Start of range to check (default: ${RANGE_FROM})
  --to        TIME   End of range to check   (default: ${RANGE_TO})
  --warn      MINS   Minutes before event to notify (default: ${WARN_MINUTES})
  --allday-at HH:MM  Assumed start time for all-day events (default: ${ALLDAY_START})
  --list             List existing timers
  --cancel UNI       Cancel timer with UNIT
  --help             Show this help

TIME accepts anything khal understands: 'today', 'tomorrow', '9:00', '2025-03-16', etc.
All options can also be set via environment variables:
  RANGE_FROM, RANGE_TO, WARN_MINUTES, ALLDAY_START

Examples:
  $(basename "$0") --from today --to tomorrow
  $(basename "$0") --from 9:00 --to 18:00 --warn 15
  $(basename "$0") --allday-at 09:00
  RANGE_FROM=today RANGE_TO='2 days' $(basename "$0")
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
    --from)
      RANGE_FROM="$2"
      shift 2
      ;;
    --to)
      RANGE_TO="$2"
      shift 2
      ;;
    --warn)
      WARN_MINUTES="$2"
      shift 2
      ;;
    --allday-at)
      ALLDAY_START="$2"
      shift 2
      ;;
    --list)
      list_timers
      exit 0
      ;;
    --cancel)
      cancel_timer "$2"
      exit 0
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    esac
  done
}

# ---------------------------------------------------------------------------
cancel_existing_timers() {
  local units
  units=$(systemctl --user list-timers --no-legend "${UNIT_PREFIX}-*.timer" 2>/dev/null |
    awk '{print $NF}')
  if [[ -n "$units" ]]; then
    echo "$units" | xargs -r systemctl --user stop
    echo "Cleared existing ${UNIT_PREFIX} timers."
  fi
}

schedule_notification() {
  local event_line="$1"
  local event_type="$2" # "timed" | "allday"
  local start_time event_name event_epoch is_allday=0

  if [[ "$event_type" == "timed" ]]; then
    [[ "$event_line" =~ $TIME_PATTERN ]] || return 0
    start_time="${BASH_REMATCH[1]}"
    event_name="${BASH_REMATCH[3]}"
    event_epoch=$(date +%s --date "$start_time today")
  else
    [[ "$event_line" =~ $ALLDAY_PATTERN ]] || return 0
    local event_date="${BASH_REMATCH[1]}" # MM/DD/YYYY
    start_time="$ALLDAY_START"
    is_allday=1
    event_name="${BASH_REMATCH[3]}"
    event_epoch=$(date +%s --date "$event_date $start_time")
  fi

  [[ -z "$event_name" ]] && return 0

  # Calculate notification epoch
  local notify_epoch now_epoch
  notify_epoch=$((event_epoch - WARN_MINUTES * 60))
  now_epoch=$(date +%s)

  if ((notify_epoch <= now_epoch)); then
    echo "Skipping (time already past): $start_time — $event_name" >&2
    return 0
  fi

  local unit_name
  unit_name="${UNIT_PREFIX}-$(systemd-escape "${start_time}-${event_name}")"

  local notify_body
  if ((is_allday)); then
    notify_body="All-day event — assumed start ${start_time} (in ${WARN_MINUTES} min)"
  else
    notify_body="Starting at $start_time (in ${WARN_MINUTES} min)"
  fi

  systemd-run --user \
    --unit="$unit_name" \
    --on-calendar="$(date '+%Y-%m-%d %H:%M:%S' --date "@$notify_epoch")" \
    --property="Description=Calendar reminder: $event_name" \
    -- \
    "$NOTIFY_BIN" \
    --urgency="$NOTIFY_URGENCY" \
    "Calendar: $event_name" \
    "$notify_body"

  echo "Scheduled: [$(date '+%H:%M' --date "@$notify_epoch")] → $event_name (starts $start_time)"
}

list_timers() {
  local timers
  timers=$(systemctl --user list-timers --no-legend "${UNIT_PREFIX}-*.timer" 2>/dev/null |
    awk '{print $1, $2, $3, $4}') # NEXT, LEFT, LAST, PASSED, omit UNIT which is col 5...

  if [[ -z "$timers" ]]; then
    echo "No ${UNIT_PREFIX} timers currently scheduled."
    return 0
  fi

  # $NF is the .service unit — derive the .timer name from it
  local timer_lines
  timer_lines=$(systemctl --user list-timers --no-legend "${UNIT_PREFIX}-*.timer" 2>/dev/null |
    awk '{sub(/\.service$/, ".timer", $NF); print $1, $2, $NF}')

  echo "Scheduled ${UNIT_PREFIX} timers:"
  echo "$timer_lines" | nl -ba -w2 -s'  ' | column -t
  echo
  echo "To cancel: $(basename "$0") --cancel <unit-name>"
}

cancel_timer() {
  local unit="$1"

  # Ensure it belongs to our prefix for safety
  if [[ "$unit" != ${UNIT_PREFIX}-* ]]; then
    echo "Error: unit '$unit' does not match prefix '${UNIT_PREFIX}-*'" >&2
    exit 1
  fi

  # Normalise suffix — swap .service for .timer, or append .timer if bare
  unit="${unit%.service}"
  unit="${unit%.timer}.timer"

  if systemctl --user stop "$unit" 2>/dev/null; then
    echo "Cancelled: $unit"
  else
    echo "Error: timer '$unit' not found or already expired." >&2
    exit 1
  fi
}

check_dependency() {
  local cmd="$1"
  # Try command -v first, then which as fallback
  if command -v "$cmd" &>/dev/null; then
    return 0
  elif which "$cmd" &>/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

main() {
  parse_args "$@"

  local dep
  for dep in khal systemd-run systemctl "$NOTIFY_BIN"; do
    if ! check_dependency "$dep"; then
      echo "Error: $dep not found in PATH ($PATH)" >&2
      exit 1
    fi
  done

  cancel_existing_timers

  echo "Checking events from '${RANGE_FROM}' to '${RANGE_TO}'..."

  local timed_events allday_events
  timed_events=$(khal list --format '{start-time}-{end-time} {title}' "${RANGE_FROM}" "${RANGE_TO}")
  allday_events=$(khal list --format '{start}-{end} {title}' "${RANGE_FROM}" "${RANGE_TO}")

  local found=0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $HEADER_PATTERN ]] && continue
    [[ "$line" =~ $TIME_PATTERN ]] || continue
    schedule_notification "$line" timed
    found=1
  done <<<"$timed_events"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $HEADER_PATTERN ]] && continue
    [[ "$line" =~ $ALLDAY_PATTERN ]] || continue
    schedule_notification "$line" allday
    found=1
  done <<<"$allday_events"

  if ((found == 0)); then
    echo "No events in range."
  fi
}

main "$@"
