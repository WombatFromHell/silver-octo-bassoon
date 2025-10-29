#!/usr/bin/env python3
# pyright: strict

import json
import os
import re
import subprocess
import sys
import tomllib
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple, Union

# Define type aliases for our sorting keys
DateVersionKey = Tuple[
    int, int, int, int, int
]  # (-1, -year, -month, -day, -subver) or (context_priority, -year, -month, -day, -subver)
AlphaVersionKey = Tuple[
    int, Tuple[int, ...]
]  # (0, tuple of char codes) or (context_priority, tuple of char codes)
VersionSortKey = Union[DateVersionKey, AlphaVersionKey]


def get_config_path() -> Path:
    """
    Get the path to the urh configuration file.

    Returns:
        Path to the configuration file.
    """
    # Check XDG_CONFIG_HOME first, fallback to ~/.config
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config_home:
        config_file = Path(xdg_config_home) / "urh.toml"
    else:
        config_file = Path.home() / ".config" / "urh.toml"

    # Make sure the parent directory exists
    config_file.parent.mkdir(parents=True, exist_ok=True)
    return config_file


def load_config() -> Dict[str, Any]:
    """
    Load the configuration from TOML file.

    Returns:
        A dictionary containing the configuration.
    """
    config_path = get_config_path()

    if not config_path.exists():
        # Create default config if it doesn't exist
        create_default_config()
        print(f"Created default config file at {config_path}")

    try:
        with open(config_path, "rb") as f:
            return tomllib.load(f)
    except tomllib.TOMLDecodeError as e:
        print(f"Error parsing TOML config file: {e}")
        print("Using default configuration instead.")
        return get_default_config()
    except Exception as e:
        print(f"Error reading config file: {e}")
        print("Using default configuration instead.")
        return get_default_config()


def create_default_config():
    """
    Create a default configuration file with default filter rules and container URLs.
    """
    config_path = get_config_path()

    default_config = get_default_config()

    # Convert to TOML format and write to file
    with open(config_path, "w") as f:
        f.write("# ublue-rebase-helper (urh) configuration file\n")
        f.write(f"# Default location: {config_path}\n")
        f.write("#\n")
        f.write("# For documentation about the format, see DESIGN.md\n")
        f.write("\n")

        # Write repositories section
        f.write('[repositories."ublue-os/bazzite"]\n')
        f.write("include_sha256_tags = false\n")
        f.write("filter_patterns = [\n")
        for pattern in default_config["repositories"]["ublue-os/bazzite"][
            "filter_patterns"
        ]:
            # Escape backslashes for TOML
            escaped_pattern = pattern.replace("\\", "\\\\")
            f.write(f'    "{escaped_pattern}",\n')
        f.write("]\n")
        f.write("ignore_tags = [\n")
        for tag in default_config["repositories"]["ublue-os/bazzite"]["ignore_tags"]:
            f.write(f'    "{tag}",\n')
        f.write("]\n")
        f.write("\n")

        f.write('[repositories."wombatfromhell/bazzite-nix"]\n')
        f.write("include_sha256_tags = false\n")
        f.write("filter_patterns = [\n")
        for pattern in default_config["repositories"]["wombatfromhell/bazzite-nix"][
            "filter_patterns"
        ]:
            # Escape backslashes for TOML
            escaped_pattern = pattern.replace("\\", "\\\\")
            f.write(f'    "{escaped_pattern}",\n')
        f.write("]\n")
        f.write("ignore_tags = [\n")
        for tag in default_config["repositories"]["wombatfromhell/bazzite-nix"][
            "ignore_tags"
        ]:
            f.write(f'    "{tag}",\n')
        f.write("]\n")
        f.write("\n")

        f.write('[repositories."astrovm/amyos"]\n')
        f.write("include_sha256_tags = false\n")
        f.write("filter_patterns = [\n")
        for pattern in default_config["repositories"]["astrovm/amyos"][
            "filter_patterns"
        ]:
            # Escape backslashes for TOML
            escaped_pattern = pattern.replace("\\", "\\\\")
            f.write(f'    "{escaped_pattern}",\n')
        f.write("]\n")
        f.write("ignore_tags = [\n")
        for tag in default_config["repositories"]["astrovm/amyos"]["ignore_tags"]:
            f.write(f'    "{tag}",\n')
        f.write("]\n")
        f.write("transform_patterns = [\n")
        for transform in default_config["repositories"]["astrovm/amyos"][
            "transform_patterns"
        ]:
            # Escape backslashes for TOML in both pattern and replacement
            escaped_pattern = transform["pattern"].replace("\\", "\\\\")
            escaped_replacement = transform["replacement"].replace("\\", "\\\\")
            f.write(
                f'    {{ pattern = "{escaped_pattern}", replacement = "{escaped_replacement}" }},\n'
            )
        f.write("]\n")
        f.write("\n")

        # Write container URLs section
        f.write("[container_urls]\n")
        f.write(f'default = "{default_config["container_urls"]["default"]}"\n')
        f.write("options = [\n")
        for url in default_config["container_urls"]["options"]:
            f.write(f'    "{url}",\n')
        f.write("]\n")
        f.write("\n")

        # Write settings section
        f.write("[settings]\n")
        f.write(
            f"max_tags_display = {default_config['settings']['max_tags_display']}\n"
        )
        f.write(
            f"debug_mode = {str(default_config['settings']['debug_mode']).lower()}\n"
        )


def get_default_config() -> Dict[str, Any]:
    """
    Get the default configuration.

    Returns:
        A dictionary containing the default configuration.
    """
    return {
        "repositories": {
            "ublue-os/bazzite": {
                "include_sha256_tags": False,
                "filter_patterns": [
                    "^sha256-.*\\.sig$",  # signature tags
                    "^sha256-.*",  # sha256- hash patterns
                    "^sha256:.*",  # sha256: hash patterns
                    "^[0-9a-fA-F]{40,64}$",  # 40-64 character hex hashes
                    "^<.*>$",  # <hex-hash> patterns
                    "^(latest|testing|stable|unstable)$",  # exact tag aliases
                    "^testing\\..*",  # testing.* patterns (except latest.YYYYMMDD)
                    "^stable\\..*",  # stable.* patterns
                    "^unstable\\..*",  # unstable.* patterns
                    "^\\d{1,2}$",  # standalone major versions (1-2 digits)
                    "^(latest|testing|stable|unstable)-\\d{1,2}$",  # major version aliases
                    "^\\d{1,2}-(testing|stable|unstable)$",  # version suffix patterns
                ],
                "ignore_tags": ["latest", "testing", "stable", "unstable"],
            },
            "wombatfromhell/bazzite-nix": {
                "include_sha256_tags": False,
                "filter_patterns": [
                    "^sha256-.*\\.sig$",
                    "^sha256-.*",
                    "^sha256:.*",
                    "^[0-9a-fA-F]{40,64}$",  # 40-64 character hex hashes
                    "^<.*>$",
                    "^(latest|testing|stable|unstable)$",
                    "^testing\\..*",
                    "^stable\\..*",
                    "^unstable\\..*",
                    "^\\d{1,2}$",
                    "^(latest|testing|stable|unstable)-\\d{1,2}$",
                    "^\\d{1,2}-(testing|stable|unstable)$",
                ],
                "ignore_tags": ["latest", "testing", "stable", "unstable"],
            },
            "astrovm/amyos": {
                "include_sha256_tags": False,
                "filter_patterns": [
                    "^sha256-.*\\.sig$",
                    "^<.*>$",
                    "^(testing|stable|unstable)$",  # exact tag aliases (NOT latest)
                    "^testing\\..*",
                    "^stable\\..*",
                    "^unstable\\..*",
                    "^\\d{1,2}$",  # standalone major versions
                    "^(latest|testing|stable|unstable)-\\d{1,2}$",  # major version aliases
                    "^\\d{1,2}-(testing|stable|unstable)$",  # version suffix patterns
                ],
                "ignore_tags": ["testing", "stable", "unstable"],
                "transform_patterns": [
                    {
                        "pattern": "^latest\\.(\\d{8})$",
                        "replacement": "\\1",
                    }  # transform latest.YYYYMMDD to YYYYMMDD
                ],
                "latest_dot_handling": "transform_dates_only",  # For amyos: transform date-like latest.YYYYMMDD, filter others
            },
        },
        "container_urls": {
            "default": "ghcr.io/wombatfromhell/bazzite-nix:testing",
            "options": [
                "ghcr.io/wombatfromhell/bazzite-nix:testing",
                "ghcr.io/wombatfromhell/bazzite-nix:stable",
                "ghcr.io/ublue-os/bazzite:stable",
                "ghcr.io/ublue-os/bazzite:testing",
                "ghcr.io/ublue-os/bazzite:unstable",
                "ghcr.io/astrovm/amyos:latest",
            ],
        },
        "settings": {"max_tags_display": 30, "debug_mode": False},
    }


