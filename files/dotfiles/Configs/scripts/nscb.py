#!/usr/bin/python3

import os
import selectors
import shlex
import subprocess
import sys
import logging
from functools import reduce
from pathlib import Path
from typing import Dict, List, Optional, TextIO, Tuple, cast


def print_help() -> None:
    """Print concise help message about nscb.py functionality."""
    help_text = """neoscopebuddy - gamescope wrapper
Usage:
  nscb.py -p fullscreen -- /bin/mygame                 # Single profile
  nscb.py --profiles=profile1,profile2 -- /bin/mygame  # Multiple profiles
  nscb.py -p profile1 -W 3140 -H 2160 -- /bin/mygame   # Profile with overrides

  Config file: $XDG_CONFIG_HOME/nscb.conf or $HOME/.config/nscb.conf
  Config format: KEY=VALUE (e.g., "fullscreen=-f")
  Supports NSCB_PRE_CMD=.../NSCB_POST_CMD=... environment hooks
"""
    print(help_text)


def run_nonblocking(cmd: str) -> int:
    """Execute command with non-blocking I/O, forwarding stdout/stderr in real-time."""
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=True,
        bufsize=0,
        text=True,
    )

    sel = selectors.DefaultSelector()
    fileobjs = [cast(TextIO, process.stdout), cast(TextIO, process.stderr)]
    for fileobj in fileobjs:
        if fileobj:
            sel.register(cast(TextIO, fileobj), selectors.EVENT_READ)

    while sel.get_map():
        for key, _ in sel.select():
            fileobj: TextIO = cast(TextIO, key.fileobj)
            line = fileobj.readline()
            if not line:
                sel.unregister(fileobj)
                continue

            target = sys.stdout if fileobj is process.stdout else sys.stderr
            target.write(line)
            target.flush()

    return process.wait()


def find_config_file() -> Optional[Path]:
    """Find nscb.conf config file path."""
    # Check XDG_CONFIG_HOME first (standard location)
    if xdg_config_home := os.getenv("XDG_CONFIG_HOME"):
        config_path = Path(xdg_config_home) / "nscb.conf"
        if config_path.exists():
            return config_path
    # Fall back to HOME/.config/nscb.conf
    home = os.getenv("HOME")
    if home:
        config_path = Path(home) / ".config" / "nscb.conf"
        if config_path.exists():
            return config_path
    return None


def load_config(config_file: Path) -> Dict[str, str]:
    """Load configuration from file as dictionary."""
    config = {}
    with open(config_file, "r") as f:
        for line in f:
            if not line.strip() or line.startswith("#"):
                continue

            key, value = line.split("=", 1)
            config[key.strip()] = value.strip().strip("\"'")
    return config


def parse_profile_args(args: List[str]) -> Tuple[List[str], List[str]]:
    """Extract profiles and remaining args from command line."""
    profiles, rest = [], []
    i = 0
    while i < len(args):
        arg = args[i]
        # Handle --profiles=profile1,profile2,...
        if arg.startswith("--profiles="):
            profile_list = arg[len("--profiles=") :].split(",")
            for p in profile_list:
                if p.strip():
                    profiles.append(p.strip())
            i += 1
            continue
        # Handle -p and --profile (existing logic)
        if arg in ("-p", "--profile"):
            if i + 1 >= len(args):
                raise ValueError(f"{arg} requires value")
            profiles.append(args[i + 1])
            i += 2
            continue
        elif arg.startswith("--profile="):
            profile_name = arg.split("=", 1)[1]
            profiles.append(profile_name)
            i += 1
            continue

        rest.append(arg)
        i += 1
    return profiles, rest


def split_at_separator(args: List[str]) -> Tuple[List[str], List[str]]:
    """Split arguments at '--' separator."""
    if "--" in args:
        idx = args.index("--")
        return args[:idx], args[idx:]
    return args, []


def separate_flags_and_positionals(
    args: List[str],
) -> Tuple[List[Tuple[str, Optional[str]]], List[str]]:
    """Separate flag/value pairs from positional arguments."""
    flags, positionals = [], []
    i = 0
    while i < len(args):
        arg = args[i]
        if not arg.startswith("-"):
            positionals.append(arg)
            i += 1
            continue

        if (
            (arg in ("-W", "-H", "-w", "-h"))
            and i + 1 < len(args)
            and not args[i + 1].startswith("-")
        ):
            flags.append((arg, args[i + 1]))
            i += 2
        else:
            flags.append((arg, None))
            i += 1
    return flags, positionals


