#!/usr/bin/python3

import os
import re
import shlex
import subprocess
import selectors
import sys
import io
from pathlib import Path
from typing import Dict, List, Optional, Tuple


def run_nonblocking(cmd: str) -> int:
    """Execute a command with non-blocking I/O, forwarding stdout/stderr in real-time."""
    process = subprocess.Popen(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        shell=True,
        bufsize=0,  # Unbuffered for real-time output
        text=True,
    )

    sel = selectors.DefaultSelector()
    if process.stdout is not None:
        sel.register(process.stdout, selectors.EVENT_READ)
    if process.stderr is not None:
        sel.register(process.stderr, selectors.EVENT_READ)

    while sel.get_map():
        for key, _ in sel.select():
            fileobj = key.fileobj
            # Narrow to TextIO to satisfy type checker
            if isinstance(fileobj, io.TextIOBase):
                line = fileobj.readline()
                if line:
                    target = sys.stdout if fileobj is process.stdout else sys.stderr
                    target.write(line)
                    target.flush()
                else:
                    sel.unregister(fileobj)
                    fileobj.close()
            else:
                # Skip unexpected types
                sel.unregister(fileobj)

    return process.wait()


class NSCBConfig:
    """Handles configuration file operations."""

    @staticmethod
    def find_config_file() -> Optional[Path]:
        """Find and return the path to nscb.conf configuration file."""
        # Check XDG_CONFIG_HOME first
        if xdg_config_home := os.getenv("XDG_CONFIG_HOME"):
            config_path = Path(xdg_config_home) / "nscb.conf"
            if config_path.exists():
                return config_path

        # Fall back to ~/.config/nscb.conf
        if home := os.getenv("HOME"):
            home_config_path = Path(home) / ".config" / "nscb.conf"
            if home_config_path.exists():
                return home_config_path

        return None

    @staticmethod
    def load_config(config_file: Path) -> Dict[str, str]:
        """Load configuration from file and return as dictionary."""
        config = {}
        with open(config_file, "r") as f:
            for line in f:
                line = line.rstrip("\n")
                if line and not line.startswith("#"):
                    key, value = line.split("=", 1)
                    key = key.strip()
                    value = value.strip()
                    # Remove surrounding quotes if present
                    if (
                        len(value) >= 2
                        and value[0] == value[-1]
                        and value[0] in ('"', "'")
                    ):
                        value = value[1:-1]
                    config[key] = value
        return config


class ArgumentParser:
    """Handles command line argument parsing and merging."""

    VALUE_FLAGS = {"-W", "-H", "-O", "-o"}
    EXCLUSIVE_GROUPS = [{"-f", "--fullscreen", "-b", "--borderless"}]

    @staticmethod
    def parse_profile_args(args: List[str]) -> Tuple[Optional[str], List[str]]:
        """Parse command line arguments to extract profile and remaining args."""
        profile = None
        remaining_args = []
        i = 0

        while i < len(args):
            arg = args[i]
            if arg in ("-p", "--profile"):
                if i + 1 < len(args):
                    profile = args[i + 1]
                    i += 2
                else:
                    print(f"Error: {arg} requires a value", file=sys.stderr)
                    sys.exit(1)
            elif arg.startswith("--profile="):
                profile = arg.split("=", 1)[1]
                i += 1
            else:
                remaining_args.append(arg)
                i += 1

        return profile, remaining_args

    @classmethod
    def _split_at_separator(cls, args: List[str]) -> Tuple[List[str], List[str]]:
        """Split arguments at '--' separator."""
        if "--" in args:
            idx = args.index("--")
            return args[:idx], args[idx:]
        return args, []

    @classmethod
    def _separate_flags_and_positionals(
        cls, args: List[str]
    ) -> Tuple[List[Tuple[str, Optional[str]]], List[str]]:
        """Separate flag/value pairs from positional arguments."""
        flags = []
        positionals = []
        i = 0

        while i < len(args):
            arg = args[i]
            if arg.startswith("-"):
                if (
                    arg in cls.VALUE_FLAGS
                    and i + 1 < len(args)
                    and not args[i + 1].startswith("-")
                ):
                    flags.append((arg, args[i + 1]))
                    i += 2
                else:
                    flags.append((arg, None))
                    i += 1
            else:
                positionals.append(arg)
                i += 1

        return flags, positionals

    @classmethod
    def merge_arguments(
        cls, profile_args: List[str], override_args: List[str]
    ) -> List[str]:
        """Merge profile arguments with override arguments."""
        if not profile_args:
            return override_args
        if not override_args:
            return profile_args

        # Split at '--' separator
        prof_before, prof_after = cls._split_at_separator(profile_args)
        over_before, over_after = cls._split_at_separator(override_args)

        # Separate flags and positionals
        p_flags, p_pos = cls._separate_flags_and_positionals(prof_before)
        o_flags, o_pos = cls._separate_flags_and_positionals(over_before)

        # Start with profile flags
        merged_flags = list(p_flags)

        # Apply overrides
        for flag, val in o_flags:
            # Remove conflicting exclusive flags
            for group in cls.EXCLUSIVE_GROUPS:
                if flag in group:
                    merged_flags = [(f, v) for (f, v) in merged_flags if f not in group]
                    break

            # Remove same flag if present
            merged_flags = [(f, v) for (f, v) in merged_flags if f != flag]
            merged_flags.append((flag, val))

        # Build result maintaining order
        result = []
        for flag, value in merged_flags:
            result.append(flag)
            if value is not None:
                result.append(value)

        # Add positionals and suffix
        result.extend(p_pos)
        result.extend(o_pos)
        result.extend(over_after if over_after else prof_after)

        return result


