-- tests/01-gate-closed.spec.lua — S1: gate closed → fallback default (fixes live bug A2).
-- decide(gate_open, available_nodes, configured, state) → name|nil, state
local gate = dofile("../scripts/gate-route.lua")

local MONO = { ["node.name"] = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.mono-chat",
	["priority.session"] = 500 } -- value from 98-disable-mono-chat.conf
local GAME = { ["node.name"] = gate.CONFIG.fallback_sink, ["priority.session"] = 0 }

spec("mono-chat-500: gate closed, no selection → fallback wins over priority.session", function()
	local sel = gate.decide(false, { MONO, GAME }, nil, {})
	assert_eq(sel, gate.CONFIG.fallback_sink)
end)

spec("fallback absent: gate closed, no selection → nil (stock picks, no phantom node)", function()
	local sel = gate.decide(false, { MONO }, nil, {})
	assert_eq(sel, nil)
end)

spec("respect stored selection: gate closed, configured present → nil (no override)", function()
	local sel = gate.decide(false, { MONO, GAME }, MONO["node.name"], {})
	assert_eq(sel, nil)
end)

spec("stored selection unplugged: gate closed, configured absent → fallback", function()
	local sel = gate.decide(false, { MONO, GAME }, "alsa_output.pci-0000_03_00.1.hdmi-stereo", {})
	assert_eq(sel, gate.CONFIG.fallback_sink)
end)

spec("empty nodes: → nil", function()
	local sel = gate.decide(false, {}, nil, {})
	assert_eq(sel, nil)
end)
