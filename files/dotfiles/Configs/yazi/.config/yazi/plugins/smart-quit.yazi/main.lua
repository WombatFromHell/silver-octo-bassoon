--- smart-quit.yazi/main.lua
-- Calls autosession's save-and-quit if the plugin is loaded, otherwise falls back to quit.
return {
	entry = function()
		local plugin_path = os.getenv("HOME") .. "/.config/yazi/plugins/autosession.yazi/init.lua"
		local f = io.open(plugin_path, "r")

		if f then
			f:close()
			ya.emit("plugin", { "autosession", args = "--save-and-quit" })
		else
			ya.emit("quit", {})
		end
	end,
}
