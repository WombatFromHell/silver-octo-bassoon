#!/usr/bin/env python3

import os
import sys
import subprocess
import re
from typing import List, Optional


def read_flags(config_path: str) -> List[str]:
    """Read and parse flags from configuration file."""
    if not os.path.isfile(config_path):
        print(f"Error: Flags configuration file '{config_path}' not found")
        sys.exit(1)
    with open(config_path, "r") as f:
        return [
            line.strip()
            for line in f
            if line.strip() and not line.strip().startswith("#")
        ]


def find_executable(name: str) -> Optional[str]:
    """Find the path of an executable."""
    try:
        return subprocess.check_output(
            ["command", "-v", name], stderr=subprocess.STDOUT, text=True
        ).strip()
    except subprocess.CalledProcessError:
        return None


def main() -> None:
    # Get configuration file path
    flags_conf = os.environ.get(
        "FLAGS", os.path.expanduser("~/.config/chromium-flags.conf")
    )
    flags = read_flags(flags_conf)

    if len(sys.argv) < 2:
        print("Error: No command specified")
        sys.exit(1)

    command = sys.argv[1]
    args = sys.argv[2:]

    # Handle flatpak commands
    if "flatpak" in command and args and args[0] == "run":
        flatpak = find_executable("flatpak")
        if flatpak is None:
            print("Error: flatpak command not found")
            sys.exit(1)

        # Look for package ID pattern (*.*.*)
        for i, arg in enumerate(args):
            if re.match(r"^[a-zA-Z0-9]+(\.[a-zA-Z0-9]+){2,}$", arg):
                cmd = [flatpak] + args[: i + 1] + flags + args[i + 1 :]
                os.execvp(cmd[0], cmd)
                break
        else:  # No package ID found
            cmd = [flatpak] + args + flags
            os.execvp(cmd[0], cmd)

    # Handle distrobox commands
    elif "distrobox" in command and "--" in args:
        distrobox_exec = find_executable("distrobox-enter")
        if distrobox_exec is None:
            print("Error: distrobox command not found")
            sys.exit(1)

        dash_dash_index = args.index("--")
        distrobox_args = args[:dash_dash_index]
        command_part = args[dash_dash_index + 1 :]

        if command_part:
            new_command_part = [command_part[0]] + flags + command_part[1:]
            cmd = [distrobox_exec] + distrobox_args + ["--"] + new_command_part
            os.execvp(cmd[0], cmd)
        else:
            print("Error: No command specified after '--'")
            sys.exit(1)

    # Standard command execution
    else:
        cmd = [command] + flags + args
        os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
