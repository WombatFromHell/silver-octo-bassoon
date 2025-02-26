#!/usr/bin/env python3

import unittest
import os
import tempfile
from generic_backup import matches_pattern, get_files_to_tar, expand_path


class TestPatternMatching(unittest.TestCase):
    def test_matches_pattern_simple_filename(self):
        # Test simple filename match (no path)
        self.assertTrue(matches_pattern("/path/to/file.txt", "file.txt"))
        self.assertFalse(matches_pattern("/path/to/file.txt", "otherfile.txt"))

    def test_matches_pattern_single_level_wildcard(self):
        self.assertTrue(matches_pattern("to/file.txt", "to/*.txt"))
        self.assertTrue(matches_pattern("file.txt", "*.txt"))
        self.assertFalse(matches_pattern("to/file.txt", "from/*.txt"))

    def test_matches_pattern_double_wildcard(self):
        # Test double wildcard (**)
        self.assertTrue(matches_pattern("/path/to/file.txt", "**/file.txt"))
        self.assertTrue(matches_pattern("/path/to/file.txt", "**/to/file.txt"))
        self.assertFalse(matches_pattern("/path/to/file.txt", "**/from/file.txt"))

    def test_matches_pattern_mixed_wildcards(self):
        self.assertTrue(matches_pattern("path/to/file.txt", "path/*/file.txt"))
        self.assertTrue(matches_pattern("path/to/file.txt", "**/to/*.txt"))

    def test_matches_pattern_complex_paths(self):
        # Test complex paths with relative paths
        self.assertTrue(matches_pattern("path/to/subdir/file.txt", "path/**/file.txt"))
        self.assertTrue(
            matches_pattern("path/to/subdir/file.txt", "**/subdir/file.txt")
        )
        self.assertFalse(matches_pattern("path/to/subdir/file.txt", "path/*/file.txt"))


class TestGetFilesToTar(unittest.TestCase):
    def setUp(self):
        # Create a temporary directory
        self.test_dir = tempfile.TemporaryDirectory()
        self.test_dir_path = self.test_dir.name

        # Create some test files
        self.file1 = os.path.join(self.test_dir_path, "file1.txt")
        self.file2 = os.path.join(self.test_dir_path, "file2.txt")
        self.subdir = os.path.join(self.test_dir_path, "subdir")
        self.file3 = os.path.join(self.subdir, "file3.txt")

        os.makedirs(self.subdir)
        with open(self.file1, "w") as f:
            f.write("test")
        with open(self.file2, "w") as f:
            f.write("test")
        with open(self.file3, "w") as f:
            f.write("test")

        # Save original working directory and change to test directory
        self.original_cwd = os.getcwd()
        os.chdir(self.test_dir_path)

    def tearDown(self):
        # Restore original working directory
        os.chdir(self.original_cwd)
        self.test_dir.cleanup()

    def test_get_files_to_tar_include_all(self):
        # Test including all files
        include_list = ["*"]
        exclude_list = []
        files = get_files_to_tar(include_list, exclude_list)
        self.assertIn(self.file1, files)
        self.assertIn(self.file2, files)
        self.assertIn(self.file3, files)

    def test_get_files_to_tar_include_with_exclude(self):
        # Test including files but excluding some
        include_list = ["*"]
        exclude_list = ["file1.txt"]
        files = get_files_to_tar(include_list, exclude_list)
        self.assertNotIn(self.file1, files)
        self.assertIn(self.file2, files)
        self.assertIn(self.file3, files)

    def test_get_files_to_tar_include_subdir(self):
        # Test including files from a subdirectory
        include_list = ["subdir/*"]
        exclude_list = []
        files = get_files_to_tar(include_list, exclude_list)
        self.assertNotIn(self.file1, files)
        self.assertNotIn(self.file2, files)
        self.assertIn(self.file3, files)


class TestExpandPath(unittest.TestCase):
    def test_expand_path_home(self):
        # Test expanding home directory
        path = "~/test"
        expanded_path = expand_path(path)
        self.assertTrue(expanded_path.startswith(os.path.expanduser("~")))

    def test_expand_path_env_var(self):
        # Test expanding environment variable
        os.environ["TEST_VAR"] = "/tmp"
        path = "$TEST_VAR/test"
        expanded_path = expand_path(path)
        self.assertEqual(expanded_path, "/tmp/test")


if __name__ == "__main__":
    unittest.main()
