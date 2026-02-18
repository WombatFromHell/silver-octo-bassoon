#!/usr/bin/env bash
# prevent script from being run outside the project directory
script_dir="$(dirname "$(readlink -f "$0")")"
if [[ "$(pwd -P)" != "$script_dir" ]]; then
  echo "Error: script must be run from the project directory!"
  exit 1
fi

rm -rf ./.venv/ ./.ansible/ ./.pytest_cache/ ./.ruff_cache/ ./__pycache__/ ./tests/__pycache__/ ./.coverage ./htmlcov
