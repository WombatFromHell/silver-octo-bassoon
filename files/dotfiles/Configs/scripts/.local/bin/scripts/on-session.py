#!/usr/bin/env python3

import os
import sys
import subprocess
from pathlib import Path

# Define the directory where scripts are stored
RUN_DIR = Path.home() / ".local/bin/monitor-session"


def print_help():
    help_text = """
    Usage: monitor-session [OPTION]

    This script executes all executable *.sh and *.py scripts located in the
    ~/.local/bin/monitor-session directory. If no scripts are found, it skips execution.

    Options:
        -h, --help    Display this help message and exit.
        false         Execute scripts in the directory (default behavior).
    """
    print(help_text.strip())


def execute_scripts():
    """Executes all executable scripts in the RUN_DIR directory."""
    if not RUN_DIR.is_dir():
        print(f"Directory {RUN_DIR} does not exist. Skipping execution.")
        return

    scripts = list(RUN_DIR.glob("*.sh")) + list(RUN_DIR.glob("*.py"))

    if scripts:
        for script in scripts:
            if os.access(script, os.X_OK | os.R_OK):
                print(f"Executing: {script}")
                subprocess.run([script])
            else:
                print(f"Skipping script: {script}")
    else:
        print(
            f"No executable *.sh or *.py scripts found in {RUN_DIR}. Skipping execution."
        )


def main():
    # Handle help argument
    if len(sys.argv) > 1 and (sys.argv[1] == "-h" or sys.argv[1] == "--help"):
        print_help()
        sys.exit(0)

    # Execute scripts if the argument is "false" or no argument is provided
    if len(sys.argv) == 1 or (len(sys.argv) > 1 and sys.argv[1] == "false"):
        execute_scripts()


if __name__ == "__main__":
    main()
