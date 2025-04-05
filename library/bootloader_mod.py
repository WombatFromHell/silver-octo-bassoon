#!/usr/bin/python
from ansible.module_utils.basic import AnsibleModule
from typing import Optional, Tuple, Dict
import os
import re
import shutil


def detect_bootloader() -> str:
    bootloader_type = "none"

    if os.path.exists("/boot/loader/entries/linux-cachyos.conf"):
        bootloader_type = "systemd-boot"
    elif os.path.exists("/boot/refind_linux.conf"):
        bootloader_type = "refind"
    elif os.path.exists("/etc/default/grub"):
        bootloader_type = "grub"

    return bootloader_type


def get_bootloader_config(
    bootloader_type: str, config_file: Optional[str] = None
) -> Optional[str]:
    if config_file is not None:
        return config_file

    config_files: Dict[str, str] = {
        "systemd-boot": "/boot/loader/entries/linux-cachyos.conf",
        "refind": "/boot/refind_linux.conf",
        "grub": "/etc/default/grub",
    }

    return config_files.get(bootloader_type)


def create_backup(module: AnsibleModule, config_file: str) -> bool:
    try:
        backup_file = config_file + ".bak"
        shutil.copy2(config_file, backup_file)
        return True
    except Exception as e:
        module.fail_json(msg=f"Failed to create backup: {str(e)}")
        return False


def write_config(
    module: AnsibleModule,
    config_file: str,
    content: str,
    backup_file: Optional[str] = None,
) -> bool:
    try:
        with open(config_file, "w") as f:
            f.write(content)
        return True
    except IOError as e:
        if backup_file:
            try:
                shutil.move(backup_file, config_file)
            except Exception:
                pass
        module.fail_json(msg=f"Failed to write config file: {str(e)}")
        return False


def update_grub_config(module: AnsibleModule, config_file: str) -> None:
    rc, _, err = module.run_command(f"grub-mkconfig -o {config_file}", check_rc=False)
    if rc != 0:
        module.warn("Failed to update grub config: " + err)


def modify_systemd_boot_config(
    content: str, text_to_add: Optional[str], text_to_remove: Optional[str]
) -> Tuple[str, bool]:
    needs_change = False
    new_content = content

    if text_to_remove and re.search(
        r"(^|\s)" + re.escape(text_to_remove) + r"(\s|$)", new_content
    ):
        needs_change = True
        new_content = re.sub(
            r"(^|\s)" + re.escape(text_to_remove) + r"(\s|$)",
            " ",
            new_content,
            flags=re.MULTILINE,
        )
        new_content = re.sub(r" +", " ", new_content)
        new_content = re.sub(r" $", "", new_content, flags=re.MULTILINE)

    if text_to_add:
        if re.search(r"^(options .*)", new_content, flags=re.MULTILINE):
            new_content = re.sub(
                r"^(options .*)", f"\\1 {text_to_add}", new_content, flags=re.MULTILINE
            )
        else:
            new_content += f"\noptions {text_to_add}\n"
        needs_change = True

    return new_content, needs_change


def modify_refind_config(
    content: str, text_to_add: Optional[str], text_to_remove: Optional[str]
) -> Tuple[str, bool]:
    needs_change = False
    new_lines: list[str] = []
    first_match_modified = False

    for line in content.split("\n"):
        if not line.strip() or line.strip().startswith("#"):
            new_lines.append(line)
            continue

        match = re.match(r'^(\s*"[^"]*"\s*)(.*)', line)
        if not match:
            new_lines.append(line)
            continue

        description, params = match.groups()
        original_params = params

        if not first_match_modified:
            if text_to_remove:
                params = re.sub(
                    r"(^|\s)" + re.escape(text_to_remove) + r"(\s|$)", " ", params
                )
                params = params.strip()

            if text_to_add and text_to_add not in params.split():
                params = f"{params} {text_to_add}".strip()

            if params != original_params:
                needs_change = True
                new_lines.append(f"{description}{params}")
                first_match_modified = True
                continue
            else:
                new_lines.append(line)
        else:
            new_lines.append(line)

    return "\n".join(new_lines), needs_change


