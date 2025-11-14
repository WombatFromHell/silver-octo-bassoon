import os
import tempfile

import pytest

from bootloader_mod import (
    check_kernel_args_exist,
    create_backup,
    detect_bootloader,
    get_bootloader_config,
    main,
    modify_config,
    modify_grub_config,
    modify_refind_config,
    modify_systemd_boot_config,
    update_grub_config,
    write_config,
)


class TestBootloaderDetection:
    """Test bootloader detection functions"""

    def test_detect_bootloader_systemd_boot(self, mocker):
        """Test detection of systemd-boot bootloader"""
        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.return_value = True
        result = detect_bootloader()
        assert result == "systemd-boot"

    def test_detect_bootloader_refind(self, mocker):
        """Test detection of refind bootloader"""
        # First call to /boot/loader/entries/linux-cachyos.conf returns False
        # Second call to /boot/refind_linux.conf returns True
        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.side_effect = [False, True, False]  # systemd-boot, refind, grub
        result = detect_bootloader()
        assert result == "refind"

    def test_detect_bootloader_grub(self, mocker):
        """Test detection of GRUB bootloader"""
        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.side_effect = [False, False, True]  # systemd-boot, refind, grub
        result = detect_bootloader()
        assert result == "grub"

    def test_detect_bootloader_none(self, mocker):
        """Test detection when no bootloader is found"""
        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.return_value = False
        result = detect_bootloader()
        assert result == "none"

    def test_get_bootloader_config_with_custom_file(self):
        """Test getting custom config file"""
        custom_file = "/custom/path/config"
        result = get_bootloader_config("systemd-boot", custom_file)
        assert result == custom_file

    def test_get_bootloader_config_systemd_boot(self):
        """Test getting default systemd-boot config file"""
        result = get_bootloader_config("systemd-boot")
        assert result == "/boot/loader/entries/linux-cachyos.conf"

    def test_get_bootloader_config_refind(self):
        """Test getting default refind config file"""
        result = get_bootloader_config("refind")
        assert result == "/boot/refind_linux.conf"

    def test_get_bootloader_config_grub(self):
        """Test getting default grub config file"""
        result = get_bootloader_config("grub")
        assert result == "/etc/default/grub"


class TestBootloaderConfigModification:
    """Test configuration modification functions"""

    def test_modify_systemd_boot_config_add_option(self):
        """Test adding an option to systemd-boot config"""
        content = "title    Arch Linux\nlinux    /vmlinuz-linux\nefi      /EFI/Linux/arch-stable.efi\noptions  root=PARTUUID=12345 ro"
        new_content, needs_change = modify_systemd_boot_config(content, "quiet", None)
        assert "quiet" in new_content
        assert needs_change is True

    def test_modify_systemd_boot_config_remove_option(self):
        """Test removing an option from systemd-boot config"""
        content = "title    Arch Linux\nlinux    /vmlinuz-linux\nefi      /EFI/Linux/arch-stable.efi\noptions  root=PARTUUID=12345 ro quiet"
        new_content, needs_change = modify_systemd_boot_config(content, None, "quiet")
        assert "quiet" not in new_content
        assert needs_change is True

    def test_modify_systemd_boot_config_no_change_needed(self):
        """Test when no changes are needed to systemd-boot config"""
        content = "title    Arch Linux\nlinux    /vmlinuz-linux\nefi      /EFI/Linux/arch-stable.efi\noptions  root=PARTUUID=12345 ro"
        new_content, needs_change = modify_systemd_boot_config(content, None, "quiet")
        assert new_content == content
        assert needs_change is False

    def test_modify_refind_config_add_option(self):
        """Test adding an option to refind config"""
        content = '"Boot with standard options" "root=PARTUUID=12345 ro"\n"Boot with fallback initramfs" "root=PARTUUID=12345 ro initramfs-linux-fallback.img"'
        new_content, needs_change = modify_refind_config(content, "quiet", None)
        assert "quiet" in new_content
        assert needs_change is True

    def test_modify_refind_config_remove_option(self):
        """Test removing an option from refind config"""
        content = '"Boot with standard options" "root=PARTUUID=12345 ro quiet"\n"Boot fallback" "root=PARTUUID=12345 ro"'
        new_content, needs_change = modify_refind_config(content, None, "quiet")
        # The "quiet" parameter should be removed from the first matching line
        assert "quiet" not in new_content or new_content.count("quiet") < content.count(
            "quiet"
        )
        assert needs_change is True

    def test_modify_grub_config_add_option(self):
        """Test adding an option to GRUB config"""
        content = (
            'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
        )
        new_content, needs_change = modify_grub_config(
            content, "intel_pstate=disable", None
        )
        assert "intel_pstate=disable" in new_content
        assert needs_change is True

    def test_modify_grub_config_remove_option(self):
        """Test removing an option from GRUB config"""
        content = 'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash mitigations=auto"'
        new_content, needs_change = modify_grub_config(
            content, None, "mitigations=auto"
        )
        assert "mitigations=auto" not in new_content
        assert needs_change is True


