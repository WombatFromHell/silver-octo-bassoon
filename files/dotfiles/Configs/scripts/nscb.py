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


GAMESCOPE_ARGS_MAP = {
    "-W": "--output-width",
    "-H": "--output-height",
    "-w": "--nested-width",
    "-h": "--nested-height",
    "-b": "--borderless",
    "-C": "--hide-cursor-delay",
    "-e": "--steam",
    "-f": "--fullscreen",
    "-F": "--filter",
    "-g": "--grab",
    "-o": "--nested-unfocused-refresh",
    "-O": "--prefer-output",
    "-r": "--nested-refresh",
    "-R": "--ready-fd",
    "-s": "--mouse-sensitivity",
    "-T": "--stats-path",
    "--sharpness": "--fsr-sharpness",
}


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
    """
    Split arguments into (flags, positionals).

    * `flags` – list of tuples ``(flag, value)`` where *value* is the
      following argument if it does **not** start with a dash; otherwise
      ``None``.  Flags are returned unchanged (short or long form).
    * `positionals` – arguments that do not begin with a dash.
    """
    flags: List[Tuple[str, Optional[str]]] = []
    positionals: List[str] = []

    i = 0
    while i < len(args):
        arg = args[i]

        # Positional argument – keep as‑is.
        if not arg.startswith("-"):
            positionals.append(arg)
            i += 1
            continue

        # Flag that may or may not have an accompanying value.
        if i + 1 < len(args) and not args[i + 1].startswith("-"):
            flags.append((arg, args[i + 1]))
            i += 2
        else:
            flags.append((arg, None))
            i += 1

    return flags, positionals


def merge_arguments(profile_args: List[str], override_args: List[str]) -> List[str]:
    """
    Merge a profile argument list with an override argument list.

    * Profile arguments are merged with overrides such that:
        1. Override flags take precedence over profile flags.
        2. Any conflict flag supplied by the override replaces **all**
           profile conflict flags (mutual exclusivity).
        3. Non‑conflict overrides replace matching profile non‑conflict
           flags.
    * All override flags are appended after all surviving profile flags,
      preserving the order in which they were specified.
    * Positional arguments and everything after a ``--`` separator is
      preserved verbatim.

    Returns a flat list of strings ready to be passed to
    `execute_gamescope_command`.
    """
    # Split each argument list at the '--' separator (everything after
    # the separator is treated as application args).
    (p_before, _), (o_before, o_after) = (
        split_at_separator(profile_args),
        split_at_separator(override_args),
    )

    p_flags, p_pos = separate_flags_and_positionals(p_before)
    o_flags, o_pos = separate_flags_and_positionals(o_before)

    # Helper: canonical long form for a flag
    def canon(flag: str) -> str:
        return GAMESCOPE_ARGS_MAP.get(flag, flag)

    conflict_canon_set = {canon("-f"), canon("-b")}

    # Classify profile flags
    profile_conflict_flags = [
        (flag, val) for flag, val in p_flags if canon(flag) in conflict_canon_set
    ]
    profile_nonconflict_flags = [
        (flag, val) for flag, val in p_flags if canon(flag) not in conflict_canon_set
    ]

    # Classify override flags
    override_conflict_flags = [
        (flag, val) for flag, val in o_flags if canon(flag) in conflict_canon_set
    ]
    override_nonconflict_flags = [
        (flag, val) for flag, val in o_flags if canon(flag) not in conflict_canon_set
    ]

    # Determine which conflict flags survive: any override conflict wins over all profile conflicts.
    final_conflict_flags = (
        override_conflict_flags if override_conflict_flags else profile_conflict_flags
    )

    # Flags from the profile that are NOT overridden by a non‑conflict override
    overridden_nonconflict = {canon(f) for f, _ in override_nonconflict_flags}
    remaining_profile_nonconflict = [
        (flag, val)
        for flag, val in profile_nonconflict_flags
        if canon(flag) not in overridden_nonconflict
    ]

    # Override flags to be appended after all surviving profile flags
    override_all_flags = (
        override_nonconflict_flags  # conflict overrides already handled
    )

    # Assemble final ordered list of flags:
    #   [profile conflicts] + [remaining profile non‑conflicts] + [override flags]
    final_flags: List[Tuple[str, Optional[str]]] = []
    final_flags.extend(final_conflict_flags)
    final_flags.extend(remaining_profile_nonconflict)
    final_flags.extend(override_all_flags)

    # Convert to a flat argument sequence
    result: List[str] = []
    for flag, val in final_flags:
        result.append(flag)
        if val is not None:
            result.append(val)

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
                full_cmd = build_command(
                    [pre_cmd, build_app_command(app_args), post_cmd]
                )
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
