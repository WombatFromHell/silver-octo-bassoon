import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add the parent directory to sys.path so we can import the module
sys.path.insert(0, str(Path(__file__).parent.parent))

from systemd_mount import (
    check_mount_device,
    filter_mount_unit,
    main,
    manage_systemd_units,
    process_single_mount,
    process_single_swap,
    remove_existing_mounts,
    run_systemctl,
    setup_external_mounts,
    unit_exists,
)


class TestSystemctlOperations:
    """Test systemctl operation functions"""

    def test_run_systemctl_basic_command(self, mocker):
        """Test basic systemctl command execution"""
        mock_module = mocker.Mock()
        mock_module.run_command.return_value = (0, "output", "error")

        result = run_systemctl(mock_module, "status", "example.service")

        assert result["rc"] == 0
        assert result["stdout"] == "output"
        assert result["stderr"] == "error"
        assert result["changed"] is True
        assert result["unit"] == "example.service"
        assert result["command"] == "systemctl status example.service"
        assert result["failed"] is False

    def test_run_systemctl_no_unit(self, mocker):
        """Test systemctl command execution without unit"""
        mock_module = mocker.Mock()
        mock_module.run_command.return_value = (0, "output", "error")

        result = run_systemctl(mock_module, "daemon-reload")

        assert result["command"] == "systemctl daemon-reload"
        assert result["unit"] is None

    def test_run_systemctl_with_error(self, mocker):
        """Test systemctl command execution with error"""
        mock_module = mocker.Mock()
        mock_module.run_command.return_value = (1, "output", "error")

        result = run_systemctl(mock_module, "status", "example.service")

        assert result["rc"] == 1
        assert result["changed"] is False
        assert result["failed"] is True


class TestMountUnitManagement:
    """Test systemd mount unit management functions"""

    def test_manage_systemd_units_enable_only(self, mocker):
        """Test managing systemd units with enable only"""
        mock_module = mocker.Mock()
        mock_run_systemctl = mocker.patch("systemd_mount.run_systemctl")
        mock_run_systemctl.return_value = {"changed": True, "rc": 0}

        units = ["test.mount", "test2.mount"]
        changed = manage_systemd_units(mock_module, units, enable=True, start=False)

        assert changed is True
        assert mock_run_systemctl.call_count == len(units)  # Called once for each unit

    def test_manage_systemd_units_enable_and_start(self, mocker):
        """Test managing systemd units with both enable and start"""
        mock_module = mocker.Mock()
        mock_run_systemctl = mocker.patch("systemd_mount.run_systemctl")
        mock_run_systemctl.return_value = {"changed": True, "rc": 0}

        units = ["test.mount", "test2.automount"]
        changed = manage_systemd_units(mock_module, units, enable=True, start=True)

        # Enable should be called twice, start should not be called for .automount
        assert (
            mock_run_systemctl.call_count >= 2
        )  # At least 2 calls (enable for both units)

    def test_manage_systemd_units_start_only(self, mocker):
        """Test managing systemd units with start only"""
        mock_module = mocker.Mock()
        mock_run_systemctl = mocker.patch("systemd_mount.run_systemctl")
        mock_run_systemctl.return_value = {"changed": True, "rc": 0}

        units = ["test.mount"]
        changed = manage_systemd_units(mock_module, units, enable=False, start=True)

        # Only start should be called, not enable
        assert mock_run_systemctl.call_count == 1