def modify_grub_config(
    content: str, text_to_add: Optional[str], text_to_remove: Optional[str]
) -> Tuple[str, bool]:
    needs_change = False
    new_content = content

    def replace_or_add_grub_cmdline(text_to_replace, replacement):
        nonlocal new_content, needs_change
        regex = r'^(GRUB_CMDLINE_LINUX(_DEFAULT)?="[^"]*)'
        if re.search(regex, new_content, re.MULTILINE):
            new_content, count = re.subn(
                regex,
                replacement,
                new_content,
                count=1,
                flags=re.MULTILINE,
            )
            if count > 0:
                needs_change = True
            return True
        else:
            new_content += f'\nGRUB_CMDLINE_LINUX="{text_to_replace}"\n'
            needs_change = True
            return True

    if text_to_remove:
        regex_remove = r"(^|\s)" + re.escape(text_to_remove) + r"(\s|$)"

        def remove_from_grub_cmdline():
            nonlocal new_content, needs_change
            regex = r'^(GRUB_CMDLINE_LINUX(_DEFAULT)?="[^"]*)'
            match = re.search(regex, new_content, re.MULTILINE)
            if match:
                original_line = match.group(0)
                updated_line = re.sub(regex_remove, " ", original_line)
                updated_line = re.sub(r" +", " ", updated_line).strip()
                updated_line = updated_line.rstrip('"') + '"'
                new_content, count = re.subn(
                    regex, updated_line, new_content, count=1, flags=re.MULTILINE
                )
                if count > 0 and updated_line != original_line:
                    needs_change = True
                    return True
            return False

        remove_from_grub_cmdline()

    if text_to_add:

        def add_to_grub_cmdline():
            nonlocal new_content, needs_change
            regex = r'^(GRUB_CMDLINE_LINUX(_DEFAULT)?="[^"]*)'
            match = re.search(regex, new_content, re.MULTILINE)
            if match:
                current_value = match.group(1)
                if text_to_add not in current_value:
                    replacement = re.sub(r'(")$', f' {text_to_add}"', current_value)
                    new_content, count = re.subn(
                        regex, replacement, new_content, count=1, flags=re.MULTILINE
                    )
                    if count > 0:
                        needs_change = True
                        return True
            return False

        if not add_to_grub_cmdline():
            replace_or_add_grub_cmdline(
                text_to_add, f'GRUB_CMDLINE_LINUX="{text_to_add}"'
            )

    return new_content, needs_change


def modify_config(
    module: AnsibleModule,
    bootloader_type: str,
    text_to_add: Optional[str] = None,
    text_to_remove: Optional[str] = None,
    config_file: Optional[str] = None,
) -> Tuple[bool, str]:
    if not text_to_add and not text_to_remove:
        return False, "No text to add or remove provided"

    config_path = get_bootloader_config(bootloader_type, config_file)
    if not config_path:
        module.fail_json(msg="Could not determine config file path")
        return False, "Could not determine config file path"

    if not os.path.exists(config_path):
        module.fail_json(msg=f"Config file {config_path} does not exist")
        return False, f"Config file {config_path} does not exist"

    backup_file = config_path + ".bak"
    if os.path.exists(backup_file):
        module.fail_json(
            msg=f"Backup file {backup_file} already exists. Please remove it to proceed."
        )
        return False, f"Backup file {backup_file} already exists."

    try:
        with open(config_path, "r") as f:
            original_content = f.read()
    except IOError as e:
        module.fail_json(msg=f"Failed to read config file: {str(e)}")
        return False, f"Failed to read config file: {str(e)}"

    modifier_funcs = {
        "systemd-boot": modify_systemd_boot_config,
        "refind": modify_refind_config,
        "grub": modify_grub_config,
    }

    modifier_func = modifier_funcs.get(bootloader_type)
    if not modifier_func:
        module.fail_json(msg=f"Unsupported bootloader type: {bootloader_type}")
        return False, f"Unsupported bootloader type: {bootloader_type}"

    new_content, needs_change = modifier_func(
        original_content, text_to_add, text_to_remove
    )

    if not needs_change:
        return False, "No changes needed to bootloader configuration"

    if module.check_mode:
        return True, "Would update bootloader configuration"

    if not create_backup(module, config_path):
        return False, "Failed to create backup"

    if not write_config(module, config_path, new_content, config_path + ".bak"):
        return False, "Failed to write config file"

    if config_file is not None and bootloader_type == "grub":
        update_grub_config(module, config_file)

    return True, f"Updated {bootloader_type} configuration at {config_path}"


