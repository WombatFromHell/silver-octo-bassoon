import os
import sys
from pathlib import Path

import pytest

# Add the parent directory to sys.path so we can import the module
sys.path.insert(0, str(Path(__file__).parent.parent))

from tuckr_manage import TuckrManager


class TestTuckrManager:
    """Test the TuckrManager class"""

    @pytest.mark.parametrize(
        "run_side_effect,expected_result,should_raise_exception",
        [
            ((0, "tuckr version 1.0.0", ""), True, False),  # Success case
            (FileNotFoundError(), None, True),  # Failure case that raises exception
        ],
    )
    def test_is_tuckr_available_parametrized(
        self, mocker, run_side_effect, expected_result, should_raise_exception
    ):
        """Test that TuckrManager detects tuckr availability in different scenarios"""
        if should_raise_exception:
            # Test failure case
            mock_run = mocker.patch("tuckr_manage.subprocess.run")
            mock_run.side_effect = run_side_effect

            mock_module = mocker.Mock()
            # Make fail_json raise SystemExit as it does in real Ansible module
            mock_module.fail_json.side_effect = SystemExit

            manager = TuckrManager(mock_module)
            # This should call fail_json and cause SystemExit
            with pytest.raises(SystemExit):
                manager.is_tuckr_available()
        else:
            # Test success case
            returncode, stdout, stderr = run_side_effect
            mock_proc = mocker.Mock()
            mock_proc.returncode = returncode
            mock_proc.stdout = stdout
            mock_proc.stderr = stderr

            mock_run = mocker.patch("tuckr_manage.subprocess.run")
            mock_run.return_value = mock_proc

            mock_module = mocker.Mock()
            manager = TuckrManager(mock_module)
            result = manager.is_tuckr_available()

            assert result is expected_result
            mock_run.assert_called_once_with(
                ["tuckr", "--version"],
                check=True,
                stdout=-1,
                stderr=-1,
            )

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
        _mock_exists = mocker.patch("tuckr_manage.os.path.exists", return_value=False)

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

    @pytest.mark.parametrize(
        "rc,stdout,stderr,expected_result",
        [
            (0, "Removed successfully", "", True),  # Success case
            (1, "", "error", False),  # Failure case
        ],
    )
    def test_handle_rm_parametrized(self, mocker, rc, stdout, stderr, expected_result):
        """Test handling rm command for both success and failure scenarios"""
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (rc, stdout, stderr)

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        result = manager.handle_rm("test-package")

        assert result is expected_result
        if not expected_result:
            mock_module.warn.assert_called()  # warn should be called when there's an error

    def test_execute_present_success(self, mocker):
        """Test execute method with present state"""
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_handle_add = mocker.patch("tuckr_manage.TuckrManager.handle_add")

        mock_is_available.return_value = True
        mock_handle_add.return_value = True

        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)
        _result = manager.execute("test-package", "present", False, True)

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
        _result = manager.execute("test-package", "absent", False, True)

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


class TestMissingCoverage:
    """Test cases to cover previously untested functionality"""

    def test_is_tuckr_available_subprocess_exception(self, mocker):
        """Test TuckrManager.is_tuckr_available with subprocess exception"""
        mock_module = mocker.Mock()
        mock_module.fail_json.side_effect = SystemExit("Module failed")

        manager = TuckrManager(mock_module)

        # Mock subprocess.run to raise an exception
        mock_run = mocker.patch("tuckr_manage.subprocess.run")
        mock_run.side_effect = FileNotFoundError("tuckr not found")

        # This should cause fail_json to be called and raise SystemExit
        with pytest.raises(SystemExit):
            manager.is_tuckr_available()

    def test_parse_conflicts_none_output(self, mocker):
        """Test TuckrManager.parse_conflicts with None output"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        result = manager.parse_conflicts(None)
        assert result == []

    def test_parse_conflicts_complex_output(self, mocker):
        """Test TuckrManager.parse_conflicts with more complex output"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        output = """file1.txt -> /home/user/.config/file1.txt (already exists)