class TestBootloaderFileOperations:
    """Test file operation functions"""

    def test_create_backup_success(self, mocker):
        """Test that backup creation works successfully"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock shutil.copy2 using mocker
        mock_copy = mocker.patch("bootloader_mod.shutil.copy2")
        config_file = "/boot/loader/entries/linux-cachyos.conf"
        result = create_backup(mock_module, config_file)
        assert result is True
        mock_copy.assert_called_once_with(config_file, config_file + ".bak")

    def test_create_backup_failure(self, mocker):
        """Test that backup creation handles exceptions properly"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock shutil.copy2 using mocker
        mock_copy = mocker.patch("bootloader_mod.shutil.copy2")
        mock_copy.side_effect = Exception("Permission denied")

        with pytest.raises(SystemExit):
            create_backup(mock_module, "/boot/loader/entries/linux-cachyos.conf")

        mock_module.fail_json.assert_called_once()

    def test_write_config_success(self, mocker):
        """Test that config writing works successfully"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock builtins.open using mocker
        mock_file = mocker.mock_open(read_data="title Arch Linux\nlinux /vmlinuz-linux")
        mocker.patch("builtins.open", mock_file)

        config_file = "/boot/loader/entries/linux-cachyos.conf"
        content = "title Arch Linux\nlinux /vmlinuz-linux"

        result = write_config(mock_module, config_file, content)
        assert result is True
        mock_file.assert_called_once_with(config_file, "w")
        mock_file().write.assert_called_once_with(content)

    def test_write_config_failure(self, mocker):
        """Test that config writing handles exceptions properly"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock builtins.open to raise an exception
        mocker.patch("builtins.open", side_effect=IOError("Permission denied"))

        with pytest.raises(SystemExit):
            write_config(
                mock_module, "/boot/loader/entries/linux-cachyos.conf", "content"
            )

    def test_update_grub_config(self, mocker):
        """Test updating GRUB config"""
        mock_module = mocker.Mock()
        mock_module.run_command.return_value = (0, "", "")

        # Mock AnsibleModule class to return our mock module
        mocker.patch("bootloader_mod.AnsibleModule", return_value=mock_module)

        update_grub_config(mock_module, "/boot/grub/grub.cfg")
        mock_module.run_command.assert_called_once_with(
            ["grub-mkconfig", "-o", "/boot/grub/grub.cfg"], check_rc=False
        )


class TestKernelArgsCheck:
    """Test kernel arguments checking functions"""

    def test_check_kernel_args_exist_systemd_boot(self, temp_config_file, mocker):
        """Test checking for kernel args in systemd-boot config"""
        with open(temp_config_file, "w") as f:
            f.write(
                "title    Arch Linux\nlinux    /vmlinuz-linux\nefi      /EFI/Linux/arch-stable.efi\noptions  root=PARTUUID=12345 ro quiet splash"
            )

        mock_module = mocker.Mock()
        mock_module.fail_json = mocker.Mock()
        result = check_kernel_args_exist(
            mock_module, "systemd-boot", "quiet", temp_config_file
        )
        assert result is True

    def test_check_kernel_args_not_exist_systemd_boot(self, temp_config_file, mocker):
        """Test checking for non-existent kernel args in systemd-boot config"""
        with open(temp_config_file, "w") as f:
            f.write(
                "title    Arch Linux\nlinux    /vmlinuz-linux\nefi      /EFI/Linux/arch-stable.efi\noptions  root=PARTUUID=12345 ro"
            )

        mock_module = mocker.Mock()
        mock_module.fail_json = mocker.Mock()
        result = check_kernel_args_exist(
            mock_module, "systemd-boot", "quiet", temp_config_file
        )
        assert result is False

    def test_check_kernel_args_exist_grub(self, temp_config_file, mocker):
        """Test checking for kernel args in GRUB config"""
        with open(temp_config_file, "w") as f:
            f.write(
                'GRUB_DEFAULT=0\nGRUB_TIMEOUT=5\nGRUB_CMDLINE_LINUX_DEFAULT="quiet splash"'
            )

        mock_module = mocker.Mock()
        mock_module.fail_json = mocker.Mock()
        result = check_kernel_args_exist(mock_module, "grub", "quiet", temp_config_file)
        assert result is True


