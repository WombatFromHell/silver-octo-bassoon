#!/usr/bin/env python3

import os
import sys
import time
import shutil
import subprocess
import configparser
from typing import Optional

DEFAULT_CONFIG = {
    "WAYLAND_OUTPUT": "DP-3",
    "TARGET_M0": "2560x1440@144",
    "TARGET_M1": "2560x1440@120",
}


def print_help() -> None:
    help_text = """
Usage: fix-gsync.py [-h | --help]

This script toggles display modes using kscreen tools on Wayland sessions.

It expects a configuration file in INI format with the following structure:

[display]
WAYLAND_OUTPUT = DP-3
TARGET_M0 = 2560x1440@144
TARGET_M1 = 2560x1440@120

The script first looks for the config file in $XDG_CONFIG_HOME/fix-gsync.ini.
If not found there, it looks in $HOME/fix-gsync.ini.
If no config file exists, one will be created with the default values shown above.

Any additional command-line arguments will be executed after the display mode switching.
"""
    print(help_text)
    sys.exit(0)


def find_command(cmd_name: str) -> Optional[str]:
    return shutil.which(cmd_name)


def run_command(cmd_list: list[str], capture_output: bool = True) -> str:
    try:
        result = subprocess.run(
            cmd_list, capture_output=capture_output, text=True, check=True
        )
        return result.stdout.strip() if result.stdout else ""
    except subprocess.CalledProcessError as e:
        print(
            f"Error: Command '{' '.join(cmd_list)}' failed with exit code {e.returncode}"
        )
        sys.exit(1)


def get_config_path() -> str:
    """
    Determine the config file path. Look in $XDG_CONFIG_HOME first, then $HOME.
    If the file doesn't exist, return the path where it should be created.
    """
    if "XDG_CONFIG_HOME" in os.environ:
        config_dir = os.environ["XDG_CONFIG_HOME"]
    else:
        config_dir = os.path.join(os.environ["HOME"], ".config")

    # Ensure the config directory exists
    if not os.path.isdir(config_dir):
        os.makedirs(config_dir, exist_ok=True)

    return os.path.join(config_dir, "fix-gsync.ini")


def create_default_config(path: str) -> None:
    """
    Create a default config file at the specified path.
    """
    config = configparser.ConfigParser()
    config["display"] = DEFAULT_CONFIG
    with open(path, "w") as configfile:
        config.write(configfile)
    print(f"Created default config file at: {path}")


def load_config() -> dict[str, str]:
    """
    Load configuration from the config file.
    If it doesn't exist, create one with default values.
    Expects a [display] section with keys:
        WAYLAND_OUTPUT, TARGET_M0, TARGET_M1
    """
    config_path = get_config_path()
    if not os.path.isfile(config_path):
        create_default_config(config_path)

    config = configparser.ConfigParser()
    config.read(config_path)

    if "display" not in config:
        print(f"Error: Section 'display' not found in config file: {config_path}")
        sys.exit(1)

    section = config["display"]
    required_keys = ["WAYLAND_OUTPUT", "TARGET_M0", "TARGET_M1"]
    missing_keys = [key for key in required_keys if key not in section]
    if missing_keys:
        print(f"Error: Missing keys {missing_keys} in config file: {config_path}")
        sys.exit(1)
    return {key: section[key] for key in required_keys}


def main():
    # Check for help argument.
    if any(arg in {"-h", "--help"} for arg in sys.argv):
        print_help()

    # Load configuration for display settings.
    config = load_config()
    WAYLAND_OUTPUT = config["WAYLAND_OUTPUT"]
    TARGET_M0 = config["TARGET_M0"]
    TARGET_M1 = config["TARGET_M1"]

    # Find required commands
    kscreen_doctor = find_command("kscreen-doctor")
    kscreen_id = find_command("kscreen-id")
    nvidia_settings = find_command("nvidia-settings")

    if nvidia_settings is None:
        print("ERROR: nvidia-settings not found in PATH, aborting!")
        sys.exit(1)

    if kscreen_doctor is None:
        print("ERROR: kscreen-doctor not found in PATH, aborting!")
        sys.exit(1)

    if kscreen_id is None:
        print("ERROR: kscreen-id not found in PATH, aborting!")
        sys.exit(1)

    # Check session type
    if os.environ.get("XDG_SESSION_TYPE") != "wayland":
        print("Error: an unknown session type was detected!")
        sys.exit(1)

    # Get VRR_ENABLED and CURRENT_PRIMARY using kscreen-id
    vrr_output = run_command([kscreen_id, "--vrr"])
    # Expecting something like "VRR True" - grab the second token.
    tokens = vrr_output.split()
    if len(tokens) < 2:
        print("Error: Unexpected output from kscreen-id --vrr!")
        sys.exit(1)
    VRR_ENABLED = tokens[1]

    CURRENT_PRIMARY = run_command([kscreen_id, "--current"])

    if VRR_ENABLED == "True" and CURRENT_PRIMARY == WAYLAND_OUTPUT:
        # Toggle between mode0 and mode1 to temporarily "fix" gsync
        targetm0_mode = run_command([kscreen_id, "--mid", WAYLAND_OUTPUT, TARGET_M0])
        targetm1_mode = run_command([kscreen_id, "--mid", WAYLAND_OUTPUT, TARGET_M1])

        mode1 = f"output.{WAYLAND_OUTPUT}.mode.{targetm1_mode}"
        subprocess.run([kscreen_doctor, mode1])
        time.sleep(1)
        mode0 = f"output.{WAYLAND_OUTPUT}.mode.{targetm0_mode}"
        subprocess.run([kscreen_doctor, mode0])

        if len(sys.argv) > 1:
            subprocess.run(sys.argv[1:])
    elif CURRENT_PRIMARY != WAYLAND_OUTPUT:
        print("Warning: the current primary monitor does not match our defined output!")
        sys.exit(1)
    elif VRR_ENABLED != "True":
        print("Warning: VRR is not enabled, aborting!")
        sys.exit(1)
    else:
        print(
            "Error: an unknown error occurred when attempting to detect active output!"
        )
        sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
