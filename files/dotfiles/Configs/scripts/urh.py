#!/usr/bin/env python3
# pyright: strict

"""
ublue-rebase-helper (urh) - A wrapper utility for rpm-ostree and ostree commands.

This module provides a simplified interface for common rpm-ostree and ostree operations,
with interactive menus and user-friendly prompts.
"""

# ============================================================================
# IMPORTS AND GLOBAL CONSTANTS
# ============================================================================

import functools
import json
import logging
import os
import re
import subprocess
import sys
import tomllib
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import (
    Any,
    Callable,
    Dict,
    Final,
    List,
    LiteralString,
    NamedTuple,
    Optional,
    Self,
    Sequence,
    Tuple,
    TypeAlias,
    TypeGuard,
    Union,
    cast,
    override,
)

# Set up logging
logger: Final = logging.getLogger(__name__)

# Type aliases for better type safety
DateVersionKey: TypeAlias = Tuple[int, int, int, int, int]
AlphaVersionKey: TypeAlias = Tuple[int, Tuple[int, ...]]
VersionSortKey: TypeAlias = Union[DateVersionKey, AlphaVersionKey]
TagFilterFunc: TypeAlias = Callable[[str], bool]
TagTransformFunc: TypeAlias = Callable[[str], str]

# Constants
DEFAULT_CONFIG_PATH: Final = "~/.config/urh.toml"
XDG_CONFIG_PATH: Final = "$XDG_CONFIG_HOME/urh.toml"
CACHE_FILE_PATH: Final = "/tmp/oci_ghcr_token"
MAX_TAGS_DISPLAY: Final = 30
DEFAULT_REGISTRY: Final = "ghcr.io"
GITHUB_TOKEN_URL: Final = "https://ghcr.io/token"


# Command constants
class CommandType(StrEnum):
    """Enumeration of available commands."""

    CHECK = "check"
    KARGS = "kargs"
    LS = "ls"
    PIN = "pin"
    REBASE = "rebase"
    REMOTE_LS = "remote-ls"
    RM = "rm"
    ROLLBACK = "rollback"
    UNPIN = "unpin"
    UPGRADE = "upgrade"


# Context constants for tag filtering
class TagContext(StrEnum):
    """Enumeration of tag contexts."""

    TESTING = "testing"
    STABLE = "stable"
    UNSTABLE = "unstable"
    LATEST = "latest"


# Exception classes
class URHError(Exception):
    """Base exception for urh errors."""

    pass


class ConfigurationError(URHError):
    """Raised when configuration is invalid."""

    pass


class OCIError(URHError):
    """Raised when OCI operations fail."""

    pass


class MenuExitException(Exception):
    """Exception raised when ESC is pressed in a menu."""

    def __init__(self, is_main_menu: bool = False):
        self.is_main_menu = is_main_menu
        super().__init__()


# ============================================================================
# CONFIGURATION MANAGEMENT
# ============================================================================


@dataclass(slots=True, kw_only=True)
class RepositoryConfig:
    """Configuration for a specific repository."""

    include_sha256_tags: bool = False
    filter_patterns: List[str] = field(default_factory=lambda: cast(List[str], []))
    ignore_tags: List[str] = field(default_factory=lambda: cast(List[str], []))
    transform_patterns: List[Dict[str, str]] = field(
        default_factory=lambda: cast(List[Dict[str, str]], [])
    )
    latest_dot_handling: Optional[str] = None

    def __post_init__(self):
        """Validate configuration after initialization."""
        # Validate filter patterns are valid regex
        for pattern in self.filter_patterns:
            try:
                re.compile(pattern)
            except re.error as e:
                raise ValueError(f"Invalid regex pattern '{pattern}': {e}")

        # Validate transform patterns
        for transform in self.transform_patterns:
            if not all(key in transform for key in ["pattern", "replacement"]):
                raise ValueError(
                    f"Transform pattern must have 'pattern' and 'replacement' keys: {transform}"
                )
            try:
                re.compile(transform["pattern"])
            except re.error as e:
                raise ValueError(
                    f"Invalid regex in transform pattern '{transform['pattern']}': {e}"
                )

        # Validate latest_dot_handling
        valid_handlers = {None, "transform_dates_only"}
        if self.latest_dot_handling not in valid_handlers:
            raise ValueError(
                f"latest_dot_handling must be one of {valid_handlers}, "
                f"got '{self.latest_dot_handling}'"
            )


@dataclass(slots=True, kw_only=True)
class ContainerURLsConfig:
    """Configuration for container URLs."""

    default: str
    options: List[str] = field(default_factory=lambda: cast(List[str], []))


@dataclass(slots=True, kw_only=True)
class SettingsConfig:
    """Global settings configuration."""

    max_tags_display: int = MAX_TAGS_DISPLAY
    debug_mode: bool = False

    def __post_init__(self):
        """Validate settings configuration."""
        if self.max_tags_display <= 0:
            raise ValueError(
                f"max_tags_display must be positive, got {self.max_tags_display}"
            )
        if self.max_tags_display > 1000:
            raise ValueError(
                f"max_tags_display too large (max 1000), got {self.max_tags_display}"
            )


@dataclass(slots=True, kw_only=True)
class URHConfig:
    """Main configuration class."""

    repositories: Dict[str, RepositoryConfig] = field(
        default_factory=lambda: cast(Dict[str, RepositoryConfig], {})
    )
    container_urls: ContainerURLsConfig = field(
        default_factory=lambda: ContainerURLsConfig(
            default="ghcr.io/wombatfromhell/bazzite-nix:testing",
            options=[
                "ghcr.io/wombatfromhell/bazzite-nix:testing",
                "ghcr.io/wombatfromhell/bazzite-nix:stable",
                "ghcr.io/ublue-os/bazzite:stable",
                "ghcr.io/ublue-os/bazzite:testing",
                "ghcr.io/ublue-os/bazzite:unstable",
                "ghcr.io/astrovm/amyos:latest",
            ],
        )
    )
    settings: SettingsConfig = field(default_factory=lambda: SettingsConfig())

    @classmethod
    def get_default(cls) -> Self:
        """Get default configuration."""
        config = cls()

        # Add default repository configurations
        config.repositories["ublue-os/bazzite"] = RepositoryConfig(
            include_sha256_tags=False,
            filter_patterns=[
                r"^sha256-.*\.sig$",
                r"^sha256-.*",
                r"^sha256:.*",
                r"^[0-9a-fA-F]{40,64}$",
                r"^<.*>$",
                r"^(latest|testing|stable|unstable)$",
                r"^testing\..*",
                r"^stable\..*",
                r"^unstable\..*",
                r"^\d{1,2}$",
                r"^(latest|testing|stable|unstable)-\d{1,2}$",
                r"^\d{1,2}-(testing|stable|unstable)$",
            ],
            ignore_tags=["latest", "testing", "stable", "unstable"],
        )

        config.repositories["wombatfromhell/bazzite-nix"] = RepositoryConfig(
            include_sha256_tags=False,
            filter_patterns=[
                r"^sha256-.*\.sig$",
                r"^sha256-.*",
                r"^sha256:.*",
                r"^[0-9a-fA-F]{40,64}$",
                r"^<.*>$",
                r"^(latest|testing|stable|unstable)$",
                r"^testing\..*",
                r"^stable\..*",
                r"^unstable\..*",
                r"^\d{1,2}$",
                r"^(latest|testing|stable|unstable)-\d{1,2}$",
                r"^\d{1,2}-(testing|stable|unstable)$",
            ],
            ignore_tags=["latest", "testing", "stable", "unstable"],
        )

        config.repositories["astrovm/amyos"] = RepositoryConfig(
            include_sha256_tags=False,
            filter_patterns=[
                r"^sha256-.*\.sig$",
                r"^<.*>$",
                r"^(testing|stable|unstable)$",
                r"^testing\..*",
                r"^stable\..*",
                r"^unstable\..*",
                r"^\d{1,2}$",
                r"^(latest|testing|stable|unstable)-\d{1,2}$",
                r"^\d{1,2}-(testing|stable|unstable)$",
            ],
            ignore_tags=["testing", "stable", "unstable"],
            transform_patterns=[
                {"pattern": r"^latest\.(\d{8})$", "replacement": r"\1"}
            ],
            latest_dot_handling="transform_dates_only",
        )

        return config


