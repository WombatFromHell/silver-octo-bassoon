#!/usr/bin/python3

import logging
import os
import selectors
import shlex
import subprocess
import sys
from functools import reduce
from pathlib import Path
from typing import TextIO, cast

# Type aliases at the top of the file for readability
ArgsList = list[str]
FlagTuple = tuple[str, str | None]
ProfileArgs = dict[str, str]
ConfigData = dict[str, str]
ExitCode = int
ProfileArgsList = list[ArgsList]

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


class NscbError(Exception):
    """Base exception for nscb errors."""

    pass


class ConfigNotFoundError(NscbError):
    """Raised when config file cannot be found."""

    pass


class ProfileNotFoundError(NscbError):
    """Raised when a specified profile is not found in config."""

    pass


class PathHelper:
    """Utility class for path operations."""

    @staticmethod
    def get_config_path() -> Path | None:
        """Get the path to the config file."""
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

    @staticmethod
    def executable_exists(name: str) -> bool:
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


class EnvironmentHelper:
    """Utility class for environment variable operations."""

    @staticmethod
    def get_pre_post_commands() -> tuple[str, str]:
        """Get pre/post commands from environment."""
        # Check new variable names first, then fall back to legacy names
        pre_cmd = os.environ.get("NSCB_PRE_CMD") or os.environ.get("NSCB_PRECMD", "")
        post_cmd = os.environ.get("NSCB_POST_CMD") or os.environ.get("NSCB_POSTCMD", "")
        return pre_cmd.strip(), post_cmd.strip()

    @staticmethod
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


class ProfileManager:
    """Manages profile parsing and merging functionality."""

    @staticmethod
    def parse_profile_args(args: ArgsList) -> tuple[ArgsList, ArgsList]:
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
                profiles.append(args[i + 1])  # Fixed: was "forms" before
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

    @staticmethod
    def merge_arguments(profile_args: ArgsList, override_args: ArgsList) -> ArgsList:
        """
        Merge a profile argument list with an override argument list.

        Override flags take precedence over profile flags.
        Display mode conflicts (-f/--fullscreen vs --borderless) are mutually exclusive.
        """
        # Split arguments at the '--' separator
        (p_before, _), (o_before, o_after) = (
            ArgumentProcessor.split_at_separator(profile_args),
            ArgumentProcessor.split_at_separator(override_args),
        )

        # Separate flags and positionals
        p_flags, p_pos = ArgumentProcessor.separate_flags_and_positionals(p_before)
        o_flags, o_pos = ArgumentProcessor.separate_flags_and_positionals(o_before)

        # Process flags
        final_flags = ProfileManager._merge_flags(p_flags, o_flags)

        # Convert to flat argument sequence
        result = ProfileManager._flags_to_args_list(final_flags)

        return result + p_pos + o_pos + o_after

    @staticmethod
    def _merge_flags(
        profile_flags: list[FlagTuple], override_flags: list[FlagTuple]
    ) -> list[FlagTuple]:
        """Merge profile and override flags with proper conflict resolution."""
        # Define conflict set
        conflict_canon_set = {
            ProfileManager._canon("-f"),  # fullscreen
            ProfileManager._canon("-b"),  # borderless
        }

        # Classify flags
        profile_conflicts = [
            f
            for f in profile_flags
            if ProfileManager._canon(f[0]) in conflict_canon_set
        ]
        profile_nonconflicts = [
            f
            for f in profile_flags
            if ProfileManager._canon(f[0]) not in conflict_canon_set
        ]
        override_conflicts = [
            f
            for f in override_flags
            if ProfileManager._canon(f[0]) in conflict_canon_set
        ]
        override_nonconflicts = [
            f
            for f in override_flags
            if ProfileManager._canon(f[0]) not in conflict_canon_set
        ]

        # Resolve conflicts
        final_conflicts = (
            override_conflicts if override_conflicts else profile_conflicts
        )

        # Handle non-conflicts
        override_canon_set = {
            ProfileManager._canon(f[0]) for f in override_nonconflicts
        }
        remaining_profile_nonconflicts = [
            f
            for f in profile_nonconflicts
            if ProfileManager._canon(f[0]) not in override_canon_set
        ]

        # Combine all flags
        return final_conflicts + remaining_profile_nonconflicts + override_nonconflicts

    @staticmethod
    def _canon(flag: str) -> str:
        """Convert flag to canonical form."""
        return GAMESCOPE_ARGS_MAP.get(flag, flag)

    @staticmethod
    def _flags_to_args_list(flags: list[FlagTuple]) -> ArgsList:
        """Convert flag tuples to flat argument list."""
        result = []
        for flag, val in flags:
            result.append(flag)
            if val is not None:
                result.append(val)
        return result

    @staticmethod
    def merge_multiple_profiles(profile_args_list: ProfileArgsList) -> ArgsList:
        """Merge multiple profile argument lists."""
        if not profile_args_list:
            return []
        if len(profile_args_list) == 1:
            return profile_args_list[0]
        return reduce(ProfileManager.merge_arguments, profile_args_list)