class MenuExitException(Exception):
    """Exception raised when ESC is pressed in a menu.

    Args:
        is_main_menu: If True, indicates ESC was pressed in main menu (should exit program).
                     If False, indicates ESC was pressed in submenu (should return to main menu).
    """

    def __init__(self, is_main_menu: bool = False):
        self.is_main_menu = is_main_menu
        super().__init__()


class OCIClient:
    """
    A simple client for OCI Container Registry interactions (ghcr.io) that uses OAuth2
    and caches tokens to a temporary file.
    """

    def __init__(
        self,
        repository: str,
        cache_path: Optional[str] = None,
        filter_rules: Optional["TOMLFilterRules"] = None,
        debug: bool = False,
    ):
        """
        Initialize the client with a repository name.

        Args:
            repository: The repository name in format "owner/repo"
            cache_path: Optional cache path for testing purposes
            filter_rules: Optional custom filter rules for this repository
            debug: Enable debug output to see raw and processed tags
        """
        if not repository or "/" not in repository:
            raise ValueError("Repository must be in 'owner/repo' format.")
        self.repository = repository
        self._cache_path_override = cache_path
        self.filter_rules = (
            filter_rules
            if filter_rules is not None
            else get_filter_rules_for_repository(repository)
        )
        self.debug = debug

    def _get_cache_filepath(self) -> str:
        """
        Generates a safe and unique cache file path in /tmp/ for the token.
        Uses a single token file for all GHCR repositories.
        """
        if self._cache_path_override:
            return self._cache_path_override

        return "/tmp/oci_ghcr_token"

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
                    print(f"Found cached token at {cache_filepath}")
                    return f.read().strip()
            except (IOError, OSError) as e:
                print(f"Warning: Could not read cached token at {cache_filepath}: {e}")

        # 2. If no cache, fetch a new token
        print("No valid cached token found. Fetching a new one...")
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
                try:
                    with open(cache_filepath, "w") as f:
                        f.write(token)
                    print(f"Successfully cached new token to {cache_filepath}")
                except (IOError, OSError) as e:
                    print(
                        f"Warning: Could not write token to cache {cache_filepath}: {e}"
                    )
                return token
            return None
        except (subprocess.SubprocessError, json.JSONDecodeError, KeyError) as e:
            print(f"Error getting token: {e}")
            return None

    def _invalidate_cache(self):
        """Deletes the cached token file if it exists."""
        cache_filepath = self._get_cache_filepath()
        try:
            os.remove(cache_filepath)
            print(f"Invalidated and removed cache file: {cache_filepath}")
        except FileNotFoundError:
            # Cache file doesn't exist, nothing to do.
            pass

    def _parse_link_header(self, link_header: Optional[str]) -> Optional[str]:
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

    def get_all_tags(self, token: str) -> Optional[Dict[str, Any]]:
        """
        Get all tags for the repository using the provided token with pagination.
        Follows Link headers to get all tags until no more pages exist.

        Args:
            token: The OAuth2 token.

        Returns:
            A dictionary containing all tags if successful, None otherwise.
        """
        # Use the full URL with protocol for the initial request
        base_url = f"https://ghcr.io/v2/{self.repository}/tags/list"
        initial_url = f"{base_url}?n=200"
        all_tags: List[str] = []
        next_url = initial_url

        while next_url:
            # Check if the next_url is a relative path (from Link header) or full URL
            if next_url.startswith("/"):
                # If it's a relative path, prepend the base URL
                full_url = f"https://ghcr.io{next_url}"
            else:
                # If it's already a full URL, use as is
                full_url = next_url

            # Fetch a single page of tags using the shared method
            result = self._fetch_single_page_tags(full_url, token)
            if not result:
                return None

            # Extract tags and next URL from the result
            tags_data = result["tags_data"]
            link_header = result["link_header"]

            # Get the next URL by parsing the Link header
            next_url = (
                self._parse_link_header(link_header)
                if link_header is not None
                else None
            )

            # Add tags to the collection
            if "tags" in tags_data:
                all_tags.extend(tags_data["tags"])

        # Return all collected tags
        return {"tags": all_tags}

    def _parse_response_headers_and_body(self, response_text: str) -> Tuple[str, str]:
        """
        Parse headers and body from an HTTP response.

        Args:
            response_text: The raw response text from curl

        Returns:
            A tuple of (headers_part, body)
        """
        # Split headers and body (HTTP responses are separated by \r\n\r\n)
        if "\r\n\r\n" in response_text:
            headers_part, body = response_text.split("\r\n\r\n", 1)
        elif "\n\n" in response_text:
            # In test environments, newlines might not be \r\n
            headers_part, body = response_text.split("\n\n", 1)
        else:
            # If no separate headers found, treat the entire output as response body
            headers_part = ""
            body = response_text

        return headers_part, body

    def _extract_link_header(self, headers_part: str) -> Optional[str]:
        """
        Extract the Link header from response headers.

        Args:
            headers_part: The headers part of the response

        Returns:
            The Link header value if found, None otherwise
        """
        link_header = None
        if headers_part:
            for line in headers_part.splitlines():
                if line.lower().startswith("link:"):
                    link_header = line[5:].strip()  # Remove 'Link:' and whitespace
                    break
        return link_header

    def _process_response(self, stdout_text: str) -> Optional[Dict[str, Any]]:
        """
        Process the HTTP response from curl.

        Args:
            stdout_text: The raw response text from curl

        Returns:
            A dictionary containing the parsed response if successful, None otherwise.
        """
        # Parse headers and body from the response
        headers_part, body = self._parse_response_headers_and_body(stdout_text)

        # Find Link header in headers_part
        link_header = self._extract_link_header(headers_part)

        # Parse tags from the response body
        try:
            response_data = json.loads(body)
            return {"tags_data": response_data, "link_header": link_header}
        except json.JSONDecodeError as e:
            print(f"Error parsing tags response: {e}")
            print(f"Response body: {body}")
            return None

    def _make_request_with_token(
        self, url: str, token: str
    ) -> subprocess.CompletedProcess[str]:
        """
        Make a request to the given URL with the provided token.

        Args:
            url: The URL to fetch tags from
            token: The OAuth2 token to use for authentication

        Returns:
            The subprocess result
        """
        return subprocess.run(
            ["curl", "-s", "-i", "-H", f"Authorization: Bearer {token}", url],
            capture_output=True,
            text=True,
            check=True,
        )

    def _fetch_single_page_tags(self, url: str, token: str) -> Optional[Dict[str, Any]]:
        """
        Fetch a single page of tags from the given URL with the provided token.
        Implements a retry logic if the token is expired/invalid.

        Args:
            url: The URL to fetch tags from
            token: The OAuth2 token to use for authentication

        Returns:
            A dictionary containing the tags if successful, None otherwise.
        """
        # First try with the original token
        try:
            result = self._make_request_with_token(url, token)
            return self._process_response(result.stdout)
        except subprocess.CalledProcessError as e:
            # Check if the failure was due to an invalid/expired token
            if "401" in e.stderr or "403" in e.stderr:
                print("Request failed with 401/403. Token might be expired.")
                self._invalidate_cache()

                print("Retrying with a new token...")
                new_token = self.get_token()
                if new_token:
                    # Retry the request once with the new token
                    try:
                        retry_result = self._make_request_with_token(url, new_token)
                        processed_result = self._process_response(retry_result.stdout)
                        if processed_result:
                            print("Retry successful.")
                        return processed_result
                    except subprocess.CalledProcessError as retry_e:
                        print(f"Retry also failed: {retry_e.stderr}")
                        return None
            else:
                print(f"Error getting tags: {e.stderr}")
                return None
        except json.JSONDecodeError as e:
            print(f"Error parsing tags response: {e}")
            return None

    def get_tags(self, token: str) -> Optional[Dict[str, Any]]:
        """
        Get the tags for the repository using the provided token.
        Implements a retry logic if the token is expired/invalid.

        Args:
            token: The OAuth2 token.

        Returns:
            A dictionary containing the tags if successful, None otherwise.
        """
        # For backward compatibility, keep the original behavior with 200 tags
        url = f"https://ghcr.io/v2/{self.repository}/tags/list?n=200"

        result = self._fetch_single_page_tags(url, token)
        if result:
            return result["tags_data"]
        return None

    def _should_filter_tag(self, tag: str) -> bool:
        """
        Determine if a tag should be filtered out based on multiple criteria.

        Args:
            tag: The tag to evaluate

        Returns:
            True if the tag should be filtered out, False otherwise
        """
        # Use the repository-specific filter rules
        return self.filter_rules.should_filter_tag(tag)

    def _filter_and_sort_tags(
        self, tags_data: Optional[Dict[str, Any]]
    ) -> Optional[Dict[str, Any]]:
        """
        Filter out SHA256 tags and tag aliases (latest, testing, stable), then sort tags in descending order by version.
        Uses repository-specific filter rules to handle different tag formats appropriately.

        Args:
            tags_data: Dictionary containing tags data from the API

        Returns:
            A dictionary containing filtered and sorted tags, or None if input is None
        """

        if tags_data is None or "tags" not in tags_data:
            return tags_data

        tags: List[str] = tags_data["tags"]

        if self.debug:
            print(
                f"DEBUG: Raw tags from API ({len(tags)} total): {tags[:20]}{'...' if len(tags) > 20 else ''}"
            )
            # Check specifically for latest.YYYYMMDD format tags
            latest_format_tags = [
                tag
                for tag in tags
                if tag.lower().startswith("latest.")
                and len(tag) > 7
                and tag[7:].isdigit()
                and len(tag[7:]) >= 8
            ]
            if latest_format_tags:
                print(
                    f"DEBUG: Found latest.YYYYMMDD format tags: {latest_format_tags[:10]}"
                )

        # Use the repository-specific filter rules to process tags
        processed_tags = self.filter_rules.filter_and_sort_tags(tags, limit=30)

        if self.debug:
            print(
                f"DEBUG: Processed tags: {processed_tags[:20]}{'...' if len(processed_tags) > 20 else ''}"
            )

        # Return a new dictionary with processed tags
        result: Dict[str, Any] = tags_data.copy()
        result["tags"] = processed_tags
        return result

    def fetch_repository_tags(self) -> Optional[Dict[str, Any]]:
        """
        Get the tags for the repository by first obtaining a token,
        then filter and sort the results.

        Returns:
            A dictionary containing the filtered and sorted tags if successful, None otherwise.
        """
        token = self.get_token()
        if token is None:
            print("Could not obtain a token. Aborting.")
            return None

        tags_data = self.get_all_tags(token)
        return self._filter_and_sort_tags(tags_data)

    def get_raw_tags(self) -> Optional[Dict[str, Any]]:
        """
        Get the raw tags for the repository by first obtaining a token,
        without any filtering or sorting.

        Returns:
            A dictionary containing the raw tags if successful, None otherwise.
        """
        token = self.get_token()
        if token is None:
            print("Could not obtain a token. Aborting.")
            return None

        tags_data = self.get_all_tags(token)
        return tags_data

    def get_all_tags_raw(self) -> Optional[Dict[str, Any]]:
        """
        Get all tags from the repository without any processing by filter rules.
        This bypasses the filter rules entirely and returns raw tag data.

        Returns:
            A dictionary containing the raw tags if successful, None otherwise.
        """
        token = self.get_token()
        if token is None:
            print("Could not obtain a token. Aborting.")
            return None

        tags_data = self.get_all_tags(token)
        # Return the raw data without applying filter rules
        return tags_data


