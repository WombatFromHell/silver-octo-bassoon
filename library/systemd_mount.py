#!/usr/bin/python3

import glob
import os
import re
import shutil
import tempfile

from ansible.module_utils.basic import AnsibleModule


def run_systemctl(module, command, unit=None, check_rc=True):
    """
    Run a systemctl command and return result.

    Args:
        module (AnsibleModule): Ansible module object
        command (str): systemctl command (e.g., 'enable', 'start', 'stop', 'disable')
        unit (str): systemd unit name
        check_rc (bool): Whether to fail on non-zero return code

    Returns:
        dict: Result of the systemctl command
    """
    args = ["systemctl", command]
    if unit is not None:
        args.append(unit)

    rc, stdout, stderr = module.run_command(args, check_rc=check_rc)

    return {
        "rc": rc,
        "stdout": stdout,
        "stderr": stderr,
        "changed": rc == 0,
        "unit": unit,
        "command": " ".join(args),
        "failed": rc != 0,
    }


def manage_systemd_units(module, units, enable=True, start=True):
    """
    Manage (enable/start) a list of systemd units.

    Args:
        module (AnsibleModule): Ansible module object
        units (list): List of systemd unit names
        enable (bool): Whether to enable the units
        start (bool): Whether to start the units

    Returns:
        bool: Whether any changes occurred
    """
    changed = False

    for unit in units:
        if enable:
            # Check if already enabled
            rc, stdout, stderr = module.run_command(
                ["systemctl", "is-enabled", unit], check_rc=False
            )
            if rc != 0 or "enabled" not in stdout:
                result = run_systemctl(module, "enable", unit, check_rc=False)
                if result["changed"]:
                    changed = True

        if start and not unit.endswith(".automount"):
            # Check if already running (or will be at next boot)
            # For mount units, check if the mount point exists instead
            if unit.endswith(".mount"):
                # Extract mount path from unit name
                mount_path = "/" + unit.replace(".mount", "").replace("-", "/")
                rc, stdout, stderr = module.run_command(
                    ["findmnt", "--raw", "--noheadings", mount_path], check_rc=False
                )
                # If mount point doesn't exist, don't try to start (it's an automount scenario)
                if rc != 0:
                    continue
            else:
                rc, stdout, stderr = module.run_command(
                    ["systemctl", "is-active", unit], check_rc=False
                )
                if rc != 0 or "active" not in stdout:
                    result = run_systemctl(module, "start", unit, check_rc=False)
                    if result["changed"]:
                        changed = True

    return changed


def check_mount_device(module, mount_file):
    if not os.access(mount_file, os.R_OK) or not os.path.isfile(mount_file):
        module.fail_json(
            msg=f"Error: File '{mount_file}' does not exist or is unreadable!"
        )
        return False

    with open(mount_file, "r") as f:
        for line in f:
            if re.match(r"^\s*What=", line):
                device_path = line.split("=", 1)[1].strip()
                if device_path.startswith("//"):
                    return True
                if os.access(device_path, os.R_OK) or os.path.exists(device_path):
                    return True
                else:
                    return False

    module.fail_json(msg=f"Error: Could not find 'What=' line in {mount_file}!")
    return False


def unit_exists(module, unit_name):
    result = run_systemctl(
        module,
        "list-units",
        f"{unit_name} --all --no-legend --no-pager",
        check_rc=False,
    )
    if result["rc"] == 0 and result["stdout"].strip():
        for line in result["stdout"].strip().splitlines():
            if unit_name in line and line.endswith(unit_name.split(".")[-1] + "."):
                return True
    return False


def remove_existing_mounts(module, src_dir, base_path):
    dst = module.params.get("dst", "/etc/systemd/system")
    changed = False
    check_mode = module.check_mode

    # Only touch units this role's own source files would produce: render each
    # source file to its canonical dst name, then stop/disable + remove that file.
    for pattern in ["*.mount", "*.automount"]:
        for src in glob.glob(os.path.join(src_dir, pattern)):
            with open(src, "r") as f_src:
                _, new_basename = render_unit(f_src.read(), base_path, os.path.basename(src))
            unit_path = os.path.join(dst, new_basename)
            if not os.path.exists(unit_path):
                continue

            try:
                if unit_exists(module, new_basename):
                    if not check_mode:
                        if new_basename.endswith(".automount"):
                            run_systemctl(module, "disable", f"--now {new_basename}", check_rc=False)
                        else:
                            run_systemctl(module, "stop", new_basename, check_rc=False)
                            run_systemctl(module, "disable", new_basename, check_rc=False)
                if not check_mode:
                    os.remove(unit_path)
                changed = True
            except Exception as e:
                module.fail_json(msg=f"Failed to remove unit {new_basename}: {e}")

    if changed and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)

    return changed


