#!/usr/bin/python3

import subprocess
from ansible.module_utils.basic import AnsibleModule


def is_tuckr_available():
    """Check if tuckr is in PATH and executable"""
    try:
        subprocess.run(
            ["tuckr", "--version"],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        return True
    except (subprocess.CalledProcessError, FileNotFoundError):
        return False


def parse_tuckr_conflicts(output):
    """Parse tuckr output for conflict information"""
    conflicts = []
    if not output:
        return conflicts

    for line in output.splitlines():
        if "->" in line and "(already exists)" in line:
            conflicts.append(line.strip().split("->")[1].split("(")[0].strip())
    return conflicts


def run_tuckr(module, command, name, force=False):
    """Run tuckr command with improved error handling"""
    if not is_tuckr_available():
        module.fail_json(msg="tuckr not found in PATH or not executable")

    cmd = ["tuckr"] + command.split() + [name]
    if force and "add" in command:
        cmd.insert(2, "--force")

    try:
        result = subprocess.run(
            cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        module.debug(f"tuckr succeeded: {result.stdout}")
        return True, result.stdout
    except subprocess.CalledProcessError as e:
        error_msg = e.stderr.strip() or "Unknown error (no stderr output)"
        stdout_msg = e.stdout.strip()

        # Handle conflicts specifically
        if "Conflicts were detected" in stdout_msg:
            conflicts = parse_tuckr_conflicts(stdout_msg)
            if conflicts:
                error_msg = f"Conflicts detected: {', '.join(conflicts)}"

        if "rm" in command:
            module.warn(f"Non-critical tuckr rm failure: {error_msg}")
            return False, stdout_msg

        module.fail_json(
            msg=f"tuckr {' '.join(command.split())} failed: {error_msg}",
            stdout=e.stdout,
            stderr=e.stderr,
            rc=e.returncode,
            conflicts=parse_tuckr_conflicts(stdout_msg) if stdout_msg else [],
        )
        return (
            False,
            stdout_msg,
        )  # This line is theoretically unreachable due to fail_json


def main():
    module = AnsibleModule(
        argument_spec={
            "name": {"type": "str", "required": True},
            "state": {
                "type": "str",
                "default": "present",
                "choices": ["present", "absent"],
            },
            "force": {"type": "bool", "default": False},
        },
        supports_check_mode=False,
    )

    name = module.params["name"]
    state = module.params["state"]
    force = module.params["force"]
    changed = False

    if state == "absent":
        success, _ = run_tuckr(module, "rm", name)
        changed = success
    else:
        # Clean up first, ignoring failures
        run_tuckr(module, "rm", name)
        success, output = run_tuckr(module, "add -y", name, force)
        changed = success

        # If failed with conflicts and force is True, try again with backup
        if not success and force:
            conflicts = parse_tuckr_conflicts(output or "")
            if conflicts:
                module.warn(f"Force mode enabled - backing up conflicts: {conflicts}")
                success, _ = run_tuckr(module, "add -y --force", name)
                changed = success

    module.exit_json(changed=changed)


if __name__ == "__main__":
    main()
