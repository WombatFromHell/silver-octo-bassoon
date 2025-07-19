#!/usr/bin/python3

import os
import sys
from pathlib import Path
from typing import Optional, Dict, List, Tuple
import shlex


def find_config_file() -> Optional[Path]:
    """Find and return the path to nscb.conf configuration file."""
    xdg_config_home = os.getenv('XDG_CONFIG_HOME')
    if xdg_config_home:
        config_path = Path(xdg_config_home) / 'nscb.conf'
        if config_path.exists():
            return config_path

    home_config_path = Path(os.getenv('HOME', '/')) / '.config' / 'nscb.conf'
    if home_config_path.exists():
        return home_config_path

    return None


def find_executable(name: str) -> bool:
    """Check if an executable is in the system PATH."""
    path_dirs = os.environ['PATH'].split(':')
    for path_dir in path_dirs:
        executable_path = Path(path_dir) / name
        if executable_path.exists() and executable_path.is_file() and os.access(executable_path, os.X_OK):
            return True
    return False


def load_config(config_file: Path) -> Dict[str, str]:
    """Load configuration from file and return as dictionary."""
    config = {}
    with open(config_file, 'r') as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith('#'):
                key, value = line.split('=', 1)
                key = key.strip()
                value = value.strip()
                # Remove surrounding quotes if present
                if len(value) >= 2 and ((value.startswith('"') and value.endswith('"')) or 
                                       (value.startswith("'") and value.endswith("'"))):
                    value = value[1:-1]

                config[key] = value
    return config


def parse_arguments(args: List[str]) -> Tuple[Optional[str], List[str]]:
    """Parse command line arguments to extract profile and remaining args.
    Returns:
        Tuple of (profile_name, remaining_args)
    """
    profile = None
    remaining_args = []
    i = 0

    while i < len(args):
        arg = args[i]
        if arg == '-p' or arg == '--profile':
            # Next argument should be the profile name
            if i + 1 < len(args):
                profile = args[i + 1]
                i += 2  # Skip both the flag and its value
            else:
                print(f"Error: {arg} requires a value", file=sys.stderr)
                sys.exit(1)
        elif arg.startswith('--profile='):
            # Handle --profile=value format
            profile = arg.split('=', 1)[1]
            i += 1
        else:
            # This argument is not related to profile, pass it through
            remaining_args.append(arg)
            i += 1

    return profile, remaining_args


def merge_arguments(profile_args: List[str], override_args: List[str]) -> List[str]:
    """Merge profile arguments with override arguments.
    Override arguments take precedence over profile arguments for conflicting options.
    """
    if not profile_args:
        return override_args
    if not override_args:
        return profile_args

    # Define which flags take values
    value_flags = {'-W', '-H'}
    # Define mutually exclusive flag groups
    exclusives = [
        {'--windowed', '-f'},
        {'--grab-cursor', '--force-grab-cursor'}
    ]

    # Split at '--'
    def split_dash(args: List[str]) -> Tuple[List[str], List[str]]:
        if '--' in args:
            idx = args.index('--')
            return args[:idx], args[idx:]
        return args, []

    prof_before, prof_after = split_dash(profile_args)
    over_before, over_after = split_dash(override_args)

    # Parse into sequences of flag/value and positionals
    def separate(arg_list: List[str]) -> Tuple[List[Tuple[str, Optional[str]]], List[str]]:
        flags_seq: List[Tuple[str, Optional[str]]] = []
        pos_seq: List[str] = []
        i = 0
        while i < len(arg_list):
            arg = arg_list[i]
            if arg.startswith('-'):
                if arg in value_flags and i + 1 < len(arg_list) and not arg_list[i+1].startswith('-'):
                    flags_seq.append((arg, arg_list[i+1]))
                    i += 2
                else:
                    flags_seq.append((arg, None))
                    i += 1
            else:
                pos_seq.append(arg)
                i += 1
        return flags_seq, pos_seq

    p_flags, p_pos = separate(prof_before)
    o_flags, o_pos = separate(over_before)

    # Start with profile flags, then apply overrides
    merged_flags: List[Tuple[str, Optional[str]]] = []
    # Use set to track which flags have been added
    for flag, val in p_flags:
        merged_flags.append((flag, val))

    for flag, val in o_flags:
        # Remove any exclusive-group flags that conflict
        for group in exclusives:
            if flag in group:
                merged_flags = [(f, v) for (f, v) in merged_flags if f not in group]
                break
        # Also remove same flag if present earlier
        merged_flags = [(f, v) for (f, v) in merged_flags if f != flag]
        # Append this override
        merged_flags.append((flag, val))

            # Build final ordered flags: use profile order, then any override-only flags, then any remaining
    # Create a map of merged flags
    merged_map: Dict[str, Optional[str]] = {f: v for f, v in merged_flags}
    ordered_flags: List[Tuple[str, Optional[str]]] = []
    # 1. Flags in profile sequence
    for f, _ in p_flags:
        if f in merged_map:
            ordered_flags.append((f, merged_map.pop(f)))
    # 2. Flags in override sequence that weren't in profile
    for f, _ in o_flags:
        if f in merged_map:
            ordered_flags.append((f, merged_map.pop(f)))
    # 3. Any remaining flags
    for f, v in merged_flags:
        if f in merged_map:
            ordered_flags.append((f, merged_map.pop(f)))

    # Flatten into result
    result: List[str] = []
    for f, v in ordered_flags:
        result.append(f)
        if v is not None:
            result.append(v)
    # Add positionals
    result.extend(p_pos)
    result.extend(o_pos)
    # Add suffix
    if over_after:
        result.extend(over_after)
    else:
        result.extend(prof_after)

    return result


def main() -> None:
    if not find_executable('gamescope'):
        print("Error: gamescope not found in PATH or is not executable", file=sys.stderr)
        sys.exit(1)

    # Skip the script name (sys.argv[0])
    command_args = sys.argv[1:]
    # Parse profile arguments manually
    profile, gamescope_args = parse_arguments(command_args)

    profile_args: List[str] = []
    if profile:
        # Only require config file if a profile is specified
        config_file = find_config_file()
        if not config_file:
            print("Error: Could not find nscb.conf in $XDG_CONFIG_HOME/nscb.conf or $HOME/.config/nscb.conf", file=sys.stderr)
            sys.exit(1)

        config = load_config(config_file)

        if profile in config:
            # Use shlex.split to properly handle quoted arguments
            profile_args = shlex.split(config[profile])
        else:
            print(f"Error: Profile '{profile}' not found", file=sys.stderr)
            sys.exit(1)

    # Merge profile args with command line args (command line takes precedence)
    final_args = merge_arguments(profile_args, gamescope_args)
    # Build the final command
    gamescope_cmd = ['gamescope'] + final_args

    print('Executing:', ' '.join(shlex.quote(arg) for arg in gamescope_cmd))
    os.execvp('gamescope', gamescope_cmd[1:])


if __name__ == '__main__':
    main()
