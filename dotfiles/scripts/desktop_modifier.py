#!/usr/bin/env python3

import os
import re
import sys
import shutil
import argparse


def modify_desktop_file(file_path, insert_string):
    """
    Modify all Exec lines in a .desktop file.

    Args:
        file_path (str): Path to the .desktop file
        insert_string (str): String to insert between Exec= and the path

    Returns:
        tuple: (success (bool), message (str))
    """
    # Check if file exists
    if not os.path.isfile(file_path):
        return False, f"Error: File '{file_path}' not found!"

    # Read the file
    with open(file_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Pattern to match Exec= lines
    pattern = re.compile(r"^(Exec=)(.*)$", re.MULTILINE)
    matches = list(pattern.finditer(content))
    exec_lines_count = len(matches)

    if not exec_lines_count:
        return False, "No 'Exec=' line found"

    # Check if insert_string already exists in any Exec line
    if insert_string:
        for match in matches:
            current_exec_line = match.group(0)
            if insert_string in current_exec_line:
                return (
                    False,
                    "Warning: The string already exists in an Exec line. No changes made.",
                )

    # Create backup
    backup_path = f"{file_path}.bak"
    shutil.copy2(file_path, backup_path)

    # Split the content into lines for easier replacement
    lines = content.split("\n")
    modified_lines = []

    # Process each line
    for line in lines:
        if line.startswith("Exec="):
            # Extract the command part (everything after Exec=)
            exec_cmd = line[5:]
            # Create the new line
            new_line = f"Exec={insert_string}{exec_cmd}"
            modified_lines.append(new_line)
        else:
            modified_lines.append(line)

    # Join the lines back to create the modified content
    modified_content = "\n".join(modified_lines)

    # Write the modified content back to the file
    with open(file_path, "w", encoding="utf-8") as f:
        f.write(modified_content)

    message = f"Modified {exec_lines_count} Exec line" + (
        "s" if exec_lines_count != 1 else ""
    )
    return True, message


def main():
    """Main function to handle command line arguments and execute the script."""
    parser = argparse.ArgumentParser(
        description="Modify all Exec lines in .desktop files"
    )
    parser.add_argument("desktop_file", help="Path to the .desktop file")
    parser.add_argument(
        "insert_string", help="String to insert after Exec= and before the path"
    )

    args = parser.parse_args()

    success, message = modify_desktop_file(args.desktop_file, args.insert_string)
    print(message)

    if success:
        print(
            f"Backup created: {args.desktop_file}.bak"
        )  # Using a placeholder to avoid actual backup message
        print(f"Desktop file '{args.desktop_file}' has been updated!")
    else:
        sys.exit(1)


if __name__ == "__main__":
    main()
