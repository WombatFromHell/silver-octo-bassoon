#!/usr/bin/env bash
# khalreminder.sh — schedule desktop notifications for khal events
# Uses systemd-run --user for one-shot transient timers.
# Recommended: run at login and after each vdirsyncer sync.
#
# Requires: khal, systemd (systemd-run), libnotify (notify-send)

set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════
# Configuration — override via environment or edit here
# ═══════════════════════════════════════════════════════════════════════════
NOTIFY_BIN="${NOTIFY_BIN:-notify-send}"
NOTIFY_URGENCY="${NOTIFY_URGENCY:-normal}" # low | normal | critical
WARN_MINUTES="${WARN_MINUTES:-30}"
ALLDAY_START="${ALLDAY_START:-08:00}" # assumed start time for all-day events
RANGE_FROM="${RANGE_FROM:-now}"
RANGE_TO="${RANGE_TO:-72h}"
UNIT_PREFIX="calremind"

# ═══════════════════════════════════════════════════════════════════════════
# khal output format
# ═══════════════════════════════════════════════════════════════════════════
# {start-time} emits "HH:MM AM" for timed events, "" (empty) for all-day.
# {start}      emits "MM/DD/YYYY HH:MM AM" for timed, "MM/DD/YYYY" for all-day.
#
# Observed output:
#   all-day: --<MM/DD/YYYY>-<MM/DD/YYYY>-<title>
#   timed:   <HH:MM AP>-<HH:MM AP>-<MM/DD/YYYY HH:MM AP>-<MM/DD/YYYY HH:MM AP>-<title>
KHAL_FORMAT='{start-time}-{end-time}-{start}-{end}-{title}'

# All-day: empty start/end time fields produce leading "--"
# Captures: (1) start date MM/DD/YYYY  (2) end date  (3) title
ALLDAY_PATTERN='^--([0-9]{2}/[0-9]{2}/[0-9]{4})-([0-9]{2}/[0-9]{2}/[0-9]{4})-(.+)$'

# Timed: HH:MM AM/PM times followed by full datetime stamps
# Captures: (1) start time  (2) end time  (3) start datetime  (4) end datetime  (5) title
TIMED_PATTERN='^([0-9]{2}:[0-9]{2} [AP]M)-([0-9]{2}:[0-9]{2} [AP]M)-([0-9]{2}/[0-9]{2}/[0-9]{4}) [0-9]{2}:[0-9]{2} [AP]M-([0-9]{2}/[0-9]{2}/[0-9]{4}) [0-9]{2}:[0-9]{2} [AP]M-(.+)$'

# khal's day-group headers like "Saturday, 05/04/2026"
HEADER_PATTERN='^[A-Z][a-z]+,'

# ═══════════════════════════════════════════════════════════════════════════
# Usage
# ═══════════════════════════════════════════════════════════════════════════
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  --from      TIME   Start of range to check (default: ${RANGE_FROM})
  --to        TIME   End of range to check   (default: ${RANGE_TO})
  --warn      MINS   Minutes before event to notify (default: ${WARN_MINUTES})
  --allday-at HH:MM  Assumed start for all-day events (default: ${ALLDAY_START})
  --list             List existing timers
  --cancel UNIT      Cancel timer by hash or unit name
  --help             Show this help

TIME accepts anything khal understands: 'today', 'tomorrow', '9:00', etc.
Environment overrides: RANGE_FROM, RANGE_TO, WARN_MINUTES, ALLDAY_START

Examples:
  $(basename "$0") --from today --to tomorrow
  $(basename "$0") --from 9:00 --to 18:00 --warn 15
  $(basename "$0") --list
  $(basename "$0") --cancel abc123def456
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

# ═══════════════════════════════════════════════════════════════════════════
# systemd timer helpers
#
# All timer queries funnel through _list_our_timers so there is exactly
# ONE place that talks to systemctl.  Everything else composes on top.
# ═══════════════════════════════════════════════════════════════════════════