class ConfigManager:
    """Manages configuration file loading and management."""

    @staticmethod
    def find_config_file() -> Path | None:
        """Find nscb.conf config file path."""
        return PathHelper.get_config_path()

    @staticmethod
    def load_config(config_file: Path) -> ConfigData:
        """Load configuration from file as dictionary."""
        config: ConfigData = {}
        with open(config_file, "r") as f:
            for line in f:
                if not line.strip() or line.startswith("#"):
                    continue

                # Handle lines without equals signs gracefully
                if "=" not in line:
                    continue

                key, value = line.split("=", 1)
                config[key.strip()] = value.strip().strip("\"'")
        return config


class ArgumentProcessor:
    """Handles argument parsing and manipulation."""

    @staticmethod
    def split_at_separator(args: ArgsList) -> tuple[ArgsList, ArgsList]:
        """Split arguments at '--' separator."""
        if "--" in args:
            idx = args.index("--")
            return args[:idx], args[idx:]
        return args, []

    @staticmethod
    def separate_flags_and_positionals(
        args: ArgsList,
    ) -> tuple[list[FlagTuple], ArgsList]:
        """
        Split arguments into (flags, positionals).

        * `flags` – list of tuples ``(flag, value)`` where *value* is the
          following argument if it does **not** start with a dash; otherwise
          ``None``.  Flags are returned unchanged (short or long form).
        * `positionals` – arguments that do not begin with a dash.
        """
        flags: list[FlagTuple] = []
        positionals: ArgsList = []

        i = 0
        while i < len(args):
            arg = args[i]

            # Positional argument – keep as-is.
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


