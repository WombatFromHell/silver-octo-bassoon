#!/usr/bin/python3

import subprocess
import os
import shutil
import time
from ansible.module_utils.basic import AnsibleModule
from ansible.module_utils.common.text.converters import to_bytes, to_native
from typing import Tuple, List, Optional, Dict, Any


class TuckrManager:
    def __init__(self, module: AnsibleModule):
        self.module = module
        self.result: Dict[str, Any] = {"changed": False}

    def is_tuckr_available(self) -> bool:
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
            self.module.fail_json(msg="tuckr not found in PATH or not executable")
            return False  # Unreachable, but satisfies type checker

    def parse_conflicts(self, output: Optional[str]) -> List[str]:
        """Parse tuckr output for conflict information"""
        conflicts: List[str] = []
        if not output:
            return conflicts

        for line in output.splitlines():
            if "->" in line and "(already exists)" in line:
                parts = line.strip().split("->")
                if len(parts) > 1:
                    path_part = parts[1].split("(")[0].strip()
                    if path_part:
                        conflicts.append(path_part)
        return conflicts

    def backup_files(self, conflicts: List[str]) -> bool:
        """Backup conflicting files before overwriting"""
        if not conflicts:
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
                    self.module.warn(f"Backed up {file_path} to {backup_path}")
            return True
        except Exception as e:
            self.module.warn(f"Backup failed: {str(e)}")
            return False

    def run_command(self, cmd: List[str]) -> Tuple[int, str, str]:
        """Run a tuckr command and return (rc, stdout, stderr)"""
        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
        )
        return (proc.returncode, proc.stdout.strip(), proc.stderr.strip())

    def handle_add(self, name: str, force: bool, backup: bool) -> bool:
        """Handle the add command with retry logic"""
        rc, stdout, stderr = self.run_command(["tuckr", "add", "-y", name])

        if rc == 0:
            self.result["changed"] = True
            return True

        conflicts = self.parse_conflicts(stdout)

        # Record conflicts in the result regardless of force setting
        self.result.update(
            {"conflicts": conflicts, "stdout": stdout, "stderr": stderr, "rc": rc}
        )

        # If there are conflicts but force is enabled, try force operation
        if conflicts and force:
            if backup:
                self.backup_files(conflicts)

            force_rc, force_stdout, force_stderr = self.run_command(
                ["tuckr", "add", "-y", "--force", name]
            )

            # Update result with force command output
            self.result.update(
                {
                    "force_stdout": force_stdout,
                    "force_stderr": force_stderr,
                    "force_rc": force_rc,
                }
            )

            if force_rc == 0:
                self.result["changed"] = True
                return True
            else:
                # Even if force fails, don't consider it a module failure if conflicts were the issue
                self.result["msg"] = (
                    f"Force operation failed: {force_stderr or force_stdout}"
                )
                # Return true to avoid failing in Ansible
                return True

        # If no conflicts or force is disabled, fail as usual
        if not conflicts or not force:
            self.result["msg"] = stderr or stdout or "Unknown error"
            return False

        # This should be unreachable, but just in case
        return False

    def handle_rm(self, name: str) -> bool:
        """Handle the rm command"""
        rc, stdout, stderr = self.run_command(["tuckr", "rm", name])
        if rc != 0:
            self.module.warn(f"tuckr rm reported: {stderr or stdout}")
        self.result["changed"] = rc == 0
        return rc == 0

    def execute(
        self, name: str, state: str, force: bool, backup: bool
    ) -> Dict[str, Any]:
        """Main execution method"""
        if not self.is_tuckr_available():
            return self.result

        if state == "present":
            success = self.handle_add(name, force, backup)
            if not success and not (force and "conflicts" in self.result):
                self.module.fail_json(**self.result)
        else:
            self.handle_rm(name)

        return self.result


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

    manager = TuckrManager(module)
    result = manager.execute(
        name=module.params["name"],
        state=module.params["state"],
        force=module.params["force"],
        backup=module.params["backup"],
    )
    module.exit_json(**result)


if __name__ == "__main__":
    main()
