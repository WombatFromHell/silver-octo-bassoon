#!/usr/bin/env bash

# Define the two profiles to toggle between
profiles=("tv" "notv")

# Get current profile from kanshictl status
current_profile=$(kanshictl status | grep "Current profile:" | awk '{print $3}')

# Check current profile and switch to the other one
if [[ "$current_profile" == "${profiles[0]}" ]]; then
  kanshictl switch "${profiles[1]}"
  echo "Switched to profile: ${profiles[1]}"
elif [[ "$current_profile" == "${profiles[1]}" ]]; then
  kanshictl switch "${profiles[0]}"
  echo "Switched to profile: ${profiles[0]}"
else
  echo "Unknown or no active profile: $current_profile"
  echo "Available profiles: ${profiles[*]}"
  exit 1
fi
