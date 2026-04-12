#!/usr/bin/env bash
#
# Ansible Playbook Runner
# =======================
# Wrapper script for running the Ansible playbook with common options.
#
# Usage:
#   ./run.sh [OPTIONS] [ANSIBLE_ARGS...]
#
# Options:
#   --test, -t          Run test harness instead of deployment
#   --idempotency       Run idempotency test (all roles twice)
#   --check, -c         Dry-run mode (show what would change)
#   --diff, -d          Show file content differences
#   --verbose, -v       Verbose output (can be repeated: -vvv)
#   --preflight         Run preflight checks only
#   --verify            Run verification play only
#   --role NAME         Run a specific role (e.g., --role base)
#   --tags TAGS         Run tasks with specific tags
#   --list, -l          List all available roles
#   --limit HOST        Run on specific host(s)
#   --all-hosts         Run on ALL hosts in inventory (overrides auto-limit)
#   --help, -h          Show this help message
#
# Note: --ask-become-pass is automatically enabled for deployment modes.
#       You will be prompted ONCE for the sudo password at the start.
#
# Examples:
#   ./run.sh                      # Deploy to current host (auto-limited)
#   ./run.sh --check              # Dry-run on current host
#   ./run.sh --check --diff       # Dry-run with diffs
#   ./run.sh -vvv                 # Verbose output
#   ./run.sh --test               # Run test harness
#   ./run.sh --test --role base   # Test base role
#   ./run.sh --test --idempotency # Run idempotency test
#   ./run.sh --preflight          # Run preflight checks
#   ./run.sh --role btrfs --check # Test btrfs role dry-run
#   ./run.sh --tags packages      # Run only package-related tasks
#   ./run.sh --all-hosts          # Deploy to ALL hosts (careful!)
#   ./run.sh --list               # List all available roles
#

set -euo pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Directory layout
ROLES_DIR="$SCRIPT_DIR/roles"
PLAYS_DIR="$SCRIPT_DIR/plays"

# Execution state
MODE="deploy"
ROLE=""
LIMIT_HOST=""
LIMIT_EXPLICIT=false
ANSIBLE_ARGS=()
VERBOSE=""

# Color codes
declare -r RED='\033[0;31m'
declare -r GREEN='\033[0;32m'
declare -r YELLOW='\033[1;33m'
declare -r BLUE='\033[0;34m'
declare -r NC='\033[0m'

# Tag categories for display grouping
declare -ra CORE_TAGS=(core always setup bootstrap preflight verify teardown facts extra)
declare -ra ROLE_TAGS=(aur pacman btrfs dotfiles flatpak mounts nix vfio arpc tuckr udev polkit sudoers bootloader fonts zram chaoticaur appimages brew etc globalbin globalunits limitsd shortcuts home_manager)

# Mode behaviors (declarative, single source of truth)
declare -ra MODES_NEED_BECOME=(deploy role preflight verify)
declare -ra MODES_AUTO_LIMIT=(deploy role)

# ============================================================================
# OUTPUT HELPERS
# ============================================================================

print_header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error() { echo -e "${RED}✗ $1${NC}" >&2; }

print_bullet() { echo -e "  ${GREEN}•${NC} $1"; }

