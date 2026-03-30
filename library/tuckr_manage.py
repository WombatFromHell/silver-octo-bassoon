#!/usr/bin/python3

import os
import re
import shutil
import subprocess
import time
from typing import Any, Dict, List, Optional, Tuple

from ansible.module_utils.basic import AnsibleModule


class TuckrManager:
    def __init__(self, module: AnsibleModule):
        self.module = module
        self.result: Dict[str, Any] = {"changed": False}
        self.check_mode = module.check_mode

    def is_tuckr_available(self) -> bool:
        """Check if tuckr is in PATH and executable"""
        # Ensure /usr/local/bin is in PATH (where tuckr is installed)
        env = os.environ.copy()
        if "/usr/local/bin" not in env.get("PATH", ""):
            env["PATH"] = "/usr/local/bin:" + env.get("PATH", "")

        # Store PATH for debugging
        self.result["_env_path"] = env.get("PATH", "")
        self.result["_which_tuckr"] = (
            subprocess.run(
                ["which", "tuckr"], capture_output=True, text=True
            ).stdout.strip()
            or "not found"
        )

        try:
            proc = subprocess.run(
                ["tuckr", "--version"],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
            )
            self.result["_tuckr_version_rc"] = proc.returncode
            self.result["_tuckr_version_stdout"] = proc.stdout.strip()[:200]
            self.result["_tuckr_version_stderr"] = proc.stderr.strip()[:200]

            if proc.returncode == 0:
                return True
            else:
                self.result["_tuckr_error"] = (
                    f"tuckr --version failed with rc={proc.returncode}"
                )
                self.module.fail_json(msg="tuckr not found in PATH or not executable")
                return False
        except FileNotFoundError as e:
            self.result["_tuckr_error"] = f"tuckr not found: {str(e)}"
            self.module.fail_json(msg="tuckr not found in PATH or not executable")
            return False

    def config_exists(self, name: str) -> Tuple[bool, Optional[str]]:
        """Check if tuckr config already exists for this program.

        Uses 'tuckr status' to check if the program is already managed.
        Returns (exists, location) tuple where location is 'symlinked',
        'not_symlinked', or 'conflicting'.
        """
        dotfiles_root = os.path.expanduser("~/.config/dotfiles")
        if not os.path.exists(dotfiles_root):
            return False, None

        env = os.environ.copy()
        if "/usr/local/bin" not in env.get("PATH", ""):
            env["PATH"] = "/usr/local/bin:" + env.get("PATH", "")

        try:
            proc = subprocess.run(
                ["tuckr", "status"],
                capture_output=True,
                text=True,
                check=False,
                env=env,
            )

            self.result["_tuckr_status_rc"] = proc.returncode
            self.result["_tuckr_status_stderr"] = proc.stderr[:500] if proc.stderr else "(empty)"

            # tuckr status returns 0 normally, 1 when there are conflicting dotfiles
            if proc.stdout and proc.returncode in (0, 1):
                output = re.sub(r"\x1b\[[0-9;]*m", "", proc.stdout)

                # Capture debug info after stripping so it's readable
                self.result["_tuckr_status_raw"] = output[:500]

                name_lower = name.lower()

                table_section = (
                    output.split("Conflicting Dotfiles")[0]
                    if "Conflicting Dotfiles" in output
                    else output
                )

                for line in table_section.splitlines():
                    if any(c in line for c in ("╭", "┬", "├", "┼", "╰")):
                        continue
                    if "│" not in line:
                        continue

                    parts = [p.strip().lower() for p in line.split("│")]
                    for i, part in enumerate(parts):
                        if part == name_lower:
                            if i == 1:
                                return True, "symlinked"
                            elif i == 2:
                                return True, "not_symlinked"

                if "Conflicting Dotfiles" in output:
                    conflict_section = output.split("Conflicting Dotfiles")[1]
                    for line in conflict_section.splitlines():
                        if line.strip().lower() == name_lower:
                            return True, "conflicting"

        except (subprocess.SubprocessError, FileNotFoundError) as e:
            self.result["_debug_error"] = str(e)

        # Fallback: check for config file on disk
        config_dir = os.path.expanduser("~/.config/tuckr")
        config_file = os.path.join(config_dir, name)
        if os.path.exists(config_file):
            return True, "config_file"

        return False, None

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

    def run_command(
        self, cmd: List[str], check_mode: bool = False
    ) -> Tuple[int, str, str]:
        """Run a tuckr command and return (rc, stdout, stderr)"""
        if check_mode or self.check_mode:
            # In check mode, just simulate - don't actually run
            return (0, "[check mode] would execute: " + " ".join(cmd), "")

        # Ensure /usr/local/bin is in PATH (where tuckr is installed)
        env = os.environ.copy()
        if "/usr/local/bin" not in env.get("PATH", ""):
            env["PATH"] = "/usr/local/bin:" + env.get("PATH", "")

        proc = subprocess.run(
            cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env
        )
        return (proc.returncode, proc.stdout.strip(), proc.stderr.strip())

    def handle_add(self, name: str, force: bool, backup: bool) -> bool:
        """Handle the add command with retry logic"""
        dotfiles_root = os.path.expanduser("~/.config/dotfiles")
        if not os.path.exists(dotfiles_root):
            self.result["changed"] = False
            self.result["msg"] = f"Dotfiles root not found, skipping '{name}'"
            return True

        exists, config_info = self.config_exists(name)

        self.result["_debug"] = {
            "name": name,
            "exists": exists,
            "config_info": config_info,
            "dotfiles_root_exists": os.path.exists(dotfiles_root),
        }

        # Already fully symlinked — nothing to do
        if exists and config_info == "symlinked":
            self.result["changed"] = False
            self.result["msg"] = f"Config for '{name}' already symlinked"
            self.result["config"] = config_info
            return True

        # Determine base command (use --force only if user explicitly requested it)
        add_cmd = ["tuckr", "add", "-y", name]
        if force:
            add_cmd.insert(2, "--force")

        # Known to tuckr but not yet symlinked — real work pending
        if exists and config_info == "not_symlinked":
            if self.check_mode:
                self.result["changed"] = True
                self.result["msg"] = (
                    f"Would symlink '{name}' (registered but not symlinked)"
                )
                return True
            # fall through to tuckr add

        # Known to tuckr but conflicting files present
        if exists and config_info == "conflicting":
            if self.check_mode:
                self.result["changed"] = True
                self.result["msg"] = (
                    f"Would force-add '{name}' (conflicting dotfiles present)"
                )
                return True
            # fall through to tuckr add

        # Completely absent from tuckr
        if not exists:
            if self.check_mode:
                self.result["changed"] = True
                self.result["msg"] = f"Would add tuckr config for '{name}'"
                return True
            # fall through to tuckr add

        rc, stdout, stderr = self.run_command(add_cmd)

        if rc == 0:
            # Re-query status — tuckr exits 0 on no-ops so rc alone is not
            # a reliable changed signal
            _, after = self.config_exists(name)
            self.result["changed"] = config_info != after
            self.result["msg"] = (
                f"Successfully added tuckr config for '{name}'"
                if self.result["changed"]
                else f"No change after tuckr add for '{name}' (was: {config_info}, now: {after})"
            )
            return True

        conflicts = self.parse_conflicts(stdout)

        self.result.update(
            {"conflicts": conflicts, "stdout": stdout, "stderr": stderr, "rc": rc}
        )

        if conflicts and force:
            if backup:
                self.backup_files(conflicts)

            force_rc, force_stdout, force_stderr = self.run_command(
                ["tuckr", "add", "--force", "-y", name]
            )

            self.result.update(
                {
                    "force_stdout": force_stdout,
                    "force_stderr": force_stderr,
                    "force_rc": force_rc,
                }
            )

            if force_rc == 0:
                _, after = self.config_exists(name)
                self.result["changed"] = config_info != after
                self.result["msg"] = (
                    f"Successfully added tuckr config for '{name}' (forced)"
                    if self.result["changed"]
                    else f"No change after forced tuckr add for '{name}'"
                )
                return True
            else:
                self.result["msg"] = (
                    f"Force operation failed: {force_stderr or force_stdout}"
                )
                return True

        self.result["msg"] = stderr or stdout or "Unknown error"
        return False

    def handle_rm(self, name: str) -> bool:
        """Handle the rm command"""
        # Check if config exists - if not, no change needed
        exists, config_info = self.config_exists(name)
        if not exists:
            self.result["changed"] = False
            self.result["msg"] = f"Config for '{name}' does not exist"
            return True

        if self.check_mode:
            self.result["changed"] = True
            self.result["msg"] = f"Would remove tuckr config for '{name}'"
            return True

        rc, stdout, stderr = self.run_command(["tuckr", "rm", name])
        if rc != 0:
            self.module.warn(f"tuckr rm reported: {stderr or stdout}")
        self.result["changed"] = rc == 0
        self.result["msg"] = (
            f"Removed tuckr config for '{name}'"
            if rc == 0
            else f"Failed to remove config for '{name}'"
        )
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
        supports_check_mode=True,
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