class CommandExecutor:
    """Handles command building and execution."""

    @staticmethod
    def run_nonblocking(cmd: str) -> ExitCode:
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

    @staticmethod
    def get_env_commands() -> tuple[str, str]:
        """Get pre/post commands from environment."""
        return EnvironmentHelper.get_pre_post_commands()

    @staticmethod
    def build_command(parts: ArgsList) -> str:
        """Build command string from parts with proper filtering."""
        # Filter out empty strings before joining to avoid semicolon artifacts
        filtered_parts = [part for part in parts if part]
        return "; ".join(filtered_parts)

    @staticmethod
    def execute_gamescope_command(final_args: ArgsList) -> ExitCode:
        """Execute gamescope command with proper handling and return exit code."""
        pre_cmd, post_cmd = CommandExecutor.get_env_commands()

        if SystemDetector.is_gamescope_active():
            command = CommandExecutor._build_active_gamescope_command(
                final_args, pre_cmd, post_cmd
            )
        else:
            command = CommandExecutor._build_inactive_gamescope_command(
                final_args, pre_cmd, post_cmd
            )

        if not command:
            return 0

        print("Executing:", command)
        return CommandExecutor.run_nonblocking(command)

    @staticmethod
    def _build_inactive_gamescope_command(
        args: ArgsList, pre_cmd: str, post_cmd: str
    ) -> str:
        """Build command when gamescope is not active."""
        app_args = ["gamescope"] + args
        return CommandExecutor.build_command(
            [pre_cmd, CommandExecutor._build_app_command(app_args), post_cmd]
        )

    @staticmethod
    def _build_active_gamescope_command(
        args: ArgsList, pre_cmd: str, post_cmd: str
    ) -> str:
        """Build command when gamescope is already active."""
        try:
            dash_index = args.index("--")
            app_args = args[dash_index + 1 :]

            # If pre_cmd and post_cmd are both empty, just execute the app args directly
            if not pre_cmd and not post_cmd:
                return CommandExecutor._build_app_command(app_args)
            else:
                return CommandExecutor.build_command(
                    [pre_cmd, CommandExecutor._build_app_command(app_args), post_cmd]
                )
        except ValueError:
            # If no -- separator found but we have pre/post commands, use those
            if not pre_cmd and not post_cmd:
                return ""
            else:
                return CommandExecutor.build_command([pre_cmd, post_cmd])

    @staticmethod
    def _build_app_command(args: ArgsList) -> str:
        """Build application command from arguments."""
        if not args:
            return ""
        quoted = [shlex.quote(arg) for arg in args]
        return " ".join(quoted)


class SystemDetector:
    """Handles environment detection functionality."""

    @staticmethod
    def find_executable(name: str) -> bool:
        """Check if executable exists in PATH."""
        return PathHelper.executable_exists(name)

    @staticmethod
    def is_gamescope_active() -> bool:
        """Determine if system runs under gamescope."""
        return EnvironmentHelper.is_gamescope_active()


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


class Application:
    """Main application orchestrator."""

    def __init__(
        self,
        profile_manager: ProfileManager | None = None,
        config_manager: ConfigManager | None = None,
        command_executor: CommandExecutor | None = None,
        system_detector: SystemDetector | None = None,
    ):
        self.profile_manager = profile_manager or ProfileManager()
        self.config_manager = config_manager or ConfigManager()
        self.command_executor = command_executor or CommandExecutor()
        self.system_detector = system_detector or SystemDetector()

    def run(self, args: ArgsList) -> ExitCode:
        """Run the application with the given arguments."""
        # Handle help request
        if not args or "--help" in args:
            print_help()
            return 0

        # Validate dependencies
        if not self.system_detector.find_executable("gamescope"):
            logging.error("'gamescope' not found in PATH")
            return 1

        # Parse profiles and remaining args
        profiles, remaining_args = self.profile_manager.parse_profile_args(args)

        # Process profiles if any
        if profiles:
            final_args = self._process_profiles(profiles, remaining_args)
        else:
            final_args = remaining_args

        # Execute the command
        return self.command_executor.execute_gamescope_command(final_args)

    def _process_profiles(self, profiles: ArgsList, args: ArgsList) -> ArgsList:
        """Process profiles and merge with arguments."""
        config_file = self.config_manager.find_config_file()
        if not config_file:
            raise ConfigNotFoundError("could not find nscb.conf")

        config = self.config_manager.load_config(config_file)
        merged_profiles = []

        for profile in profiles:
            if profile not in config:
                raise ProfileNotFoundError(f"profile {profile} not found")
            merged_profiles.append(shlex.split(config[profile]))

        return self.profile_manager.merge_multiple_profiles(merged_profiles + [args])


def main() -> ExitCode:
    """Main entry point."""
    try:
        app = Application()
        return app.run(sys.argv[1:])
    except NscbError as e:
        logging.error(str(e))
        return 1
    except Exception as e:
        logging.error(f"Unexpected error: {e}")
        return 1


if __name__ == "__main__":
    exit_code = main()
    sys.exit(exit_code)