print_bullet_list() {
  local label="$1"
  shift
  if [[ $# -gt 0 ]]; then
    echo -e "${YELLOW}${label}${NC}"
    for item in "$@"; do
      print_bullet "$item"
    done
    echo ""
  fi
}

# ============================================================================
# PLAYBOOK EXECUTION
# ============================================================================

run_playbook() {
  local playbook_path="$1"
  shift
  exec ansible-playbook "$playbook_path" "${ANSIBLE_ARGS[@]}" "$@"
}

run_playbook_checked() {
  local playbook_path="$1"
  shift
  run_playbook "$playbook_path" "$@" || {
    print_error "Deployment failed"
    exit 1
  }
}

# ============================================================================
# ARGUMENT PARSING
# ============================================================================

show_help() {
  head -30 "$0" | tail -25 | sed 's/^# \?//'
  cat <<EOF

Test Modes:
   --test                    Run all tests
   --test --role base        Test specific role
   --test --all              Run full smoke test
   --idempotency             Run idempotency test (all roles twice)

Deployment Modes:
   (no args)                 Deploy to current host (auto-limited)
   --all-hosts               Deploy to ALL hosts in inventory
   --check                   Dry-run (no changes)
   --preflight               Prerequisite checks only
   --verify                  Verify system state
   --role NAME               Run specific role
   --list                    List available roles

Common Ansible Arguments:
   -v, -vv, -vvv             Verbosity levels
   --diff                    Show file diffs
   --tags TAGS               Run specific tags
   --limit HOST              Run on specific host
   --ask-become-pass         Prompt for sudo password

Examples:
   ./run.sh --check --diff           # Preview all changes
   ./run.sh --preflight              # Check prerequisites
   ./run.sh --role base --check      # Test base role
   ./run.sh --tags packages -vvv     # Debug package install
   ./run.sh --test                   # Run test harness
   ./run.sh --idempotency            # Run idempotency test
   ./run.sh --all-hosts              # Deploy to ALL hosts
EOF
  exit 0
}

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case $1 in
    --help | -h) show_help ;;
    --test | -t)
      MODE="test"
      shift
      ;;
    --idempotency)
      MODE="idempotency"
      shift
      ;;
    --check | -c)
      ANSIBLE_ARGS+=("--check")
      shift
      ;;
    --diff | -d)
      ANSIBLE_ARGS+=("--diff")
      shift
      ;;
    --verbose | -v)
      while [[ $1 == -v* ]]; do
        VERBOSE+="v"
        shift
      done
      ;;
    --preflight)
      MODE="preflight"
      shift
      ;;
    --verify)
      MODE="verify"
      shift
      ;;
    --role)
      ROLE="$2"
      MODE="role"
      shift 2
      ;;
    --tags)
      ANSIBLE_ARGS+=("--tags" "$2")
      shift 2
      ;;
    --limit)
      LIMIT_HOST="$2"
      LIMIT_EXPLICIT=true
      shift 2
      ;;
    --all-hosts)
      LIMIT_EXPLICIT=true
      shift
      ;;
    --list | -l)
      MODE="list"
      shift
      ;;
    --ask-become-pass)
      ANSIBLE_ARGS+=("--ask-become-pass")
      shift
      ;;
    *)
      ANSIBLE_ARGS+=("$1")
      shift
      ;;
    esac
  done
}

# ============================================================================
# DEFAULT RESOLUTION
# ============================================================================

mode_has_behavior() {
  local mode="$1"
  shift
  local -a behavior_list=("$@")
  for m in "${behavior_list[@]}"; do
    [[ "$m" == "$mode" ]] && return 0
  done
  return 1
}

apply_defaults() {
  # Auto-enable become password for modes that need it
  if mode_has_behavior "$MODE" "${MODES_NEED_BECOME[@]}" &&
    [[ ! " ${ANSIBLE_ARGS[*]:-} " =~ " --ask-become-pass " ]]; then
    ANSIBLE_ARGS+=("--ask-become-pass")
  fi

  # Auto-limit to current host (unless explicitly overridden)
  if [[ "$LIMIT_EXPLICIT" == "false" ]] && mode_has_behavior "$MODE" "${MODES_AUTO_LIMIT[@]}"; then
    LIMIT_HOST=$(hostname)
    if [[ "$MODE" == "deploy" ]]; then
      echo -e "${YELLOW}Auto-limiting to current host: $LIMIT_HOST${NC}"
      echo -e "${YELLOW}Use --all-hosts to run on all inventory hosts${NC}"
      echo ""
    fi
  fi

  # Apply limit and verbosity
  if [[ -n "$LIMIT_HOST" ]]; then ANSIBLE_ARGS+=("--limit" "$LIMIT_HOST"); fi
  if [[ -n "$VERBOSE" ]]; then ANSIBLE_ARGS+=("-$VERBOSE"); fi
}

# ============================================================================
# TAG LISTING
# ============================================================================

extract_all_tags() {
  grep -rhoP 'tags:\s*\K\[?[^\]]+\]?' "$ROLES_DIR/" "$PLAYS_DIR/" --include='*.yml' 2>/dev/null |
    tr -d '[]' | tr ',' '\n' | sed 's/^["'"'"']\+//;s/["'"'"']\+$//' | xargs -n1 | sort -u | grep -v '^$' || true
}