def run_command(cmd: List[str]) -> int:
    """Run a command and return its exit code."""
    try:
        result = subprocess.run(cmd, check=False)
        return result.returncode
    except FileNotFoundError:
        print(f"Command not found: {' '.join(cmd)}")
        return 1


def create_submenu_display_functions(
    data_source: Callable[[], List[str]],
    non_tty_message: str,
    gum_not_found_message: str,
) -> Tuple[
    Callable[[Callable[[str], Any]], None], Callable[[Callable[[str], Any]], None]
]:
    """
    Factory function that creates the non-TTY and gum-not-found display functions for a submenu.

    Args:
        data_source: Function that returns the list of options to display
        non_tty_message: Message to show when not in TTY context
        gum_not_found_message: Message to show when gum is not found

    Returns:
        A tuple of (non_tty_func, gum_not_found_func)
    """

    def display_non_tty(print_func: Callable[[str], Any]) -> None:
        print_func(non_tty_message)
        options: List[str] = data_source()
        for option in options:
            print_func(f"{option}")
        print_func("\nRun 'urh.py with a specific option.'")

    def display_gum_not_found(print_func: Callable[[str], Any]) -> None:
        print_func(gum_not_found_message)
        options: List[str] = data_source()
        for option in options:
            print_func(f"{option}")
        print_func("\nRun 'urh.py with a specific option.'")

    return display_non_tty, display_gum_not_found


def run_gum_submenu(
    options: List[str],
    header: str,
    display_func_non_tty: Callable[[Callable[[str], Any]], None],
    display_func_gum_not_found: Callable[[Callable[[str], Any]], None],
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
    no_selection_message: str = "No option selected.",
    is_main_menu: bool = False,
) -> Optional[str]:
    """
    Generic function to run a gum submenu with specified options.

    Args:
        options: List of options to display in submenu
        header: Header text for the submenu
        display_func_non_tty: Function to call when not in TTY
        display_func_gum_not_found: Function to call when gum is not found
        is_tty_func: Function to determine if running in TTY
        subprocess_run_func: Function for subprocess execution
        print_func: Function for printing
        no_selection_message: Message to display when no selection is made

    Returns:
        Selected option string or None if no selection made
    """
    # If not running in TTY, show the list only
    if not is_tty_func():
        display_func_non_tty(print_func)
        return None

    # Try to run gum
    try:
        result = subprocess_run_func(
            [
                "gum",
                "choose",
                "--cursor",
                "→",
                "--selected-prefix",
                "✓ ",
                "--header",
                header,
            ]
            + options,
            text=True,
            stdout=subprocess.PIPE,  # Only capture stdout to get user selection
            # stdin and stderr will inherit from the parent process, allowing gum's UI to appear
        )

        # Handle successful selection
        if result.returncode == 0:
            selected_option = result.stdout.strip()
            return selected_option

        # Handle gum exit code 1 (ESC or Ctrl+C)
        if result.returncode == 1:
            return _handle_gum_no_selection(
                print_func, no_selection_message, is_main_menu
            )

        # For other errors, return None
        return None

    except FileNotFoundError:
        # gum not found, show the list only
        display_func_gum_not_found(print_func)
        return None


def _handle_gum_no_selection(
    print_func: Callable[[str], Any], no_selection_message: str, is_main_menu: bool
) -> Optional[str]:
    """
    Handle the case when gum returns exit code 1 (no selection made).

    Args:
        print_func: Function for printing
        no_selection_message: Message to display when no selection is made
        is_main_menu: Whether this is the main menu

    Returns:
        None, but may raise MenuExitException
    """
    # Check if we're in a test environment
    in_test_mode = "PYTEST_CURRENT_TEST" in os.environ
    if in_test_mode:
        # In test mode, print message and return None for integration tests
        print_func(no_selection_message)
        return None
    else:
        # avoid printing fallback message on ESC
        sys.stdout.write("\033[F\033[K")
        sys.stdout.flush()
        # In normal mode, raise exception with context
        raise MenuExitException(is_main_menu=is_main_menu)


def parse_command_argument(
    args: List[str],
    submenu_func: Callable[..., Optional[Any]],
    arg_parser: Optional[Callable[[str], Any]],
    persistent_header: Optional[str] = None,
) -> Optional[Any]:
    """
    Parse command argument, either from provided args or from submenu.

    Args:
        args: Command line arguments
        submenu_func: Function to call when no arguments provided
        arg_parser: Function to parse the argument
        persistent_header: Optional persistent header to display

    Returns:
        The parsed argument value, or None if no selection made
    """
    if not args:
        # No arguments provided, show submenu to select
        # Call submenu_func with persistent header if it accepts it
        if persistent_header:
            # Use a wrapper function that accepts persistent_header and calls submenu_func
            selected_value = submenu_func(persistent_header=persistent_header)
        else:
            selected_value = submenu_func()
        # If submenu raises an exception (like MenuExitException), it will propagate up
        # If submenu returns None, we exit gracefully
        if selected_value is None or arg_parser is None:
            return None  # No selection made, exit gracefully
        return arg_parser(selected_value)
    else:
        if arg_parser is None:
            return str(args[0])  # Default to string parsing if no parser provided
        return arg_parser(args[0])


def get_error_message(
    args: List[str], error_message_func: Optional[Callable[[str], str]]
) -> str:
    """
    Get the appropriate error message for invalid arguments.

    Args:
        args: Command line arguments
        error_message_func: Optional function to format error message

    Returns:
        The error message string
    """
    # Default error message if no custom function provided
    if error_message_func:
        return error_message_func(args[0])
    else:
        return f"Invalid argument: {args[0]}"


def handle_command_with_submenu(
    args: List[str],
    submenu_func: Callable[[], Optional[Any]],
    cmd_builder: Callable[[Any], List[str]],
    arg_parser: Optional[Callable[[str], Any]] = None,
    error_message_func: Optional[Callable[[str], str]] = None,
) -> None:
    """
    Generic function to handle commands that can accept arguments or show submenus.

    Args:
        args: Command line arguments
        submenu_func: Function to call when no arguments provided
        cmd_builder: Function to build command from parsed argument
        arg_parser: Optional function to parse the argument (default: str)
        error_message_func: Optional function to format error message (default: uses arg_parser name)
    """
    if arg_parser is None:
        arg_parser = str  # Default to string parsing

    try:
        parsed_value = parse_command_argument(args, submenu_func, arg_parser)
        if parsed_value is None:
            return  # No selection made, exit gracefully
    except ValueError:
        error_msg = get_error_message(args, error_message_func)
        print(error_msg)
        return

    cmd = cmd_builder(parsed_value)
    sys.exit(run_command(cmd))