def check_kernel_args_exist(
    module: AnsibleModule,
    bootloader_type: str,
    kernel_args: str,
    config_file: Optional[str] = None,
) -> bool:
    config_path = get_bootloader_config(bootloader_type, config_file)
    if not config_path:
        module.fail_json(msg="Could not determine config file path")
        return False

    if not os.path.exists(config_path):
        module.fail_json(msg=f"Config file {config_path} does not exist")
        return False

    try:
        with open(config_path, "r") as f:
            content = f.read()
    except IOError as e:
        module.fail_json(msg=f"Failed to read config file: {str(e)}")
        return False

    if bootloader_type == "systemd-boot":
        return bool(
            re.search(r"options.*" + re.escape(kernel_args), content, re.IGNORECASE)
        )
    elif bootloader_type == "refind":
        for line in content.split("\n"):
            match = re.match(r'^(\s*"[^"]*"\s*)(.*)', line)
            if match:
                _, params = match.groups()
                if kernel_args in params:
                    return True
        return False
    elif bootloader_type == "grub":
        return bool(
            re.search(
                r'GRUB_CMDLINE_LINUX_DEFAULT=".*' + re.escape(kernel_args) + '.*"',
                content,
                re.IGNORECASE,
            )
        )
    else:
        module.fail_json(msg=f"Unsupported bootloader type: {bootloader_type}")
        return False


def main() -> None:
    module = AnsibleModule(
        argument_spec=dict(
            text_to_add=dict(type="str", required=False, default=None),
            text_to_remove=dict(type="str", required=False, default=None),
            detect_only=dict(type="bool", default=False),
            check_args=dict(type="str", required=False, default=None),
            bootloader=dict(
                type="str",
                choices=["auto", "systemd-boot", "refind", "grub"],
                default="auto",
            ),
            config_file=dict(type="str", default=None),
        ),
        supports_check_mode=True,
        required_one_of=[
            ["text_to_add", "text_to_remove", "detect_only", "check_args"]
        ],
    )

    bootloader_type_param = module.params["bootloader"]
    if bootloader_type_param == "auto":
        bootloader_type = detect_bootloader()
    else:
        bootloader_type = bootloader_type_param

    if bootloader_type == "none":
        module.fail_json(
            msg="No supported bootloader detected (systemd-boot, refind, or grub)"
        )
        return

    config_file = module.params["config_file"]

    if module.params["detect_only"]:
        module.exit_json(
            changed=False,
            bootloader_type=bootloader_type,
            config_file=get_bootloader_config(bootloader_type, config_file),
        )

    if module.params["check_args"]:
        args_exist = check_kernel_args_exist(
            module, bootloader_type, module.params["check_args"], config_file
        )
        module.exit_json(
            changed=False,
            bootloader_type=bootloader_type,
            config_file=get_bootloader_config(bootloader_type, config_file),
            args_exist=args_exist,
        )

    changed, message = modify_config(
        module,
        bootloader_type,
        module.params["text_to_add"],
        module.params["text_to_remove"],
        config_file,
    )

    module.exit_json(
        changed=changed,
        msg=message,
        bootloader_type=bootloader_type,
        config_file=get_bootloader_config(bootloader_type, config_file),
    )


if __name__ == "__main__":
    main()
