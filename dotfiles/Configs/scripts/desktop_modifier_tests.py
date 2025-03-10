#!/usr/bin/env -S python3 -m unittest

import os
import unittest
import tempfile
import shutil
from desktop_modifier import modify_desktop_file


class TestDesktopFileModifier(unittest.TestCase):
    """Test cases for the modify_desktop_file function."""

    def setUp(self):
        """Set up test environment."""
        # Create a temporary directory for test files
        self.test_dir = tempfile.mkdtemp()

        # Sample .desktop file content
        self.sample_content = """[Desktop Entry]
Name=Brave Web Browser
Exec=/usr/bin/brave
Exec=/usr/bin/brave-something-else
Terminal=false
Type=Application
Icon=brave
Categories=Network;WebBrowser;
"""

        # Sample with existing string
        self.existing_string_content = """[Desktop Entry]
Name=Brave Web Browser
Exec=env MOZ_ENABLE_WAYLAND=1 /usr/bin/brave --incognito
Terminal=false
Type=Application
Icon=brave
Categories=Network;WebBrowser;
"""

        # Create a sample .desktop file
        self.test_file = os.path.join(self.test_dir, "test.desktop")
        with open(self.test_file, "w", encoding="utf-8") as f:
            f.write(self.sample_content)

        # Create a file with existing string
        self.existing_string_file = os.path.join(
            self.test_dir, "existing_string.desktop"
        )
        with open(self.existing_string_file, "w", encoding="utf-8") as f:
            f.write(self.existing_string_content)

        # Create a file without Exec= line
        self.no_exec_file = os.path.join(self.test_dir, "no_exec.desktop")
        with open(self.no_exec_file, "w", encoding="utf-8") as f:
            f.write("[Desktop Entry]\nName=Test\nType=Application\n")

    def tearDown(self):
        """Clean up after tests."""
        # Remove the temporary directory and its contents
        shutil.rmtree(self.test_dir)

    def test_file_not_found(self):
        """Test behavior when file is not found."""
        success, message = modify_desktop_file("nonexistent.desktop", "test")
        self.assertFalse(success)
        self.assertTrue("not found" in message)

    def test_successful_modification(self):
        """Test successful modification of a .desktop file."""
        insert_string = "env MOZ_ENABLE_WAYLAND=1 "
        success, message = modify_desktop_file(self.test_file, insert_string)

        # Check function return
        self.assertTrue(success)
        self.assertTrue("Modified 2 Exec lines" in message)

        # Check that backup file was created
        self.assertTrue(os.path.exists(f"{self.test_file}.bak"))

        # Check file content was modified correctly
        with open(self.test_file, "r", encoding="utf-8") as f:
            content = f.read()

        expected_line = f"Exec={insert_string}/usr/bin/brave"
        self.assertTrue(expected_line in content)

        # Check backup content is original
        with open(f"{self.test_file}.bak", "r", encoding="utf-8") as f:
            backup_content = f.read()
        self.assertEqual(backup_content, self.sample_content)

    def test_multiple_exec_lines(self):
        """Test modification of multiple Exec lines in a .desktop file."""
        insert_string = "test="
        success, message = modify_desktop_file(self.test_file, insert_string)

        self.assertTrue(success)
        self.assertTrue("Modified 2 Exec lines" in message)

        with open(self.test_file, "r", encoding="utf-8") as f:
            content = f.read()

        expected_line1 = f"Exec={insert_string}/usr/bin/brave"
        expected_line2 = f"Exec={insert_string}/usr/bin/brave-something-else"
        self.assertTrue(expected_line1 in content)
        self.assertTrue(expected_line2 in content)

    def test_string_already_exists(self):
        """Test behavior when the string to insert already exists in the file."""
        insert_string = "env MOZ_ENABLE_WAYLAND=1 "
        success, message = modify_desktop_file(self.existing_string_file, insert_string)

        # Should fail with a warning
        self.assertFalse(success)
        self.assertTrue("already exists" in message)

        # Check that no backup file was created
        self.assertFalse(os.path.exists(f"{self.existing_string_file}.bak"))

        # Check file content was not modified
        with open(self.existing_string_file, "r", encoding="utf-8") as f:
            content = f.read()
        self.assertEqual(content, self.existing_string_content)

    def test_empty_insert_string(self):
        """Test with an empty insert string."""
        success, _ = modify_desktop_file(self.test_file, "")
        self.assertTrue(success)

        with open(self.test_file, "r", encoding="utf-8") as f:
            content = f.read()

        self.assertTrue("Exec=/usr/bin/brave" in content)
        self.assertTrue("Exec=/usr/bin/brave-something-else" in content)

    def test_no_exec_line(self):
        """Test behavior when file has no Exec= line."""
        success, message = modify_desktop_file(self.no_exec_file, "test")
        self.assertFalse(success)
        self.assertTrue("No 'Exec=' line found" in message)

    def test_special_chars_in_insert_string(self):
        """Test insertion of string with special characters."""
        special_chars = r"env SPECIAL='\$\"\\'"
        success, _ = modify_desktop_file(self.test_file, special_chars)
        self.assertTrue(success)

        with open(self.test_file, "r", encoding="utf-8") as f:
            content = f.read()

        expected_line1 = f"Exec={special_chars}/usr/bin/brave"
        expected_line2 = f"Exec={special_chars}/usr/bin/brave-something-else"
        self.assertTrue(expected_line1 in content)
        self.assertTrue(expected_line2 in content)


if __name__ == "__main__":
    unittest.main()