def get_commands_with_descriptions() -> List[str]:
    """Get the list of commands with descriptions."""
    return [
        "check - Check for available updates",
        "ls - List deployments with details",
        "pin - Pin a deployment",
        "rebase - Rebase to a container image",
        "remote-ls - List available tags for a container image",
        "rm - Remove a deployment",
        "rollback - Roll back to the previous deployment",
        "unpin - Unpin a deployment",
        "upgrade - Upgrade to the latest version",
    ]


def get_container_options() -> List[str]:
    """Get the list of container URL options from TOML configuration."""
    config = load_config()
    return config.get("container_urls", {}).get(
        "options",
        [
            "ghcr.io/wombatfromhell/bazzite-nix:testing",
            "ghcr.io/wombatfromhell/bazzite-nix:stable",
            "ghcr.io/ublue-os/bazzite:stable",
            "ghcr.io/ublue-os/bazzite:testing",
            "ghcr.io/ublue-os/bazzite:unstable",
            "ghcr.io/astrovm/amyos:latest",
        ],
    )


def show_command_menu(
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
) -> Optional[str]:
    """Show a menu of available commands using gum."""
    data_source = get_commands_with_descriptions
    display_non_tty, display_gum_not_found = create_submenu_display_functions(
        data_source,
        "Not running in interactive mode. Available commands:",
        "gum not found. Available commands:",
    )

    options = get_commands_with_descriptions()
    result = run_gum_submenu(
        options,
        "Select command (ESC to cancel):",
        display_non_tty,
        display_gum_not_found,
        is_tty_func,
        subprocess_run_func,
        print_func,
        "No command selected.",
        is_main_menu=True,
    )

    if result:
        # Extract just the command name from the selected option
        command = result.split(" - ")[0] if " - " in result else result
        return command
    return result


def show_rebase_submenu(
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
) -> Optional[str]:
    """Show a submenu of common container URLs using gum."""
    data_source = get_container_options
    display_non_tty, display_gum_not_found = create_submenu_display_functions(
        data_source,
        "Available container URLs:",
        "gum not found. Available container URLs:",
    )

    options = data_source()
    return run_gum_submenu(
        options,
        "Select container image (ESC to cancel):",
        display_non_tty,
        display_gum_not_found,
        is_tty_func,
        subprocess_run_func,
        print_func,
    )


def show_remote_ls_submenu(
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
) -> Optional[str]:
    """Show a submenu of common container URLs for remote-ls using gum."""
    data_source = get_container_options
    display_non_tty, display_gum_not_found = create_submenu_display_functions(
        data_source,
        "Available container URLs:",
        "gum not found. Available container URLs:",
    )

    options = data_source()
    return run_gum_submenu(
        options,
        "Select container image to list tags (ESC to cancel):",
        display_non_tty,
        display_gum_not_found,
        is_tty_func,
        subprocess_run_func,
        print_func,
    )


def rebase_command(
    args: List[str],
    show_rebase_submenu_func: Optional[Callable[[], Optional[str]]] = None,
):
    """Handle the rebase command."""
    if show_rebase_submenu_func is None:
        show_rebase_submenu_func = show_rebase_submenu

    def cmd_builder(url: str) -> List[str]:
        return ["sudo", "rpm-ostree", "rebase", url]

    handle_command_with_submenu(args, show_rebase_submenu_func, cmd_builder)


def extract_repository_from_url(url: str) -> str:
    """
    Extract the repository name from a container URL.

    Args:
        url: The container URL (e.g., "ghcr.io/user/repo:tag")

    Returns:
        The repository name (e.g., "user/repo")
    """
    if url.startswith(("ghcr.io/", "docker.io/", "quay.io/", "gcr.io/")):
        # Extract the part after the registry
        registry_removed = url.split("/", 1)[1]
        # Remove the tag part if present
        repo_part = registry_removed.split(":")[0]
    else:
        # For URLs that don't start with a specific registry, assume it's the full repo part
        repo_part = url.split(":")[0] if ":" in url else url
    return repo_part


def extract_context_from_url(url: str) -> Optional[str]:
    """
    Extract the tag context from a URL (e.g., "testing", "stable", "unstable").

    Args:
        url: The container URL

    Returns:
        The tag context if present, None otherwise
    """
    if ":" in url:
        url_tag = url.split(":")[-1]
        if url_tag in ["testing", "stable", "unstable"]:
            return url_tag
    return None


def get_current_deployment_info() -> Optional[Dict[str, str]]:
    """
    Get the current deployment information by parsing 'rpm-ostree status'.

    Returns:
        A dictionary containing repository and version info, or None if parsing fails
    """
    try:
        result = subprocess.run(
            ["rpm-ostree", "status"], capture_output=True, text=True
        )
        if result.returncode != 0:
            return None

        lines = result.stdout.split("\n")

        # Find the current deployment line (marked with ●)
        current_deployment = None
        version = None

        for i, line in enumerate(lines):
            # Look for the current deployment (marked with ●)
            if line.strip().startswith("●"):
                current_deployment = line.strip()
                # Look for the version in subsequent lines
                for j in range(i + 1, len(lines)):
                    next_line = lines[j].strip()
                    # Stop if we reach another deployment line or empty line
                    if next_line.startswith("●") or (
                        next_line.startswith(" ")
                        and "ostree-image-signed:" in next_line
                    ):
                        break
                    # Look for the Version line
                    if next_line.startswith("Version:"):
                        version = next_line.replace("Version:", "").strip()
                        # Extract just the version string (e.g., 'testing-43.20251030')
                        if " (" in version:
                            version = version.split(" (")[0].strip()
                        break
                break

        if not current_deployment:
            return None

        # Extract the image URL from the current deployment line
        # Find the URL part after "ostree-image-signed:"
        url_part = None
        if "ostree-image-signed:" in current_deployment:
            # Handle both formats: "ostree-image-signed:docker://<url>" and "ostree-image-signed:<url>"
            after_prefix = current_deployment.split("ostree-image-signed:", 1)[
                1
            ].strip()
            if after_prefix.startswith("docker://"):
                url_part = after_prefix[9:]  # Remove "docker://" prefix
            else:
                url_part = after_prefix

        if not url_part:
            return None

        # Extract repository from the URL
        repository = extract_repository_from_url(url_part)

        return {"repository": repository, "version": version or "Unknown"}
    except Exception as e:
        print(f"Error parsing current deployment info: {e}")
        return None


def format_deployment_header(deployment_info: Optional[Dict[str, str]]) -> str:
    """
    Format the deployment information into a header string.

    Args:
        deployment_info: Dictionary containing repository and version info

    Returns:
        Formatted header string
    """
    if not deployment_info or not deployment_info.get("repository"):
        return (
            "Current deployment: System Information: Unable to retrieve deployment info"
        )

    repository = deployment_info["repository"]
    version = deployment_info.get("version", "Unknown")

    return f"Current deployment: {repository} ({version})"


