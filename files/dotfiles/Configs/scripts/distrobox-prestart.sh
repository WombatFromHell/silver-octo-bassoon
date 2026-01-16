#!/usr/bin/env bash

# distrobox-prestart.sh - Start a distrobox container in background
# Usage: distrobox-prestart.sh <container_name>
# Designed to be called from .desktop files for autostart

set -euo pipefail

# Function: Display usage information
show_usage() {
    local script_name
    script_name=$(basename "$0")
    echo "Usage: $script_name <container_name>" >&2
    echo "Starts the specified distrobox container in background" >&2
}

# Function: Check if distrobox is installed
check_distrobox_installed() {
    if ! command -v distrobox >/dev/null 2>&1; then
        echo "ERROR: distrobox is not installed" >&2
        return 1
    fi
    return 0
}

# Function: Check if container exists
check_container_exists() {
    local container_name="$1"

    if ! distrobox list | tail -n +2 | grep -q "| ${container_name} "; then
        echo "ERROR: Container '${container_name}' does not exist" >&2
        return 1
    fi
    return 0
}

# Function: Check if container is already running (Up or running status)
is_container_running() {
    local container_name="$1"

    # Check for both "running" and "Up" statuses - these mean container is already active
    if distrobox list | tail -n +2 | grep -q "| ${container_name} |.*\<running\>\|.*\<Up\>"; then
        return 0  # Container is running
    fi
    return 1  # Container is not running (Exited or other state)
}

# Function: Start container in background
start_container_background() {
    local container_name="$1"

    echo "Starting container '${container_name}' in background..." >&2

    # Use nohup and & for non-blocking execution
    # Use sleep infinity as a no-op to keep container alive
    nohup distrobox enter "${container_name}" -- /bin/sleep infinity >/dev/null 2>&1 &

    return 0
}

# Main execution
main() {
    local container_name
    local script_name

    script_name=$(basename "$0")

    # Validate input
    if [[ $# -eq 0 ]]; then
        echo "ERROR: No container name specified" >&2
        show_usage
        exit 1
    fi

    container_name="$1"

    # Check dependencies
    if ! check_distrobox_installed; then
        exit 1
    fi

    # Check container existence
    if ! check_container_exists "$container_name"; then
        exit 1
    fi

    # Check if already running
    if is_container_running "$container_name"; then
        echo "Container '${container_name}' is already running" >&2
        exit 0
    fi

    # Start the container
    if ! start_container_background "$container_name"; then
        echo "ERROR: Failed to start container '${container_name}'" >&2
        exit 1
    fi

    # Give it a moment to start
    sleep 1

    echo "Container '${container_name}' started successfully in background" >&2
    exit 0
}

# Execute main function
main "$@"