def filter_mount_unit(module, tgt):
    basename = os.path.basename(tgt)

    if basename.endswith(".automount"):
        mount_file = tgt[: -len(".automount")] + ".mount"
        if os.path.isfile(mount_file) and check_mount_device(module, mount_file):
            return [basename, os.path.basename(mount_file)]
    elif basename.endswith(".mount"):
        if check_mount_device(module, tgt):
            automount_file = tgt[: -len(".mount")] + ".automount"
            if os.path.isfile(automount_file):
                return [basename, os.path.basename(automount_file)]
            else:
                return [basename]

    return []


def render_unit(text, base_path, basename):
    # ponytail: naive sed-style rewrite instead of ini parsing; safe because ALL mnt-*
    # units rename uniformly. Upgrade path: real [Mount] section parsing if exotic units appear.
    if base_path != "/mnt":
        # (?<!/var) keeps existing /var/mnt/ paths from becoming /var/var/mnt/
        text = re.sub(r"(?<!/var)/mnt/", base_path.rstrip("/") + "/", text)
        # sibling unit refs must follow the rename: Requires=mnt-x.mount -> Requires=var-mnt-x.mount
        text = re.sub(r"\bmnt-([\w.-]+\.(?:mount|automount))\b", r"var-mnt-\1", text)
    m = re.search(r"^Where=(.+)$", text, re.M)
    if m:
        # .mount/.automount unit names must equal their canonical Where= path
        suffix = basename.rsplit(".", 1)[1]
        name = m.group(1).strip().strip("/").replace("/", "-") + "." + suffix
    else:
        # swaps have no Where=; nothing couples a swap unit's name to a path
        name = f"var-{basename}" if base_path != "/mnt" else basename
    return text, name


def install_units(module, src_dir, basenames, dst, base_path, check_mode):
    """Render units via render_unit and install into dst; skips already-current content."""
    changed = False
    installed = []
    for basename in basenames:
        original_file = os.path.join(src_dir, basename)
        with open(original_file, "r") as f_in:
            text, new_basename = render_unit(f_in.read(), base_path, basename)
        dest_path = os.path.join(dst, new_basename)
        installed.append(new_basename)

        if os.path.exists(dest_path):
            with open(dest_path, "r") as f_dst:
                if f_dst.read() == text:
                    continue

        changed = True
        if not check_mode:
            try:
                with tempfile.NamedTemporaryFile("w", delete=False) as f_out:
                    f_out.write(text)
                shutil.copy(f_out.name, dest_path)
                os.chmod(dest_path, 0o644)
                os.unlink(f_out.name)
            except Exception as e:
                module.fail_json(msg=f"Failed to process {original_file}: {str(e)}")
    return changed, installed


def process_single_mount(module):
    src_dir = module.params["src_dir"]
    dst = module.params["dst"]
    base_path = module.params["base_path"]
    mount_file = module.params["mount_file"]
    changed = False
    check_mode = module.check_mode

    mount_path = os.path.join(src_dir, mount_file)
    enabled_units = filter_mount_unit(module, mount_path)

    if not enabled_units:
        module.exit_json(
            changed=changed, msg=f"Mount file {mount_file} failed validation"
        )
        return False

    changed, unit_files = install_units(
        module, src_dir, enabled_units, dst, base_path, check_mode
    )

    if unit_files and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)
        changed = manage_systemd_units(module, unit_files, enable=True, start=True)

    return module.exit_json(
        changed=changed,
        units_installed=unit_files,
        msg=f"Processed mount file {mount_file}",
    )


def main():
    module_args = dict(
        src_dir=dict(type="str", required=False),
        mount_file=dict(type="str", required=False),
        dst=dict(type="str", default="/etc/systemd/system"),
        base_path=dict(type="str", default="/mnt"),
        state=dict(type="str", default="present", choices=["present", "absent"]),
        mode=dict(type="str", default="single_mount", choices=["single_mount"]),
    )

    module = AnsibleModule(argument_spec=module_args, supports_check_mode=True)

    mode = module.params["mode"]
    state = module.params["state"]

    if state == "absent":
        if not module.params["src_dir"]:
            module.fail_json(msg="Parameter 'src_dir' is required for state 'absent'")
        changed = remove_existing_mounts(
            module, module.params["src_dir"], module.params["base_path"]
        )
        module.exit_json(changed=changed)
    elif mode == "single_mount":
        if not module.params["mount_file"] or not module.params["src_dir"]:
            module.fail_json(
                msg="Parameters 'mount_file' and 'src_dir' are required for mode 'single_mount'"
            )
        process_single_mount(module)


if __name__ == "__main__":
    main()