def merge_arguments(profile_args: List[str], override_args: List[str]) -> List[str]:
    """Merge profile arguments with overrides."""
    (p_before, _), (o_before, o_after) = (
        split_at_separator(profile_args),
        split_at_separator(override_args),
    )

    p_flags, p_pos = separate_flags_and_positionals(p_before)
    o_flags, o_pos = separate_flags_and_positionals(o_before)

    # Define mutually exclusive flags
    conflict_set = {"-f", "--fullscreen", "-b", "--borderless"}

    # Split current profile flags into conflicts and non-conflicts
    conflicts = []
    others = []
    for flag, value in p_flags:
        if flag in conflict_set:
            conflicts.append((flag, value))
        else:
            others.append((flag, value))

    new_conflict_flag = None
    new_others = []  # Processed override non-conflict flags

    # Handle overrides: process conflicting flags first (for placement at front)
    for flag, value in o_flags:
        if flag in conflict_set:
            new_conflict_flag = (flag, value)  # Keep the latest one
        else:
            # Remove existing non-conflicting flags that are overridden
            others = [(f, v) for f, v in others if f != flag]
            new_others.append((flag, value))

    # Build merged flags: [new conflict] + [new resolution] + [existing resolutions]
    merged_flags = []
    for pair in conflicts:
        if not (new_conflict_flag and pair[0] in conflict_set):
            merged_flags.append(pair)

    if new_conflict_flag:
        merged_flags.insert(0, new_conflict_flag)  # Put the override first

    merged_flags.extend(new_others + others)

    # Rebuild command parts
    result = []
    for pair in merged_flags:
        result.extend([pair[0]] + ([pair[1]] if pair[1] is not None else []))

    return result + p_pos + o_pos + o_after


def merge_multiple_profiles(profile_args_list: List[List[str]]) -> List[str]:
    """Merge multiple profile argument lists."""
    if not profile_args_list:
        return []
    if len(profile_args_list) == 1:
        return profile_args_list[0]
    return reduce(merge_arguments, profile_args_list)


def find_executable(name: str) -> bool:
    """Check if executable exists in PATH."""
    path = os.environ.get("PATH", "")
    if not path:
        return False
    for path_dir in path.split(":"):
        if path_dir and Path(path_dir).exists() and Path(path_dir).is_dir():
            executable_path = Path(path_dir) / name
            if (
                executable_path.exists()
                and executable_path.is_file()
                and os.access(executable_path, os.X_OK)
            ):
                return True
    return False


def is_gamescope_active() -> bool:
    """Determine if system runs under gamescope."""
    # Check XDG_CURRENT_DESKTOP first (more reliable than ps check)
    if os.environ.get("XDG_CURRENT_DESKTOP") == "gamescope":
        return True

    try:
        output = subprocess.check_output(
            ["ps", "ax"], stderr=subprocess.STDOUT, text=True
        )
        # More precise checking for gamescope process
        lines = output.split("\n")
        for line in lines:
            if "gamescope" in line and "grep" not in line:
                return True
    except Exception:
        pass

    return False


def get_env_commands() -> Tuple[str, str]:
    """Get pre/post commands from environment."""
    # Check new variable names first, then fall back to legacy names
    pre_cmd = os.environ.get("NSCB_PRE_CMD") or os.environ.get("NSCB_PRECMD", "")
    post_cmd = os.environ.get("NSCB_POST_CMD") or os.environ.get("NSCB_POSTCMD", "")
    return pre_cmd.strip(), post_cmd.strip()


def build_command(parts: List[str]) -> str:
    """Build command string from parts with proper filtering."""
    # Filter out empty strings before joining to avoid semicolon artifacts
    filtered_parts = [part for part in parts if part]
    return "; ".join(filtered_parts)


def execute_gamescope_command(final_args: List[str]) -> None:
    """Execute gamescope command with proper handling."""
    pre_cmd, post_cmd = get_env_commands()

    def build_app_command(args: Optional[List[str]]) -> str:
        # Always quote arguments before joining
        if not args:
            return ""
        quoted = [shlex.quote(arg) for arg in args]
        return " ".join(quoted)

    if not is_gamescope_active():
        app_args = ["gamescope"] + final_args
        full_cmd = build_command([pre_cmd, build_app_command(app_args), post_cmd])
    else:
        try:
            dash_index = final_args.index("--")
            app_args = final_args[dash_index + 1 :]
            # If pre_cmd and post_cmd are both empty, just execute the app args directly
            if not pre_cmd and not post_cmd:
                full_cmd = build_app_command(app_args)
            else:
                full_cmd = build_command([pre_cmd, build_app_command(app_args), post_cmd])
        except ValueError:
            # If no -- separator found but we have pre/post commands, use those
            if not pre_cmd and not post_cmd:
                full_cmd = ""
            else:
                full_cmd = build_command([pre_cmd, post_cmd])

    if not full_cmd:
        return

    print("Executing:", full_cmd)
    exit_code = run_nonblocking(full_cmd)
    sys.exit(exit_code)


def main() -> None:
    """Main entry point."""
    # Handle help request
    if len(sys.argv) == 1 or "--help" in sys.argv:
        print_help()

    if not find_executable("gamescope"):
        logging.error("'gamescope' not found in PATH")
        sys.exit(1)

    profiles, args = parse_profile_args(sys.argv[1:])

    # Merge profile arguments
    if profiles:
        config_file = find_config_file()
        if not config_file:
            logging.error("could not find nscb.conf")
            sys.exit(1)

        try:
            config = load_config(config_file)
            # Load the profile arguments safely
            merged_profiles = []
            for profile in profiles:
                merged_profiles.append(shlex.split(config[profile]))
            args = merge_multiple_profiles(merged_profiles + [args])
        except KeyError as e:
            logging.error(f"profile {e} not found")
            sys.exit(1)

    execute_gamescope_command(args)


if __name__ == "__main__":
    main()