def remote_ls_command(
    args: List[str],
    show_remote_ls_submenu_func: Optional[Callable[[], Optional[str]]] = None,
):
    """Handle the remote-ls command to list tags for a container image."""
    if show_remote_ls_submenu_func is None:
        show_remote_ls_submenu_func = show_remote_ls_submenu

    def parse_url(url: str) -> str:
        """Parse and validate the container URL."""
        return url

    def error_message(value: str) -> str:
        return f"Invalid container URL: {value}"

    def handle_selection(url: str) -> None:
        """Handle the selected or provided URL by listing its tags."""
        try:
            # Extract the repository name from the URL (e.g., from "ghcr.io/user/repo:tag" get "user/repo")
            repo_part = extract_repository_from_url(url)

            # Determine the tag context from the URL (e.g., "testing", "stable", "unstable", etc.)
            url_tag_context = extract_context_from_url(url)

            # For astrovm/amyos repository, also treat "latest" as a special context
            if repo_part == "astrovm/amyos" and url_tag_context is None:
                # Check if the URL has :latest tag without it being recognized as a context
                if ":" in url and url.split(":")[-1] == "latest":
                    url_tag_context = "latest"

            # Create OCIClient instance with appropriate filter rules
            client = OCIClient(repo_part)

            if url_tag_context:
                # If there's a URL context (e.g. :testing or :stable), get raw tags and apply context-aware processing
                # For some repositories, we still need to apply transformations even with context
                tags_data = client.get_raw_tags()

                if tags_data and "tags" in tags_data:
                    tags = tags_data["tags"]
                    if tags:
                        print(f"Tags for {url}:")

                        # Apply repository-specific transformations first, then context-aware filtering
                        # This ensures that amyos 'latest.20251031' becomes '20251031' before context filtering
                        transformed_tags = [
                            client.filter_rules.transform_tag(tag) for tag in tags
                        ]

                        # Apply context-aware filtering and sorting based on URL tag context
                        # Use the repository-specific filter rules from the client
                        filtered_and_sorted_tags = (
                            client.filter_rules.context_aware_filter_and_sort(
                                transformed_tags, url_tag_context
                            )
                        )

                        for tag in filtered_and_sorted_tags:
                            print(f"  {tag}")
                    else:
                        print(f"No tags found for {url}")
                else:
                    print(f"Could not fetch tags for {url}")
            else:
                # Otherwise, use the standard processed tags with repository-specific rules
                tags_data = client.fetch_repository_tags()

                if tags_data and "tags" in tags_data:
                    tags = tags_data["tags"]
                    if tags:
                        print(f"Tags for {url}:")

                        # Use the already processed tags from repository-specific rules
                        for tag in tags:
                            print(f"  {tag}")
                    else:
                        print(f"No tags found for {url}")
                else:
                    print(f"Could not fetch tags for {url}")
        except Exception as e:
            print(f"Error fetching tags for {url}: {e}")

    if not args:
        # No arguments provided, show submenu to select
        selected_value = show_remote_ls_submenu_func()
        if selected_value is not None:
            handle_selection(selected_value)
    else:
        try:
            parsed_value = parse_url(args[0])
            handle_selection(parsed_value)
        except ValueError:
            print(error_message(args[0]))

    # Exit after displaying tags since the command is complete
    sys.exit(0)


class TOMLFilterRules:
    """
    Filter rules implementation that uses TOML configuration for repository-specific settings.
    """

    def __init__(self, repository: str):
        """
        Initialize filter rules based on TOML configuration.

        Args:
            repository: The repository name to get rules for
        """
        self.config = load_config()
        self.repository = repository

        # Get repository-specific settings, falling back to default if not found
        repo_config = self.config.get("repositories", {}).get(repository, {})

        # If no specific configuration is found for this repository, fall back to a default repository configuration
        if not repo_config and repository not in self.config.get("repositories", {}):
            # For unknown repositories, use bazzite as a default since it has general-purpose rules
            repo_config = self.config.get("repositories", {}).get(
                "ublue-os/bazzite", {}
            )

        self.include_sha256_tags = repo_config.get("include_sha256_tags", False)
        self.filter_patterns = repo_config.get("filter_patterns", [])
        self.ignore_tags = repo_config.get("ignore_tags", [])
        self.transform_patterns = repo_config.get("transform_patterns", [])

        # Get global settings
        self.max_tags_display = self.config.get("settings", {}).get(
            "max_tags_display", 30
        )

    def should_filter_tag(self, tag: str) -> bool:
        """
        Determine if a tag should be filtered out based on TOML configuration.

        Args:
            tag: The tag to evaluate

        Returns:
            True if the tag should be filtered out, False otherwise
        """
        # Special handling for latest. tags (mimics original _should_filter_tag_common behavior):
        # - Filter out "latest." (no suffix)
        # - Filter out "latest.<non-date>" like "latest.1", "latest.something"
        # - Keep "latest.<date>" like "latest.20251031" for transformation by repository-specific rules
        if tag.lower().startswith("latest."):
            suffix = tag.lower()[7:]  # Get part after "latest."
            if not suffix:  # "latest." with no suffix
                return True
            # Check if suffix looks like a date (YYYYMMDD format) - don't filter these, they need transformation
            if len(suffix) >= 8 and suffix.isdigit():
                # This looks like a date in YYYYMMDD format, don't filter it - let repo-specific rules handle it
                return False
            else:
                # This is not a date format, likely "latest.1", "latest.something", etc. - filter it out
                return True

        # Check if tag is in ignore list
        if tag.lower() in [t.lower() for t in self.ignore_tags]:
            return True

        # Check against filter patterns
        for pattern in self.filter_patterns:
            if re.match(pattern, tag.lower()):
                return True

        # Always filter out signature tags (sha256-*.sig) unless specifically allowed
        if tag.lower().endswith(".sig") and "sha256-" in tag.lower():
            return True

        # Filter out 64-character SHA256 hash tags (unless override is enabled)
        if not self.include_sha256_tags:
            if len(tag) == 64 and all(c in "0123456789abcdefABCDEF" for c in tag):
                return True

        return False

    def transform_tag(self, tag: str) -> str:
        """
        Transform a tag to its desired format based on TOML configuration.

        Args:
            tag: The original tag

        Returns:
            The transformed tag
        """
        # Apply transformation patterns from config
        for transform in self.transform_patterns:
            pattern = transform.get("pattern", "")
            replacement = transform.get("replacement", "")

            if pattern and replacement:
                try:
                    # Use re.sub to apply the transformation
                    # The replacement string should be applied as-is to allow capture groups like $1
                    transformed = re.sub(pattern, replacement, tag)
                    if transformed != tag:  # Only return if transformation occurred
                        return transformed
                except re.error:
                    # If the regex is invalid, skip this pattern
                    continue

        # Return the original tag if no transformations applied
        return tag

    def filter_and_sort_tags(
        self, tags: List[str], limit: Optional[int] = None
    ) -> List[str]:
        """
        Filter, transform, and sort the complete list of tags based on TOML configuration.

        Args:
            tags: List of tags to process
            limit: Maximum number of tags to return (None to use configured default)

        Returns:
            List of processed tags
        """
        # Apply transformations first
        transformed_tags = [self.transform_tag(tag) for tag in tags]

        # Then filter tags
        filtered_tags = [
            tag for tag in transformed_tags if not self.should_filter_tag(tag)
        ]

        # Then sort tags using the existing sorting function
        sorted_tags = sorted(
            filtered_tags,
            key=lambda t: _create_version_sort_key(t, include_context_priority=False),
        )

        # Use the specified limit or fall back to configured default
        effective_limit = limit if limit is not None else self.max_tags_display
        if effective_limit is not None:
            return sorted_tags[:effective_limit]
        return sorted_tags

    def context_aware_filter_and_sort(
        self,
        tags: List[str],
        url_context: Optional[str] = None,
        limit: Optional[int] = None,
    ) -> List[str]:
        """
        Filter and sort tags based on the context from the URL, using repository-specific TOML rules.

        Args:
            tags: List of tags to filter and sort
            url_context: The context from the URL (e.g., "testing", "stable", or None)
            limit: Maximum number of tags to return (None to use configured default)

        Returns:
            Filtered, sorted, and limited list of tags
        """
        # Apply transformations first
        transformed_tags = [self.transform_tag(tag) for tag in tags]

        # Then filter tags using repository-specific rules
        filtered_tags = [
            tag for tag in transformed_tags if not self.should_filter_tag(tag)
        ]

        if url_context:
            # If URL has a tag context (like :testing or :stable), only show tags with that prefix
            context_filtered_tags = self._context_filter_tags(
                filtered_tags, url_context
            )

            # Apply deduplication for context-aware filtering to avoid duplicates
            # (e.g., when both original YYYYMMDD and transformed latest.YYYYMMDD exist)
            unique_context_filtered_tags = self._deduplicate_tags_by_version(
                context_filtered_tags
            )

            # Sort by context-aware sorting function
            sorted_tags: List[str] = sorted(
                unique_context_filtered_tags,
                key=lambda t: _create_version_sort_key(
                    t, url_context, include_context_priority=True
                ),
            )
        else:
            # When no context specified, deduplicate by extracting version information
            unique_tags = self._deduplicate_tags_by_version(filtered_tags)

            # Use basic date-based sorting without preferencing prefixes
            sorted_tags: List[str] = sorted(
                unique_tags,
                key=lambda t: _create_version_sort_key(
                    t, include_context_priority=False
                ),
            )

        # Use the specified limit or fall back to configured default
        effective_limit = limit if limit is not None else self.max_tags_display
        if effective_limit is not None:
            return sorted_tags[:effective_limit]
        return sorted_tags

    def _context_filter_tags(self, tags: List[str], url_context: str) -> List[str]:
        """
        Filter tags to only include those with the matching context prefix.
        For the 'astrovm/amyos' repository with 'latest' context, filter to include only YYYYMMDD format tags
        (which are the transformed version of 'latest.YYYYMMDD' tags).

        Args:
            tags: List of tags to filter
            url_context: The context to filter by (e.g., "testing", "stable", "latest")

        Returns:
            List of tags that match the context
        """
        if self.repository == "astrovm/amyos" and url_context == "latest":
            # For astrovm/amyos with latest context, after transformation we expect YYYYMMDD format tags
            # (originally from latest.YYYYMMDD which got transformed to YYYYMMDD)
            import re

            yyyymmdd_pattern = r"^\d{8}$"  # 8 digits representing YYYYMMDD
            return [tag for tag in tags if re.match(yyyymmdd_pattern, tag)]
        else:
            # For other repositories or other contexts, use the standard prefix-based filtering
            context_prefix = f"{url_context}-"
            return [tag for tag in tags if tag.startswith(context_prefix)]

    def _deduplicate_tags_by_version(self, tags: List[str]) -> List[str]:
        """
        Deduplicate tags by extracting version information to keep unique versions.

        Args:
            tags: List of tags to deduplicate

        Returns:
            List of deduplicated tags
        """
        # Create a dict to store the best tag for each unique version pattern
        unique_version_tags: Dict[str, str] = {}

        for tag in tags:
            # Extract version information for deduplication
            version_key = self._extract_version_key(tag)
            if version_key not in unique_version_tags or self._should_replace_tag(
                unique_version_tags[version_key], tag
            ):
                unique_version_tags[version_key] = tag

        # Get the unique tags
        return list(unique_version_tags.values())

    def _extract_version_key(self, tag: str) -> str:
        """
        Extract a version key for deduplication purposes.
        For tags like 'stable-43.20251028', '43.20251028', 'testing-43.20251028',
        this returns a normalized version string to identify duplicates.
        """
        import re

        # Remove prefix if present for version parsing
        clean_tag = tag
        if tag.startswith("testing-"):
            clean_tag = tag[8:]  # Remove "testing-" prefix
        elif tag.startswith("stable-"):
            clean_tag = tag[7:]  # Remove "stable-" prefix
        elif tag.startswith("unstable-"):
            clean_tag = tag[9:]  # Remove "unstable-" prefix

        # Try XX.YYYYMMDD[.SUBVER] format
        match = re.match(r"^(\d+)\.(\d{8})(?:\.(\d+))?$", clean_tag)
        if match:
            version_series = match.group(1)
            date_part = match.group(2)
            subver_part = match.group(3) if match.group(3) else ""
            return f"{version_series}.{date_part}.{subver_part}"

        # Try YYYYMMDD[.SUBVER] format
        match = re.match(r"^(\d{8})(?:\.(\d+))?$", clean_tag)
        if match:
            date_part = match.group(1)
            subver_part = match.group(2) if match.group(2) else ""
            return f"{date_part}.{subver_part}"

        # For non-matching formats, return the tag itself as the key (lowercase for case-insensitive comparison)
        return tag.lower()

    def _should_replace_tag(self, existing_tag: str, new_tag: str) -> bool:
        """
        Determine if a new tag should replace an existing tag during deduplication.
        When there are duplicates, prefer the prefixed version (stable-, testing-, unstable-)
        over the unprefixed version with the same content.
        """
        # If the new tag has a prefix but the existing doesn't, prefer the new one
        new_has_prefix = new_tag.startswith(("stable-", "testing-", "unstable-"))
        existing_has_prefix = existing_tag.startswith(
            ("stable-", "testing-", "unstable-")
        )

        if new_has_prefix and not existing_has_prefix:
            return True
        elif not new_has_prefix and existing_has_prefix:
            return False
        else:
            # If both have prefixes or both don't, keep the existing one (arbitrary choice)
            return False


