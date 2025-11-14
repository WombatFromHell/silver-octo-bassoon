import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add the parent directory to sys.path so we can import the module
sys.path.insert(0, str(Path(__file__).parent.parent))

from tuckr_manage import TuckrManager, main


class TestTuckrManager:
    """Test the TuckrManager class"""

    def test_is_tuckr_available_success(self, mocker):
        """Test that TuckrManager detects tuckr when it's available"""
        mock_run = mocker.patch("tuckr_manage.subprocess.run")
        mock_proc = mocker.Mock()
        mock_proc.returncode = 0
        mock_proc.stdout = "tuckr version 1.0.0"
        mock_proc.stderr = ""
        mock_run.return_value = mock_proc

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.is_tuckr_available()

        assert result is True
        mock_run.assert_called_once_with(
            ["tuckr", "--version"],
            check=True,
            stdout=-1,
            stderr=-1,
        )

    def test_is_tuckr_available_failure(self, mocker):
        """Test that TuckrManager handles missing tuckr properly"""
        mock_run = mocker.patch("tuckr_manage.subprocess.run")
        mock_run.side_effect = FileNotFoundError()

        mock_module = mocker.Mock()
        # Make fail_json raise SystemExit as it does in real Ansible module
        mock_module.fail_json.side_effect = SystemExit

        manager = TuckrManager(mock_module)
        # This should call fail_json and cause SystemExit
        with pytest.raises(SystemExit):
            manager.is_tuckr_available()

    def test_parse_conflicts_empty_output(self, mocker):
        """Test parsing conflicts from empty output"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.parse_conflicts("")
        assert result == []

        result = manager.parse_conflicts(None)
        assert result == []

    def test_parse_conflicts_with_conflicts(self, mocker):
        """Test parsing conflicts from output with conflicts"""
        output = "file1.txt -> /home/user/.config/file1.txt (already exists)\nfile2.txt -> /home/user/.config/file2.txt"
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.parse_conflicts(output)
        assert "/home/user/.config/file1.txt" in result
        assert len(result) == 1  # Only the one with "already exists"

    def test_run_command(self, mocker):
        """Test running a tuckr command"""
        mock_run = mocker.patch("tuckr_manage.subprocess.run")
        mock_proc = mocker.Mock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Success"
        mock_proc.stderr = ""
        mock_run.return_value = mock_proc

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        rc, stdout, stderr = manager.run_command(["tuckr", "list"])

        assert rc == 0
        assert stdout == "Success"
        assert stderr == ""

    def test_backup_files(self, mocker):
        """Test backing up conflicting files"""
        mock_strftime = mocker.patch("tuckr_manage.time.strftime")
        mock_move = mocker.patch("tuckr_manage.shutil.move")
        mock_makedirs = mocker.patch("tuckr_manage.os.makedirs")
        mock_exists = mocker.patch("tuckr_manage.os.path.exists")

        mock_strftime.return_value = "20231201-120000"
        mock_exists.return_value = True

        conflicts = ["/home/user/.config/test.conf"]

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.backup_files(conflicts)

        assert result is True
        mock_makedirs.assert_called_once()
        mock_move.assert_called_once()

    def test_backup_files_no_conflicts(self, mocker):
        """Test backup with no conflicts"""
        mock_exists = mocker.patch("tuckr_manage.os.path.exists", return_value=False)

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.backup_files([])

        assert result is True  # Should succeed if no conflicts

    def test_handle_add_force_with_conflicts(self, mocker):
        """Test handling add command with force and conflicts"""
        # Mock all the required methods
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")

        # First call (normal add) fails with conflicts
        mock_run_command.return_value = (
            1,
            "file -> /path/file (already exists)",
            "error",
        )
        mock_parse_conflicts.return_value = ["/path/file"]
        mock_backup.return_value = True

        # Second call (force add) succeeds
        mock_subprocess = mocker.patch("tuckr_manage.subprocess.run")
        mock_proc = mocker.Mock()
        mock_proc.returncode = 0
        mock_proc.stdout = "Success"
        mock_proc.stderr = ""
        mock_subprocess.return_value = mock_proc

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.handle_add("test-package", force=True, backup=True)

        assert result is True

    def test_handle_rm_success(self, mocker):
        """Test handling rm command that succeeds"""
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (0, "Removed successfully", "")

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.handle_rm("test-package")

        assert result is True

    def test_handle_rm_failure(self, mocker):
        """Test handling rm command that fails"""
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (1, "", "error")

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.handle_rm("test-package")

        # handle_rm returns rc == 0, so with rc=1 it should return False
        assert result is False
        mock_module.warn.assert_called()  # warn should be called when there's an error

    def test_execute_present_success(self, mocker):
        """Test execute method with present state"""
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_handle_add = mocker.patch("tuckr_manage.TuckrManager.handle_add")

        mock_is_available.return_value = True
        mock_handle_add.return_value = True

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.execute("test-package", "present", False, True)

        # Check that handle_add was called with the right parameters
        mock_handle_add.assert_called_once_with("test-package", False, True)

    def test_execute_absent_success(self, mocker):
        """Test execute method with absent state"""
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_handle_rm = mocker.patch("tuckr_manage.TuckrManager.handle_rm")

        mock_is_available.return_value = True
        mock_handle_rm.return_value = True

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.execute("test-package", "absent", False, True)

        # The changed status depends on the handle_rm result
        mock_handle_rm.assert_called_once_with("test-package")


class TestTuckrModuleIntegration:
    """Integration tests for the tuckr module"""

    def test_tuckr_module_integration(self):
        """Test tuckr module integration"""
        # Verify the module can be imported and has the expected structure
        from tuckr_manage import main as tuckr_main

        assert callable(tuckr_main)

        # Verify the expected functions exist
        from tuckr_manage import TuckrManager

        assert TuckrManager is not None
