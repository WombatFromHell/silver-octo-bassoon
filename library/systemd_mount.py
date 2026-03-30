#!/usr/bin/python3

import glob
import hashlib
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


def files_are_identical(src, dst):
    """Check if two files have identical content using SHA256"""
    if not os.path.exists(src) or not os.path.exists(dst):
        return False
    
    def file_hash(filepath):
        sha256 = hashlib.sha256()
        with open(filepath, 'rb') as f:
            for block in iter(lambda: f.read(4096), b""):
                sha256.update(block)
        return sha256.hexdigest()
    
    return file_hash(src) == file_hash(dst)


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


def remove_existing_mounts(module):
    dst = "/etc/systemd/system"
    changed = False
    check_mode = module.check_mode

    # Process automounts first, then mounts, then swaps
    for unit_type in ["automount", "mount", "swap"]:
        for unit in glob.glob(f"{dst}/*mnt-*.{unit_type}"):
            unit_basename = os.path.basename(unit)

            try:
                if unit_exists(module, unit_basename):
                    if not check_mode:
                        if unit_type in ["automount", "swap"]:
                            run_systemctl(
                                module, "disable", f"--now {unit_basename}", check_rc=False
                            )
                        elif unit_type == "mount":
                            run_systemctl(module, "stop", unit_basename, check_rc=False)
                            run_systemctl(module, "disable", unit_basename, check_rc=False)
                    changed = True
            except Exception as e:
                module.warn(f"Failed to stop/disable unit {unit_basename}: {e}")

            if not check_mode:
                try:
                    os.remove(unit)
                    changed = True
                except Exception as e:
                    module.fail_json(msg=f"Failed to remove unit file: {unit} - {e}")
            else:
                # In check mode, just report that we would remove it
                changed = True

    if changed and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)

    return changed


def filter_mount_unit(module, tgt):
    basename = os.path.basename(tgt)

    if basename.endswith(".automount"):
        mount_file = tgt[: -len(".automount")] + ".mount"
        if os.path.isfile(mount_file) and check_mount_device(module, mount_file):
            return [basename, os.path.basename(mount_file)]
    elif basename.endswith(".swap"):
        if check_mount_device(module, tgt):
            return [basename]
    elif basename.endswith(".mount"):
        if check_mount_device(module, tgt):
            automount_file = tgt[: -len(".mount")] + ".automount"
            if os.path.isfile(automount_file):
                return [basename, os.path.basename(automount_file)]
            else:
                return [basename]

    return []


def setup_external_mounts(module):
    src = module.params["src"]
    dst = module.params["dst"]
    os_type = module.params["os_type"].lower()
    unit_files = []
    changed = False
    check_mode = module.check_mode

    if remove_existing_mounts(module):
        changed = True

    # Process all mount, automount, and swap files
    for unit_type in ["mount", "automount", "swap"]:
        for file in glob.glob(f"{src}/*mnt-*.{unit_type}"):
            enabled_units = filter_mount_unit(module, file)

            if not enabled_units:
                continue

            for basename in enabled_units:
                original_file = os.path.join(src, basename)

                if "bazzite" in os_type:
                    new_basename = f"var-{basename}"
                    dest_path = os.path.join(dst, new_basename)
                    
                    # Check if file already exists with same content
                    if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
                        # File exists and is identical, no change needed
                        unit_files.append(new_basename)
                        continue
                    
                    if not check_mode:
                        try:
                            with (
                                open(original_file, "r") as f_in,
                                tempfile.NamedTemporaryFile("w", delete=False) as f_out,
                            ):
                                for line in f_in:
                                    # Only replace /mnt/ with /var/mnt/ if the path doesn't already start with /var/mnt/
                                    if "/var/mnt/" not in line:
                                        f_out.write(line.replace("/mnt/", "/var/mnt/"))
                                    else:
                                        f_out.write(line)
                            shutil.copy(f_out.name, dest_path)
                            os.chmod(dest_path, 0o644)
                            os.unlink(f_out.name)
                            changed = True
                            unit_files.append(new_basename)
                        except Exception as e:
                            module.fail_json(
                                msg=f"Failed to process {original_file}: {str(e)}"
                            )
                    else:
                        changed = True
                        unit_files.append(new_basename)
                elif "arch" in os_type or "cachyos" in os_type:
                    dest_path = os.path.join(dst, basename)
                    
                    # Check if file already exists with same content
                    if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
                        # File exists and is identical, no change needed
                        unit_files.append(basename)
                        continue
                    
                    if not check_mode:
                        shutil.copy(original_file, dest_path)
                        changed = True
                        unit_files.append(basename)
                    else:
                        changed = True
                        unit_files.append(basename)
                else:
                    module.fail_json(
                        msg="Error: unsupported OS, skipping systemd mounts!"
                    )
                    return False

    if unit_files and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)
        changed = manage_systemd_units(module, unit_files, enable=True, start=True)

    return changed