# _list_our_timers [--all]
#   Print one unit name per line (e.g. calremind-abc123def456.timer).
#   Default: only active/waiting timers.
#   --all:   include inactive / expired timers too.
#
#   WHY list-timers and not list-unit-files or list-units:
#     - systemd-run creates transient units with no on-disk unit file,
#       so list-unit-files never sees them.
#     - list-units --type=timer with glob patterns behaves inconsistently
#       across systemd versions (some filter the glob before applying --type).
#     - list-timers is purpose-built for enumerating timers and reliably
#       includes both persistent and transient timer units.
_list_our_timers() {
  local -a extra=()
  [[ "${1:-}" == "--all" ]] && extra=(--all)

  systemctl --user list-timers "${extra[@]}" --no-legend 2>/dev/null |
    grep -Eo "\b${UNIT_PREFIX}-[0-9a-f]+\.timer\b" || true
}

# _timer_exists <unit_base>
#   True when <unit_base>.timer is known to systemd (active or inactive).
#   Delegates to _list_our_timers — no duplicate systemctl calls.
_timer_exists() {
  _list_our_timers --all | grep -qxF "${1}.timer"
}

# _stop_timer <unit.timer>
#   Stop a timer unit and its companion .service; errors are silenced.
_stop_timer() {
  systemctl --user stop "$1" 2>/dev/null || true
  systemctl --user stop "${1%.timer}.service" 2>/dev/null || true
}

# _unit_description <unit.timer>
#   Human-readable event name from the unit's Description= property.
_unit_description() {
  local raw
  raw=$(systemctl --user show "$1" --property=Description --value 2>/dev/null || true)
  # --value was added in systemd 246; older versions ignore it and
  # return "Description=Calendar reminder: ...", so strip both forms.
  raw="${raw#Description=}"
  raw="${raw#"Calendar reminder: "}"
  echo "${raw:-$1}"
}

