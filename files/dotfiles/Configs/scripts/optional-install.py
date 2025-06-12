#!/usr/bin/python3
import shutil
import subprocess
import argparse
import platform
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile
from tempfile import NamedTemporaryFile


class Installer:
    def __init__(self):
        self.os_type = self.detect_os()
        self.home = Path.home()
        self.local_bin = self.home / ".local" / "bin"
        self.local_share = self.home / ".local" / "share"
        self.config_dir = self.home / ".config"
        self.temp_dir = Path("/tmp")
        self.pacman_cmd = ["sudo", "pacman", "-S", "--needed", "--noconfirm"]
        self.hostname = platform.node()

        # Ensure directories exist
        self.local_bin.mkdir(parents=True, exist_ok=True)
        self.config_dir.mkdir(exist_ok=True)

    def detect_os(self):
        system = platform.system()
        if system == "Linux":
            try:
                with open("/etc/os-release") as f:
                    content = f.read()
                if "Arch Linux" in content or "CachyOS" in content:
                    return "Arch"
                elif "Bazzite" in content:
                    return "Bazzite"
                elif "NixOS" in content:
                    return "NixOS"
            except FileNotFoundError:
                pass
            return "Linux"
        elif system == "Darwin":
            return "Darwin"
        return "Unknown"

    def run_command(
        self,
        cmd,
        *,
        check=True,
        capture_output=False,
        allow_failure=False,
        input=None,
        shell=False,
    ):
        """
        Improved command runner with better argument handling
        Parameters:
        - cmd: List or string of commands (use string with shell=True for pipes)
        - check: Raise exception if command fails
        - capture_output: Capture stdout/stderr
        - allow_failure: Return exception instead of None on failure
        - input: Input to pass to command
        - shell: Whether to run through system shell (needed for pipes/redirection)
        """
        try:
            result = subprocess.run(
                cmd,
                check=check,
                capture_output=capture_output,
                text=True,
                input=input,
                shell=shell,
            )
            return result
        except subprocess.CalledProcessError as e:
            if not allow_failure:
                if capture_output:
                    print(f"Command failed: {e.stderr}")
                return None
            return e

    def command_exists(self, cmd):
        return shutil.which(cmd) is not None

    def confirm(self, prompt):
        while True:
            response = input(f"{prompt} [y/N]: ").strip().lower()
            if response in ("y", "yes"):
                return True
            elif response in ("", "n", "no"):
                return False

    def check_nix_prerequisites(self):
        """
        Check system prerequisites for Nix installation
        Returns True if conditions are met, False otherwise
        """
        # Check for read-only root filesystem
        ro_check = self.run_command(
            "findmnt / | grep ro",
            check=False,
            capture_output=True,
            allow_failure=True,
            shell=True,
        )

        # Check for read-write root filesystem
        rw_check = self.run_command(
            "findmnt / | grep rw",
            check=False,
            capture_output=True,
            allow_failure=True,
            shell=True,
        )

        if (
            isinstance(ro_check, subprocess.CompletedProcess)
            and ro_check.returncode == 0
        ):
            # Root is read-only, check for /nix mount point
            nix_stat = self.run_command(
                ["stat", "/nix"],
                check=False,
                capture_output=True,
                allow_failure=True,
            )

            if not (
                isinstance(nix_stat, subprocess.CompletedProcess)
                and nix_stat.returncode == 0
            ):
                print(
                    """
    Error: Root filesystem is read-only and /nix is not a valid mount point.
    The Nix installer will likely fail in this environment.
    Please ensure /nix is properly mounted before proceeding.
    """
                )
                return False

        elif (
            isinstance(rw_check, subprocess.CompletedProcess)
            and rw_check.returncode == 0
        ):
            # Root is read-write, proceed with installation
            return True
        else:
            print(
                """
    Warning: Unable to determine filesystem mount status.
    Nix installation may fail if / is read-only without /nix mounted.
    """
            )
            return self.confirm(
                "Continue with Nix installation despite potential issues?"
            )

        return True

    def install_neovim_config(self):
        nvim_dir = self.config_dir / "nvim"
        nvim_share = self.local_share / "nvim"
        nvim_cache = self.home / ".cache" / "nvim"
        nvim_state = self.home / ".local" / "state" / "nvim"

        if not self.command_exists("git"):
            print("Error: unable to find 'git', skipping NeoVim config installation!")
            return False

        if (
            nvim_dir.exists()
            or nvim_share.exists()
            or nvim_cache.exists()
            or nvim_state.exists()
        ):
            if not self.confirm(
                "Wipe any existing NeoVim config and download custom distribution?"
            ):
                return False

        for path in [nvim_dir, nvim_share, nvim_cache, nvim_state]:
            if path.exists():
                shutil.rmtree(path, ignore_errors=True)

        self.run_command(
            ["git", "clone", "git@github.com:WombatFromHell/lazyvim.git", str(nvim_dir)]
        )
        return True

    def install_neovim(self):
        if self.command_exists("nvim"):
            print("Error: 'nvim' already installed, skipping NeoVim setup!")
            return False

        if self.os_type == "NixOS":
            print("Error: NixOS detected, skipping NeoVim setup!")
            return False

        bob_url = "https://github.com/MordechaiHadad/bob/releases/download/v4.0.3/bob-linux-x86_64.zip"
        bob_zip = self.temp_dir / "bob-linux-x86_64.zip"
        bob_binary = self.local_bin / "bob"
        global_nvim = Path("/usr/local/bin/nvim")

        # Install dependencies for Arch Linux
        if self.os_type == "Arch":
            self.run_command(
                self.pacman_cmd
                + ["base-devel", "procps-ng", "curl", "file", "git", "unzip", "rsync"]
            )

        # Download and install bob
        try:
            with urlopen(bob_url) as response, open(bob_zip, "wb") as out_file:
                shutil.copyfileobj(response, out_file)

            with ZipFile(bob_zip) as zip_ref:
                zip_ref.extractall(self.temp_dir)

            extracted_bob = self.temp_dir / "bob-linux-x86_64" / "bob"
            shutil.move(str(extracted_bob), str(bob_binary))
            bob_binary.chmod(0o755)

            # Install neovim nightly
            self.run_command([str(bob_binary), "use", "nightly"])

            # Create symlink
            nvim_bin = self.local_share / "bob" / "nvim-bin" / "nvim"
            if global_nvim.exists() or global_nvim.is_symlink():
                global_nvim.unlink()
            global_nvim.symlink_to(nvim_bin)

            # Clean up
            bob_zip.unlink(missing_ok=True)
            shutil.rmtree(self.temp_dir / "bob-linux-x86_64", ignore_errors=True)

            # Install config
            self.install_neovim_config()
            return True
        except Exception as e:
            print(f"Error installing neovim: {e}")
            return False

    def install_brew(self):
        brew_script = (
            "https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
        )
        try:
            with urlopen(brew_script) as response:
                script_content = response.read().decode("utf-8")

            with NamedTemporaryFile(mode="w+") as temp_script:
                temp_script.write(script_content)
                temp_script.flush()
                self.run_command(["bash", temp_script.name])
            return True
        except Exception as e:
            print(f"Error installing brew: {e}")
            return False

    def install_nix(self):
        if not self.check_nix_prerequisites():
            return False

        nix_script = "https://install.determinate.systems/nix"
        try:
            with urlopen(nix_script) as response:
                script_content = response.read().decode("utf-8")

            install_args = ["sh", "-s", "--", "install"]

            if self.os_type == "Bazzite":
                install_args.append("ostree")
            elif self.os_type == "Darwin":
                install_args.append("linux")
                install_args.append("--determinate")
            elif self.os_type in ("Arch", "CachyOS"):
                install_args.append("linux")

            install_args.append("--no-confirm --force")

            with NamedTemporaryFile(mode="w+") as temp_script:
                temp_script.write(script_content)
                temp_script.flush()

                result = self.run_command(
                    install_args,
                    input=script_content,
                    capture_output=True,
                )

            if result and result.returncode == 0:
                print(
                    "\nNix installed successfully! Please restart your shell for changes to take effect."
                )
                return True
            return False
        except Exception as e:
            print(f"Error installing nix: {e}")
            return False

    def install_nix_flake(self):
        if not self.command_exists("nix"):
            print("Error: 'nix' wasn't found in your PATH, skipping Nix flake setup!")
            return False

        nix_dir = self.home / ".nix"
        home_manager_dir = self.config_dir / "home-manager"

        # Install home-manager if not present
        if not self.command_exists("home-manager"):
            self.run_command(
                [
                    "nix",
                    "run",
                    "home-manager/master",
                    "--",
                    "init",
                    "--switch",
                    str(home_manager_dir),
                ]
            )

        # Clone flake if not present
        if not nix_dir.exists():
            self.run_command(
                [
                    "git",
                    "clone",
                    "https://github.com/WombatFromHell/automatic-palm-tree.git",
                    str(nix_dir),
                ]
            )

        # Apply flake using the stored hostname
        if self.command_exists("home-manager"):
            self.run_command(
                ["home-manager", "switch", "--flake", f"{nix_dir}#{self.hostname}"]
            )
            return True
        return False

    def setup_package_manager(self, install_brew=False):
        if self.os_type == "NixOS":
            print("NixOS detected, skipping package manager setup!")
            return False

        pkgs = [
            "bat",
            "eza",
            "fd",
            "rdfind",
            "ripgrep",
            "fzf",
            "bat",
            "lazygit",
            "fish",
            "rustup",
            "zoxide",
        ]

        # Arch Linux packages
        if self.os_type == "Arch" and self.confirm(
            "Install common devtools/shell using pacman?"
        ):
            self.run_command(self.pacman_cmd + pkgs)

        # Brew installation
        if install_brew and not self.command_exists("brew"):
            if self.confirm("Install Brew?"):
                self.install_brew()

        # Install packages with brew if available
        if self.command_exists("brew") and self.confirm(
            "Brew found, use it to install common utils?"
        ):
            self.run_command(["brew", "install"] + pkgs)

        return True


