#!/usr/bin/env python3

import subprocess
import argparse
import os
import shutil


def create_default_config(file_path):
    config = {}
    config["BASE_PL"] = "320"
    config["LIMIT"] = "0.8"

    try:
        with open(file_path, "w") as configfile:
            for key, value in config.items():
                configfile.write(f"{key}={value}\n")  # Basic key-value pairs
        print(f"Created default config file at: {file_path}")
        return 320, 0.8  # Return the default values
    except OSError as e:
        print(f"Error creating config file: {e}")
        exit(1)


def read_config(file_path):
    config = {}
    if not os.path.exists(file_path):
        return create_default_config(file_path)

    try:
        with open(file_path, "r") as configfile:
            for line in configfile:
                line = line.strip()
                if line and not line.startswith("#"):  # Ignore empty lines and comments
                    try:
                        key, value = line.split("=", 1)
                        config[key] = value
                    except ValueError:
                        print(
                            f"Skipping invalid line: {line}"
                        )  # Handle invalid lines gracefully

        base_pl = int(config["BASE_PL"])
        limit_str = config["LIMIT"]

        try:
            limit = float(limit_str)
            if 0.0 < limit < 1.0:  # Percentage
                limit = int(round(base_pl * limit))
            elif 45 <= int(limit) <= base_pl:  # Watt Limit
                limit = int(limit)
            else:
                raise ValueError(
                    "Limit must be between 0.0 and 1.0 or between 45 and BASE_PL"
                )

        except (ValueError, KeyError):
            raise ValueError(
                "Invalid LIMIT or BASE_PL value in config file. Must be a float between 0.0 and 1.0 or an int between 45 and BASE_PL"
            )

        return base_pl, limit

    except FileNotFoundError:
        return create_default_config(file_path)  # Create if it doesn't exist.
    except (ValueError, KeyError) as e:
        print(f"Error reading config file: {e}")
        exit(1)


def nvidia_smi_command(command, *args):
    nvidia_smi = shutil.which("nvidia-smi", os.F_OK | os.X_OK)
    if nvidia_smi is not None:
        try:
            subprocess.run([nvidia_smi, command, *args], check=True)
        except subprocess.CalledProcessError as e:
            print(f"Error running nvidia-smi: {e}")
            exit(1)
    else:
        print("Error: 'nvidia-smi' must be in your environment path!")
        exit(1)


def underclock(pl):
    nvidia_smi_command("-pl", str(pl))


def undo(base_pl):
    nvidia_smi_command("-pl", str(base_pl))
    nvidia_smi_command("-rgc")
    nvidia_smi_command("-rmc")


def main():
    config_file = "/etc/nvidia-pm.conf"

    parser = argparse.ArgumentParser(
        description="Control NVIDIA GPU power limits",
        epilog=f"""Config file format ({config_file}):
        BASE_PL=<watts>
        LIMIT=<percentage as decimal or watts as integer>""",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument(
        "mode",
        nargs="?",
        choices=["undo"],
        help="reset power limit back to GPU default",
    )
    args = parser.parse_args()

    base_pl, limit_val = read_config(config_file)

    nvidia_smi_command("-pm", "1")

    if args.mode == "undo":
        undo(base_pl)
    elif base_pl is not None and limit_val is not None:
        underclock(limit_val)
    else:
        pass


if __name__ == "__main__":
    main()