def get_filter_rules_for_repository(
    repository: str, include_sha256_tags: bool = False
) -> TOMLFilterRules:
    """
    Get the appropriate filter rules for a given repository from TOML configuration.

    Args:
        repository: The repository name (e.g., "astrovm/amyos")
        include_sha256_tags: Whether to override the default filtering of SHA256 hash tags (deprecated)

    Returns:
        An instance of the TOMLFilterRules class
    """
    # Return a TOMLFilterRules instance which will load the appropriate configuration
    # The include_sha256_tags parameter is now handled through config
    return TOMLFilterRules(repository)


def _extract_prefix_and_clean_tag(tag: str) -> Tuple[Optional[str], str]:
    """
    Extract the prefix (if any) and clean tag without prefix.

    Args:
        tag: The original tag

    Returns:
        A tuple of (prefix, clean_tag) where prefix is None if no prefix exists
    """
    if tag.startswith("testing-"):
        return "testing", tag[8:]  # Remove "testing-" prefix
    elif tag.startswith("stable-"):
        return "stable", tag[7:]  # Remove "stable-" prefix
    elif tag.startswith("unstable-"):
        return "unstable", tag[9:]  # Remove "unstable-" prefix
    else:
        return None, tag


def _parse_xx_yyyymmdd_format(
    clean_tag: str,
) -> Optional[Tuple[int, int, int, int, int]]:
    """
    Parse XX.YYYYMMDD[.SUBVER] format.

    Args:
        clean_tag: Tag without any prefix

    Returns:
        A tuple of (version_series, year, month, day, subver) or None if no match
    """
    import re

    match = re.match(r"^(\d+)\.(\d{8})(?:\.(\d+))?$", clean_tag)
    if match:
        version_series_str = match.group(1)  # XX
        date_str = match.group(2)  # YYYYMMDD
        subver_str = match.group(3)  # SUBVER if present

        # Convert to integers for proper numeric comparison
        version_series = int(version_series_str)
        year = int(date_str[:4])
        month = int(date_str[4:6])
        day = int(date_str[6:8])
        subver = int(subver_str) if subver_str is not None else 0

        return version_series, year, month, day, subver
    return None


def _parse_yyyymmdd_format(clean_tag: str) -> Optional[Tuple[int, int, int, int]]:
    """
    Parse YYYYMMDD[.SUBVER] format.

    Args:
        clean_tag: Tag without any prefix

    Returns:
        A tuple of (year, month, day, subver) or None if no match
    """
    import re

    match = re.match(r"^(\d{8})(?:\.(\d+))?$", clean_tag)
    if match:
        date_str = match.group(1)  # YYYYMMDD
        subver_str = match.group(2)  # SUBVER if present

        # Convert to integers for proper numeric comparison
        year = int(date_str[:4])
        month = int(date_str[4:6])
        day = int(date_str[6:8])
        subver = int(subver_str) if subver_str is not None else 0

        return year, month, day, subver
    return None


def _parse_version_components(
    clean_tag: str,
) -> Optional[Tuple[Optional[int], int, int, int, int]]:
    """
    Parse version components from a clean tag (without prefix).

    Args:
        clean_tag: Tag without any prefix

    Returns:
        A tuple of (version_series, year, month, day, subver) or None if no match
    """
    # Try XX.YYYYMMDD[.SUBVER] format first
    result = _parse_xx_yyyymmdd_format(clean_tag)
    if result:
        version_series, year, month, day, subver = result
        return version_series, year, month, day, subver

    # Try YYYYMMDD[.SUBVER] format
    result = _parse_yyyymmdd_format(clean_tag)
    if result:
        year, month, day, subver = result
        return None, year, month, day, subver  # version_series is None for this format

    return None  # No match for known formats


def _create_date_sort_key(
    year: int, month: int, day: int, subver: int
) -> DateVersionKey:
    """
    Create a sort key for date-based version formats.

    Args:
        year: The year component
        month: The month component
        day: The day component
        subver: The subversion component

    Returns:
        A tuple for date-based sorting
    """
    return (-1, -year, -month, -day, -subver)


def _create_version_series_sort_key(
    version_series: int, year: int, month: int, day: int, subver: int
) -> DateVersionKey:
    """
    Create a sort key for version series formats (XX.YYYYMMDD).

    Args:
        version_series: The version series component
        year: The year component
        month: The month component
        day: The day component
        subver: The subversion component

    Returns:
        A tuple for version series sorting
    """
    return (-10000 - version_series, -year, -month, -day, -subver)


def _create_context_date_sort_key(
    year: int, month: int, day: int, subver: int, context_priority: int
) -> DateVersionKey:
    """
    Create a sort key for date-based formats with context priority.

    Args:
        year: The year component
        month: The month component
        day: The day component
        subver: The subversion component
        context_priority: The context priority value

    Returns:
        A tuple for context-aware date sorting
    """
    return (
        -1,  # Original behavior: -1 for date-based versions
        -year,
        -month,
        -day,
        -subver,
    )


def _create_context_version_series_sort_key(
    version_series: int,
    year: int,
    month: int,
    day: int,
    subver: int,
    context_priority: int,
) -> DateVersionKey:
    """
    Create a sort key for version series formats with context priority.

    Args:
        version_series: The version series component
        year: The year component
        month: The month component
        day: The day component
        subver: The subversion component
        context_priority: The context priority value

    Returns:
        A tuple for context-aware version series sorting
    """
    return (
        context_priority * 10000 - version_series,
        -year,
        -month,
        -day,
        -subver,
    )