# cleanup_expired_timers
#   Stop and clear out timers that have already fired.
#   After a transient timer fires, systemd leaves it in an inactive state;
#   is-active returns "inactive" (nonzero), so we stop and let systemd reap it.
cleanup_expired_timers() {
  local timer
  while IFS= read -r timer; do
    [[ -z "$timer" ]] && continue
    if ! systemctl --user is-active --quiet "$timer" 2>/dev/null; then
      _stop_timer "$timer"
    fi
  done < <(_list_our_timers --all)
  systemctl --user reset-failed 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════════════════════════
# Scheduling
# ═══════════════════════════════════════════════════════════════════════════

# build_unit_name <start_date> <start_time> <event_name>
#   Deterministic unit name: 12-char hex SHA-256 digest.
build_unit_name() {
  local digest
  digest=$(printf '%s' "${1} ${2} ${3}" | sha256sum | cut -c1-12)
  echo "${UNIT_PREFIX}-${digest}"
}

schedule_notification() {
  local event_line="$1"
  local start_date start_time event_name is_allday=0

  if [[ "$event_line" =~ $ALLDAY_PATTERN ]]; then
    start_date="${BASH_REMATCH[1]}"
    start_time="$ALLDAY_START"
    event_name="${BASH_REMATCH[3]}"
    is_allday=1
  elif [[ "$event_line" =~ $TIMED_PATTERN ]]; then
    start_time="${BASH_REMATCH[1]}"
    start_date="${BASH_REMATCH[3]}"
    event_name="${BASH_REMATCH[5]}"
  else
    return 0
  fi

  [[ -z "$event_name" ]] && return 0

  # date(1) understands "MM/DD/YYYY HH:MM AM" directly
  local event_epoch
  event_epoch=$(date +%s --date "${start_date} ${start_time}") || {
    echo "Warning: could not parse date '${start_date} ${start_time}' for '${event_name}'" >&2
    return 0
  }

  local unit_name
  unit_name=$(build_unit_name "$start_date" "$start_time" "$event_name")

  if _timer_exists "$unit_name"; then
    echo "Already scheduled: ${start_date} ${start_time} — ${event_name}" >&2
    return 0
  fi

  local now_epoch notify_epoch
  now_epoch=$(date +%s)
  notify_epoch=$((event_epoch - WARN_MINUTES * 60))

  if ((notify_epoch <= now_epoch)); then
    echo "Skipping (time already past): ${start_date} ${start_time} — ${event_name}" >&2
    return 0
  fi

  local notify_body
  if ((is_allday)); then
    notify_body="All-day event — assumed start ${start_time} (in ${WARN_MINUTES} min)"
  else
    notify_body="Starting at ${start_time} (in ${WARN_MINUTES} min)"
  fi

  systemd-run --user \
    --unit="$unit_name" \
    --on-calendar="$(date '+%Y-%m-%d %H:%M:%S' --date "@${notify_epoch}")" \
    --property="Description=Calendar reminder: ${event_name}" \
    -- \
    "$NOTIFY_BIN" \
    --urgency="$NOTIFY_URGENCY" \
    "Calendar: ${event_name}" \
    "$notify_body"

  echo "Scheduled: [$(date '+%H:%M' --date "@${notify_epoch}")] → ${event_name} (${start_date} starts ${start_time})"
}

# ═══════════════════════════════════════════════════════════════════════════
# User-facing commands
# ═══════════════════════════════════════════════════════════════════════════

list_timers() {
  cleanup_expired_timers

  local -a units
  mapfile -t units < <(_list_our_timers)

  if [[ ${#units[@]} -eq 0 ]]; then
    echo "No ${UNIT_PREFIX} timers currently scheduled."
    return 0
  fi

  # Build display rows: hash, next-fire time, event description.
  local -a hashes nexts descs
  local unit
  for unit in "${units[@]}"; do
    # list-timers columns: NEXT LEFT LAST PASSED UNIT ACTIVATES
    # NEXT = "Day YYYY-MM-DD HH:MM:SS TZ"  →  $2 $3 $4
    local timer_line next_human
    timer_line=$(systemctl --user list-timers --no-legend "$unit" 2>/dev/null || true)
    if [[ -z "$timer_line" ]]; then
      next_human="(elapsed)"
    else
      next_human=$(awk '{print $2, $3, $4}' <<<"$timer_line")
    fi

    local hash="${unit#"${UNIT_PREFIX}-"}"
    hash="${hash%.timer}"
    hashes+=("$hash")
    nexts+=("$next_human")
    descs+=("$(_unit_description "$unit")")
  done

  printf '\n  %-14s  %-22s  %s\n' "HASH" "FIRES AT" "EVENT"
  printf '  %-14s  %-22s  %s\n' "──────────────" "──────────────────────" \
    "────────────────────────────────────────────"
  local i
  for i in "${!hashes[@]}"; do
    printf '  %-14s  %-22s  %s\n' "${hashes[$i]}" "${nexts[$i]}" "${descs[$i]}"
  done
  printf '\n'
  echo "  To cancel: $(basename "$0") --cancel <hash>"
}

cancel_timer() {
  local arg="$1"
  local unit

  if [[ "$arg" =~ ^[0-9a-f]{12}$ ]]; then
    unit="${UNIT_PREFIX}-${arg}.timer"
  elif [[ "$arg" == ${UNIT_PREFIX}-* ]]; then
    unit="${arg%.service}"
    unit="${unit%.timer}.timer"
  else
    echo "Error: '$arg' must be a 12-char hex hash or a '${UNIT_PREFIX}-*' unit name." >&2
    exit 1
  fi

  local bare="${unit%.timer}"
  if ! _timer_exists "$bare"; then
    echo "Error: timer '$unit' not found or already expired." >&2
    exit 1
  fi

  _stop_timer "$unit"
  systemctl --user reset-failed 2>/dev/null || true
  echo "Cancelled: $unit"
}

# ═══════════════════════════════════════════════════════════════════════════
# Main
# ═══════════════════════════════════════════════════════════════════════════
check_dependency() {
  command -v "$1" &>/dev/null
}

main() {
  parse_args "$@"

  local dep
  for dep in khal systemd-run systemctl sha256sum "$NOTIFY_BIN"; do
    if ! check_dependency "$dep"; then
      echo "Error: $dep not found in PATH ($PATH)" >&2
      exit 1
    fi
  done

  cleanup_expired_timers

  echo "Checking events from '${RANGE_FROM}' to '${RANGE_TO}'..."

  local events
  events=$(khal list --format "$KHAL_FORMAT" "${RANGE_FROM}" "${RANGE_TO}" 2>/dev/null || true)

  local found=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    [[ "$line" =~ $HEADER_PATTERN ]] && continue
    [[ "$line" =~ $ALLDAY_PATTERN ]] || [[ "$line" =~ $TIMED_PATTERN ]] || continue
    schedule_notification "$line"
    found=1
  done <<<"$events"

  if ((found == 0)); then
    echo "No events in range."
  fi
}

main "$@"
