#!/usr/bin/env bash
WTTRBAR="$HOME/.local/bin/wttrbar"
if command -v "$WTTRBAR" &>/dev/null && ! pgrep -x wttrbar; then
	$WTTRBAR \
		--location "Fort Collins" \
		--hide-conditions --fahrenheit --mph --ampm \
		--custom-indicator "{FeelsLikeF}°F {ICON}"
fi