class ConfigManager:
    """Manages configuration loading and saving."""

    def __init__(self):
        self._config: Optional[URHConfig] = None
        self._config_path: Optional[Path] = None

    def get_config_path(self) -> Path:
        """Get the path to the configuration file with caching."""
        if self._config_path is None:
            xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
            if xdg_config_home:
                config_file = Path(xdg_config_home) / "urh.toml"
            else:
                config_file = Path.home() / ".config" / "urh.toml"

            config_file.parent.mkdir(parents=True, exist_ok=True)
            self._config_path = config_file
        return self._config_path

    def load_config(self) -> URHConfig:
        """Load configuration from file."""
        if self._config is not None:
            return self._config

        config_path = self.get_config_path()

        if not config_path.exists():
            self.create_default_config()
            logger.info(f"Created default config file at {config_path}")
            self._config = URHConfig.get_default()
            return self._config

        try:
            with open(config_path, "rb") as f:
                data = tomllib.load(f)
                self._config = self._parse_config(data)
                return self._config
        except tomllib.TOMLDecodeError as e:
            logger.error(f"Error parsing TOML config file: {e}")
            logger.info("Using default configuration instead.")
            self._config = URHConfig.get_default()
            return self._config
        except Exception as e:
            logger.error(f"Error reading config file: {e}")
            logger.info("Using default configuration instead.")
            self._config = URHConfig.get_default()
            return self._config

    def _parse_config(self, data: Dict[str, Any]) -> URHConfig:
        """Parse configuration data from TOML."""
        from typing import cast

        config = URHConfig()

        # Parse repositories (now as array of tables)
        if "repository" in data:
            repositories_list = cast(List[Dict[str, Any]], data["repository"])
            for repo_data in repositories_list:
                # Get the repository name from the 'name' field
                repo_name = repo_data.get("name")
                if not repo_name:
                    continue

                # Extract with explicit type annotations and validation
                include_sha256_tags: bool = repo_data.get("include_sha256_tags", False)

                # Type-safe extraction of list fields
                filter_patterns_raw = repo_data.get("filter_patterns", [])
                filter_patterns: List[str] = [
                    p
                    for p in cast(List[Any], filter_patterns_raw)
                    if isinstance(p, str)
                ]

                ignore_tags_raw = repo_data.get("ignore_tags", [])
                ignore_tags: List[str] = [
                    t for t in cast(List[Any], ignore_tags_raw) if isinstance(t, str)
                ]

                transform_patterns_raw = repo_data.get("transform_patterns", [])
                transform_patterns: List[Dict[str, str]] = []
                for item in cast(List[Any], transform_patterns_raw):
                    if isinstance(item, dict):
                        item_dict = cast(Dict[str, Any], item)
                        # Ensure both 'pattern' and 'replacement' exist and are strings
                        pattern = item_dict.get("pattern")
                        replacement = item_dict.get("replacement")
                        if isinstance(pattern, str) and isinstance(replacement, str):
                            transform_patterns.append(
                                {"pattern": pattern, "replacement": replacement}
                            )

                latest_dot_handling_raw = repo_data.get("latest_dot_handling")
                latest_dot_handling: Optional[str] = (
                    latest_dot_handling_raw
                    if isinstance(latest_dot_handling_raw, str)
                    else None
                )

                repo_config = RepositoryConfig(
                    include_sha256_tags=include_sha256_tags,
                    filter_patterns=filter_patterns,
                    ignore_tags=ignore_tags,
                    transform_patterns=transform_patterns,
                    latest_dot_handling=latest_dot_handling,
                )
                config.repositories[repo_name] = repo_config

        # Parse container URLs
        if "container_urls" in data:
            urls_data = cast(Dict[str, Any], data["container_urls"])

            default_raw = urls_data.get("default", config.container_urls.default)
            default: str = (
                default_raw
                if isinstance(default_raw, str)
                else config.container_urls.default
            )

            options_raw = urls_data.get("options", config.container_urls.options)
            options: List[str] = [
                o for o in cast(List[Any], options_raw) if isinstance(o, str)
            ]

            config.container_urls = ContainerURLsConfig(
                default=default,
                options=options,
            )

        # Parse settings
        if "settings" in data:
            settings_data = cast(Dict[str, Any], data["settings"])

            max_tags_display_raw = settings_data.get(
                "max_tags_display", MAX_TAGS_DISPLAY
            )
            max_tags_display: int = (
                max_tags_display_raw
                if isinstance(max_tags_display_raw, int)
                else MAX_TAGS_DISPLAY
            )

            debug_mode_raw = settings_data.get("debug_mode", False)
            debug_mode: bool = (
                debug_mode_raw if isinstance(debug_mode_raw, bool) else False
            )

            config.settings = SettingsConfig(
                max_tags_display=max_tags_display,
                debug_mode=debug_mode,
            )

        return config

    def _serialize_value(self, value: Any, indent: int = 0) -> str:
        """Serialize a value to TOML format with proper escaping using pattern matching."""
        indent_str = "    " * indent
        match value:
            case bool():
                return str(value).lower()
            case int():
                return str(value)
            case str():
                # Escape backslashes for TOML
                return f'"{value.replace("\\", "\\\\")}"'
            case []:
                return "[]"
            case _ if isinstance(value, list):
                items = cast(List[Any], value)
                if not items:
                    return "[]"
                serialized_items: List[str] = []
                for item in items:
                    if isinstance(item, str):
                        # Escape backslashes for TOML
                        serialized_items.append(
                            f'{indent_str}    "{item.replace("\\", "\\\\")}"'
                        )
                    elif isinstance(item, dict):
                        # Handle inline tables
                        table_items: List[str] = []
                        item_dict = cast(Dict[str, Any], item)
                        for k, v in item_dict.items():
                            if isinstance(v, str):
                                table_items.append(f'{k} = "{v.replace("\\", "\\\\")}"')
                            else:
                                table_items.append(
                                    f"{k} = {self._serialize_value(v, 0)}"
                                )
                        serialized_items.append(
                            f"{indent_str}    {{ {', '.join(table_items)} }}"
                        )
                    else:
                        serialized_items.append(
                            f"{indent_str}    {self._serialize_value(item, 0)}"
                        )
                return "[\n" + ",\n".join(serialized_items) + "\n" + indent_str + "]"
            case _ if isinstance(value, dict):
                d = cast(Dict[str, Any], value)
                # Handle regular tables
                lines: List[str] = []
                for k, v in d.items():
                    lines.append(f"{indent_str}{k} = {self._serialize_value(v, 0)}")
                return "\n".join(lines)
            case _:
                return str(value)

    def create_default_config(self) -> None:
        """Create default configuration file."""
        config_path = self.get_config_path()
        default_config = URHConfig.get_default()

        with open(config_path, "w") as f:
            f.write("# ublue-rebase-helper (urh) configuration file\n")
            f.write(f"# Default location: {config_path}\n")
            f.write("#\n")
            f.write("# For documentation about the format, see DESIGN.md\n")
            f.write("\n")

            # Write repositories section as an array of tables
            for repo_name, repo_config in default_config.repositories.items():
                f.write("[[repository]]\n")
                f.write(f'name = "{repo_name}"\n')
                f.write(
                    f"include_sha256_tags = {self._serialize_value(repo_config.include_sha256_tags)}\n"
                )

                # Write filter_patterns
                f.write("filter_patterns = ")
                f.write(self._serialize_value(repo_config.filter_patterns, 0) + "\n")

                # Write ignore_tags
                f.write("ignore_tags = ")
                f.write(self._serialize_value(repo_config.ignore_tags, 0) + "\n")

                # Write transform_patterns if present
                if repo_config.transform_patterns:
                    f.write("transform_patterns = ")
                    f.write(
                        self._serialize_value(repo_config.transform_patterns, 0) + "\n"
                    )

                # Write latest_dot_handling if present
                if repo_config.latest_dot_handling:
                    f.write(
                        f'latest_dot_handling = "{repo_config.latest_dot_handling}"\n'
                    )

                f.write("\n")

            # Write container URLs section
            f.write("[container_urls]\n")
            f.write(f'default = "{default_config.container_urls.default}"\n')
            f.write("options = ")
            f.write(
                self._serialize_value(default_config.container_urls.options, 0) + "\n"
            )
            f.write("\n")

            # Write settings section
            f.write("[settings]\n")
            f.write(f"max_tags_display = {default_config.settings.max_tags_display}\n")
            f.write(
                f"debug_mode = {self._serialize_value(default_config.settings.debug_mode)}\n"
            )


# Global config manager instance
_config_manager = ConfigManager()


def get_config() -> URHConfig:
    """Get the current configuration."""
    return _config_manager.load_config()


# ============================================================================
# UTILITY FUNCTIONS
# ============================================================================


