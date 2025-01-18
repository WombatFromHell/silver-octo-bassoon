#!/usr/bin/env bash
# bindel = ,XF86AudioRaiseVolume, exec, $scripts/run.sh wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
# bindel = ,XF86AudioLowerVolume, exec, $scripts/run.sh wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-
# bindel = ,XF86AudioMute, exec, $scripts/run.sh wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
# bindel = ,XF86AudioMicMute, exec, $scripts/run.sh wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
#
# # Requires playerctl
# bindl = , XF86AudioNext, exec, $scripts/run.sh playerctl next
# bindl = , XF86AudioPause, exec, $scripts/run.sh playerctl play-pause
# bindl = , XF86AudioPlay, exec, $scripts/run.sh playerctl play-pause
# bindl = , XF86AudioPrev, exec, $scripts/run.sh playerctl previous

RUN="$HOME/.config/hypr/scripts/run.sh"
case "$1" in
up)
	"$RUN" wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%+
	;;
down)
	"$RUN" wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ 5%-
	;;
mute)
	"$RUN" wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle
	;;
mic)
	"$RUN" wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle
	;;
next)
	"$RUN" playerctl next
	;;
pause)
	"$RUN" playerctl play-pause
	;;
play)
	"$RUN" playerctl play-pause
	;;
prev)
	"$RUN" playerctl previous
	;;
start)
	systemctl --user start {pipewire,wireplumber}.service
	;;
stop)
	systemctl --user stop {pipewire,wireplumber}.service
	;;
restart)
	systemctl --user restart {pipewire,wireplumber}.service
	;;
esac