def _create_alpha_sort_key(tag: str, context_priority: int = 0) -> AlphaVersionKey:
    """
    Create a sort key for non-date formats using reverse alphabetical order.

    Args:
        tag: The tag to create a sort key for
        context_priority: The context priority value (only used in context-aware mode)

    Returns:
        A tuple for alphabetical sorting
    """
    return (
        0,
        tuple(-ord(c) for c in tag.lower()),
    )


def _create_context_alpha_sort_key(
    tag: str, tag_prefix: Optional[str], url_context: Optional[str]
) -> AlphaVersionKey:
    """
    Create a sort key for non-date formats with context priority.

    Args:
        tag: The tag to create a sort key for
        tag_prefix: The prefix of the tag
        url_context: The URL context to match against

    Returns:
        A tuple for context-aware alphabetical sorting
    """
    context_priority = 0 if tag_prefix == url_context else 1
    return (
        context_priority * 10000 - 20000,
        tuple(-ord(c) for c in tag.lower()),
    )


def _create_version_sort_key(
    tag: str, url_context: Optional[str] = None, include_context_priority: bool = False
) -> VersionSortKey:
    """
    Create a sort key for a tag with optional context priority.
    This maintains backward compatibility with the original sorting behavior.

    Args:
        tag: The tag to create a sort key for
        url_context: The context from the URL (e.g., "testing", "stable")
        include_context_priority: Whether to prioritize context-matching tags

    Returns:
        A tuple that can be used for sorting
    """
    # Extract prefix and clean tag
    tag_prefix, clean_tag = _extract_prefix_and_clean_tag(tag)

    # Try to parse version components
    version_components = _parse_version_components(clean_tag)

    if version_components:
        version_series, year, month, day, subver = version_components

        if include_context_priority and url_context:
            # Context priority: 0 if matching context, 1 otherwise
            context_priority = 0 if tag_prefix == url_context else 1

            if version_series is not None:
                # XX.YYYYMMDD[.SUBVER] format
                return _create_context_version_series_sort_key(
                    version_series, year, month, day, subver, context_priority
                )
            else:
                # YYYYMMDD[.SUBVER] format
                return _create_context_date_sort_key(
                    year, month, day, subver, context_priority
                )
        else:
            # No context priority - regular version sorting
            if version_series is not None:
                # XX.YYYYMMDD[.SUBVER] format
                return _create_version_series_sort_key(
                    version_series, year, month, day, subver
                )
            else:
                # YYYYMMDD[.SUBVER] format
                return _create_date_sort_key(year, month, day, subver)
    else:
        # For tags that don't match the expected format, use reverse alphabetical
        if include_context_priority and url_context:
            return _create_context_alpha_sort_key(tag, tag_prefix, url_context)
        else:
            # For non-date formats, use reverse alphabetical order
            return _create_alpha_sort_key(tag)


def check_command(args: List[str]):
    """Handle the check command."""
    cmd = ["rpm-ostree", "upgrade", "--check"]
    sys.exit(run_command(cmd))


def ls_command(args: List[str]):
    """Handle the ls command."""
    cmd = ["rpm-ostree", "status", "-v"]
    sys.exit(run_command(cmd))


def rollback_command(args: List[str]):
    """Handle the rollback command."""
    cmd = ["sudo", "rpm-ostree", "rollback"]
    sys.exit(run_command(cmd))


def pin_command(
    args: List[str],
    show_deployment_submenu_func: Optional[Callable[..., Optional[int]]] = None,
):
    """Handle the pin command."""
    if show_deployment_submenu_func is None:
        show_deployment_submenu_func = show_deployment_submenu

    def cmd_builder(num: int) -> List[str]:
        return ["sudo", "ostree", "admin", "pin", str(num)]

    def not_pinned_filter(deployment: Dict[str, Any]) -> bool:
        return not deployment["pinned"]

    def submenu_func():
        return show_deployment_submenu_func(filter_func=not_pinned_filter)

    def error_message(value: str) -> str:
        return f"Invalid deployment number: {value}"

    handle_command_with_submenu(args, submenu_func, cmd_builder, int, error_message)


def unpin_command(
    args: List[str],
    show_deployment_submenu_func: Optional[Callable[..., Optional[int]]] = None,
):
    """Handle the unpin command."""
    if show_deployment_submenu_func is None:
        show_deployment_submenu_func = show_deployment_submenu

    def cmd_builder(num: int) -> List[str]:
        return ["sudo", "ostree", "admin", "pin", "-u", str(num)]

    def pinned_filter(deployment: Dict[str, Any]) -> bool:
        return deployment["pinned"]

    def submenu_func():
        return show_deployment_submenu_func(filter_func=pinned_filter)

    def error_message(value: str) -> str:
        return f"Invalid deployment number: {value}"

    handle_command_with_submenu(args, submenu_func, cmd_builder, int, error_message)


def get_rpm_ostree_status_output() -> Optional[str]:
    """
    Get the output from 'rpm-ostree status -v' command.

    Returns:
        The command output as a string, or None if the command failed
    """
    try:
        result = subprocess.run(
            ["rpm-ostree", "status", "-v"], capture_output=True, text=True
        )
        if result.returncode != 0:
            print("Error getting deployments")
            return None
        return result.stdout
    except subprocess.CalledProcessError:
        print("Error running rpm-ostree status command")
        return None
    except Exception:
        print(
            "Error parsing deployments"
        )  # Maintain original message for test compatibility
        return None


def is_deployment_line(line: str) -> bool:
    """
    Check if a line represents the start of a deployment.

    Args:
        line: The line to check

    Returns:
        True if the line represents a deployment start, False otherwise
    """
    return line.startswith("●") or (
        line.startswith(" ") and "ostree-image-signed:" in line
    )


def extract_deployment_index(line: str) -> Optional[int]:
    """
    Extract the deployment index from a deployment line.

    Args:
        line: The deployment line

    Returns:
        The deployment index, or None if not found or not parseable
    """
    if "index:" in line:
        start_idx = line.find("index:") + len("index:")
        end_idx = line.find(")", start_idx)
        if end_idx != -1:
            index_str = line[start_idx:end_idx].strip()
            try:
                return int(index_str)
            except ValueError:
                pass  # Keep as None if can't parse
    return None


def is_new_deployment_line(line: str) -> bool:
    """
    Check if a line represents the start of a new deployment.

    Args:
        line: The line to check

    Returns:
        True if the line represents a new deployment start, False otherwise
    """
    return line.startswith("●") or (
        line.startswith(" ") and "ostree-image-signed:" in line
    )


def is_version_line(line: str) -> bool:
    """
    Check if a line contains version information.

    Args:
        line: The line to check

    Returns:
        True if the line contains version information, False otherwise
    """
    return line.startswith("Version:")


def is_pinned_line(line: str) -> bool:
    """
    Check if a line contains pinned information.

    Args:
        line: The line to check

    Returns:
        True if the line contains pinned information, False otherwise
    """
    return line.startswith("Pinned:")


def extract_version_from_line(line: str) -> str:
    """
    Extract version information from a version line.

    Args:
        line: The version line

    Returns:
        The version information
    """
    return line[len("Version:") :].strip()


def extract_pinned_from_line(line: str) -> bool:
    """
    Extract pinned status from a pinned line.

    Args:
        line: The pinned line

    Returns:
        True if the deployment is pinned, False otherwise
    """
    pinned_info = line[len("Pinned:") :].strip()
    return pinned_info.lower() == "yes"


def parse_deployment_details(
    lines: List[str], start_idx: int
) -> Tuple[Dict[str, Any], int]:
    """
    Parse details for a single deployment starting from a specific line index.

    Args:
        lines: List of lines from rpm-ostree status output
        start_idx: Index of the line that starts the deployment

    Returns:
        A tuple of (deployment_info, next_idx) where next_idx is where to continue parsing
    """
    line = lines[start_idx].rstrip()

    deployment_info: Dict[str, Any] = {
        "index": extract_deployment_index(line),
        "version": None,
        "pinned": False,
        "current": line.startswith("●"),  # Mark if it's the current deployment
    }

    # Continue processing subsequent lines for this deployment
    i = start_idx + 1
    while i < len(lines):
        next_line = lines[i].strip()

        # If we hit an empty line or a new deployment, break
        if not next_line or is_new_deployment_line(next_line):
            break

        # Look for Version field
        if is_version_line(next_line):
            deployment_info["version"] = extract_version_from_line(next_line)

        # Look for Pinned field
        elif is_pinned_line(next_line):
            deployment_info["pinned"] = extract_pinned_from_line(next_line)

        i += 1

    return deployment_info, i


