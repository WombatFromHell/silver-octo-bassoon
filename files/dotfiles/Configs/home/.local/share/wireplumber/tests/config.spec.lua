-- tests/config.spec.lua — pin config values (logic tests use the constants, not literals).
local gate = dofile("../scripts/gate-route.lua")

spec("CONFIG.fallback_sink is the live Arctis 7 Game sink name", function()
	assert_eq(gate.CONFIG.fallback_sink,
		"alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game")
end)
