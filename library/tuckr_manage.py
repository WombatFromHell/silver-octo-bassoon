#!/usr/bin/python3

import subprocess
import os
import shutil
import time
from ansible.module_utils.basic import AnsibleModule
from typing import Tuple, List, Optional


def is_tuckr_available() -> bool:
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


def parse_tuckr_conflicts(output: Optional[str]) -> List[str]:
    """Parse tuckr output for conflict information"""
    conflicts: List[str] = []
    if not output:
        return conflicts

    for line in output.splitlines():
        if "->" in line and "(already exists)" in line:
            parts = line.strip().split("->")
            if len(parts) > 1:
                path_part = parts[1].split("(")[0].strip()
                if path_part:  # Ensure we don't add empty strings
                    conflicts.append(path_part)
    return conflicts


def backup_conflicting_files(module: AnsibleModule, conflicts: List[str]) -> bool:
    """Backup conflicting files before overwriting"""
    if not conflicts:  # Handle empty conflict list
        return True

    backup_dir = os.path.expanduser("~/.tuckr_backups")
    timestamp = time.strftime("%Y%m%d-%H%M%S")

    try:
        os.makedirs(backup_dir, exist_ok=True)
        for file_path in conflicts:
            if os.path.exists(file_path):
                backup_path = os.path.join(
                    backup_dir, f"{os.path.basename(file_path)}.{timestamp}"
                )
                shutil.move(file_path, backup_path)
                module.warn(f"Backed up conflicting file {file_path} to {backup_path}")
        return True
    except Exception as e:
        module.warn(f"Failed to backup conflicting files: {str(e)}")
        return False


def run_tuckr(
    module: AnsibleModule,
    command: str,
    name: str,
    force: bool = False,
    backup: bool = True,
) -> Tuple[bool, Optional[str]]:
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
                if force and backup:
                    if backup_conflicting_files(module, conflicts):
                        # Try again after backup
                        try:
                            result = subprocess.run(
                                ["tuckr", "add", "-y", "--force", name],
                                check=True,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE,
                                text=True,
                            )
                            return True, result.stdout
                        except subprocess.CalledProcessError as e2:
                            error_msg = f"Failed even with force: {e2.stderr.strip()}"

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
        return False, None  # This line is theoretically unreachable due to fail_json


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
            "backup": {"type": "bool", "default": True},
        },
        supports_check_mode=False,
    )

    name = module.params["name"]
    state = module.params["state"]
    force = module.params["force"]
    backup = module.params["backup"]
    changed = False

    if state == "absent":
        success, _ = run_tuckr(module, "rm", name, force, backup)
        changed = success
    else:
        # Clean up first, ignoring failures
        run_tuckr(module, "rm", name, force, backup)
        success, _ = run_tuckr(module, "add -y", name, force, backup)
        changed = success

    module.exit_json(changed=changed)


if __name__ == "__main__":
    main()