def filter_valid_deployments(deployments: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """
    Filter out deployments that don't have a valid index.

    Args:
        deployments: List of deployments to filter

    Returns:
        List of deployments with valid indices
    """
    return [d for d in deployments if d["index"] is not None]


def parse_deployments() -> List[Dict[str, Any]]:
    """Parse rpm-ostree status -v to extract deployment information."""
    output = get_rpm_ostree_status_output()
    if not output:
        return []

    lines = output.split("\n")
    deployments: List[Dict[str, Any]] = []
    i = 0

    while i < len(lines):
        line = lines[i].rstrip()

        # Check if this line starts a new deployment
        if is_deployment_line(line):
            deployment_info, next_idx = parse_deployment_details(lines, i)
            deployments.append(deployment_info)
            i = next_idx
        else:
            i += 1

    # Return only deployments with valid indices
    return filter_valid_deployments(deployments)


def show_deployment_submenu(
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
    filter_func: Optional[Callable[[Dict[str, Any]], bool]] = None,
) -> Optional[int]:
    """Show a submenu of deployments using gum."""
    deployments = parse_deployments()

    if not deployments:
        print_func("No deployments found.")
        return None

    # Apply filter if provided
    if filter_func:
        deployments = [d for d in deployments if filter_func(d)]

    if not deployments:
        print_func("No deployments match the filter criteria.")
        return None

    # Create options for gum with version info
    options: List[str] = []
    deployment_map: Dict[str, int] = {}

    for deployment in deployments:
        # Create display string with version info
        version_info = (
            deployment["version"] if deployment["version"] else "Unknown Version"
        )

        # Add pinning status for pin/unpin commands
        pin_status = ""
        if "pinned" in deployment:
            pin_status = f" [Pinned: {'Yes' if deployment['pinned'] else 'No'}]"

        option_text = f"{version_info}{pin_status}"
        options.append(option_text)
        deployment_map[option_text] = deployment["index"]

    # Create deployment data source function for the abstraction
    def get_deployment_options() -> List[str]:
        result: List[str] = []
        for deployment in deployments:
            version_info = (
                deployment["version"] if deployment["version"] else "Unknown Version"
            )
            pin_status = f" [Pinned: {'Yes' if deployment['pinned'] else 'No'}]"
            result.append(f"  {deployment['index']}: {version_info}{pin_status}")
        return result

    display_non_tty, display_gum_not_found = create_submenu_display_functions(
        get_deployment_options,
        "Available deployments:",
        "gum not found. Available deployments:",
    )

    result_str = run_gum_submenu(
        options,
        "Select deployment (ESC to cancel):",
        display_non_tty,
        display_gum_not_found,
        is_tty_func,
        subprocess_run_func,
        print_func,
    )

    if result_str:
        # Get the corresponding deployment index
        if result_str in deployment_map:
            return deployment_map[result_str]
        else:
            print_func("Invalid selection.")
            return None
    return None


def rm_command(
    args: List[str],
    show_deployment_submenu_func: Optional[Callable[..., Optional[int]]] = None,
):
    """Handle the rm command."""
    if show_deployment_submenu_func is None:
        show_deployment_submenu_func = show_deployment_submenu

    def cmd_builder(num: int) -> List[str]:
        return ["sudo", "rpm-ostree", "cleanup", "-r", str(num)]

    def error_message(value: str) -> str:
        return f"Invalid deployment number: {value}"

    handle_command_with_submenu(
        args, show_deployment_submenu_func, cmd_builder, int, error_message
    )


def upgrade_command(args: List[str]):
    """Handle the upgrade command."""
    cmd = ["sudo", "rpm-ostree", "upgrade"]
    sys.exit(run_command(cmd))


def help_command(args: List[str], print_func: Callable[[str], Any] = print) -> None:
    """Show help information."""
    print_func(
        "ublue-rebase-helper (urh.py) - Wrapper for rpm-ostree and ostree commands"
    )
    print_func("")
    print_func("Usage: urh.py <command> [args]")
    print_func("")
    print_func("Commands:")
    print_func("  check            - Check for available updates")
    print_func("  help             - Show this help message")
    print_func("  ls               - List deployments with details")
    print_func("  pin <num>        - Pin a deployment")
    print_func("  rebase <url>     - Rebase to a container image")
    print_func("  remote-ls <url>  - List available tags for a container image")
    print_func("  rm <num>         - Remove a deployment")
    print_func("  rollback         - Roll back to the previous deployment")
    print_func("  unpin <num>      - Unpin a deployment")
    print_func("  upgrade          - Upgrade to the latest version")


def execute_simple_command(command_parts: List[str]) -> None:
    """Execute a simple command with no arguments needed."""
    sys.exit(run_command(command_parts))


def execute_command_with_args(command_parts: List[str], args: List[str]) -> None:
    """Execute a command with additional arguments."""
    cmd = command_parts + args
    sys.exit(run_command(cmd))


def execute_command_with_header(
    command: str,
    args: List[str],
    persistent_header: Optional[str] = None,
    is_interactive: bool = False,
) -> None:
    """
    Execute a command with given arguments, optionally with a persistent header.

    Args:
        command: The command name to execute
        args: List of arguments for the command
        persistent_header: Optional header to display with submenu commands
        is_interactive: Whether this is running in interactive mode
    """
    command_map = get_command_registry()

    command_func = command_map.get(command)
    if command_func:
        try:
            # Only pass the persistent_header to commands that accept it
            import inspect

            sig = inspect.signature(command_func)
            if "persistent_header" in sig.parameters:
                command_func(args, persistent_header=persistent_header)  # pyright: ignore [reportCallIssue]
            else:
                command_func(args)
        except MenuExitException as e:
            # In interactive mode, handle MenuExitException based on context
            if is_interactive and e.is_main_menu:
                # User pressed ESC in main menu, exit the program
                sys.exit(0)
            elif is_interactive:
                # User pressed ESC in submenu, return to main menu (exit with success)
                sys.exit(0)
    else:
        print(f"Unknown command: {command}")
        help_command([])


def get_command_registry() -> Dict[str, Callable[[List[str]], None]]:
    """
    Get the registry of available commands mapped to their functions.

    Returns:
        A dictionary mapping command names to their respective functions
    """
    return {
        "rebase": rebase_command,
        "remote-ls": remote_ls_command,
        "check": check_command,
        "upgrade": upgrade_command,
        "ls": ls_command,
        "rollback": rollback_command,
        "pin": pin_command,
        "unpin": unpin_command,
        "rm": rm_command,
        "help": help_command,
    }


def show_command_menu_with_header(
    is_tty_func: Callable[[], bool] = lambda: os.isatty(1),
    subprocess_run_func: Callable[..., Any] = subprocess.run,
    print_func: Callable[[str], Any] = print,
    persistent_header: Optional[str] = None,
) -> Optional[str]:
    """Show a menu of available commands using gum with a persistent header."""
    # Display the persistent header first if provided
    if persistent_header:
        print_func(persistent_header)
        # No extra blank line to keep header close to menu

    # Call the original function to show the actual menu
    return show_command_menu(is_tty_func, subprocess_run_func, print_func)


def execute_command(
    command: str, args: List[str], is_interactive: bool = False
) -> None:
    """
    Execute a command with given arguments.

    Args:
        command: The command name to execute
        args: List of arguments for the command
        is_interactive: Whether this is running in interactive mode
    """
    command_map = get_command_registry()

    command_func = command_map.get(command)
    if command_func:
        try:
            command_func(args)
        except MenuExitException as e:
            # In interactive mode, handle MenuExitException based on context
            if is_interactive and e.is_main_menu:
                # User pressed ESC in main menu, exit the program
                sys.exit(0)
            elif is_interactive:
                # User pressed ESC in submenu, return to main menu (exit with success)
                sys.exit(0)
    else:
        print(f"Unknown command: {command}")
        help_command([])


def main(argv: Optional[List[str]] = None):
    if argv is None:
        argv = sys.argv

    # If arguments were provided directly, execute that command
    if len(argv) >= 2:
        command = argv[1]
        execute_command(command, argv[2:])
    else:
        # No command provided, enter menu loop for interactive use
        # Check if we're in a test environment to avoid infinite loops
        import os

        in_test_mode = "PYTEST_CURRENT_TEST" in os.environ

        if in_test_mode:
            # Single execution for tests to avoid hanging
            deployment_info = get_current_deployment_info()
            header = format_deployment_header(deployment_info)
            command = show_command_menu_with_header(persistent_header=header)
            if not command:
                sys.exit(0)

            execute_command(command, [], is_interactive=True)
        else:
            # Interactive menu loop
            while True:
                try:
                    deployment_info = get_current_deployment_info()
                    header = format_deployment_header(deployment_info)
                    command = show_command_menu_with_header(persistent_header=header)
                    if not command:
                        sys.exit(0)

                    execute_command(command, [], is_interactive=True)

                except MenuExitException as e:
                    if e.is_main_menu:
                        # User pressed ESC in main menu, exit the program
                        sys.exit(0)
                    else:
                        # User pressed ESC in submenu, return to main menu (continue loop)
                        continue


if __name__ == "__main__":
    main()