class GameScopeChecker:
    """Checks if gamescope is active or available."""

    @staticmethod
    def find_executable(name: str) -> bool:
        """Check if an executable is in the system PATH."""
        return any(
            (Path(path_dir) / name).is_file()
            and os.access(Path(path_dir) / name, os.X_OK)
            for path_dir in os.environ["PATH"].split(":")
            if Path(path_dir).exists()
        )

    @staticmethod
    def is_gamescope_active() -> bool:
        """Determine whether the system is already running under gamescope."""
        # Check XDG_CURRENT_DESKTOP
        if os.environ.get("XDG_CURRENT_DESKTOP", "") == "gamescope":
            return True

        # Check for steam.sh process with -steampal
        try:
            cmd = "ps ax"
            buffer = io.StringIO()
            # Temporarily capture stdout/stderr
            old_out, old_err = sys.stdout, sys.stderr
            sys.stdout, sys.stderr = buffer, io.StringIO()
            _ = run_nonblocking(cmd)
            # Restore stdout/stderr
            sys.stdout, sys.stderr = old_out, old_err
            output = buffer.getvalue()
            return bool(re.search(r"steam\.sh .+ -steampal", output))
        except Exception:
            return False


class CommandBuilder:
    """Builds and executes the final gamescope command."""

    @staticmethod
    def get_env_commands() -> Tuple[str, str]:
        """Get pre and post commands from environment variables."""
        pre_cmd = os.environ.get("NSCB_PRE_CMD", os.environ.get("NSCB_PRECMD", ""))
        post_cmd = os.environ.get("NSCB_POST_CMD", os.environ.get("NSCB_POSTCMD", ""))
        return pre_cmd.strip(), post_cmd.strip()

    @staticmethod
    def build_command_string(parts: List[str]) -> str:
        """Build command string from parts, filtering empty parts."""
        return "; ".join(part for part in parts if part)

    @classmethod
    def execute_gamescope_command(cls, final_args: List[str]) -> None:
        """Execute the gamescope command with proper handling."""
        pre_cmd, post_cmd = cls.get_env_commands()

        if not GameScopeChecker.is_gamescope_active():
            # Run with gamescope
            gamescope_cmd = ["gamescope"] + final_args
            gamescope_str = " ".join(shlex.quote(arg) for arg in gamescope_cmd)
            full_command = cls.build_command_string([pre_cmd, gamescope_str, post_cmd])
        else:
            # Extract app args (after '--') and run directly
            try:
                dash_index = final_args.index("--")
                app_args = final_args[dash_index + 1 :]
                app_str = (
                    " ".join(shlex.quote(arg) for arg in app_args) if app_args else ""
                )
                full_command = cls.build_command_string([pre_cmd, app_str, post_cmd])
            except ValueError:
                full_command = cls.build_command_string([pre_cmd, post_cmd])

        # Execute command if there's something to run
        if full_command:
            print("Executing:", full_command)
            try:
                exit_code = run_nonblocking(full_command)
                sys.exit(exit_code)
            except Exception as e:
                print(f"Error executing command: {e}", file=sys.stderr)
                sys.exit(1)
        else:
            # No command to execute, exit cleanly
            sys.exit(0)


def main() -> None:
    """Main entry point."""
    # Check if gamescope is available
    if not GameScopeChecker.find_executable("gamescope"):
        print(
            "Error: gamescope not found in PATH or is not executable", file=sys.stderr
        )
        sys.exit(1)

    # Parse command line arguments
    command_args = sys.argv[1:]
    profile, gamescope_args = ArgumentParser.parse_profile_args(command_args)

    # Load profile arguments if specified
    profile_args = []
    if profile:
        config_file = NSCBConfig.find_config_file()
        if not config_file:
            print(
                "Error: Could not find nscb.conf in $XDG_CONFIG_HOME/nscb.conf or $HOME/.config/nscb.conf",
                file=sys.stderr,
            )
            sys.exit(1)

        config = NSCBConfig.load_config(config_file)
        if profile not in config:
            print(f"Error: Profile '{profile}' not found", file=sys.stderr)
            sys.exit(1)

        profile_args = shlex.split(config[profile])

    # Merge arguments and execute
    final_args = ArgumentParser.merge_arguments(profile_args, gamescope_args)
    CommandBuilder.execute_gamescope_command(final_args)


if __name__ == "__main__":
    main()
