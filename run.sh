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
  echo "   --idempotency             Run idempotency test (all roles twice)"
  echo ""
  echo "Deployment Modes:"
  echo "   (no args)                 Deploy to current host (auto-limited)"
  echo "   --all-hosts               Deploy to ALL hosts in inventory"
  echo "   --check                   Dry-run (no changes)"
  echo "   --preflight               Prerequisite checks only"
  echo "   --verify                  Verify system state"
  echo "   --role NAME               Run specific role"
  echo "   --list                    List available roles"
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
  echo "   ./run.sh --idempotency            # Run idempotency test"
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
    MODE="role"
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
  --list | -l)
    MODE="list"
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

# Auto-enable become password prompt for deployment modes
if [[ "$MODE" == "deploy" || "$MODE" == "role" || "$MODE" == "preflight" || "$MODE" == "verify" ]]; then
  # Only add if not already specified by user
  if [[ ! " ${ANSIBLE_ARGS[*]} " =~ " --ask-become-pass " ]]; then
    ANSIBLE_ARGS+=("--ask-become-pass")
  fi
fi

# Auto-limit to current host if not explicitly specified
if [[ "$LIMIT_EXPLICIT" == "false" && "$MODE" == "deploy" ]]; then
  CURRENT_HOST=$(hostname)
  ANSIBLE_ARGS+=("--limit" "$CURRENT_HOST")
  echo -e "${YELLOW}Auto-limiting to current host: $CURRENT_HOST${NC}"
  echo -e "${YELLOW}Use --all-hosts to run on all inventory hosts${NC}"
  echo ""
fi

# Also auto-limit for role mode
if [[ "$LIMIT_EXPLICIT" == "false" && "$MODE" == "role" ]]; then
  CURRENT_HOST=$(hostname)
  ANSIBLE_ARGS+=("--limit" "$CURRENT_HOST")
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
    exec ./test.sh "$ROLE" "${ANSIBLE_ARGS[@]}"
  else
    print_header "Running all tests"
    exec ./test.sh all "${ANSIBLE_ARGS[@]}"
  fi
  ;;

idempotency)
  print_header "Running Idempotency Test"
  echo ""
  echo "This test runs all roles twice to verify idempotency."
  echo "The second run should report 0 changes."
  echo ""
  exec ./test.sh idempotency "${ANSIBLE_ARGS[@]}"
  ;;

preflight)
  print_header "Running Preflight Checks"
  exec ansible-playbook plays/preflight.yml "${ANSIBLE_ARGS[@]}"
  ;;

verify)
  print_header "Verifying System State"
  exec ansible-playbook plays/verify.yml "${ANSIBLE_ARGS[@]}"
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
    exec ansible-playbook "$ROLE_PLAY" "${ANSIBLE_ARGS[@]}"
  else
    print_warning "No role-specific play found, running full site.yml with role tag"
    exec ansible-playbook site.yml --tags "$ROLE" "${ANSIBLE_ARGS[@]}"
  fi
  ;;

deploy)
  print_header "Ansible Deployment"
  echo ""

  # Show what we're doing
  if [[ " ${ANSIBLE_ARGS[*]} " =~ " --check " ]]; then
    print_warning "DRY-RUN MODE: No changes will be made"
  fi
  echo ""

  # Run everything in a single ansible-playbook invocation
  # This ensures only ONE become password prompt
  print_header "Running System Configuration"
  ansible-playbook site.yml "${ANSIBLE_ARGS[@]}" || {
    print_error "Deployment failed"
    exit 1
  }
  echo ""

  print_success "Deployment complete!"
  ;;

list)
  print_header "Available Roles"
  echo ""
  
  ROLES_DIR="$SCRIPT_DIR/roles"
  if [[ -d "$ROLES_DIR" ]]; then
    echo -e "${GREEN}Roles:${NC}"
    for role_dir in "$ROLES_DIR"/*/; do
      if [[ -d "$role_dir" ]]; then
        role_name=$(basename "$role_dir")
        echo -e "  ${GREEN}•${NC} $role_name"
      fi
    done
  else
    print_warning "No roles directory found at: $ROLES_DIR"
  fi
  
  echo ""
  print_header "Available Tags"
  echo ""
  
  # Extract unique tags from roles and plays
  TAGS=$(grep -rhoP 'tags:\s*\K\[?[^\]]+\]?' "$SCRIPT_DIR/roles/" "$SCRIPT_DIR/plays/" --include='*.yml' 2>/dev/null | \
    tr -d '[]' | tr ',' '\n' | sed 's/^["'"'"']\+//;s/["'"'"']\+$//' | xargs -n1 | sort -u | grep -v '^$')
  
  if [[ -n "$TAGS" ]]; then
    # Group tags by prefix
    echo -e "${YELLOW}Core tags:${NC}"
    echo "$TAGS" | grep -E '^(core|always|setup|bootstrap|preflight|verify|teardown|facts|extra)$' | while read -r tag; do
      echo -e "  ${GREEN}•${NC} $tag"
    done
    
    echo ""
    echo -e "${YELLOW}Role tags:${NC}"
    echo "$TAGS" | grep -E '^(aur|pacman|btrfs|dotfiles|flatpak|mounts|nix|vfio|arpc|distrobox|tuckr|udev|polkit|sudoers|bootloader|fonts|zram|chaoticaur|appimages|brew|etc|globalbin|globalunits|limitsd|shortcuts|home_manager)$' | while read -r tag; do
      echo -e "  ${GREEN}•${NC} $tag"
    done
    
    echo ""
    echo -e "${YELLOW}Sub-tags:${NC}"
    echo "$TAGS" | grep -vE '^(core|always|setup|bootstrap|preflight|verify|teardown|facts|extra|aur|pacman|btrfs|dotfiles|flatpak|mounts|nix|vfio|arpc|distrobox|tuckr|udev|polkit|sudoers|bootloader|fonts|zram|chaoticaur|appimages|brew|etc|globalbin|globalunits|limitsd|shortcuts|home_manager)$' | while read -r tag; do
      echo -e "  ${GREEN}•${NC} $tag"
    done
  else
    print_warning "No tags found"
  fi
  
  echo ""
  echo -e "${BLUE}Usage examples:${NC}"
  echo "  ./run.sh --role base          # Run base role"
  echo "  ./run.sh --role base --check  # Dry-run base role"
  echo "  ./run.sh --tags packages      # Run tasks tagged 'packages'"
  echo "  ./run.sh --tags btrfs --check # Test btrfs-related tasks"
  exit 0
  ;;

*)
  print_error "Unknown mode: $MODE"
  exit 1
  ;;
esac

exit 0