file2.txt -> /home/user/.config/file2.txt (already exists)
some other output without conflict
file3.txt -> /home/user/.config/file3.txt"""

        result = manager.parse_conflicts(output)
        assert "/home/user/.config/file1.txt" in result
        assert "/home/user/.config/file2.txt" in result
        assert "/home/user/.config/file3.txt" not in result  # No "(already exists)" tag
        assert len(result) == 2

    def test_backup_files_functionality(self, mocker, temp_dir):
        """Test TuckrManager.backup_files functionality"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Create test files
        test_file = os.path.join(temp_dir, "test.conf")
        with open(test_file, "w") as f:
            f.write("test content")

        conflicts = [test_file]  # List of files to backup

        # Mock time.strftime to return a consistent timestamp
        mock_time = mocker.patch("tuckr_manage.time.strftime")
        mock_time.return_value = "20231201-120000"

        # Mock shutil.move and os.makedirs
        mock_move = mocker.patch("tuckr_manage.shutil.move")
        mock_makedirs = mocker.patch("tuckr_manage.os.makedirs")

        result = manager.backup_files(conflicts)
        assert result is True
        mock_makedirs.assert_called_once()
        mock_move.assert_called_once()

    def test_backup_files_no_conflicts(self, mocker):
        """Test TuckrManager.backup_files with no conflicts"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        result = manager.backup_files([])  # Empty conflicts list
        assert result is True

    def test_backup_files_with_exception(self, mocker, temp_dir):
        """Test TuckrManager.backup_files when an exception occurs"""
        mock_module = mocker.Mock()
        mock_module.warn = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Create test files
        test_file = os.path.join(temp_dir, "test.conf")
        with open(test_file, "w") as f:
            f.write("test content")

        conflicts = [test_file]  # List of files to backup

        # Mock time.strftime to return a consistent timestamp
        mock_time = mocker.patch("tuckr_manage.time.strftime")
        mock_time.return_value = "20231201-120000"

        # Mock shutil.move to raise an exception
        mock_move = mocker.patch("tuckr_manage.shutil.move")
        mock_move.side_effect = Exception("Permission denied")

        # Mock os.makedirs
        _mock_makedirs = mocker.patch("tuckr_manage.os.makedirs")

        result = manager.backup_files(conflicts)
        assert result is False  # Should return False on exception
        mock_module.warn.assert_called()  # Should warn about the failure

    def test_handle_add_with_force_and_conflicts_success(self, mocker):
        """Test TuckrManager.handle_add with force=True and conflicts that get resolved"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the first run_command to fail with conflicts
        normal_call_result = (1, "file -> /path/file (already exists)", "error")

        # Mock the forced run_command to succeed
        def side_effect(cmd):
            if "--force" in cmd:
                return (0, "Force add succeeded", "")
            else:
                return normal_call_result

        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.side_effect = side_effect

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = ["/path/file"]

        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")
        mock_backup.return_value = True

        result = manager.handle_add("test-package", force=True, backup=True)
        assert result is True
        # Verify backup was called because there were conflicts and force was True
        mock_backup.assert_called_once()

    def test_handle_add_with_force_and_backup_false(self, mocker):
        """Test TuckrManager.handle_add with force=True but backup=False"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the first run_command to fail with conflicts
        normal_call_result = (1, "file -> /path/file (already exists)", "error")

        # Mock the forced run_command to succeed
        def side_effect(cmd):
            if "--force" in cmd:
                return (0, "Force add succeeded", "")
            else:
                return normal_call_result

        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.side_effect = side_effect

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = ["/path/file"]

        # Should not call backup when backup=False
        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")

        result = manager.handle_add("test-package", force=True, backup=False)
        assert result is True
        # Verify backup was not called when backup=False
        mock_backup.assert_not_called()

    def test_handle_add_force_operation_fails(self, mocker):
        """Test TuckrManager.handle_add when force operation also fails"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the first run_command to fail with conflicts
        normal_call_result = (1, "file -> /path/file (already exists)", "error")

        # Mock the forced run_command to also fail
        def side_effect(cmd):
            if "--force" in cmd:
                return (1, "", "Force operation failed")  # Force operation also fails
            else:
                return normal_call_result

        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.side_effect = side_effect

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = ["/path/file"]

        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")
        mock_backup.return_value = True

        result = manager.handle_add("test-package", force=True, backup=True)
        assert (
            result is True
        )  # Function returns True even if force fails (not considered a module failure)
        # The function updates manager.result with the failure information

    def test_execute_method_with_state_absent(self, mocker):
        """Test TuckrManager.execute with state='absent'"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock is_tuckr_available to return True
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_is_available.return_value = True

        # Mock handle_rm
        mock_handle_rm = mocker.patch("tuckr_manage.TuckrManager.handle_rm")
        mock_handle_rm.return_value = True  # Simulate successful removal

        result = manager.execute("test-package", "absent", force=False, backup=True)

        # The result should contain the updated result dict
        assert result is manager.result
        mock_handle_rm.assert_called_once_with("test-package")

    def test_execute_with_force_and_backup(self, mocker):
        """Test TuckrManager.execute with force and backup parameters"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock is_tuckr_available to return True
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_is_available.return_value = True

        # Mock handle_add
        mock_handle_add = mocker.patch("tuckr_manage.TuckrManager.handle_add")
        mock_handle_add.return_value = True

        _result = manager.execute("test-package", "present", force=True, backup=True)

        # Verify handle_add was called with correct parameters
        mock_handle_add.assert_called_once_with("test-package", True, True)

    def test_execute_with_tuckr_not_available(self, mocker):
        """Test TuckrManager.execute when tuckr is not available"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock is_tuckr_available to return False and call fail_json
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_is_available.return_value = (
            False  # This should not happen since it would exit
        )

        # Actually, is_tuckr_available would call fail_json and exit, so let's simulate that
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)
        mock_is_available_with_exit = mocker.patch(
            "tuckr_manage.TuckrManager.is_tuckr_available"
        )
        mock_is_available_with_exit.side_effect = SystemExit  # Simulate exit behavior

        manager = TuckrManager(mock_module)

        # This should cause an exit
        with pytest.raises(SystemExit):
            manager.execute("test-package", "present", force=False, backup=True)

    def test_run_command_with_different_return_values(self, mocker):
        """Test TuckrManager.run_command with different subprocess return values"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock subprocess.run to return different values
        mock_proc = mocker.Mock()
        mock_proc.returncode = 1  # Error return code
        mock_proc.stdout = "Error output"
        mock_proc.stderr = "Error details"
        mock_subprocess = mocker.patch("tuckr_manage.subprocess.run")
        mock_subprocess.return_value = mock_proc

        rc, stdout, stderr = manager.run_command(["tuckr", "nonexistent-cmd"])
        assert rc == 1
        assert stdout == "Error output"
        assert stderr == "Error details"

    def test_handle_add_with_backup_false_and_conflicts(self, mocker):
        """Test TuckrManager.handle_add with backup=False and conflicts"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the first run_command to fail with conflicts
        normal_call_result = (1, "file -> /path/file (already exists)", "error")

        # Mock the forced run_command to succeed
        def side_effect(cmd):
            if "--force" in cmd:
                return (0, "Force add succeeded", "")
            else:
                return normal_call_result

        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.side_effect = side_effect

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = ["/path/file"]

        # Should not call backup when backup=False
        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")

        # Test the handle_add method directly
        result = manager.handle_add("test-package", force=True, backup=False)
        assert result is True  # Should succeed since force operation succeeded
        # Verify backup was not called when backup=False
        mock_backup.assert_not_called()

    def test_handle_add_force_fails_with_conflicts(self, mocker):
        """Test TuckrManager.handle_add when force operation also fails"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the first run_command to fail with conflicts
        normal_call_result = (1, "file -> /path/file (already exists)", "error")

        # Mock the forced run_command to also fail
        def side_effect(cmd):
            if "--force" in cmd:
                return (1, "", "Force operation failed")  # Force operation also fails
            else:
                return normal_call_result

        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.side_effect = side_effect

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = ["/path/file"]

        mock_backup = mocker.patch("tuckr_manage.TuckrManager.backup_files")
        mock_backup.return_value = True

        result = manager.handle_add("test-package", force=True, backup=True)
        assert result is True  # Function returns True even if force fails
        # The function updates manager.result with the failure information

    def test_handle_add_no_conflicts_and_no_force(self, mocker):
        """Test TuckrManager.handle_add with no conflicts and force disabled"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock the run_command to fail without conflicts
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (1, "some error", "error message")

        mock_parse_conflicts = mocker.patch("tuckr_manage.TuckrManager.parse_conflicts")
        mock_parse_conflicts.return_value = []  # No conflicts found

        result = manager.handle_add("test-package", force=False, backup=True)
        assert (
            result is False
        )  # Should return False when no conflicts but force disabled

    def test_handle_rm_with_error(self, mocker):
        """Test TuckrManager.handle_rm when tuckr command fails"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock run_command to return error
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (1, "", "error message")

        # Mock warn to verify it gets called
        mock_module.warn = mocker.Mock()

        result = manager.handle_rm("test-package")
        assert result is False  # Should return False on error
        assert manager.result["changed"] is False  # Changed should be False
        mock_module.warn.assert_called_once()  # Should call warn with error

    def test_handle_rm_success(self, mocker):
        """Test TuckrManager.handle_rm when tuckr command succeeds"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock run_command to return success
        mock_run_command = mocker.patch("tuckr_manage.TuckrManager.run_command")
        mock_run_command.return_value = (0, "success", "")

        result = manager.handle_rm("test-package")
        assert result is True  # Should return True on success
        assert manager.result["changed"] is True  # Changed should be True

    def test_execute_with_missing_tuckr(self, mocker):
        """Test TuckrManager.execute when tuckr is not available"""
        # We need to mock the is_tuckr_available method to return False
        # but we can't do that directly since the instance is created in the method
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Since we can't prevent is_tuckr_available from calling fail_json,
        # we need to test at the level where is_tuckr_available is called
        mocker.patch.object(manager, "is_tuckr_available", side_effect=SystemExit)
        with pytest.raises(SystemExit):
            manager.execute("test-package", "present", force=False, backup=True)

    def test_execute_add_failure_without_force(self, mocker):
        """Test TuckrManager.execute when add fails without force"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock is_tuckr_available to return True
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_is_available.return_value = True

        # Mock handle_add to return False (failure)
        mock_handle_add = mocker.patch("tuckr_manage.TuckrManager.handle_add")
        mock_handle_add.return_value = False

        # Also mock the conflicts check for the condition
        # Mock the result dict to be updated with conflicts
        mock_module.fail_json = mocker.Mock(side_effect=SystemExit)

        # This should call fail_json since success is False and not force-conflict case
        with pytest.raises(SystemExit):
            manager.execute("test-package", "present", force=False, backup=True)

        # Verify fail_json was called
        mock_module.fail_json.assert_called()

    def test_execute_absent_state(self, mocker):
        """Test TuckrManager.execute with state='absent'"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock is_tuckr_available to return True
        mock_is_available = mocker.patch("tuckr_manage.TuckrManager.is_tuckr_available")
        mock_is_available.return_value = True

        # Mock handle_rm
        mock_handle_rm = mocker.patch("tuckr_manage.TuckrManager.handle_rm")
        mock_handle_rm.return_value = True

        _result = manager.execute("test-package", "absent", force=False, backup=True)

        # Verify handle_rm was called (not handle_add)
        mock_handle_rm.assert_called_once_with("test-package")

    def test_parse_conflicts_with_complex_format(self, mocker):
        """Test TuckrManager.parse_conflicts with complex output format"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Complex output with multiple conflicts
        output = """file1.txt -> /home/user/.config/file1.txt (already exists)
some other message
file2.conf -> /home/user/.config/file2.conf (already exists)
another message without conflict
file3.ini -> /home/user/.config/file3.ini (already exists)"""

        result = manager.parse_conflicts(output)
        assert "/home/user/.config/file1.txt" in result
        assert "/home/user/.config/file2.conf" in result
        assert "/home/user/.config/file3.ini" in result
        assert len(result) == 3

    def test_backup_files_with_nonexistent_paths(self, mocker):
        """Test TuckrManager.backup_files with nonexistent paths"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock os.makedirs and shutil.move
        mock_makedirs = mocker.patch("tuckr_manage.os.makedirs")
        mock_move = mocker.patch("tuckr_manage.shutil.move")
        _mock_exists = mocker.patch("tuckr_manage.os.path.exists", return_value=False)

        # Test with a list of nonexistent files
        conflicts = ["/nonexistent/file1.txt", "/nonexistent/file2.conf"]

        result = manager.backup_files(conflicts)
        # Should succeed even when no files exist
        assert result is True
        # makedirs should still be called, but move shouldn't be
        mock_makedirs.assert_called_once()
        mock_move.assert_not_called()

    def test_run_command_with_exception(self, mocker):
        """Test TuckrManager.run_command when subprocess.run raises an exception"""
        mock_module = mocker.Mock()
        manager = TuckrManager(mock_module)

        # Mock subprocess.run to raise an exception
        mock_subprocess = mocker.patch("tuckr_manage.subprocess.run")
        mock_subprocess.side_effect = Exception("Subprocess failed")

        # Since run_command doesn't handle exceptions, expect it to propagate
        with pytest.raises(Exception, match="Subprocess failed"):
            manager.run_command(["tuckr", "test"])
