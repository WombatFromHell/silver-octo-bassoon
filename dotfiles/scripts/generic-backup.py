#!/usr/bin/env python3

import os
import sys
import subprocess
import argparse
import datetime


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
    """Get the default configuration file path based on XDG and fallback to ~/.config."""
    # Get the XDG_CONFIG_HOME environment variable, defaulting to None if not set
    xdg_data_home = os.getenv("XDG_CONFIG_HOME")

    # If XDG_DATA_HOME is set, use it to construct the path
    if xdg_data_home:
        default_path = os.path.join(xdg_data_home, "generic-backup.toml")
    else:
        # Fallback to ~/.config if XDG_CONFIG_HOME is not set
        home_dir = os.getenv("HOME")
        if not home_dir:
            raise ValueError("HOME environment variable is not set.")
        default_path = os.path.join(home_dir, ".config", "generic-backup.toml")

    return default_path


def read_config(config_file):
    """Reads and parses the TOML configuration file using tomllib or toml."""
    try:
        with open(config_file, "rb") as f:  # Must open file in binary mode for tomllib
            config = toml_lib.load(f)
        return config.get("backup", [])
    except FileNotFoundError:
        print(f"Error: {config_file} not found.")
        return None
    except toml_lib.TOMLDecodeError as e:
        print(f"Error decoding TOML: {e}")
        return None
    except (
        Exception
    ) as e:  # Catch any other potential exceptions during file processing
        print(f"An unexpected error occurred: {e}")
        return None


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


def get_files_to_tar(include_str, exclude_str):
    """Gets the list of files to include in the tar archive, checking readability."""
    include_list = [item.strip() for item in include_str.split(";") if item.strip()]
    exclude_list = [item.strip() for item in exclude_str.split(";") if item.strip()]
    files_to_tar = []
    for item in include_list:
        if os.path.exists(item):
            if os.access(item, os.R_OK):
                files_to_tar.append(item)
            else:
                print(f"Warning: Cannot read '{item}'. Skipping.")
        else:
            print(f"Warning: Included item '{item}' not found. Skipping.")
    return files_to_tar, exclude_list


def create_tar_archive(output, files_to_tar, exclude_list, backup_dir):
    """Creates the tar archive in the specified backup directory and shows progress."""
    if not files_to_tar:
        print("Warning: No readable files to archive. Skipping.")
        return False

    tar_path = os.path.join(backup_dir, f"{output}-{date_str}.tar")
    tar_command = ["tar", "cf", tar_path] + files_to_tar
    if exclude_list:
        for ex in exclude_list:
            tar_command.extend(["--exclude", ex])

    try:
        # Run the tar command and capture stdout/stderr in real-time
        print(f"Creating tar archive: {tar_path}")
        process = subprocess.Popen(
            tar_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )

        if process.stdout is None or process.stderr is None:
            print("Error: Failed to capture stdout or stderr from the tar process.")
            return False

        # Print stdout and stderr in real-time
        while True:
            output_line = process.stdout.readline()
            error_line = process.stderr.readline()
            if output_line == "" and error_line == "" and process.poll() is not None:
                break
            if output_line:
                print(output_line.strip())
            if error_line:
                print(error_line.strip(), file=sys.stderr)

        # Check for errors
        if process.returncode != 0:
            print(f"Error creating tar archive: Process returned {process.returncode}")
            return False

        print(f"Successfully created tar archive: {tar_path}")
        return True

    except FileNotFoundError as e:
        print(f"Error: tar not found: {e}")
        return False
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return False


def compress_archive(output, backup_dir):
    """Compresses the tar archive using pv and zstd, showing progress during compression."""
    tar_path = os.path.join(backup_dir, f"{output}-{date_str}.tar")
    zst_path = os.path.join(backup_dir, f"{output}-{date_str}.tar.zst")

    try:
        # Check if the tar file exists before attempting to compress
        if not os.path.exists(tar_path):
            print(f"Error: Tar file '{tar_path}' not found.")
            return False

        print(f"Compressing tar archive: {tar_path} -> {zst_path}")

        # Use pv to show progress while compressing with zstd
        pv_command = ["pv", tar_path]
        zstd_command = ["zstd", "--threads=0", "--long=27", "-5", "-o", zst_path, "-"]

        pv_process = subprocess.Popen(
            pv_command,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        zstd_process = subprocess.Popen(
            zstd_command,
            stdin=pv_process.stdout,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )

        if pv_process.stderr is None or zstd_process.stderr is None:
            print("Error: Failed to capture stderr from the pv or zstd process.")
            return False

        # Print pv and zstd output in real-time
        while True:
            pv_output = pv_process.stderr.readline()
            zstd_output = zstd_process.stderr.readline()
            if (
                pv_output == ""
                and zstd_output == ""
                and pv_process.poll() is not None
                and zstd_process.poll() is not None
            ):
                break
            if pv_output:
                print(pv_output.strip())
            if zstd_output:
                print(zstd_output.strip(), file=sys.stderr)

        # Check for errors
        if zstd_process.returncode != 0:
            print(
                f"Error during zstd compression: Process returned {zstd_process.returncode}"
            )
            return False

        # Clean up the tar file after successful compression
        os.remove(tar_path)
        print(f"Successfully compressed archive: {zst_path}")
        return True

    except FileNotFoundError as e:
        print(f"Error: pv or zstd not found: {e}")
        return False
    except Exception as e:
        print(f"An unexpected error occurred: {e}")
        return False


def expand_path(path):
    """Expands user home directory and environment variables in a path."""
    return os.path.expanduser(os.path.expandvars(path))


def process_path(path_config, backup_dir):
    """Processes a single path configuration."""
    path = path_config.get("path")
    output = path_config.get("output")
    include_str = path_config.get("include", "")
    exclude_str = path_config.get("exclude", "")

    if not path or not output:
        print("Error: 'name' and 'output' are required. Skipping.")
        return

    path = expand_path(path)

    if not change_directory(path):
        return

    files_to_tar, exclude_list = get_files_to_tar(include_str, exclude_str)

    if not create_tar_archive(output, files_to_tar, exclude_list, backup_dir):
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
        "generic-backup.toml in $XDG_DATA_HOME or ~/.config.",
    )
    parser.add_argument(
        "-o",
        "--output-dir",
        dest="output_dir",
        required=True,
        help="Path to the output directory for backups.",
    )

    args = parser.parse_args()

    # If no config file is provided, use the default path
    if not args.config_file:
        args.config_file = get_default_config_path()

    config_paths = read_config(args.config_file)
    if config_paths is None:
        return

    # Create dated backup directory
    backup_dir = os.path.join(args.output_dir, f"backup-{date_str}")
    os.makedirs(backup_dir, exist_ok=True)

    for path_config in config_paths:
        process_path(path_config, backup_dir)


if __name__ == "__main__":
    main()
