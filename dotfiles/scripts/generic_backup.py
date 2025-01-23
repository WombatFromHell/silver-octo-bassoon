#!/usr/bin/env python3

import os
import sys
import subprocess
import argparse
import datetime
import glob
from pathlib import PurePath

import unittest
import test_generic_backup

# Use tomllib if available (Python 3.11+), otherwise fall back to the external toml package
if sys.version_info >= (3, 11):
    import tomllib as toml_lib
else:
    try:
        import toml as toml_lib
    except ImportError:
        print(
            "Error: The 'toml' package is required for Python versions < 3.11. Install it with 'pip install toml'"
        )
        sys.exit(1)

date_str = datetime.datetime.now().strftime("%H%M%S_%m%d%Y")


def get_default_config_path():
    """Get the default configuration file path based on XDG and fallback to $HOME/.config."""
    xdg_data_home = os.getenv("XDG_CONFIG_HOME")
    home_dir = os.getenv("HOME")

    if not home_dir:
        raise ValueError("HOME environment variable is not set.")

    return os.path.join(
        xdg_data_home or os.path.join(home_dir, ".config"), "generic-backup.toml"
    )


def read_config(config_file):
    """Reads and parses the TOML configuration file, ensuring 'include' and 'exclude' are arrays."""
    try:
        with open(config_file, "rb") as f:
            config = toml_lib.load(f)

        backup_configs = config.get("backup", [])
        for backup in backup_configs:
            backup["include"] = ensure_list(backup.get("include", []), "include")
            backup["exclude"] = ensure_list(backup.get("exclude", []), "exclude")

        return backup_configs

    except FileNotFoundError:
        print(f"Error: {config_file} not found.")
        return None
    except toml_lib.TOMLDecodeError as e:
        print(f"Error decoding TOML: {e}")
        return None
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return None


def ensure_list(value, key):
    """Ensures that the given value is a list, converting from string if necessary."""
    if isinstance(value, str):
        print(
            f"Warning: '{key}' should be an array, not a string. Converting '{value}' to an array."
        )
        return [value.strip()]
    return value if isinstance(value, list) else []


def matches_pattern(path, pattern):
    """Checks if a path matches a glob pattern, supporting ** and filename matches."""
    path_parts = PurePath(path).parts
    pattern_parts = PurePath(pattern).parts

    # Iterate over all possible starting positions in the path
    for start in range(len(path_parts)):
        p_idx = start
        pat_idx = 0
        while pat_idx < len(pattern_parts) and p_idx < len(path_parts):
            current_pattern = pattern_parts[pat_idx]
            if current_pattern == "**":
                # Handle recursive wildcard
                # If ** is the last part, match all remaining
                if pat_idx == len(pattern_parts) - 1:
                    return True
                # Look for the next pattern part after **
                next_pat = pattern_parts[pat_idx + 1]
                found = False
                while p_idx < len(path_parts):
                    if PurePath(path_parts[p_idx]).match(next_pat):
                        pat_idx += 2  # Move past ** and next_pat
                        p_idx += 1
                        found = True
                        break
                    p_idx += 1
                if not found:
                    break
            elif PurePath(path_parts[p_idx]).match(current_pattern):
                # Current part matches
                p_idx += 1
                pat_idx += 1
            else:
                break  # Part does not match

        # Check if all pattern parts were matched
        if pat_idx >= len(pattern_parts):
            return True

    # Special case: Match filename anywhere if pattern has no slashes
    if "/" not in pattern:
        filename = PurePath(path).name
        return PurePath(filename).match(pattern)

    return False


def change_directory(path):
    """Changes the current directory and handles errors."""
    try:
        os.chdir(path)
        return True
    except FileNotFoundError:
        print(f"Error: Path '{path}' not found.")
    except NotADirectoryError:
        print(f"Error: '{path}' is not a directory.")
    return False


def get_files_to_tar(include_list, exclude_list):
    """Gets the list of files to include in the tar archive."""
    files_to_tar = set()
    current_dir = os.getcwd()

    for pattern in include_list:
        abs_pattern = os.path.join(current_dir, pattern)
        matches = glob.glob(abs_pattern, recursive=True)
        for match in matches:
            abs_match = os.path.abspath(match)
            if os.path.isdir(abs_match):
                # Recursively add all files in the directory
                for root, _, files in os.walk(abs_match):
                    for file in files:
                        file_path = os.path.join(root, file)
                        if is_readable_file(file_path):
                            files_to_tar.add(file_path)
            elif is_readable_file(abs_match):
                files_to_tar.add(abs_match)

    # Exclude files matching exclude patterns
    excluded_files = set()
    for file in files_to_tar:
        relative_path = os.path.relpath(file, current_dir)
        for pattern in exclude_list:
            if matches_pattern(relative_path, pattern):
                excluded_files.add(file)
    files_to_tar -= excluded_files

    return list(files_to_tar)


def is_readable_file(path):
    """Checks if a file exists and is readable."""
    if not os.path.exists(path):
        print(f"Warning: Included item '{path}' not found. Skipping.")
        return False
    if not os.access(path, os.R_OK):
        print(f"Warning: Cannot read '{path}'. Skipping.")
        return False
    return True


