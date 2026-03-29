#!/bin/bash
# Test runner for Ansible roles
# Usage: ./test.sh [role_name] [--check] [--verbose]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Default values
ROLE="${1:-all}"
CHECK_MODE="--check"
VERBOSE=""

# Parse arguments
for arg in "$@"; do
    case $arg in
        --check)
            CHECK_MODE="--check"
            ;;
        --verbose|-v)
            VERBOSE="-v"
            ;;
        --run)
            CHECK_MODE=""  # Actually make changes
            ;;
        --help)
            echo "Usage: $0 [role_name] [options]"
            echo ""
            echo "Roles:"
            echo "  base, flatpak, btrfs, dotfiles, nix, vfio, distrobox, arpcbridge, all"
            echo ""
            echo "Options:"
            echo "  --check     Run in check mode (default)"
            echo "  --run       Actually make changes (not dry-run)"
            echo "  --verbose   Show verbose output"
            echo "  --help      Show this help"
            exit 0
            ;;
    esac
done

echo "=== Ansible Role Test Runner ==="
echo "Role: $ROLE"
echo "Mode: ${CHECK_MODE:---run}"
echo ""

case $ROLE in
    base)
        ansible-playbook tests/test_base_role.yml $CHECK_MODE $VERBOSE
        ;;
    flatpak)
        ansible-playbook tests/test_flatpak_role.yml $CHECK_MODE $VERBOSE
        ;;
    btrfs)
        ansible-playbook tests/test_btrfs_role.yml $CHECK_MODE $VERBOSE
        ;;
    dotfiles)
        ansible-playbook tests/test_dotfiles_role.yml $CHECK_MODE $VERBOSE
        ;;
    all)
        ansible-playbook tests/test_all_roles.yml $CHECK_MODE $VERBOSE
        ;;
    *)
        echo "Unknown role: $ROLE"
        echo "Run with --help for usage"
        exit 1
        ;;
esac

echo ""
echo "=== Test Complete ==="
