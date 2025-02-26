#!/usr/bin/env python3
"""
A script to modify .desktop files by inserting a string after "Exec=" and before the path.
"""

import os
import re
import sys
import shutil
import argparse


def modify_desktop_file(file_path, insert_string):
    """
    Modify the Exec line in a .desktop file.

    Args:
        file_path (str): Path to the .desktop file
        insert_string (str): String to insert between Exec= and the path

    Returns:
        tuple: (success (bool), message (str))
    """
    # Check if file exists
    if not os.path.isfile(file_path):
        return False, f"Error: File '{file_path}' not found!"

    # Create backup
    backup_path = f"{file_path}.bak"
    shutil.copy2(file_path, backup_path)

    # Read the file
    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # Pattern to match Exec= line
    pattern = re.compile(r"^(Exec=)(.*)")
    modified = False

    # Process each line
    modified_line = None
    for i, line in enumerate(lines):
        match = pattern.match(line)
        if match:
            lines[i] = f"Exec={insert_string}{match.group(2)}\n"
            modified = True
            modified_line = lines[i].strip()

    if not modified:
        return False, "Warning: No 'Exec=' line found in the file!"

    # Write the modified content back to the file
    with open(file_path, "w", encoding="utf-8") as f:
        f.writelines(lines)

    return True, f"Modified Exec line: {modified_line}"


def main():
    """Main function to handle command line arguments and execute the script."""
    parser = argparse.ArgumentParser(description="Modify Exec line in .desktop files")
    parser.add_argument("desktop_file", help="Path to the .desktop file")
    parser.add_argument(
        "insert_string", help="String to insert after Exec= and before the path"
    )

    args = parser.parse_args()

    success, message = modify_desktop_file(args.desktop_file, args.insert_string)
    print(message)

    if success:
        print(f"Backup created as {args.desktop_file}.bak")
        print(f"Desktop file '{args.desktop_file}' has been updated!")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