def run_command_safe(
    base_cmd: LiteralString, *args: str, timeout: Optional[int] = 300
) -> int:
    """Run a command with type-level injection prevention.

    The base_cmd must be a literal string, preventing variable injection.
    """
    cmd = [base_cmd, *args]
    try:
        if timeout is None:
            result = subprocess.run(
                cmd, check=False
            )  # Original behavior for backward compatibility
        else:
            result = subprocess.run(
                cmd, check=False, timeout=timeout
            )  # With timeout if specified
        return result.returncode
    except FileNotFoundError:
        logger.error(f"Command not found: {' '.join(cmd)}")
        print(f"Command not found: {' '.join(cmd)}")  # Also print for user visibility
        return 1
    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out after {timeout}s: {' '.join(cmd)}")
        print(
            f"Command timed out after {timeout}s: {' '.join(cmd)}"
        )  # Also print for user visibility
        return 124  # Standard timeout exit code


def run_command(cmd: List[str], timeout: Optional[int] = None) -> int:
    """Run a command and return its exit code."""
    try:
        if timeout is None:
            result = subprocess.run(
                cmd, check=False
            )  # Original behavior for backward compatibility
        else:
            result = subprocess.run(
                cmd, check=False, timeout=timeout
            )  # With timeout if specified
        return result.returncode
    except FileNotFoundError:
        logger.error(f"Command not found: {' '.join(cmd)}")
        print(f"Command not found: {' '.join(cmd)}")  # Also print for user visibility
        return 1
    except subprocess.TimeoutExpired:
        logger.error(f"Command timed out after {timeout}s: {' '.join(cmd)}")
        print(
            f"Command timed out after {timeout}s: {' '.join(cmd)}"
        )  # Also print for user visibility
        return 124  # Standard timeout exit code


def check_curl_presence() -> bool:
    """Check if curl is available in the system."""
    try:
        result = subprocess.run(
            ["which", "curl"], capture_output=True, text=True, check=False
        )
        return result.returncode == 0
    except FileNotFoundError:
        return False


def extract_repository_from_url(url: str) -> str:
    """Extract the repository name from a container URL."""
    if url.startswith(("ghcr.io/", "docker.io/", "quay.io/", "gcr.io/")):
        registry_removed = url.split("/", 1)[1]
        repo_part = registry_removed.split(":")[0]
    else:
        repo_part = url.split(":")[0] if ":" in url else url
    return repo_part


def extract_context_from_url(url: str) -> Optional[str]:
    """Extract the tag context from a URL."""
    if ":" in url:
        url_tag = url.split(":")[-1]
        if url_tag in TagContext:
            return url_tag
    return None


# ============================================================================
# DEPLOYMENT MANAGEMENT
# ============================================================================


@dataclass(slots=True, frozen=True)
class DeploymentInfo:
    """Information about a deployment."""

    deployment_index: int  # Renamed from 'index' to avoid conflict
    is_current: bool
    repository: str
    version: str
    is_pinned: bool


