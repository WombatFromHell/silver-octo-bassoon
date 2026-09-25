-- gate-route.lua — gate-based default sink selection (+ browser targeting, Slice 3).
-- Pure logic is unit-tested under LuaJIT (tests/). The WirePlumber glue is added
-- in the deploy slice and runs only when WirePlumber loads this file.

local M = {}

M.CONFIG = {
	-- Pinned by tests/config.spec.lua — keep in sync with the live node name.
	fallback_sink = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game",
	-- Gate-open preference chain (Lua patterns over node.name).
	bluez_pattern = "^bluez_output%.",
	hdmi_pattern = "^alsa_output%.pci-.*hdmi",
	-- Browser streams are pinned to the game sink (same as fallback_sink).
	match_tokens = { "brave", "waterfox" },
}

local function node_in(nodes, name)
	for _, n in ipairs(nodes) do
		if n["node.name"] == name then return true end
	end
	return false
end

local function find_node(nodes, pattern)
	for _, n in ipairs(nodes) do
		local name = n["node.name"]
		if name and name:match(pattern) then return name end
	end
	return nil
end

--- Select the default sink.
-- @param gate_open boolean  gate sentinel present
-- @param available_nodes list of node property tables (the event's available-nodes)
-- @param configured string|nil  user's stored selection (default.configured.audio.sink)
-- @param state table  persistent state across events
-- @return name|nil  node name to select, or nil to leave the stock selection alone
-- @return state  updated state
function M.decide(gate_open, available_nodes, configured, state)
	-- Track the user's selection under the gate state it was made in;
	-- a gate-state flip discards it.
	if configured ~= state.user_selection then
		state.user_selection = configured
		state.user_selection_gate = gate_open
	elseif state.user_selection and gate_open ~= state.user_selection_gate then
		state.user_selection = nil
		state.user_selection_gate = nil
	end

	-- Respect a current-state user selection (stock find-selected already picked it).
	if state.user_selection and node_in(available_nodes, state.user_selection) then
		return nil, state
	end

	if not gate_open then
		-- Gate closed: force the fallback if it exists, else let stock pick.
		if node_in(available_nodes, M.CONFIG.fallback_sink) then
			return M.CONFIG.fallback_sink, state
		end
		return nil, state
	end

	-- Gate open: BlueZ → HDMI → fallback.
	local sel = find_node(available_nodes, M.CONFIG.bluez_pattern)
	if sel then return sel, state end
	sel = find_node(available_nodes, M.CONFIG.hdmi_pattern)
	if sel then return sel, state end
	if node_in(available_nodes, M.CONFIG.fallback_sink) then
		return M.CONFIG.fallback_sink, state
	end
	return nil, state
end

--- Select a target sink for a stream (browser pinning).
-- Stateless: no metadata writes, no cache — the stock select-target chain
-- does the linking.
-- @param gate_open boolean  gate sentinel present
-- @param props stream property table
-- @return name|nil  target sink name, or nil to leave the stock target alone
function M.select_browser_target(gate_open, props)
	if not gate_open then return nil end
	local haystack = table.concat({
		tostring(props["application.process.binary"] or ""),
		tostring(props["application.name"] or ""),
		tostring(props["node.name"] or ""),
		tostring(props["pipewire.access.portal.app_id"] or ""),
		tostring(props["app.id"] or ""),
	}, " "):lower()
	for _, token in ipairs(M.CONFIG.match_tokens) do
		if haystack:find(token, 1, true) then
			return M.CONFIG.fallback_sink
		end
	end
	return nil
end

-- ---------------------------------------------------------------------------
-- WirePlumber glue — runs only when WirePlumber loads this file (Log present).
-- ---------------------------------------------------------------------------
if Log then
	local log = Log.open_topic("s-gate-route")

	-- Gate state: open iff the gate_sentinel sink exists.
	local gate_open = false
	local om_gate = ObjectManager({
		Interest({
			type = "node",
			Constraint({ "media.class", "=", "Audio/Sink" }),
			Constraint({ "node.name", "=", "gate_sentinel" }),
		}),
	})
	local function on_gate_changed()
		gate_open = om_gate:get_n_objects() >= 1
		log:info("gate " .. (gate_open and "OPEN" or "CLOSED"))
	end
	om_gate:connect("object-added", on_gate_changed)
	om_gate:connect("object-removed", on_gate_changed)

	-- The user's stored selection (default.configured.audio.sink), read fresh
	-- per event — no cache, so a stale reference can never go stale.
	local om_metadata = ObjectManager({
		Interest({
			type = "metadata",
			Constraint({ "metadata.name", "=", "default" }),
		}),
	})
	local function read_configured()
		for md in om_metadata:iterate() do
			return md:get_properties()["default.configured.audio.sink"]
		end
		return nil
	end

	local state = {}

	-- select-default-node: default sink selection (gate chain).
	SimpleEventHook({
		name = "gate-route/select-default-sink",
		after = { "default-nodes/find-best-default-node" },
		interests = {
			EventInterest({
				Constraint({ "event.type", "=", "select-default-node" }),
			}),
		},
		execute = function(event)
			local props = event:get_properties()
			if props["default-node.type"] ~= "audio.sink" then
				return
			end
			local available = event:get_data("available-nodes")
			local nodes = available and (available.parse and available:parse() or available) or {}
			local sel = M.decide(gate_open, nodes, read_configured(), state)
			if sel then
				event:set_data("selected-node", sel)
				event:set_data("selected-node-priority", 100000)
				log:info("selected → " .. sel)
			end
		end,
	}):register()

	-- select-target: pin browser streams to the game sink (stateless).
	local om_sinks = ObjectManager({
		Interest({
			type = "node",
			Constraint({ "media.class", "=", "Audio/Sink" }),
		}),
	})
	SimpleEventHook({
		name = "gate-route/select-browser-target",
		before = { "linking/find-default-target" },
		interests = {
			EventInterest({
				Constraint({ "event.type", "=", "select-target" }),
			}),
		},
		execute = function(event)
			if event:get_data("target") then
				return -- a target is already chosen
			end
			local props = event:get_properties()
			if props["media.direction"] ~= "Output" then
				return -- only pin output streams to the sink
			end
			local sel = M.select_browser_target(gate_open, props)
			if sel then
				for obj in om_sinks:iterate() do
					if obj.properties["node.name"] == sel then
						event:set_data("target", obj)
						log:info("browser stream → " .. sel)
						return
					end
				end
			end
		end,
	}):register()

	om_gate:activate()
	om_metadata:activate()
	om_sinks:activate()
end

return M
