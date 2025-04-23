#!/usr/bin/env bash

devices=(
	GPP0 # PCIe bridge
	XH00 # Disable mouse/keyboard hub wakeups
)

for dev in "${devices[@]}"; do
	if grep -q "$dev.*enabled" /proc/acpi/wakeup; then
		if ! echo "$dev" | sudo tee /proc/acpi/wakeup >/dev/null; then
			echo "Error: Failed to disable $dev" >&2
		else
			echo "Disabling ACPI wakeups on: $dev"
		fi
	fi
done