def parse_install_args(value):
    valid_options = {"neovim", "nix", "flake", "brew"}
    if not value:
        return set()

    options = set(item.strip().lower() for item in value.split(","))
    invalid = options - valid_options
    if invalid:
        raise argparse.ArgumentTypeError(
            f"Invalid install options: {', '.join(invalid)}"
        )
    return options


def main():
    parser = argparse.ArgumentParser(description="System setup script")
    parser.add_argument(
        "--install",
        type=parse_install_args,
        default="",
        help="Comma-separated list of components to install (neovim,nix,flake,brew)",
    )
    args = parser.parse_args()

    installer = Installer()
    install_options = args.install

    if install_options:
        # Non-interactive mode with specified options
        if "neovim" in install_options:
            installer.install_neovim()

        if "brew" in install_options:
            installer.setup_package_manager(install_brew=True)

        if "nix" in install_options:
            installer.install_nix()

        if "flake" in install_options:
            if installer.command_exists("nix"):
                installer.install_nix_flake()
            else:
                print(
                    "Error: Nix not found. Please install Nix first or include 'nix' in --install options."
                )
    else:
        # Interactive mode if no args provided
        installer.setup_package_manager()
        if installer.confirm(
            "Install NeoVim nightly via BOB (unnecessary if using Nix flake)?"
        ):
            installer.install_neovim()

        if installer.confirm("Install Nix package manager?"):
            installer.install_nix()

        if installer.command_exists("nix") and installer.confirm(
            "Install Nix flake configuration?"
        ):
            installer.install_nix_flake()


if __name__ == "__main__":
    main()
