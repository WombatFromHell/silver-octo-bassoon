-- tests/config.spec.lua — pin config values (logic tests use the constants, not literals).
local gate = dofile("../scripts/gate-route.lua")

spec("CONFIG.fallback_sink is the live Arctis 7 Game sink name", function()
	assert_eq(gate.CONFIG.fallback_sink,
		"alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game")
end)

-- Pin the sentinel name shared by sentinel.sh and the script's gate check.
spec("CONFIG.gate_sink is the sink the sentinel script loads", function()
	assert_eq(gate.CONFIG.gate_sink, "gate_sentinel")
end)

-- An optional feature is silently skipped, so the script never loads: the
-- fragment must declare it required and provide the matching feature name.
spec("conf fragment requires the gate-route feature", function()
	local f = io.open(os.getenv("HOME") ..
		"/.config/wireplumber/wireplumber.conf.d/99-script-routing.conf")
	assert(f, "conf fragment not found")
	local text = f:read("a")
	f:close()
	assert_eq(text:match("hooks%.custom%.gate%-route%s*=%s*(%w+)"), "required")
	assert(text:match('provides%s*=%s*"hooks%.custom%.gate%-route"'))
end)