def get_status_output() -> Optional[str]:
    """Get the raw output from rpm-ostree status -v."""
    try:
        result = subprocess.run(
            ["rpm-ostree", "status", "-v"], capture_output=True, text=True, check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        logger.error(f"Error getting status: {e}")
        return None


def parse_deployment_info(status_output: str) -> List[DeploymentInfo]:
    """Parse deployment information from rpm-ostree status -v output."""
    lines = status_output.split("\n")
    deployments: List[DeploymentInfo] = []

    i = 0
    deployment_index_counter = 0  # Use counter to assign index based on order in output

    while i < len(lines):
        line = lines[i]

        # Look for deployment lines (with ●, *, or space at the start of the line, possibly with indentation)
        if re.match(r"^\s*[●* ]\s*ostree-image-signed:", line):
            deployment_index = deployment_index_counter
            deployment_index_counter += 1  # Increment for next deployment

            # Check if this is the current deployment
            is_current = "●" in line

            # Initialize values
            repository = "Unknown"
            version = "Unknown"
            is_pinned = False

            # Extract repository and tag from the ostree-image-signed line
            if "ostree-image-signed:docker://" in line:
                # Extract the full image URL
                url_match = re.search(r"docker://([^\s)]+)", line)
                if url_match:
                    full_url = url_match.group(1)
                    # Extract the full image reference: {owner}/{repo}:{tag}
                    # e.g., "ghcr.io/wombatfromhell/bazzite-nix:testing" -> "wombatfromhell/bazzite-nix:testing"
                    if "/" in full_url:
                        # Take everything after the registry: "wombatfromhell/bazzite-nix:testing"
                        repository = full_url.split("/", 1)[1]
                    else:
                        repository = full_url

            # Look ahead for more information
            j = i + 1
            while j < len(lines):
                next_line = lines[j]

                # Stop when we reach the next deployment or a major section
                if (
                    re.match(r"^\s*[●* ]\s+ostree-image-signed:", next_line)
                    or next_line.startswith("State:")
                    or next_line.startswith("AutomaticUpdates:")
                    or next_line.startswith("Deployments:")
                ):
                    break

                # Extract version - be very specific about the line format
                if next_line.strip().startswith("Version:"):
                    version_line = next_line.strip()
                    # Extract just the version part after "Version:" but keep date-version format
                    version_part = version_line.replace("Version:", "").strip()
                    # Extract the main version part before any additional metadata in parentheses
                    if " (" in version_part:
                        # Look for the pattern like "testing-XX.YYYYMMDD.N (timestamp)"
                        # We want to keep "testing-XX.YYYYMMDD.N" part
                        main_part = version_part.split(" (")[0].strip()
                        version = main_part
                    else:
                        version = version_part

                # Check for pinned status
                if "Pinned: yes" in next_line:
                    is_pinned = True

                j += 1

            deployments.append(
                DeploymentInfo(
                    deployment_index=deployment_index,
                    is_current=is_current,
                    repository=repository,
                    version=version,
                    is_pinned=is_pinned,
                )
            )

            i = j - 1  # Continue from where we left off

        i += 1

    return deployments


def get_deployment_info() -> List[DeploymentInfo]:
    """Get information about all deployments."""
    status_output = get_status_output()
    if status_output:
        return parse_deployment_info(status_output)
    return []


def get_current_deployment_info() -> Optional[Dict[str, str]]:
    """Get the current deployment information."""
    deployments = get_deployment_info()
    for deployment in deployments:
        if deployment.is_current:
            return {"repository": deployment.repository, "version": deployment.version}
    return None


def is_valid_deployment_info(
    info: Optional[Dict[str, str]],
) -> TypeGuard[Dict[str, str]]:
    """Type guard for deployment info validation."""
    return (
        info is not None
        and "repository" in info
        and "version" in info
        and bool(info["repository"])
    )


def format_deployment_header(deployment_info: Optional[Dict[str, str]]) -> str:
    """Format the deployment information into a header string."""
    if not is_valid_deployment_info(deployment_info):
        return (
            "Current deployment: System Information: Unable to retrieve deployment info"
        )

    # Now type checker knows deployment_info is Dict[str, str]
    # Extract just the repository name without the tag for display
    full_repository = deployment_info["repository"]
    repository = full_repository.split(":")[0]  # Get part before the colon
    version = deployment_info["version"]

    return f"Current deployment: {repository} ({version})"


# ============================================================================
# OCI CLIENT IMPLEMENTATION
# ============================================================================


class OCITokenManager:
    """Manages OAuth2 tokens for OCI registries using curl."""

    def __init__(self, repository: str, cache_path: Optional[str] = None):
        self.repository = repository
        self.cache_path = cache_path or CACHE_FILE_PATH

    def _get_cache_filepath(self) -> str:
        """Get the full path to the cache file."""
        return self.cache_path

    def _cache_token(self, token: str) -> None:
        """Cache the token to the cache file."""
        cache_filepath = self._get_cache_filepath()
        try:
            with open(cache_filepath, "w") as f:
                f.write(token)
            logger.debug(f"Successfully cached new token to {cache_filepath}")
        except (IOError, OSError) as e:
            logger.debug(f"Could not write token to cache {cache_filepath}: {e}")

    def get_token(self) -> Optional[str]:
        """
        Get an OAuth2 token for the repository, using a cached token if available.

        Returns:
            The token string if successful, None otherwise.
        """
        cache_filepath = self._get_cache_filepath()

        # 1. Check for a cached token
        if os.path.exists(cache_filepath):
            try:
                with open(cache_filepath, "r") as f:
                    logger.debug(f"Found cached token at {cache_filepath}")
                    return f.read().strip()
            except (IOError, OSError) as e:
                logger.warning(f"Could not read cached token at {cache_filepath}: {e}")

        # 2. If no cache, fetch a new token
        logger.debug("No valid cached token found. Fetching a new one...")
        scope = f"repository:{self.repository}:pull"
        # Note: The scope needs to be passed as a single argument to curl
        url = f"https://ghcr.io/token?scope={scope}"

        try:
            result = subprocess.run(
                ["curl", "-s", url],  # Added -s for silent mode
                capture_output=True,
                text=True,
                check=True,
            )
            response = json.loads(result.stdout)
            token = response.get("token")

            if token:
                # 3. Cache the new token for future use
                self._cache_token(token)
                return token
            return None
        except Exception as e:
            logger.error(f"Error getting token: {e}")
            print(f"Error getting token: {e}")  # Also print for user visibility
            return None

    def invalidate_cache(self) -> None:
        """Deletes the cached token file if it exists."""
        cache_filepath = self._get_cache_filepath()
        try:
            os.remove(cache_filepath)
            logger.debug(f"Invalidated and removed cache file: {cache_filepath}")
        except FileNotFoundError:
            # Cache file doesn't exist, nothing to do.
            logger.debug(f"Cache file does not exist: {cache_filepath}")

    def parse_link_header(self, link_header: Optional[str]) -> Optional[str]:
        """
        Parse the Link header to extract the next URL.
        Example: Link: </v2/WombatFromHell/bazzite-nix/tags/list?last=1.2.0&n=200>; rel="next"

        Args:
            link_header: The raw Link header value

        Returns:
            The next URL if found, None otherwise
        """
        if not link_header:
            return None

        # Look for the next link in the Link header
        # Pattern: </v2/...>; rel="next" or similar variations with spaces
        # Using a comprehensive pattern to match various formats
        # This pattern handles: '<url>; rel="next"' including possible spaces
        next_match = re.search(
            r'<\s*([^>]+?)\s*>\s*;\s*rel\s*=\s*["\']next["\']', link_header
        )
        if next_match:
            return next_match.group(1)
        return None


@functools.lru_cache(maxsize=128)
def _get_compiled_pattern(pattern: str) -> re.Pattern[str]:
    """Get a cached compiled regex pattern."""
    return re.compile(pattern)


class OCITagFilter:
    """Handles tag filtering and sorting logic."""

    def __init__(
        self, repository: str, config: URHConfig, context: Optional[str] = None
    ):
        self.repository = repository
        self.config = config
        self.repo_config = config.repositories.get(repository, RepositoryConfig())
        self.context = context

    def should_filter_tag(self, tag: str) -> bool:
        """Determine if a tag should be filtered out."""
        tag_lower = tag.lower()

        # Handle latest. tags
        if tag_lower.startswith("latest."):
            suffix = tag_lower[7:]
            if not suffix:
                return True
            if len(suffix) >= 8 and suffix.isdigit():
                return False  # Date format, keep for transformation
            return True  # Non-date format, filter out

        # Check ignore list
        if tag_lower in [t.lower() for t in self.repo_config.ignore_tags]:
            return True

        # Check filter patterns using cached patterns
        for pattern in self.repo_config.filter_patterns:
            compiled_pattern = _get_compiled_pattern(pattern)
            if compiled_pattern.match(tag_lower):
                return True

        # Filter signature tags
        if tag_lower.endswith(".sig") and "sha256-" in tag_lower:
            return True

        # Filter SHA256 hashes
        if not self.repo_config.include_sha256_tags:
            if len(tag) == 64 and all(c in "0123456789abcdefABCDEF" for c in tag):
                return True

        return False

    def transform_tag(self, tag: str) -> str:
        """Transform a tag based on repository rules."""
        for transform in self.repo_config.transform_patterns:
            pattern = transform["pattern"]
            replacement = transform["replacement"]
            compiled_pattern = _get_compiled_pattern(pattern)
            if compiled_pattern.match(tag):
                return re.sub(compiled_pattern, replacement, tag)
        return tag

    def filter_and_sort_tags(
        self, tags: List[str], limit: int = MAX_TAGS_DISPLAY
    ) -> List[str]:
        """Filter and sort tags."""
        # Filter out unwanted tags
        filtered_tags = [tag for tag in tags if not self.should_filter_tag(tag)]

        # Apply context-based filtering if a context is specified
        if self.context:
            filtered_tags = self._context_filter_tags(filtered_tags, self.context)

        # Transform tags
        transformed_tags = [self.transform_tag(tag) for tag in filtered_tags]

        # Deduplicate tags
        deduplicated_tags = self._deduplicate_tags_by_version(transformed_tags)

        # Sort tags based on version patterns
        sorted_tags = self._sort_tags(deduplicated_tags)

        # Return the first N tags
        return sorted_tags[:limit]

    def _context_filter_tags(self, tags: List[str], context: str) -> List[str]:
        """Filter tags based on context."""
        context_prefix = f"{context}-"
        context_tags = [tag for tag in tags if tag.startswith(context_prefix)]

        # Special handling for astrovm/amyos with latest context
        if self.repository == "astrovm/amyos" and context == "latest":
            # For amyos with latest context, we want YYYYMMDD format tags
            # which are the transformed version of latest.YYYYMMDD tags
            date_pattern = r"^\d{8}$"
            context_tags = [tag for tag in tags if re.match(date_pattern, tag)]

        return context_tags

    def _deduplicate_tags_by_version(self, tags: List[str]) -> List[str]:
        """Deduplicate tags by version, preferring prefixed versions when available."""
        version_map: Dict[Union[Tuple[str, str, str], str], str] = {}

        for tag in tags:
            # Extract version components - handle different formats
            # Format 1: [prefix-][XX.]YYYYMMDD[.N] where XX is optional series number
            # Format 2: [prefix-]XX.YYYYYYYY[.N] where XX is required series number
            # Try more specific pattern first: prefixed with series number
            version_match = re.match(
                r"^(?:testing-|stable-|unstable-)?(\d{2})\.(\d{8})(?:\.(\d+))?$", tag
            )

            if not version_match:
                # Try date-only format (like YYYYMMDD)
                date_only_match = re.match(
                    r"^(?:testing-|stable-|unstable-)?(\d{8})(?:\.(\d+))?$", tag
                )
                if date_only_match:
                    # Date-only format: no series (empty string), date, subver
                    date = date_only_match.group(1)
                    subver = date_only_match.group(2) or "0"
                    version_key = ("", date, subver)

                    # Check if this is a prefixed tag
                    is_prefixed = any(
                        tag.startswith(prefix)
                        for prefix in ["testing-", "stable-", "unstable-"]
                    )

                    # Use the same logic for storing
                    if version_key not in version_map:
                        version_map[version_key] = tag
                    elif is_prefixed and not any(
                        version_map[version_key].startswith(prefix)
                        for prefix in ["testing-", "stable-", "unstable-"]
                    ):
                        # Replace non-prefixed with prefixed
                        version_map[version_key] = tag
                    continue  # Continue to next tag since we handled this one

            if version_match:
                series = version_match.group(1)
                date = version_match.group(2)
                subver = version_match.group(3) or "0"

                # Create a version key
                version_key = (series, date, subver)

                # Check if this is a prefixed tag
                is_prefixed = tag.startswith(("testing-", "stable-", "unstable-"))

                # If this version is not in the map, add it
                # OR if this tag is prefixed and currently stored is not prefixed, replace it
                # But don't replace an existing prefixed tag with another prefixed tag
                if version_key not in version_map:
                    version_map[version_key] = tag
                elif is_prefixed and not version_map[version_key].startswith(
                    ("testing-", "stable-", "unstable-")
                ):
                    # Replace non-prefixed with prefixed
                    version_map[version_key] = tag
                # Otherwise, keep the existing one (whether prefixed or not)
            else:
                # For non-version tags, just add them directly
                version_map[tag] = tag

        return list(version_map.values())

    def _sort_tags(self, tags: List[str]) -> List[str]:
        """Sort tags based on version patterns."""

        def version_key(tag: str) -> VersionSortKey:
            # Handle context-prefixed version tags (testing-XX.YYYYMMDD, etc.)
            context_version_match = re.match(
                r"^(testing|stable|unstable)-(\d{2})\.(\d{8})(?:\.(\d+))?$", tag
            )
            if context_version_match:
                series = int(context_version_match.group(2))
                year, month, day = (
                    int(context_version_match.group(3)[:4]),
                    int(context_version_match.group(3)[4:6]),
                    int(context_version_match.group(3)[6:8]),
                )
                subver = (
                    int(context_version_match.group(4))
                    if context_version_match.group(4)
                    else 0
                )
                # Prefixed tags get priority over non-prefixed for same date
                # Using tuple of 5 elements: (year, month, day, subver, priority * 10000 + series)
                return (year, month, day, subver, 10000 + series)

            # Handle context-prefixed date-only tags (testing-YYYYMMDD, etc.)
            context_date_match = re.match(
                r"^(testing|stable|unstable)-(\d{8})(?:\.(\d+))?$", tag
            )
            if context_date_match:
                year, month, day = (
                    int(context_date_match.group(2)[:4]),
                    int(context_date_match.group(2)[4:6]),
                    int(context_date_match.group(2)[6:8]),
                )
                subver = (
                    int(context_date_match.group(3))
                    if context_date_match.group(3)
                    else 0
                )
                # Prefixed date-only tags get priority
                # Using tuple of 5 elements: (year, month, day, subver, priority)
                return (year, month, day, subver, 10000)

            # Handle version format tags (XX.YYYYMMDD.SUBVER)
            version_match = re.match(r"^(\d{2})\.(\d{8})(?:\.(\d+))?$", tag)
            if version_match:
                series = int(version_match.group(1))
                year, month, day = (
                    int(version_match.group(2)[:4]),
                    int(version_match.group(2)[4:6]),
                    int(version_match.group(2)[6:8]),
                )
                subver = int(version_match.group(3)) if version_match.group(3) else 0
                # Non-prefixed tags get lower priority
                # Using tuple of 5 elements: (year, month, day, subver, priority * 10000 + series)
                return (year, month, day, subver, series)  # priority 0, so just series

            # Handle date format tags (YYYYMMDD)
            date_match = re.match(r"^(\d{8})(?:\.(\d+))?$", tag)
            if date_match:
                year, month, day = (
                    int(date_match.group(1)[:4]),
                    int(date_match.group(1)[4:6]),
                    int(date_match.group(1)[6:8]),
                )
                subver = int(date_match.group(2)) if date_match.group(2) else 0
                # Non-prefixed date tags get lower priority
                # Using tuple of 5 elements: (year, month, day, subver, priority)
                return (year, month, day, subver, 0)

            # For all other tags, use alphabetical sorting
            # Using AlphaVersionKey format: (priority, tuple of character codes)
            return (-1, tuple(ord(c) for c in tag))

        return sorted(tags, key=version_key, reverse=True)


class CurlResult(NamedTuple):
    """Result of a curl operation."""

    stdout: str
    stderr: str
    returncode: int
    headers: Optional[Dict[str, str]] = None


class OCIClient:
    """A client for OCI Container Registry interactions using curl."""

    def __init__(
        self, repository: str, cache_path: Optional[str] = None, debug: bool = False
    ):
        self.repository = repository
        self.debug = debug
        self.config = get_config()
        self.token_manager = OCITokenManager(repository, cache_path)

    def _curl(
        self,
        url: str,
        token: str,
        *,
        capture_headers: bool = False,
        capture_body: bool = True,
        capture_status_code: bool = False,
        timeout: int = 30,
    ) -> CurlResult:
        """Unified curl wrapper with optional header capture."""
        cmd = ["curl", "-s", "--max-time", str(timeout)]

        if capture_status_code:
            # Write HTTP status code to stdout
            cmd.extend(["-w", "%{http_code}"])

        if capture_headers:
            # Use -i to include headers in output
            cmd.append("-i")

        if not capture_body and not capture_status_code:
            cmd.extend(["-o", "/dev/null"])

        cmd.extend(["-H", f"Authorization: Bearer {token}", url])

        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,  # Don't raise exception on non-zero exit
        )

        headers = None
        stdout = result.stdout

        if capture_headers and result.returncode == 0 and not capture_status_code:
            # Split headers and body
            parts = stdout.split("\r\n\r\n", 1)
            if len(parts) == 2:
                headers = self._parse_headers(parts[0])
                stdout = parts[1]

        return CurlResult(stdout, result.stderr, result.returncode, headers)

    def _parse_headers(self, header_text: str) -> Dict[str, str]:
        """Parse HTTP headers from text."""
        headers: Dict[str, str] = {}
        for line in header_text.split("\r\n"):
            if ":" in line:
                key, value = line.split(":", 1)
                headers[key.strip()] = value.strip()
        return headers

    def _validate_token_and_retry(self, token: str, url: str) -> Optional[str]:
        """
        Validate the token and retry with a new token if it's expired.

        Args:
            token: The current token to validate
            url: The URL to test the token against

        Returns:
            A valid token if successful, None otherwise
        """
        try:
            # Test the current token with a HEAD-like request
            cmd = [
                "curl",
                "-s",
                "-w",
                "%{http_code}",  # Write HTTP status code
                "-o",
                "/dev/null",  # Discard body
                "-H",
                f"Authorization: Bearer {token}",
                url,
            ]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )

            http_status = int(result.stdout.strip())

            # Token is valid
            if http_status == 200:
                logger.debug("Token validation successful")
                return token

            # Token expired or invalid
            if http_status == 403 or http_status == 401:
                logger.debug(
                    f"Token invalid (HTTP {http_status}). Fetching new token..."
                )
                self.token_manager.invalidate_cache()

                # Get new token
                new_token = self.token_manager.get_token()
                if not new_token:
                    logger.error("Could not obtain a new token")
                    return None

                # Validate new token
                cmd[cmd.index(f"Authorization: Bearer {token}")] = (
                    f"Authorization: Bearer {new_token}"
                )
                result = subprocess.run(
                    cmd,
                    capture_output=True,
                    text=True,
                    check=True,
                    timeout=30,
                )

                http_status = int(result.stdout.strip())
                if http_status == 200:
                    logger.debug("New token validated successfully")
                    return new_token
                else:
                    logger.error(f"New token also invalid (HTTP {http_status})")
                    return None

            # Other HTTP status
            logger.debug(f"Unexpected HTTP status during validation: {http_status}")
            return token  # Try to continue anyway

        except subprocess.TimeoutExpired:
            logger.error("Timeout during token validation")
            return None
        except Exception as e:
            logger.error(f"Error during token validation: {e}")
            return None

    def get_all_tags(
        self, context_url: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Get all tags with optimized single-request-per-page approach.
        """
        token = self.token_manager.get_token()
        if not token:
            logger.error("Could not obtain authentication token")
            return None

        base_url = f"https://ghcr.io/v2/{self.repository}/tags/list"
        next_url = f"{base_url}?n=200"
        all_tags: List[str] = []
        page_count = 0
        max_pages = 1000

        # Log the specific context if provided, otherwise the repository
        target_name = context_url if context_url else self.repository
        logger.debug(f"Starting pagination for: {target_name}")

        while next_url and page_count < max_pages:
            page_count += 1

            # Construct full URL
            if next_url.startswith("http"):
                full_url = next_url
            elif next_url.startswith("/"):
                full_url = f"https://ghcr.io{next_url}"
            else:
                full_url = f"https://ghcr.io/{next_url}"

            logger.debug(f"Page {page_count}: {full_url}")

            # NEW: Fetch page data AND next URL in single request
            page_data, next_url = self._fetch_page_with_headers(full_url, token)

            if not page_data:
                logger.error(f"Failed to fetch page {page_count}")
                if all_tags:
                    logger.warning(f"Returning {len(all_tags)} tags collected so far")
                    return {"tags": all_tags}
                return None

            # Accumulate tags
            page_tags = page_data.get("tags", [])
            if page_tags:
                all_tags.extend(page_tags)
                logger.debug(
                    f"Page {page_count}: {len(page_tags)} tags (total: {len(all_tags)})"
                )

        if page_count >= max_pages:
            logger.warning(f"Hit maximum page limit ({max_pages})")

        logger.debug(
            f"Pagination complete: {len(all_tags)} tags across {page_count} pages"
        )

        return {"tags": all_tags}

    def fetch_repository_tags(
        self, url: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """Get filtered and sorted tags for the repository."""
        # Fix: Pass the url to get_all_tags so the logs reflect the actual endpoint
        tags_data = self.get_all_tags(context_url=url)
        if not tags_data:
            return None

        # Extract context from URL if provided
        context = None
        if url:
            context = extract_context_from_url(url)

        # Create tag filter with context
        tag_filter = OCITagFilter(self.repository, self.config, context)

        filtered_tags = tag_filter.filter_and_sort_tags(
            tags_data["tags"], limit=self.config.settings.max_tags_display
        )

        return {"tags": filtered_tags}

    def _fetch_page_with_headers(
        self, url: str, token: str
    ) -> tuple[Optional[Dict[str, Any]], Optional[str]]:
        """
        Fetch page data AND Link header in a single request.

        Returns:
            Tuple of (page_data, next_url)
        """
        # Initialize variables to help with type checking
        stdout: str = ""
        body: str = ""

        try:
            cmd = [
                "curl",
                "-s",  # Silent
                "-i",  # Include headers in output
                "--http2",  # Force HTTP/2 if available
                "-H",
                f"Authorization: Bearer {token}",
                url,
            ]

            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )

            # Properly parse the HTTP response which has format:
            # HTTP/1.1 XXX Status
            # Headers...
            #
            # Body
            stdout = result.stdout

            # Split the response into HTTP status line, headers, and body
            # First, find the index of the double newline that separates headers from body
            double_crlf_pos = stdout.find("\r\n\r\n")
            double_lf_pos = stdout.find("\n\n")

            # Check which separator appears first and use it
            if double_crlf_pos != -1 and (
                double_lf_pos == -1 or double_crlf_pos < double_lf_pos
            ):
                # Use \r\n\r\n separator (4 characters)
                double_newline_pos = double_crlf_pos
                separator_len = 4
            elif double_lf_pos != -1:
                # Use \n\n separator (2 characters)
                double_newline_pos = double_lf_pos
                separator_len = 2
            else:
                logger.error("Could not find header/body separator in response")
                logger.debug(f"Response content: {repr(stdout)}")
                return None, None

            # Extract headers part (from after status line to separator)
            headers_and_status = stdout[:double_newline_pos]
            body = stdout[double_newline_pos + separator_len :]  # Skip the separator

            # The first line is the HTTP status line, subsequent lines are headers
            lines = headers_and_status.splitlines()
            if not lines:
                logger.error("Empty response headers")
                return None, None

            # First line is status line, rest are headers
            status_line = lines[0]
            header_lines = lines[1:]

            # Parse headers (case-insensitive)
            headers: Dict[str, str] = {}
            for line in header_lines:
                if ":" in line:
                    key, value = line.split(":", 1)
                    headers[key.strip().lower()] = value.strip()

            # Log status line for debugging
            logger.debug(f"HTTP Status: {status_line}")

            # Check if status indicates an auth error, and if so, try with fresh token
            if "401" in status_line or "403" in status_line:
                logger.debug(
                    f"Received {status_line}, invalidating token and retrying..."
                )
                self.token_manager.invalidate_cache()
                new_token = self.token_manager.get_token()
                if new_token:
                    logger.debug("Got new token, retrying request...")
                    return self._fetch_page_with_headers(url, new_token)
                else:
                    logger.error("Could not obtain new token after auth error")
                    return None, None

            # Get Link header
            link_header = headers.get("link")
            next_url = (
                self.token_manager.parse_link_header(link_header)
                if link_header
                else None
            )

            # Parse JSON body
            if not body.strip():
                logger.debug(f"Empty response body. Full response: {repr(stdout)}")
                return None, None

            logger.debug(f"Response body: {repr(body)}")

            # Check if the response is an error response from GHCR
            # GHCR error responses follow the pattern: {"errors":[...]}
            stripped_body = body.strip()
            if stripped_body.startswith('{"errors":'):
                logger.error(f"GHCR API returned an error: {stripped_body}")
                # This is an error response, not the expected tags response
                # The error suggests authentication/token issue
                return None, None

            data = json.loads(body)

            logger.debug(
                f"Fetched {len(data.get('tags', []))} tags, has_next: {next_url is not None}"
            )

            return data, next_url

        except subprocess.TimeoutExpired:
            logger.error(f"Timeout fetching page: {url}")
            return None, None
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in response: {e}")
            logger.debug(f"Response body that failed to parse: {repr(body)}")
            logger.debug(f"Full response that failed to parse: {repr(stdout)}")
            return None, None
        except Exception as e:
            logger.error(f"Error fetching page: {e}")
            return None, None

    def _parse_link_header(self, link_header: Optional[str]) -> Optional[str]:
        """
        Parse the Link header to extract the next URL.
        Note: This method matches the signature expected by tests but is redundant
        with the token manager's parse_link_header method. This is kept for
        test compatibility.
        """
        return self.token_manager.parse_link_header(link_header)


# ============================================================================
# UI/MENU SYSTEM
# ============================================================================


@dataclass(slots=True)
class MenuItem:
    """Represents a menu item."""

    key: str
    description: str
    value: Any = None

    @property
    def display_text(self) -> str:
        """Get the display text for the menu item."""
        return f"{self.key} - {self.description}"


@dataclass(slots=True)
class ListItem(MenuItem):
    """Represents a list item without key prefix in display."""

    @property
    @override
    def display_text(self) -> str:
        """Get the display text for the list item without key prefix."""
        return self.description


@dataclass(slots=True)
class GumCommand:
    """Builder for gum choose commands."""

    options: List[str]
    header: str
    persistent_header: Optional[str] = None
    cursor: str = "→"
    selected_prefix: str = "✓ "
    timeout: int = 300  # 5 minute timeout

    def build(self) -> List[str]:
        """Build the gum command."""
        cmd = [
            "gum",
            "choose",
            "--cursor",
            self.cursor,
            "--selected-prefix",
            self.selected_prefix,
            "--header",
            self._build_header(),
        ]
        cmd.extend(self.options)
        return cmd

    def _build_header(self) -> str:
        """Build combined header."""
        if self.persistent_header:
            return f"{self.persistent_header}\n{self.header}"
        return self.header


class MenuSystem:
    """Unified menu system using native Python."""

    def __init__(self):
        self.is_tty = os.isatty(1)

    def show_menu(
        self,
        items: Sequence[MenuItem],  # Changed from List[MenuItem] to Sequence[MenuItem]
        header: str,
        persistent_header: Optional[str] = None,
        is_main_menu: bool = False,
    ) -> Optional[Any]:
        """Show a menu and return the selected value."""
        # Check if we should force non-gum behavior (e.g., to avoid hanging during tests)
        force_non_gum = os.environ.get("URH_AVOID_GUM", "").lower() in (
            "1",
            "true",
            "yes",
        )

        if not self.is_tty or force_non_gum:
            self._show_non_tty(items, header, persistent_header)
            return None

        try:
            # Try to use gum if available
            return self._show_gum_menu(items, header, persistent_header, is_main_menu)
        except FileNotFoundError:
            # Fallback to simple text menu
            return self._show_text_menu(items, header, persistent_header, is_main_menu)

    def _show_non_tty(
        self, items: Sequence[MenuItem], header: str, persistent_header: Optional[str]
    ) -> None:
        """Show menu in non-TTY mode."""
        if persistent_header:
            print(persistent_header)
        print(header)
        for item in items:
            print(item.display_text)
        print("\nRun 'urh.py with a specific option.'")

    def _show_gum_menu(
        self,
        items: Sequence[MenuItem],
        header: str,
        persistent_header: Optional[str],
        is_main_menu: bool,
    ) -> Optional[Any]:
        """Show menu using gum with builder pattern."""
        options = [item.display_text for item in items]

        gum_cmd = GumCommand(
            options=options, header=header, persistent_header=persistent_header
        )

        try:
            result = subprocess.run(
                gum_cmd.build(),
                text=True,
                stdout=subprocess.PIPE,
                check=True,
                timeout=gum_cmd.timeout,  # 5 minute timeout
            )
            selected_text = result.stdout.strip()

            # Use walrus operator and next() for cleaner lookup
            if selected := next(
                (item for item in items if item.display_text == selected_text), None
            ):
                return (
                    selected.key
                    if selected.key and selected.key.strip()
                    else selected.value
                )

            return None
        except subprocess.CalledProcessError as e:
            if e.returncode == 1:
                # ESC pressed
                # Check if we're in a test that expects different behavior
                if "URH_TEST_NO_EXCEPTION" in os.environ:
                    print("No option selected.")
                    return None
                else:
                    # Clear the line in non-test environments
                    if "PYTEST_CURRENT_TEST" not in os.environ:
                        sys.stdout.write("\033[F\033[K")
                        sys.stdout.flush()

                    raise MenuExitException(is_main_menu=is_main_menu)
            return None
        except subprocess.TimeoutExpired:
            logger.warning("Menu selection timed out.")
            print("Menu selection timed out.")
            return None

    def _show_text_menu(
        self,
        items: Sequence[MenuItem],
        header: str,
        persistent_header: Optional[str],
        is_main_menu: bool,
    ) -> Optional[Any]:
        """Show menu using plain text."""
        if persistent_header:
            print(persistent_header)
        print(header)
        print("Press ESC to cancel")

        for i, item in enumerate(items, 1):
            print(f"{i}. {item.display_text}")

        while True:
            try:
                choice = input("\nEnter choice (number): ").strip()
                if not choice:
                    return None

                choice_num = int(choice)
                if 1 <= choice_num <= len(items):
                    # If item has a meaningful key (non-empty), return it; otherwise return value
                    item = items[choice_num - 1]
                    if item.key and item.key.strip():
                        return item.key
                    else:
                        return item.value
                else:
                    print("Invalid choice. Please try again.")
            except ValueError:
                print("Invalid choice. Please try again.")
            except KeyboardInterrupt:
                if is_main_menu:
                    sys.exit(0)
                else:
                    return None


# Global menu system instance
_menu_system = MenuSystem()

# ============================================================================
# COMMAND HANDLERS
# ============================================================================


# Type for functions that determine if sudo is required based on arguments
SudoConditionFunc: TypeAlias = Callable[[List[str]], bool]


@dataclass(slots=True, kw_only=True)
class CommandDefinition:
    """Definition of a command."""

    name: str
    description: str
    handler: Callable[[List[str]], None]
    requires_sudo: bool = False
    conditional_sudo_func: Optional[SudoConditionFunc] = (
        None  # Function to determine sudo conditionally when needed
    )
    has_submenu: bool = False


from typing import Generic, TypeVar
from typing import Optional as OptionalType

T = TypeVar("T")


def run_command_with_conditional_sudo(
    base_cmd: List[str],
    args: List[str],
    requires_sudo: bool,
    conditional_sudo_func: Optional[SudoConditionFunc] = None,
) -> None:
    """Execute a command with conditional sudo based on the requires_sudo setting."""
    # Determine if sudo is needed
    if conditional_sudo_func is not None:
        # Use the conditional function to determine if sudo is needed
        needs_sudo = conditional_sudo_func(args)
    else:
        # Use the static boolean value
        needs_sudo = requires_sudo

    # Build the command
    if needs_sudo:
        cmd = ["sudo", *base_cmd]
    else:
        cmd = base_cmd[:]

    cmd.extend(args)
    sys.exit(run_command(cmd))


class ArgumentParser(Generic[T]):
    """Generic argument parser with validation."""

    def parse_or_prompt(
        self,
        args: List[str],
        prompt_func: Callable[[], OptionalType[T]],
        validator: OptionalType[Callable[[str], T]] = None,
    ) -> OptionalType[T]:
        """Parse argument or show prompt if not provided."""
        if not args:
            try:
                return prompt_func()
            except MenuExitException:
                return None

        if validator:
            try:
                return validator(args[0])
            except (ValueError, IndexError) as e:
                logger.error(f"Invalid argument: {e}")
                print(f"Invalid argument: {e}")
                sys.exit(1)

        # If no validator provided, return the raw argument
        # This might need to be handled differently based on your needs
        if args:
            return args[0]  # type: ignore
        return None


class CommandRegistry:
    """Registry for all available commands."""

    def __init__(self):
        self._commands: Dict[str, CommandDefinition] = {}
        self._register_commands()

    def _register_commands(self) -> None:
        """Register all available commands."""
        self._commands = {
            "check": CommandDefinition(
                name="check",
                description="Check for available updates",
                handler=self._handle_check,
                requires_sudo=False,
            ),
            "kargs": CommandDefinition(
                name="kargs",
                description="Manage kernel arguments (kargs)",
                handler=self._handle_kargs,
                requires_sudo=False,  # Default value for compatibility with tests
                conditional_sudo_func=self._should_use_sudo_for_kargs,  # Use function for conditional sudo
            ),
            "ls": CommandDefinition(
                name="ls",
                description="List deployments with details",
                handler=self._handle_ls,
                requires_sudo=False,
            ),
            "rebase": CommandDefinition(
                name="rebase",
                description="Rebase to a container image",
                handler=self._handle_rebase,
                requires_sudo=True,
                has_submenu=True,
            ),
            "remote-ls": CommandDefinition(
                name="remote-ls",
                description="List available tags for a container image",
                handler=self._handle_remote_ls,
                requires_sudo=False,
                has_submenu=True,
            ),
            "upgrade": CommandDefinition(
                name="upgrade",
                description="Upgrade to the latest version",
                handler=self._handle_upgrade,
                requires_sudo=True,
            ),
            "rollback": CommandDefinition(
                name="rollback",
                description="Roll back to the previous deployment",
                handler=self._handle_rollback,
                requires_sudo=True,
            ),
            "pin": CommandDefinition(
                name="pin",
                description="Pin a deployment",
                handler=self._handle_pin,
                requires_sudo=True,
                has_submenu=True,
            ),
            "unpin": CommandDefinition(
                name="unpin",
                description="Unpin a deployment",
                handler=self._handle_unpin,
                requires_sudo=True,
                has_submenu=True,
            ),
            "rm": CommandDefinition(
                name="rm",
                description="Remove a deployment",
                handler=self._handle_rm,
                requires_sudo=True,
                has_submenu=True,
            ),
        }

    def get_commands(self) -> List[CommandDefinition]:
        """Get all registered commands."""
        return list(self._commands.values())

    def get_command(self, name: str) -> Optional[CommandDefinition]:
        """Get a specific command by name."""
        return self._commands.get(name)

    def _handle_check(self, args: List[str]) -> None:
        """Handle the check command."""
        cmd = ["rpm-ostree", "upgrade", "--check"]
        exit_code = run_command(cmd)
        sys.exit(exit_code)

    def _handle_ls(self, args: List[str]) -> None:
        """Handle the ls command."""
        # Get the status output and display it
        status_output = get_status_output()
        if status_output:
            print(status_output)
            sys.exit(0)
        else:
            sys.exit(1)

    def _should_use_sudo_for_kargs(self, args: List[str]) -> bool:
        """Determine if sudo should be used for kargs command based on arguments."""
        if not args:
            return False  # No args case is read-only

        # Check for help flags that are read-only operations
        help_flags = {"--help", "-h", "--help-all"}
        if any(arg in help_flags for arg in args):
            return False

        # Check for other potentially read-only operations (like just listing current)
        # If args contain only flags for inspection (not modification), return False
        # For kargs, typically modification operations involve --append, --delete, etc.
        # while inspection operations like --help don't need sudo
        return True  # Default to using sudo for any other argument combinations

    def _handle_kargs(self, args: List[str]) -> None:
        """Handle the kargs command."""
        # Use the general conditional sudo mechanism
        run_command_with_conditional_sudo(
            ["rpm-ostree", "kargs"],
            args,
            requires_sudo=False,  # This value is ignored when conditional_sudo_func is provided
            conditional_sudo_func=self._should_use_sudo_for_kargs,
        )

    def _handle_rebase(self, args: List[str]) -> None:
        """Handle the rebase command."""
        config = get_config()

        if not args:
            try:
                # Show submenu using ListItem instead of MenuItem
                items = [
                    ListItem("", url, url) for url in config.container_urls.options
                ]

                # Get current deployment info for persistent header
                deployment_info_header = get_current_deployment_info()
                persistent_header = format_deployment_header(deployment_info_header)

                selected = _menu_system.show_menu(
                    items,
                    "Select container image (ESC to cancel):",
                    persistent_header=persistent_header,
                    is_main_menu=False,
                )

                if selected is None:
                    return

                url = selected
            except MenuExitException as _:
                # ESC pressed in submenu, return to main menu
                return
        else:
            url = args[0]

        cmd = ["sudo", "rpm-ostree", "rebase", url]
        sys.exit(run_command(cmd))

    def _handle_remote_ls(self, args: List[str]) -> None:
        """Handle the remote-ls command."""
        config = get_config()

        if not args:
            try:
                # Show submenu using ListItem instead of MenuItem
                options: List[str] = list(config.container_urls.options)
                items = [ListItem("", url, url) for url in options]

                # Get current deployment info for persistent header
                deployment_info_header = get_current_deployment_info()
                persistent_header = format_deployment_header(deployment_info_header)

                selected = _menu_system.show_menu(
                    items,
                    "Select container image (ESC to cancel):",
                    persistent_header=persistent_header,
                    is_main_menu=False,
                )

                if selected is None:
                    return

                url = selected
            except MenuExitException as _:
                # ESC pressed in submenu, return to main menu
                return
        else:
            url = args[0]

        # Extract repository from URL
        repository = extract_repository_from_url(url)

        # Create OCI client and fetch tags
        client = OCIClient(repository)
        tags_data = client.fetch_repository_tags(url)

        if tags_data and "tags" in tags_data and tags_data["tags"]:
            print(f"Tags for {url}:")  # Keep print for user output of the actual tags
            for tag in tags_data["tags"]:
                print(f"  {tag}")
            sys.exit(0)  # Exit with success code after successful completion
        elif tags_data and "tags" in tags_data and not tags_data["tags"]:
            # No tags found
            logger.info(f"No tags found for {url}")
            print(f"No tags found for {url}")  # Print for user visibility
            sys.exit(0)
        else:
            # Error occurred
            logger.error(f"Could not fetch tags for {url}")
            print(f"Could not fetch tags for {url}")  # Print for user visibility
            sys.exit(1)

    def _handle_upgrade(self, args: List[str]) -> None:
        """Handle the upgrade command."""
        cmd = ["sudo", "rpm-ostree", "upgrade"]
        sys.exit(run_command(cmd))

    def _handle_rollback(self, args: List[str]) -> None:
        """Handle the rollback command."""
        cmd = ["sudo", "rpm-ostree", "rollback"]
        sys.exit(run_command(cmd))

    def _handle_pin(self, args: List[str]) -> None:
        """Handle the pin command."""
        deployments = get_deployment_info()
        if not deployments:
            print("No deployments found.")  # Keep as print for test compatibility
            return

        deployment_num = None  # Initialize variable

        if not args:
            try:
                # Show only unpinned deployments in ascending order
                unpinned_deployments = [d for d in deployments if not d.is_pinned][::-1]

                if not unpinned_deployments:
                    print(
                        "No deployments available to pin."
                    )  # Keep this user-facing message
                    return

                items = [
                    ListItem(
                        "",
                        f"{d.repository} ({d.version})",
                        d.deployment_index,
                    )
                    for d in unpinned_deployments
                ]

                # Get current deployment info for persistent header
                deployment_info_header = get_current_deployment_info()
                persistent_header = format_deployment_header(deployment_info_header)

                selected = _menu_system.show_menu(
                    items,
                    "Select deployment to pin (ESC to cancel):",
                    persistent_header=persistent_header,
                    is_main_menu=False,
                )

                if selected is None:
                    return

                deployment_num = selected
            except MenuExitException as _:
                # ESC pressed in submenu, return to main menu
                return
        else:
            try:
                deployment_num = int(args[0])
            except ValueError:
                print(
                    f"Invalid deployment number: {args[0]}"
                )  # Keep as print for test compatibility
                sys.exit(1)
                return  # Exit after error to avoid executing the command

        if deployment_num is not None:
            cmd = ["sudo", "ostree", "admin", "pin", str(deployment_num)]
            sys.exit(run_command(cmd))

    def _handle_unpin(self, args: List[str]) -> None:
        """Handle the unpin command."""
        deployments = get_deployment_info()
        if not deployments:
            print("No deployments found.")  # Keep as print for test compatibility
            return

        deployment_num = None  # Initialize variable

        if not args:
            try:
                # Show only pinned deployments
                pinned_deployments = [d for d in deployments if d.is_pinned]

                if not pinned_deployments:
                    print("No deployments are pinned.")
                    return

                items = [
                    ListItem(
                        "",
                        f"{d.repository} ({d.version})",
                        d.deployment_index,
                    )
                    for d in pinned_deployments
                ]

                # Get current deployment info for persistent header
                deployment_info_header = get_current_deployment_info()
                persistent_header = format_deployment_header(deployment_info_header)

                selected = _menu_system.show_menu(
                    items,
                    "Select deployment to unpin (ESC to cancel):",
                    persistent_header=persistent_header,
                    is_main_menu=False,
                )

                if selected is None:
                    return

                deployment_num = selected
            except MenuExitException as _:
                # ESC pressed in submenu, return to main menu
                return
        else:
            try:
                deployment_num = int(args[0])
            except ValueError:
                print(
                    f"Invalid deployment number: {args[0]}"
                )  # Keep as print for test compatibility
                sys.exit(1)
                return  # Exit after error to avoid executing the command

        if deployment_num is not None:
            cmd = ["sudo", "ostree", "admin", "pin", "-u", str(deployment_num)]
            sys.exit(run_command(cmd))

    def _handle_rm(self, args: List[str]) -> None:
        """Handle the rm command."""
        deployments = get_deployment_info()
        if not deployments:
            print("No deployments found.")  # Keep as print for test compatibility
            return

        deployment_num = None  # Initialize variable

        if not args:
            try:
                items = [
                    ListItem(
                        "",
                        f"{d.repository} ({d.version}){'*' if d.is_pinned else ''}",
                        d.deployment_index,
                    )
                    for d in deployments
                ][::-1]

                # Get current deployment info for persistent header
                deployment_info_header = get_current_deployment_info()
                persistent_header = format_deployment_header(deployment_info_header)

                selected = _menu_system.show_menu(
                    items,
                    "Select deployment to remove (ESC to cancel):",
                    persistent_header=persistent_header,
                    is_main_menu=False,
                )

                if selected is None:
                    return

                deployment_num = selected
            except MenuExitException as _:
                # ESC pressed in submenu, return to main menu
                return
        else:
            try:
                deployment_num = int(args[0])
            except ValueError:
                print(
                    f"Invalid deployment number: {args[0]}"
                )  # Keep as print for test compatibility
                sys.exit(1)
                return  # Exit after error to avoid executing the command

        if deployment_num is not None:
            cmd = ["sudo", "rpm-ostree", "cleanup", "-r", str(deployment_num)]
            sys.exit(run_command(cmd))


# ============================================================================
# MAIN ENTRY POINT
# ============================================================================


def _main_menu_loop() -> None:
    """Main menu functionality that shows the menu and executes commands."""
    registry = CommandRegistry()

    # Get current deployment info for persistent header
    deployment_info_header = get_current_deployment_info()
    persistent_header = format_deployment_header(deployment_info_header)

    commands = registry.get_commands()
    items = [MenuItem(cmd.name, cmd.description) for cmd in commands]

    selected = _menu_system.show_menu(
        items,
        "Select a command (ESC to exit):",
        persistent_header=persistent_header,
        is_main_menu=True,
    )

    if selected is None:
        # In text mode, if no selection is made, return to allow main to loop
        return

    # Execute the selected command
    command = registry.get_command(selected)
    if command:
        # Execute the command, which may raise MenuExitException
        command.handler([])


def setup_logging(debug: bool = False) -> None:
    """Setup logging configuration."""
    level = logging.DEBUG if debug else logging.INFO
    logging.basicConfig(
        level=level, format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
    )


def main() -> None:
    """Main entry point for the application."""
    # Setup logging based on config
    config = get_config()
    setup_logging(debug=config.settings.debug_mode)

    # Check if curl is available before proceeding
    if not check_curl_presence():
        logger.error("curl is required for this application but was not found.")
        print("Error: curl is required for this application but was not found.")
        print("Please install curl and try again.")
        sys.exit(1)
    else:
        # Only continue execution if curl is available
        # Create command registry
        registry = CommandRegistry()

        # Parse command line arguments
        if len(sys.argv) < 2:
            # Check if we're in a test environment to avoid infinite loop
            in_test_environment = "PYTEST_CURRENT_TEST" in os.environ

            # Show main menu in a loop to return to main menu after submenu ESC
            # But don't loop infinitely in test environments
            while True:
                try:
                    _main_menu_loop()
                    # If in test environment, break after one iteration
                    if in_test_environment:
                        return
                except MenuExitException as e:
                    if e.is_main_menu:
                        sys.exit(0)
                        # If sys.exit is mocked in tests, we still need to exit the function
                        return  # Exit the main function to stop the loop
                    else:
                        # When ESC is pressed in a submenu, continue the loop to show main menu again
                        # unless we're in a test environment
                        if in_test_environment:
                            return
                        continue
        else:
            # Execute command directly
            command_name = sys.argv[1]
            command = registry.get_command(command_name)

            if command:
                # Pass remaining arguments to the command handler
                command.handler(sys.argv[2:])
            else:
                print(f"Unknown command: {command_name}")
                print("\nAvailable commands:")
                for cmd in registry.get_commands():
                    print(f"  {cmd.name} - {cmd.description}")
                sys.exit(1)


if __name__ == "__main__":
    main()