classify_tag() {
  local tag="$1"
  for t in "${CORE_TAGS[@]}"; do [[ "$t" == "$tag" ]] && {
    echo "core"
    return
  }; done
  for t in "${ROLE_TAGS[@]}"; do [[ "$t" == "$tag" ]] && {
    echo "role"
    return
  }; done
  echo "other"
}

display_grouped_tags() {
  local all_tags
  all_tags=$(extract_all_tags)

  if [[ -z "$all_tags" ]]; then
    print_warning "No tags found"
    return
  fi

  # Classify tags into arrays
  local core_tags=() role_tags=() other_tags=()
  while IFS= read -r tag; do
    [[ -z "$tag" ]] && continue
    case "$(classify_tag "$tag")" in
    core) core_tags+=("$tag") ;;
    role) role_tags+=("$tag") ;;
    other) other_tags+=("$tag") ;;
    esac
  done <<<"$all_tags"

  # Display each non-empty group
  print_bullet_list "Core tags:" "${core_tags[@]+"${core_tags[@]}"}"
  print_bullet_list "Role tags:" "${role_tags[@]+"${role_tags[@]}"}"
  print_bullet_list "Sub-tags:" "${other_tags[@]+"${other_tags[@]}"}"
}

# ============================================================================
# MODE HANDLERS
# ============================================================================

run_test() {
  local test_target="all"
  [[ -n "$ROLE" ]] && test_target="$ROLE"

  print_header "$([[ "$test_target" == "all" ]] && echo "Running all tests" || echo "Testing role: $test_target")"
  exec "$SCRIPT_DIR/test.sh" "$test_target" "${ANSIBLE_ARGS[@]}"
}

run_idempotency() {
  print_header "Running Idempotency Test"
  echo ""
  echo "This test runs all roles twice to verify idempotency."
  echo "The second run should report 0 changes."
  echo ""
  exec "$SCRIPT_DIR/test.sh" idempotency "${ANSIBLE_ARGS[@]}"
}

run_preflight() { run_playbook "$PLAYS_DIR/preflight.yml"; }
run_verify() { run_playbook "$PLAYS_DIR/verify.yml"; }

run_role() {
  [[ -z "$ROLE" ]] && {
    print_error "Role name required. Use --role NAME"
    exit 1
  }

  print_header "Running role: $ROLE"

  local role_play="$PLAYS_DIR/roles/${ROLE}-setup.yml"
  if [[ -f "$role_play" ]]; then
    run_playbook "$role_play"
  else
    print_warning "No role-specific play found, running full site.yml with role tag"
    run_playbook "$SCRIPT_DIR/site.yml" --tags "$ROLE"
  fi
}

run_deploy() {
  print_header "Ansible Deployment"
  echo ""

  [[ " ${ANSIBLE_ARGS[*]:-} " =~ " --check " ]] && {
    print_warning "DRY-RUN MODE: No changes will be made"
    echo ""
  }

  print_header "Running System Configuration"
  run_playbook_checked "$SCRIPT_DIR/site.yml"
  echo ""
  print_success "Deployment complete!"
}

run_list() {
  print_header "Available Roles"
  echo ""

  if [[ -d "$ROLES_DIR" ]]; then
    echo -e "${GREEN}Roles:${NC}"
    for role_dir in "$ROLES_DIR"/*/; do
      [[ -d "$role_dir" ]] && print_bullet "$(basename "$role_dir")"
    done
  else
    print_warning "No roles directory found at: $ROLES_DIR"
  fi

  echo ""
  print_header "Available Tags"
  echo ""
  display_grouped_tags

  echo -e "${BLUE}Usage examples:${NC}"
  echo "  ./run.sh --role base          # Run base role"
  echo "  ./run.sh --role base --check  # Dry-run base role"
  echo "  ./run.sh --tags packages      # Run tasks tagged 'packages'"
  echo "  ./run.sh --tags btrfs --check # Test btrfs-related tasks"
  exit 0
}

# ============================================================================
# MAIN ENTRY POINT
# ============================================================================

main() {
  parse_arguments "$@"
  apply_defaults

  case "$MODE" in
  test) run_test ;;
  idempotency) run_idempotency ;;
  preflight) run_preflight ;;
  verify) run_verify ;;
  role) run_role ;;
  deploy) run_deploy ;;
  list) run_list ;;
  *)
    print_error "Unknown mode: $MODE"
    exit 1
    ;;
  esac
}

main "$@"
