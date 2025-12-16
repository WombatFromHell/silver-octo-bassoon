#!/usr/bin/env python3

import argparse
import os
import platform
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Optional, List


@dataclass
class SquashFSConfig:
    mount_base: str = "mounts"  # Default subdirectory in the current working directory


class SquashFSManager:
    def __init__(self, config: Optional[SquashFSConfig] = None):
        self.config = config if config else SquashFSConfig()
        self._check_dependencies()

    def _check_commands(self, commands: List[str]) -> None:
        for cmd in commands:
            try:
                subprocess.run(
                    ["which", cmd],
                    check=True,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                )
            except subprocess.CalledProcessError:
                print(
                    f"Error: {cmd} is not installed or not in PATH. Please install {cmd} to use this script."
                )
                sys.exit(1)

    def _check_linux_dependencies(self) -> None:
        self._check_commands(["squashfuse", "fusermount"])

    def _check_dependencies(self) -> None:
        current_os = platform.system().lower()
        if current_os == "linux":
            self._check_linux_dependencies()
        else:
            print(
                f"Error: This script is currently only supported on Linux. Detected OS: {current_os}"
            )
            sys.exit(1)

    def _is_mount_point_valid(self, mount_point: Path) -> bool:
        """Check if the mount point exists and is not empty."""
        if not mount_point.exists():
            print(f"Error: Mount point does not exist: {mount_point}")
            return False

        if not any(mount_point.iterdir()):
            print(f"Error: Mount point is empty, nothing to unmount: {mount_point}")
            return False

        return True

    def mount(self, file_path: str, mount_point: Optional[str] = None) -> None:
        file_path_obj = Path(file_path)
        if mount_point is None:
            # Use default mount point
            mount_point_obj = (
                Path(os.getcwd()) / self.config.mount_base / file_path_obj.stem
            )
        else:
            mount_point_obj = Path(mount_point)

        os.makedirs(mount_point_obj, exist_ok=True)
        try:
            subprocess.run(
                ["squashfuse", str(file_path_obj), str(mount_point_obj)], check=True
            )
            print(f"Mounted {file_path} to {mount_point_obj}")
        except subprocess.CalledProcessError as e:
            print(f"Failed to mount {file_path}: {e}")
            sys.exit(1)

    def unmount(self, file_path: str, mount_point: Optional[str] = None) -> None:
        file_path_obj = Path(file_path)
        if mount_point is None:
            # Use default mount point
            mount_point_obj = (
                Path(os.getcwd()) / self.config.mount_base / file_path_obj.stem
            )
        else:
            mount_point_obj = Path(mount_point)

        if not self._is_mount_point_valid(mount_point_obj):
            sys.exit(1)

        try:
            subprocess.run(["fusermount", "-u", str(mount_point_obj)], check=True)
            print(f"Unmounted {mount_point_obj}")

            # Remove the mount directory recursively
            try:
                shutil.rmtree(mount_point_obj)
                print(f"Removed directory: {mount_point_obj}")

                # Check if the parent "mounts" directory is empty and remove it if so
                mounts_dir = mount_point_obj.parent
                if mounts_dir.name == self.config.mount_base:
                    try:
                        os.rmdir(mounts_dir)
                        print(f"Removed parent directory: {mounts_dir}")
                    except OSError as e:
                        print(f"Could not remove parent directory {mounts_dir}: {e}")
            except OSError as e:
                print(f"Could not remove directory {mount_point_obj}: {e}")
        except subprocess.CalledProcessError as e:
            print(f"Failed to unmount {mount_point_obj}: {e}")
            sys.exit(1)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Mount/unmount .sqs or .squashfs files"
    )
    parser.add_argument(
        "-u", "--unmount", action="store_true", help="Unmount the squashfs file"
    )
    parser.add_argument("file", help="Path to the .sqs or .squashfs file")
    parser.add_argument(
        "mount_point", nargs="?", default=None, help="Path to mount the squashfs file"
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    manager = SquashFSManager()

    if not args.unmount and not os.path.isfile(args.file):
        print(f"File not found: {args.file}")
        sys.exit(1)

    if args.unmount:
        manager.unmount(args.file, args.mount_point)
    else:
        manager.mount(args.file, args.mount_point)


if __name__ == "__main__":
    main()
