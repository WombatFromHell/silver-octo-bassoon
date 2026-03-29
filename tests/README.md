# Ansible Testing Guide

## Overview

This project includes a comprehensive test harness for validating roles independently and together.

## Quick Start

```bash
# Run all tests in check mode (dry-run)
./test.sh all --check

# Test a specific role
./test.sh base --check

# Run with verbose output
./test.sh flatpak --check --verbose
```

## Test Types

### 1. Role Tests (`tests/test_*_role.yml`)

Test individual roles in isolation:

```bash
# Test base role
ansible-playbook tests/test_base_role.yml --check

# Test flatpak role
ansible-playbook tests/test_flatpak_role.yml --check

# Test btrfs role
ansible-playbook tests/test_btrfs_role.yml --check --diff
```

### 2. Smoke Test (`tests/test_all_roles.yml`)

Run all roles in sequence to catch integration issues:

```bash
ansible-playbook tests/test_all_roles.yml --check
```

### 3. Preflight Test (`plays/preflight.yml`)

Validate system prerequisites before making changes:

```bash
ansible-playbook plays/preflight.yml
```

### 4. Verification Test (`plays/verify.yml`)

Check actual system state against expected configuration:

```bash
ansible-playbook plays/verify.yml
```

## Test Runner

Use the included test runner script:

```bash
# Show help
./test.sh --help

# Test all roles
./test.sh all

# Test specific role with verbose output
./test.sh base --verbose

# Actually run (not dry-run) - BE CAREFUL
./test.sh base --run
```

## Testing Best Practices

### 1. Always Test in Check Mode First

```bash
# Before applying changes
ansible-playbook site.yml --check

# Review what will change
ansible-playbook site.yml --check --diff
```

### 2. Test Individual Roles After Changes

```bash
# After modifying base role
./test.sh base --check
```

### 3. Run Full Smoke Test Before Commits

```bash
# Before committing changes
./test.sh all --check
ansible-lint
```

### 4. Use Verification Play for Drift Detection

```bash
# Check if system matches expected state
ansible-playbook plays/verify.yml
```

## Test Coverage

| Role | Test File | Status |
|------|-----------|--------|
| base | `tests/test_base_role.yml` | ✅ |
| flatpak | `tests/test_flatpak_role.yml` | ✅ |
| btrfs | `tests/test_btrfs_role.yml` | ✅ |
| dotfiles | `tests/test_dotfiles_role.yml` | ✅ |
| nix | (use smoke test) | ⚠️ |
| vfio | (use smoke test) | ⚠️ |
| distrobox | (use smoke test) | ⚠️ |
| arpcbridge | (use smoke test) | ⚠️ |

## CI/CD Integration

Add to your CI pipeline:

```yaml
# Example GitHub Actions
- name: Lint Ansible
  run: ansible-lint

- name: Test Ansible Roles
  run: ./test.sh all --check

- name: Syntax Check
  run: ansible-playbook --syntax-check site.yml
```

## Troubleshooting

### Test Fails in Check Mode

Some tasks don't support check mode properly. Look for:
- `check_mode: false` tasks
- Commands that don't use `changed_when`
- Scripts that always report changed

### Role-Specific Failures

1. Check role has `defaults/main.yml`
2. Verify all required variables are defined in test
3. Run with `--diff` to see what would change

### False Positives in Verification

The verify play may report issues for:
- Optional features not enabled
- Host-specific configurations
- Expected drift (e.g., package updates)

## Adding New Tests

1. Create `tests/test_<role>_role.yml` based on existing templates
2. Add role to `tests/test_all_roles.yml`
3. Update test runner `test.sh`
4. Document in this file