def get_excluded_files(files_to_tar, exclude_list):
    """Returns a set of files that match any of the exclude patterns."""
    excluded_files = set()
    for pattern in exclude_list:
        for file in files_to_tar:
            if matches_pattern(file, pattern):
                excluded_files.add(file)
    return excluded_files


def create_tar_archive(output, files_to_tar, backup_dir):
    """Creates the tar archive in the specified backup directory and shows progress."""
    if not files_to_tar:
        print("Warning: No readable files to archive. Skipping.")
        return False

    tar_path = os.path.join(backup_dir, f"{output}-{date_str}.tar")
    tar_command = ["tar", "cf", tar_path] + files_to_tar

    return run_command_with_output(tar_command, f"Creating tar archive: {tar_path}")


def compress_archive(output, backup_dir):
    """Compresses the tar archive using pv and zstd, showing progress during compression."""
    tar_path = os.path.join(backup_dir, f"{output}-{date_str}.tar")
    zst_path = os.path.join(backup_dir, f"{output}-{date_str}.tar.zst")

    if not os.path.exists(tar_path):
        print(f"Error: Tar file '{tar_path}' not found.")
        return False

    print(f"Compressing tar archive: {tar_path} -> {zst_path}")
    pv_command = ["pv", tar_path]
    zstd_command = ["zstd", "--threads=0", "--long=27", "-5", "-o", zst_path, "-"]

    if not run_piped_commands(pv_command, zstd_command):
        return False

    os.remove(tar_path)
    print(f"Successfully compressed archive: {zst_path}")
    return True


def run_command_with_output(command, description):
    """Runs a command and prints its output in real-time."""
    print(description)
    process = subprocess.Popen(
        command,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )

    if process.stdout is None or process.stderr is None:
        print("Error: Failed to capture stdout or stderr from the process.")
        return False

    while True:
        output_line = process.stdout.readline()
        error_line = process.stderr.readline()
        if output_line == "" and error_line == "" and process.poll() is not None:
            break
        if output_line:
            print(output_line.strip())
        if error_line:
            print(error_line.strip(), file=sys.stderr)

    if process.returncode != 0:
        print(f"Error: Process returned {process.returncode}")
        return False

    return True


def run_piped_commands(command1, command2):
    """Runs two commands with a pipe between them and prints their output in real-time."""
    process1 = subprocess.Popen(
        command1,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )
    process2 = subprocess.Popen(
        command2,
        stdin=process1.stdout,
        stderr=subprocess.PIPE,
        universal_newlines=True,
    )

    if process1.stderr is None or process2.stderr is None:
        print("Error: Failed to capture stderr from the processes.")
        return False

    while True:
        output1 = process1.stderr.readline()
        output2 = process2.stderr.readline()
        if (
            output1 == ""
            and output2 == ""
            and process1.poll() is not None
            and process2.poll() is not None
        ):
            break
        if output1:
            print(output1.strip())
        if output2:
            print(output2.strip(), file=sys.stderr)

    if process2.returncode != 0:
        print(f"Error: Process returned {process2.returncode}")
        return False

    return True


def expand_path(path):
    """Expands user home directory and environment variables in a path."""
    return os.path.expanduser(os.path.expandvars(path))


def process_path(path_config, backup_dir):
    """Processes a single path configuration, respecting the 'enabled' property."""
    if not path_config.get("enabled", True):
        print(f"Skipping disabled backup block: {path_config.get('output', 'unknown')}")
        return

    path = path_config.get("path")
    output = path_config.get("output")

    if not path or not output:
        print("Error: 'path' and 'output' are required. Skipping.")
        return

    path = expand_path(path)
    if not change_directory(path):
        return

    include_list = path_config.get("include", [])
    exclude_list = path_config.get("exclude", [])

    files_to_tar = get_files_to_tar(include_list, exclude_list)
    if not create_tar_archive(output, files_to_tar, backup_dir):
        return

    if not compress_archive(output, backup_dir):
        return


def main():
    parser = argparse.ArgumentParser(description="Backup utility using tar and zstd.")
    parser.add_argument(
        "-c",
        "--config",
        dest="config_file",
        help="Path to the TOML configuration file. If not provided, the script will look for "
        "generic-backup.toml in $XDG_CONFIG_HOME or $HOME/.config.",
    )

    group = parser.add_mutually_exclusive_group(
        required=True
    )  # At least one is required
    group.add_argument(
        "-o",
        "--output-dir",
        dest="output_dir",
        help="Path to the output directory for backups.",
    )
    group.add_argument(
        "--test",
        action="store_true",
        help="Run the script in test mode without actually backing up anything.",
    )

    args = parser.parse_args()

    if args.test:
        test_suite = unittest.defaultTestLoader.loadTestsFromModule(test_generic_backup)
        test_runner = unittest.TextTestRunner()
        test_runner.run(test_suite)
        return

    if not args.config_file:
        args.config_file = get_default_config_path()

    config_paths = read_config(args.config_file)
    if config_paths is None:
        return

    backup_dir = os.path.join(args.output_dir, f"backup-{date_str}")
    os.makedirs(backup_dir, exist_ok=True)

    for path_config in config_paths:
        process_path(path_config, backup_dir)


if __name__ == "__main__":
    main()
