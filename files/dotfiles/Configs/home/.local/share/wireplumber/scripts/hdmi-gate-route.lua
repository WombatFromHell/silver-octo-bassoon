-- hdmi-gate-route.lua
--
-- HDMI is excluded from routing UNLESS a "gate_sentinel" null-sink exists
-- (spawned externally via gate-wrap.sh). Mechanism: set/clear the
-- default.audio.sink metadata override. NOTE: while the gate is closed,
-- this also suppresses Bluetooth > Arctis priority ordering, since the
-- override pins a single sink outright rather than adjusting priority.

local fallback_node_name = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"
local gate_sink_name = "gate_sentinel"

local log = Log.open_topic("s-hdmi-custom-route")

local gate_ids = {}

om_gate = ObjectManager({
	Interest({
		type = "node",
		Constraint({ "media.class", "equals", "Audio/Sink" }),
		Constraint({ "node.name", "equals", gate_sink_name }),
	}),
})

om_metadata = ObjectManager({
	Interest({ type = "metadata", Constraint({ "metadata.name", "equals", "default" }) }),
})

local function get_default_metadata()
	for m in om_metadata:iterate() do
		return m
	end
	return nil
end

local function set_default_sink(node_name)
	local metadata = get_default_metadata()
	if not metadata then
		log:warning("no default metadata object found")
		return
	end
	metadata:set(0, "default.audio.sink", "Spa:String:JSON", '{"name":"' .. node_name .. '"}')
	log:info("set default.audio.sink override to " .. node_name)
end

local function clear_default_sink()
	local metadata = get_default_metadata()
	if not metadata then
		return
	end
	metadata:delete(0, "default.audio.sink")
	log:info("cleared default.audio.sink override")
end

om_gate:connect("object-added", function(_, node)
	gate_ids[node["bound-id"]] = true
	log:info(gate_sink_name .. " detected, gate open")
	clear_default_sink()
end)
om_gate:connect("object-removed", function(_, node)
	gate_ids[node["bound-id"]] = nil
	if not next(gate_ids) then
		log:info(gate_sink_name .. " gone, gate closed")
		set_default_sink(fallback_node_name)
	end
end)

om_gate:activate()
om_metadata:activate()
