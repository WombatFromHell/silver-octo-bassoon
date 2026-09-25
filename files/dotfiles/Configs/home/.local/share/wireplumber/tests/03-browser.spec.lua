-- tests/03-browser.spec.lua — S3: browser stream target selection (stateless).
-- select_browser_target(stream_props) → name|nil
local gate = dofile("../scripts/gate-route.lua")

spec("gate open, brave stream (app.id) → game sink", function()
	local sel = gate.select_browser_target(true, {
		["app.id"] = "com.brave.Browser",
		["application.name"] = "Brave",
	})
	assert_eq(sel, gate.CONFIG.fallback_sink)
end)

spec("gate open, waterfox stream (application.name) → game sink", function()
	local sel = gate.select_browser_target(true, {
		["application.process.binary"] = "waterfox",
		["application.name"] = "Waterfox Web Browser",
	})
	assert_eq(sel, gate.CONFIG.fallback_sink)
end)

spec("gate closed, brave stream → nil (old script unpinned on close)", function()
	local sel = gate.select_browser_target(false, {
		["app.id"] = "com.brave.Browser",
		["application.name"] = "Brave",
	})
	assert_eq(sel, nil)
end)

spec("gate open, non-browser stream (game) → nil (stock target)", function()
	local sel = gate.select_browser_target(true, {
		["application.process.binary"] = "gamescope",
		["application.name"] = "Some Game",
		["node.name"] = "stream output Some Game",
	})
	assert_eq(sel, nil)
end)

spec("empty props → nil", function()
	local sel = gate.select_browser_target(true, {})
	assert_eq(sel, nil)
end)