class TestModifyConfig:
    """Test the main modify_config function"""

    def test_modify_config_no_change_needed(self, mocker):
        """Test that modify_config returns False when no changes are needed"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock the required functions and methods
        mock_backup = mocker.patch("bootloader_mod.create_backup")
        mock_write_config = mocker.patch("bootloader_mod.write_config")
        mock_file = mocker.mock_open(
            read_data="title Arch Linux\noptions root=PARTUUID=12345 ro"
        )
        mocker.patch("builtins.open", mock_file)

        # Mock os.path.exists
        def exists_side_effect(path):
            if path.endswith(".bak"):
                return False  # Backup file doesn't exist
            else:
                return True  # Main config file exists

        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.side_effect = exists_side_effect
        mock_backup.return_value = True
        mock_write_config.return_value = True

        # Test with not providing add or remove (no operation requested)
        changed, message = modify_config(
            mock_module,
            "systemd-boot",
            text_to_add=None,  # No text to add
            text_to_remove=None,  # No text to remove
        )
        assert changed is False
        assert "No text to add or remove provided" in message

    def test_modify_config_with_changes(self, mocker):
        """Test that modify_config returns True when changes are made"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock os.path.exists
        def exists_side_effect(path):
            if path.endswith(".bak"):
                return False  # Backup file doesn't exist
            else:
                return True  # Main config file exists

        mock_exists = mocker.patch("bootloader_mod.os.path.exists")
        mock_exists.side_effect = exists_side_effect

        # Mock builtins.open
        mock_file = mocker.mock_open(
            read_data="title Arch Linux\noptions root=PARTUUID=12345 ro"
        )
        mocker.patch("builtins.open", mock_file)

        # Mock the required functions
        mocker.patch("bootloader_mod.create_backup", return_value=True)
        mocker.patch("bootloader_mod.write_config", return_value=True)

        changed, message = modify_config(
            mock_module,
            "systemd-boot",
            text_to_add="quiet",  # New option
            text_to_remove=None,
        )
        assert changed is True
        assert "Updated systemd-boot configuration" in message

    def test_modify_config_missing_config_file(self, mocker):
        """Test that modify_config fails when config file doesn't exist"""
        # Create a mock Ansible module using mocker
        mock_module = mocker.Mock()
        mock_module.params = {}
        mock_module.check_mode = False
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_module.exit_json = mocker.Mock()
        mock_module.warn = mocker.Mock()
        mock_module.run_command = mocker.Mock(return_value=(0, "", ""))

        # Mock os.path.exists to return False (file doesn't exist)
        mocker.patch("bootloader_mod.os.path.exists", return_value=False)

        with pytest.raises(SystemExit):
            modify_config(
                mock_module, "systemd-boot", text_to_add="quiet", text_to_remove=None
            )
        mock_module.fail_json.assert_called_once()


class TestBootloaderModuleIntegration:
    """Integration tests for the bootloader module"""

    def test_bootloader_module_integration(self):
        """Test bootloader module integration"""
        # Verify the module can be imported and has the expected structure
        from bootloader_mod import main as bootloader_main

        assert callable(bootloader_main)

        # Verify the expected functions exist
        from bootloader_mod import detect_bootloader, modify_config

        assert callable(detect_bootloader)
        assert callable(modify_config)
