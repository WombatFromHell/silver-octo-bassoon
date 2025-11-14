#!/usr/bin/python3

import subprocess
from typing import Dict, List, Literal, Union

from ansible.module_utils.basic import AnsibleModule


def get_installed_flatpaks(scope: Literal["user", "system"]) -> List[str]:
    """Get list of installed Flatpak applications for a given scope (user/system)"""
    cmd = ["flatpak", "list", "--app", "--columns=application,installation"]
    result = subprocess.run(
        cmd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True
    )
    installed: List[str] = []
    for line in result.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2 and parts[1].strip() == scope:
            installed.append(parts[0].strip())  # app_id is first column
    return installed


def install_flatpak(
    module: AnsibleModule,
    app_id: str,
    scope: Literal["user", "system"],
    remote: str = "flathub",
) -> bool:
    """Install a Flatpak application"""
    if scope == "user":
        cmd = ["flatpak", "install", "--user", "-y", remote, app_id]
    else:
        cmd = ["flatpak", "install", "--system", "-y", remote, app_id]

    rc, _, err = module.run_command(cmd)
    if rc != 0:
        module.fail_json(msg=f"Failed to install {app_id}: {err}")
    return True


def uninstall_flatpak(
    module: AnsibleModule, app_id: str, scope: Literal["user", "system"]
) -> bool:
    """Uninstall a Flatpak application"""
    if scope == "user":
        cmd = ["flatpak", "uninstall", "--user", "-y", app_id]
    else:
        cmd = ["flatpak", "uninstall", "--system", "-y", app_id]

    rc, _, err = module.run_command(cmd)
    if rc != 0:
        module.fail_json(msg=f"Failed to uninstall {app_id}: {err}")
    return True


def run_module() -> None:
    module_args = dict(
        packages=dict(type="list", required=True),
        scope=dict(
            type="str", required=False, default="user", choices=["user", "system"]
        ),
        remote=dict(type="str", required=False, default="flathub"),
        state=dict(
            type="str", required=False, default="present", choices=["present", "absent"]
        ),
        remove_extra=dict(type="bool", required=False, default=False),
        skip_packages=dict(type="list", required=False, default=[]),
    )

    module = AnsibleModule(argument_spec=module_args, supports_check_mode=True)

    packages: List[str] = module.params["packages"]
    scope: Literal["user", "system"] = module.params["scope"]
    remote: str = module.params["remote"]
    state: Literal["present", "absent"] = module.params["state"]
    remove_extra: bool = module.params["remove_extra"]
    skip_packages: List[str] = module.params["skip_packages"]

    result: Dict[str, Union[bool, str, List[str]]] = {
        "changed": False,
        "message": "",
        "added": [],
        "removed": [],
        "kept": [],
        "skipped": [],
    }

    # Get currently installed packages
    installed: List[str] = get_installed_flatpaks(scope)

    to_add: List[str] = []
    to_remove: List[str] = []
    to_keep: List[str] = []
    to_skip: List[str] = []

    if state == "present":
        # Packages to add (present in desired but not in installed)
        to_add = [pkg for pkg in packages if pkg not in installed]

        # Packages to remove (present in installed but not in desired)
        if remove_extra:
            # Filter out skip_packages from removal list
            to_remove = [
                pkg
                for pkg in installed
                if pkg not in packages and pkg not in skip_packages
            ]
            # Track packages that would have been removed but were skipped
            to_skip = [
                pkg for pkg in installed if pkg not in packages and pkg in skip_packages
            ]
        else:
            to_keep = [pkg for pkg in installed if pkg not in packages]
    else:  # state == 'absent'
        # Only remove packages that are in both desired and installed, and not in skip_packages
        to_remove = [
            pkg for pkg in packages if pkg in installed and pkg not in skip_packages
        ]
        to_skip = [pkg for pkg in packages if pkg in installed and pkg in skip_packages]

    # Process changes
    if not module.check_mode:
        for pkg in to_add:
            if install_flatpak(module, pkg, scope, remote):
                result["added"].append(pkg)  # type: ignore

        for pkg in to_remove:
            if uninstall_flatpak(module, pkg, scope):
                result["removed"].append(pkg)  # type: ignore
    else:
        result["added"] = to_add
        result["removed"] = to_remove

    result["kept"] = to_keep
    result["skipped"] = to_skip

    if to_add or to_remove:
        result["changed"] = True
        msg_parts: List[str] = []
        if to_add:
            msg_parts.append(f"added {len(to_add)}")
        if to_remove:
            msg_parts.append(f"removed {len(to_remove)}")
        if to_keep:
            msg_parts.append(f"kept {len(to_keep)}")
        if to_skip:
            msg_parts.append(f"skipped {len(to_skip)}")
        result["message"] = "Packages " + ", ".join(msg_parts)
    else:
        result["message"] = "All packages are in the desired state"

    module.exit_json(**result)


def main() -> None:
    run_module()


if __name__ == "__main__":
    main()
