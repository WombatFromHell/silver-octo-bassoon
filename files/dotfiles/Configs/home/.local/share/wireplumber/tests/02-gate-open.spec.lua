-- tests/02-gate-open.spec.lua — S2: gate open → BlueZ → HDMI → fallback chain.
-- decide(gate_open, available_nodes, configured, state) → name|nil, state
local gate = dofile("../scripts/gate-route.lua")

local BLUEZ = { ["node.name"] = "bluez_output.dummy-SteelSeries_Arctis_7_a2dp_output",
	["priority.session"] = 2000 }
local HDMI = { ["node.name"] = "alsa_output.pci-0000_03_00.1.hdmi-stereo",
	["priority.session"] = 1200 }
local GAME = { ["node.name"] = gate.CONFIG.fallback_sink, ["priority.session"] = 0 }
local MONO = { ["node.name"] = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.mono-chat",
	["priority.session"] = 500 }

spec("gate open, BlueZ available → BlueZ", function()
	local sel = gate.decide(true, { MONO, HDMI, BLUEZ, GAME }, nil, {})
	assert_eq(sel, BLUEZ["node.name"])
end)

spec("gate open, BlueZ absent, HDMI available → HDMI", function()
	local sel = gate.decide(true, { MONO, HDMI, GAME }, nil, {})
	assert_eq(sel, HDMI["node.name"])
end)

spec("gate open, neither BlueZ nor HDMI → fallback", function()
	local sel = gate.decide(true, { MONO, GAME }, nil, {})
	assert_eq(sel, gate.CONFIG.fallback_sink)
end)

spec("gate open, all absent → nil (stock picks)", function()
	local sel = gate.decide(true, { MONO }, nil, {})
	assert_eq(sel, nil)
end)

spec("flip-discard: selection made while closed, gate now open → chain applies", function()
	local state = {}
	gate.decide(false, { MONO, GAME }, MONO["node.name"], state) -- record while closed
	local sel = gate.decide(true, { MONO, HDMI, BLUEZ, GAME }, MONO["node.name"], state)
	assert_eq(sel, BLUEZ["node.name"])
end)

spec("respect selection made while open, present → nil (no override)", function()
	local sel = gate.decide(true, { BLUEZ, GAME }, GAME["node.name"], {})
	assert_eq(sel, nil)
end)
