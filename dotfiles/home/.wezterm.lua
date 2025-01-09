local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.leader = { key = "a", mods = "CTRL", timeout_milliseconds = 1000 }
config.keys = {
	{
		key = "%",
		mods = "LEADER|SHIFT",
		action = wezterm.action({ SplitHorizontal = { domain = "CurrentPaneDomain" } }),
	},
	{
		key = '"',
		mods = "LEADER|SHIFT",
		action = wezterm.action({ SplitVertical = { domain = "CurrentPaneDomain" } }),
	},
	{
		key = "-",
		mods = "LEADER",
		action = wezterm.action({ SplitPane = {
			direction = "Down",
			size = { Percent = 25 },
		} }),
	},
}

config.initial_cols = 110
config.initial_rows = 32
config.tab_bar_at_bottom = true
config.hide_tab_bar_if_only_one_tab = true
config.window_background_opacity = 0.98
config.macos_window_background_blur = 10
config.color_scheme = "catppuccin-mocha"
config.font = wezterm.font_with_fallback({ "JetBrainsMono Nerd Font" })
config.font_size = 10.5

-- config.default_prog = { "fish", "-l" }

return config
