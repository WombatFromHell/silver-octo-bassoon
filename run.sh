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
#   --check, -c         Dry-run mode (show what would change)
#   --diff, -d          Show file content differences
#   --verbose, -v       Verbose output (can be repeated: -vvv)
#   --preflight         Run preflight checks only
#   --verify            Run verification play only
#   --role NAME         Run a specific role (e.g., --role base)
#   --tags TAGS         Run tasks with specific tags
#   --limit HOST        Run on specific host(s)
#   --all-hosts         Run on ALL hosts in inventory (overrides auto-limit)
#   --help, -h          Show this help message
#
# Examples:
#   ./run.sh                      # Deploy to current host (auto-limited)
#   ./run.sh --check              # Dry-run on current host
#   ./run.sh --check --diff       # Dry-run with diffs
#   ./run.sh -vvv                 # Verbose output
#   ./run.sh --test               # Run test harness
#   ./run.sh --test --role base   # Test base role only
#   ./run.sh --preflight          # Run preflight checks
#   ./run.sh --role btrfs --check # Test btrfs role dry-run
#   ./run.sh --tags packages      # Run only package-related tasks
#   ./run.sh --all-hosts          # Deploy to ALL hosts (careful!)
#

set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
MODE="deploy"
ANSIBLE_ARGS=()
TEST_MODE=""
VERBOSE=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Helper functions
print_header() {
  echo -e "${BLUE}========================================${NC}"
  echo -e "${BLUE}$1${NC}"
  echo -e "${BLUE}========================================${NC}"
}

print_success() {
  echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
  echo -e "${YELLOW}⚠ $1${NC}"
}

print_error() {
  echo -e "${RED}✗ $1${NC}"
}

show_help() {
  head -30 "$0" | tail -25 | sed 's/^# \?//'
  echo ""
  echo "Test Modes:"
  echo "   --test                    Run all tests"
  echo "   --test --role base        Test specific role"
  echo "   --test --all              Run full smoke test"
  echo ""
  echo "Deployment Modes:"
  echo "   (no args)                 Deploy to current host (auto-limited)"
  echo "   --all-hosts               Deploy to ALL hosts in inventory"
  echo "   --check                   Dry-run (no changes)"
  echo "   --preflight               Prerequisite checks only"
  echo "   --verify                  Verify system state"
  echo "   --role NAME               Run specific role"
  echo ""
  echo "Common Ansible Arguments:"
  echo "   -v, -vv, -vvv             Verbosity levels"
  echo "   --diff                    Show file diffs"
  echo "   --tags TAGS               Run specific tags"
  echo "   --limit HOST              Run on specific host"
  echo "   --ask-become-pass         Prompt for sudo password"
  echo ""
  echo "Examples:"
  echo "   ./run.sh --check --diff           # Preview all changes"
  echo "   ./run.sh --preflight              # Check prerequisites"
  echo "   ./run.sh --role base --check      # Test base role"
  echo "   ./run.sh --tags packages -vvv     # Debug package install"
  echo "   ./run.sh --test                   # Run test harness"
  echo "   ./run.sh --all-hosts              # Deploy to ALL hosts"
  exit 0
}

# Parse arguments
LIMIT_EXPLICIT=false
while [[ $# -gt 0 ]]; do
  case $1 in
  --help | -h)
    show_help
    ;;
  --test | -t)
    MODE="test"
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
    # Count v's for verbosity
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
    shift 2
    ;;
  --tags)
    ANSIBLE_ARGS+=("--tags" "$2")
    shift 2
    ;;
  --limit)
    ANSIBLE_ARGS+=("--limit" "$2")
    LIMIT_EXPLICIT=true
    shift 2
    ;;
  --all-hosts)
    # Explicitly run on all hosts (overrides auto-limit)
    LIMIT_EXPLICIT=true
    shift
    ;;
  --ask-become-pass)
    ANSIBLE_ARGS+=("--ask-become-pass")
    shift
    ;;
  *)
    # Pass remaining args to ansible-playbook
    ANSIBLE_ARGS+=("$1")
    shift
    ;;
  esac