class TestMountDeviceValidation:
    """Test mount device validation functions"""

    def test_check_mount_device_valid(self, temp_config_file, mocker):
        """Test checking a mount device that exists"""
        device_path = (
            "/dev/sda1"  # This is a common device that theoretically could exist
        )

        mocker.patch("systemd_mount.os.access", return_value=True)
        mocker.patch("systemd_mount.os.path.exists", return_value=True)

        with open(temp_config_file, "w") as f:
            f.write(f"[Unit]\nWhat={device_path}\n")

        mock_module = mocker.Mock()
        result = check_mount_device(mock_module, temp_config_file)
        assert result is True

    def test_check_mount_device_network_path(self, temp_config_file, mocker):
        """Test checking a network mount device (should return True)"""
        device_path = "//server/share"  # Network share

        with open(temp_config_file, "w") as f:
            f.write(f"[Unit]\nWhat={device_path}\n")

        mock_module = mocker.Mock()
        result = check_mount_device(mock_module, temp_config_file)
        assert result is True

    def test_check_mount_device_missing_what(self, temp_config_file, mocker):
        """Test checking a mount device when What= line is missing"""
        with open(temp_config_file, "w") as f:
            f.write("[Unit]\nDescription=Test mount\n")

        mock_module = mocker.Mock()
        result = check_mount_device(mock_module, temp_config_file)
        assert result is False
        mock_module.fail_json.assert_called_once()

    def test_check_mount_device_nonexistent(self, temp_config_file, mocker):
        """Test checking a mount device that doesn't exist"""
        device_path = "/dev/nonexistent"

        mocker.patch("systemd_mount.os.access", return_value=False)
        mocker.patch("systemd_mount.os.path.exists", return_value=False)

        with open(temp_config_file, "w") as f:
            f.write(f"[Unit]\nWhat={device_path}\n")

        mock_module = mocker.Mock()
        result = check_mount_device(mock_module, temp_config_file)
        assert result is False


class TestMountUnitFiltering:
    """Test unit filtering functions"""

    def test_filter_mount_unit_automount_with_mount(self, temp_dir, mocker):
        """Test filtering an automount unit with corresponding mount"""
        # Create a mount file that corresponds to the automount
        mount_file = os.path.join(temp_dir, "test.mount")
        automount_file = os.path.join(temp_dir, "test.automount")

        with open(mount_file, "w") as f:
            f.write("What=/dev/sda1\n")

        mocker.patch(
            "systemd_mount.os.path.isfile", side_effect=lambda x: x == mount_file
        )
        mocker.patch("systemd_mount.check_mount_device", return_value=True)

        mock_module = mocker.Mock()
        result = filter_mount_unit(mock_module, automount_file)
        assert len(result) == 2  # Both automount and mount should be included

    def test_filter_mount_unit_mount_with_automount(self, temp_dir, mocker):
        """Test filtering a mount unit with corresponding automount"""
        mount_file = os.path.join(temp_dir, "test.mount")
        automount_file = os.path.join(temp_dir, "test.automount")

        with open(mount_file, "w") as f:
            f.write("What=/dev/sda1\n")

        mocker.patch(
            "systemd_mount.os.path.isfile", side_effect=lambda x: x == automount_file
        )
        mocker.patch("systemd_mount.check_mount_device", return_value=True)

        mock_module = mocker.Mock()
        result = filter_mount_unit(mock_module, mount_file)
        assert len(result) == 2  # Both mount and automount should be included

    def test_filter_mount_unit_mount_only(self, temp_dir, mocker):
        """Test filtering a mount unit without automount"""
        mount_file = os.path.join(temp_dir, "test.mount")

        with open(mount_file, "w") as f:
            f.write("What=/dev/sda1\n")

        mocker.patch(
            "systemd_mount.os.path.isfile", return_value=False
        )  # No corresponding automount
        mocker.patch("systemd_mount.check_mount_device", return_value=True)

        mock_module = mocker.Mock()
        result = filter_mount_unit(mock_module, mount_file)
        assert result == ["test.mount"]  # Only the mount file


class TestMountUnitSetup:
    """Test mount unit setup functions"""

    def test_filter_mount_unit_swap(self, mocker, temp_dir):
        """Test filtering a swap unit"""
        mock_glob = mocker.patch("systemd_mount.glob.glob")
        swap_file = os.path.join(temp_dir, "test.swap")

        with open(swap_file, "w") as f:
            f.write("What=/dev/sda2\n")

        mocker.patch("systemd_mount.os.path.isfile", return_value=True)
        mocker.patch("systemd_mount.check_mount_device", return_value=True)

        mock_module = mocker.Mock()
        result = filter_mount_unit(mock_module, swap_file)
        assert result == ["test.swap"]  # Should return the swap file


class TestSystemdMountModuleIntegration:
    """Integration tests for the systemd mount module"""

    def test_systemd_mount_module_integration(self):
        """Test systemd mount module integration"""
        # Verify the module can be imported and has the expected structure
        from systemd_mount import main as systemd_main

        assert callable(systemd_main)

        # Verify the expected functions exist
        from systemd_mount import manage_systemd_units, run_systemctl

        assert callable(run_systemctl)
        assert callable(manage_systemd_units)