def process_single_mount(module):
    src_dir = module.params["src_dir"]
    dst = module.params["dst"]
    os_type = module.params["os_type"].lower()
    mount_file = module.params["mount_file"]
    changed = False
    check_mode = module.check_mode
    unit_files = []

    mount_path = os.path.join(src_dir, mount_file)
    enabled_units = filter_mount_unit(module, mount_path)

    if not enabled_units:
        module.exit_json(
            changed=changed, msg=f"Mount file {mount_file} failed validation"
        )
        return False

    for basename in enabled_units:
        original_file = os.path.join(src_dir, basename)

        if "bazzite" in os_type:
            new_basename = f"var-{basename}"
            dest_path = os.path.join(dst, new_basename)
            
            # Check if file already exists with same content
            if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
                # File exists and is identical, no change needed
                unit_files.append(new_basename)
                continue
            
            if not check_mode:
                try:
                    with (
                        open(original_file, "r") as f_in,
                        tempfile.NamedTemporaryFile("w", delete=False) as f_out,
                    ):
                        for line in f_in:
                            # Only replace /mnt/ with /var/mnt/ if the path doesn't already start with /var/mnt/
                            if "/var/mnt/" not in line:
                                f_out.write(line.replace("/mnt/", "/var/mnt/"))
                            else:
                                f_out.write(line)
                    shutil.copy(f_out.name, dest_path)
                    os.chmod(dest_path, 0o644)
                    os.unlink(f_out.name)
                    changed = True
                    unit_files.append(new_basename)
                except Exception as e:
                    module.fail_json(msg=f"Failed to process {original_file}: {str(e)}")
            else:
                changed = True
                unit_files.append(new_basename)
        elif "arch" in os_type or "cachyos" in os_type:
            dest_path = os.path.join(dst, basename)
            
            # Check if file already exists with same content
            if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
                # File exists and is identical, no change needed
                unit_files.append(basename)
                continue
            
            if not check_mode:
                shutil.copy(original_file, dest_path)
                changed = True
                unit_files.append(basename)
            else:
                changed = True
                unit_files.append(basename)
        else:
            module.fail_json(msg="Error: unsupported OS, skipping systemd mount!")
            return False

    if unit_files and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)
        changed = manage_systemd_units(module, unit_files, enable=True, start=True)

    return module.exit_json(
        changed=changed,
        units_installed=unit_files,
        msg=f"Processed mount file {mount_file}",
    )


def process_single_swap(module):
    src_dir = module.params["src_dir"]
    dst = module.params["dst"]
    os_type = module.params["os_type"].lower()
    swap_file = module.params["swap_file"]
    changed = False
    check_mode = module.check_mode

    swap_path = os.path.join(src_dir, swap_file)
    enabled_units = filter_mount_unit(module, swap_path)

    if not enabled_units:
        module.exit_json(
            changed=changed, msg=f"Swap file {swap_file} failed validation"
        )
        return False

    basename = enabled_units[0]
    original_file = os.path.join(src_dir, basename)
    unit_files = []

    if "bazzite" in os_type:
        new_basename = f"var-{basename}"
        dest_path = os.path.join(dst, new_basename)
        
        # Check if file already exists with same content
        if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
            # File exists and is identical, no change needed
            unit_files.append(new_basename)
        elif not check_mode:
            try:
                with (
                    open(original_file, "r") as f_in,
                    tempfile.NamedTemporaryFile("w", delete=False) as f_out,
                ):
                    for line in f_in:
                        # Only replace /mnt/ with /var/mnt/ if the path doesn't already start with /var/mnt/
                        if "/var/mnt/" not in line:
                            f_out.write(line.replace("/mnt/", "/var/mnt/"))
                        else:
                            f_out.write(line)
                shutil.copy(f_out.name, dest_path)
                os.chmod(dest_path, 0o644)
                os.unlink(f_out.name)
                changed = True
                unit_files.append(new_basename)
            except Exception as e:
                module.fail_json(msg=f"Failed to process {original_file}: {str(e)}")
        else:
            changed = True
            unit_files.append(new_basename)
    elif "arch" in os_type or "cachyos" in os_type:
        dest_path = os.path.join(dst, basename)
        
        # Check if file already exists with same content
        if os.path.exists(dest_path) and files_are_identical(original_file, dest_path):
            # File exists and is identical, no change needed
            unit_files.append(basename)
        elif not check_mode:
            shutil.copy(original_file, dest_path)
            changed = True
            unit_files.append(basename)
        else:
            changed = True
            unit_files.append(basename)
    else:
        module.fail_json(msg="Error: unsupported OS, skipping systemd swap!")
        return False

    if unit_files and not check_mode:
        run_systemctl(module, "daemon-reload", unit=None, check_rc=True)
        changed = manage_systemd_units(module, [basename], enable=True, start=False)

    return module.exit_json(
        changed=changed,
        units_installed=[basename],
        msg=f"Processed swap file {swap_file}",
    )


def main():
    module_args = dict(
        src=dict(type="str", required=False),
        src_dir=dict(type="str", required=False),
        mount_file=dict(type="str", required=False),
        swap_file=dict(type="str", required=False),
        dst=dict(type="str", default="/etc/systemd/system"),
        os_type=dict(type="str", required=True),
        state=dict(type="str", default="present", choices=["present", "absent"]),
        mode=dict(
            type="str", default="all", choices=["all", "single_mount", "single_swap"]
        ),
    )

    module = AnsibleModule(argument_spec=module_args, supports_check_mode=True)

    mode = module.params["mode"]
    state = module.params["state"]

    if state == "absent":
        changed = remove_existing_mounts(module)
        module.exit_json(changed=changed)
    elif mode == "single_mount":
        if not module.params["mount_file"] or not module.params["src_dir"]:
            module.fail_json(
                msg="Parameters 'mount_file' and 'src_dir' are required for mode 'single_mount'"
            )
        process_single_mount(module)
    elif mode == "single_swap":
        if not module.params["swap_file"] or not module.params["src_dir"]:
            module.fail_json(
                msg="Parameters 'swap_file' and 'src_dir' are required for mode 'single_swap'"
            )
        process_single_swap(module)
    else:
        if not module.params["src"]:
            module.fail_json(msg="Parameter 'src' is required for mode 'all'")
        changed = setup_external_mounts(module)
        module.exit_json(changed=changed)


if __name__ == "__main__":
    main()