done

# Auto-limit to current host if not explicitly specified
if [[ "$LIMIT_EXPLICIT" == "false" && "$MODE" == "deploy" ]]; then
  CURRENT_HOST=$(hostname)
  ANSIBLE_ARGS+=("--limit" "$CURRENT_HOST")
  echo -e "${YELLOW}Auto-limiting to current host: $CURRENT_HOST${NC}"
  echo -e "${YELLOW}Use --all-hosts to run on all inventory hosts${NC}"
  echo ""
fi

# Add verbosity
if [[ -n "$VERBOSE" ]]; then
  ANSIBLE_ARGS+=("-$VERBOSE")
fi

# Main execution
case $MODE in
test)
  print_header "Running Test Harness"

  if [[ -n "$ROLE" ]]; then
    print_header "Testing role: $ROLE"
    ./test.sh "$ROLE" "${ANSIBLE_ARGS[@]}"
  else
    print_header "Running all tests"
    ./test.sh all "${ANSIBLE_ARGS[@]}"
  fi

  print_success "Tests completed"
  ;;

preflight)
  print_header "Running Preflight Checks"
  ansible-playbook plays/preflight.yml "${ANSIBLE_ARGS[@]}"
  print_success "Preflight checks passed"
  ;;

verify)
  print_header "Verifying System State"
  ansible-playbook plays/verify.yml "${ANSIBLE_ARGS[@]}"
  print_success "Verification complete"
  ;;

role)
  if [[ -z "$ROLE" ]]; then
    print_error "Role name required. Use --role NAME"
    exit 1
  fi

  print_header "Running role: $ROLE"

  # Check if role-specific play exists
  ROLE_PLAY="plays/roles/${ROLE}-setup.yml"
  if [[ -f "$ROLE_PLAY" ]]; then
    ansible-playbook "$ROLE_PLAY" "${ANSIBLE_ARGS[@]}"
  else
    print_warning "No role-specific play found, running full site.yml with role tag"
    ansible-playbook site.yml --tags "$ROLE" "${ANSIBLE_ARGS[@]}"
  fi

  print_success "Role execution complete"
  ;;

deploy)
  if [[ -n "$ROLE" ]]; then
    # User specified --role but not --test mode
    MODE="role"
    exec "$0" --role "$ROLE" "${ANSIBLE_ARGS[@]}"
  fi

  print_header "Ansible Deployment"
  echo ""

  # Show what we're doing
  if [[ " ${ANSIBLE_ARGS[*]} " =~ " --check " ]]; then
    print_warning "DRY-RUN MODE: No changes will be made"
  fi
  echo ""

  # Run preflight first (unless check mode)
  if [[ ! " ${ANSIBLE_ARGS[*]} " =~ " --check " ]]; then
    print_header "Step 1: Preflight Checks"
    ansible-playbook plays/preflight.yml "${ANSIBLE_ARGS[@]}" || {
      print_error "Preflight checks failed"
      exit 1
    }
    echo ""
  fi

  # Run main deployment
  print_header "Step 2: System Configuration"
  ansible-playbook site.yml "${ANSIBLE_ARGS[@]}" || {
    print_error "Deployment failed"
    exit 1
  }
  echo ""

  # Run teardown (unless check mode)
  if [[ ! " ${ANSIBLE_ARGS[*]} " =~ " --check " ]]; then
    print_header "Step 3: Teardown"
    ansible-playbook plays/teardown.yml "${ANSIBLE_ARGS[@]}" || {
      print_warning "Teardown had warnings (this may be expected)"
    }
    echo ""
  fi

  print_success "Deployment complete!"
  ;;

*)
  print_error "Unknown mode: $MODE"
  exit 1
  ;;
esac

exit 0
