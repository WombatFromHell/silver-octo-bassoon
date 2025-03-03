#!/usr/bin/env -S python -m unittest

import unittest
from unittest.mock import patch
import contextlib
import tempfile
import os
import sys
import re
import subprocess
import io
from contextlib import redirect_stdout

import chrome_with_flags


class TestChromiumFlags(unittest.TestCase):
    def test_read_flags_valid_file(self):
        """Test reading flags from valid config file"""
        test_content = "--flag1\n# comment\n\n--flag2\n"
        with tempfile.NamedTemporaryFile(mode="w+", delete=False) as tmp:
            tmp.write(test_content)
            tmp.close()
            result = chrome_with_flags.read_flags(tmp.name)
            os.unlink(tmp.name)
        self.assertEqual(result, ["--flag1", "--flag2"])

    def test_read_flags_missing_file(self):
        """Test handling missing config file"""
        old_stdout = sys.stdout
        redirected_output = io.StringIO()
        with self.assertRaises(SystemExit) as cm:
            with contextlib.redirect_stdout(redirected_output):
                chrome_with_flags.read_flags("nonexistent.conf")
        sys.stdout = old_stdout
        self.assertEqual(cm.exception.code, 1)

    def test_find_executable_found(self):
        """Test finding an existing executable"""
        with patch("subprocess.check_output") as mock_check:
            mock_check.return_value = "/usr/bin/flatpak"
            result = chrome_with_flags.find_executable("flatpak")
            self.assertEqual(result, "/usr/bin/flatpak")

    def test_find_executable_not_found(self):
        """Test handling missing executable"""
        with patch("subprocess.check_output") as mock_check:
            mock_check.side_effect = subprocess.CalledProcessError(1, "cmd")
            result = chrome_with_flags.find_executable("nonexistent")
            self.assertIsNone(result)

    @patch("os.execvp")
    @patch("chrome_with_flags.read_flags")  # Use actual module name
    @patch.dict("os.environ", {"FLAGS": "dummy_path"})
    def test_main_normal_command(self, mock_read_flags, mock_execvp):
        """Test standard command execution"""
        mock_read_flags.return_value = ["--test-flag"]
        test_args = ["script.py", "chromium", "http://example.com"]

        with patch.object(sys, "argv", test_args):
            chrome_with_flags.main()
            mock_execvp.assert_called_once_with(
                "chromium", ["chromium", "--test-flag", "http://example.com"]
            )

    @patch("os.execvp")
    @patch("chrome_with_flags.find_executable")
    @patch("chrome_with_flags.read_flags")
    @patch.dict("os.environ", {"FLAGS": "dummy_path"})
    def test_flatpak_with_package_id(
        self, mock_read_flags, mock_find_exec, mock_execvp
    ):
        """Test Flatpak command with package ID"""
        mock_read_flags.return_value = ["--test-flag"]
        mock_find_exec.return_value = "/usr/bin/flatpak"
        test_args = ["script.py", "flatpak", "run", "org.pkg.id", "arg1"]

        with patch.object(sys, "argv", test_args):
            chrome_with_flags.main()
            mock_execvp.assert_called_once_with(
                "/usr/bin/flatpak",
                ["/usr/bin/flatpak", "run", "org.pkg.id", "--test-flag", "arg1"],
            )

    @patch("os.execvp")
    @patch("chrome_with_flags.find_executable")  # Use actual module name
    @patch("chrome_with_flags.read_flags")  # Use actual module name
    @patch.dict("os.environ", {"FLAGS": "dummy_path"})
    def test_flatpak_without_package_id(
        self, mock_read_flags, mock_find_exec, mock_execvp
    ):
        """Test Flatpak command without package ID"""
        mock_read_flags.return_value = ["--test-flag"]
        mock_find_exec.return_value = "/usr/bin/flatpak"
        test_args = ["script.py", "flatpak", "run", "invalidpkg", "arg1"]

        with patch.object(sys, "argv", test_args):
            chrome_with_flags.main()
            mock_execvp.assert_called_once_with(
                "/usr/bin/flatpak",
                ["/usr/bin/flatpak", "run", "invalidpkg", "arg1", "--test-flag"],
            )

    def test_package_id_regex(self):
        """Test package ID pattern matching"""
        valid_ids = ["org.pkg.id", "com.example.app", "org.example123.app"]
        invalid_ids = ["org", "package.id", "org.pkg", "com-example.app"]
        pattern = re.compile(r"^[a-zA-Z0-9]+(\.[a-zA-Z0-9]+){2,}$")

        for pid in valid_ids:
            self.assertTrue(pattern.match(pid), f"Valid ID failed: {pid}")

        for pid in invalid_ids:
            self.assertIsNone(pattern.match(pid), f"Invalid ID matched: {pid}")

    def test_no_command_handling(self):
        """Test error when no command is provided"""
        test_args = ["script.py"]

        with patch.object(sys, "argv", test_args), self.assertRaises(
            SystemExit
        ) as cm, redirect_stdout(io.StringIO()) as stdout:

            chrome_with_flags.main()

        self.assertEqual(cm.exception.code, 1)
        self.assertIn("Error: No command specified", stdout.getvalue())


if __name__ == "__main__":
    unittest.main()
