-- browser-gate-route.lua
--
-- While a "gate_sentinel" null-sink exists (spawned externally via
-- gate-wrap.sh), pin Brave/Waterfox streams to the wired Arctis
-- ("stereo-game") sink specifically. When the gate closes, unpin them
-- and let default priority routing (handled by hdmi-priority-gate.lua)
-- take over. Noop for every other app at all times.

local fallback_node_name = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"
local gate_sink_name = "gate_sentinel"

local log = Log.open_topic("s-browser-gate-route")

local gate_ids = {} -- bound_id -> true; presence == gate open
local routed_ids = {} -- bound_id -> true; streams we've pinned

om_gate = ObjectManager({
	Interest({
		type = "node",
		Constraint({ "media.class", "equals", "Audio/Sink" }),
		Constraint({ "node.name", "equals", gate_sink_name }),
	}),
})

om_streams = ObjectManager({
	Interest({
		type = "node",
		Constraint({ "media.class", "equals", "Stream/Output/Audio" }),
	}),
})

om_metadata = ObjectManager({
	Interest({ type = "metadata", Constraint({ "metadata.name", "equals", "default" }) }),
})

local target_binaries = {
	["brave"] = true,
	["waterfox"] = true,
}
local target_ids = {
	["com.brave.Browser"] = true,
	["net.waterfox.waterfox"] = true,
}

local function get_default_metadata()
	for m in om_metadata:iterate() do
		return m
	end
	return nil
end

local function pin_node(node)
	local metadata = get_default_metadata()
	if not metadata then
		log:warning("no default metadata object found, cannot route node")
		return
	end
	local bound_id = node["bound-id"]
	if not bound_id then
		log:warning("node has no bound-id yet, skipping")
		return
	end
	metadata:set(bound_id, "target.object", "Spa:Utf8", fallback_node_name)
	routed_ids[bound_id] = true
	log:info(
		"pinned node "
			.. tostring(bound_id)
			.. " ("
			.. tostring(node.properties["application.name"])
			.. ") to "
			.. fallback_node_name
	)
end

local function unpin_all()
	local metadata = get_default_metadata()
	if not metadata then
		return
	end
	for bound_id in pairs(routed_ids) do
		metadata:clear(bound_id, "target.object")
		log:info("cleared pin on node " .. tostring(bound_id))
	end
	routed_ids = {}
end

om_gate:connect("object-added", function(_, node)
	gate_ids[node["bound-id"]] = true
	log:info(gate_sink_name .. " detected, gate open")
end)
om_gate:connect("object-removed", function(_, node)
	gate_ids[node["bound-id"]] = nil
	if not next(gate_ids) then
		log:info(gate_sink_name .. " gone, gate closed")
		unpin_all()
	end
end)

om_streams:connect("object-added", function(_, node)
	local binary = node.properties["application.process.binary"] or ""
	local portal_id = node.properties["pipewire.access.portal.app_id"] or ""
	local is_target = target_binaries[binary] or target_ids[portal_id]

	if not is_target then
		return
	end
	if not next(gate_ids) then
		return
	end -- noop when gate closed

	pin_node(node)
end)
om_streams:connect("object-removed", function(_, node)
	routed_ids[node["bound-id"]] = nil
end)

om_gate:activate()
om_streams:activate()
om_metadata:activate()
