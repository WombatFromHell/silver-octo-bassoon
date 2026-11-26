-- gate-route.lua — gate-based default sink selection (+ browser targeting, Slice 3).
-- Pure logic is unit-tested under LuaJIT (tests/). The WirePlumber glue is added
-- in the deploy slice and runs only when WirePlumber loads this file.

local M = {}

M.CONFIG = {
	-- Pinned by tests/config.spec.lua — keep in sync with the live node name.
	fallback_sink = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game",
	-- Gate-open preference chain (Lua patterns over node.name).
	-- The null-sink the sentinel script loads; its presence is the gate signal.
	gate_sink = "gate_sentinel",

	bluez_pattern = "^bluez_output%.",
	hdmi_pattern = "^alsa_output%.pci-.*hdmi",
	-- Browser streams are pinned to the game sink (same as fallback_sink).
	match_tokens = { "brave", "waterfox" },
}

--- Compute the gate state.
-- The gamescope session is itself the "gate open" signal (env-driven); the
-- sentinel is the escape-hatch for non-gamescope environments.
-- @param is_gamescope boolean  XDG_CURRENT_DESKTOP is "gamescope"
-- @param sentinel_present boolean  gate_sentinel node present
-- @return boolean  gate open
function M.compute_gate_open(is_gamescope, sentinel_present)
	return is_gamescope or sentinel_present
end

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

	-- Gate state: open iff the gamescope env is set OR the gate_sentinel sink
	-- exists. The gamescope session is itself the "gate open" signal; the
	-- sentinel is the escape-hatch for non-gamescope environments.
	local is_gamescope = os.getenv("XDG_CURRENT_DESKTOP") == "gamescope"
	local om_sinks = ObjectManager({
		Interest({
			type = "node",
			Constraint({ "media.class", "=", "Audio/Sink" }),
		}),
	})
	-- Gate state is read at event time, not from an object-added callback: a
	-- callback can land after default-nodes' rescan, so that rescan would still
	-- see the old gate state and never re-select the default.
	local last_gate = nil
	local function gate_is_open()
		local sentinel_present = false
		for obj in om_sinks:iterate() do
			if obj.properties["node.name"] == M.CONFIG.gate_sink then
				sentinel_present = true
			end
		end
		return M.compute_gate_open(is_gamescope, sentinel_present)
	end

	-- The user's stored selection (default.configured.audio.sink), read fresh
	-- per event — no cache, so a stale reference can never go stale.
	local function read_configured(event)
		local om = event:get_source():call("get-object-manager", "metadata")
		local md = om and om:lookup({ Constraint({ "metadata.name", "=", "default" }) })
		if md == nil then
			return nil
		end
		local raw = md:find(0, "default.configured.audio.sink")
		if raw == nil then
			return nil
		end
		local parsed = Json.Raw(raw):parse()
		return parsed and parsed.name or nil
	end

	local state = {}

	-- select-default-node: default sink selection (gate chain).
	SimpleEventHook({
		name = "gate-route/select-default-sink",
		after = { "default-nodes/find-best-default-node" },
		before = { "default-nodes/apply-default-node" },
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
			local gate = gate_is_open()
			if gate ~= last_gate then
				last_gate = gate
				log:info("gate " .. (gate and "OPEN" or "CLOSED"))
			end
			local sel = M.decide(gate, nodes, read_configured(event), state)
			if sel then
				event:set_data("selected-node", sel)
				event:set_data("selected-node-priority", 100000)
				log:info("selected → " .. sel)
			end
		end,
	}):register()

	-- select-target: pin browser streams to the game sink (stateless).
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
			local sel = M.select_browser_target(gate_is_open(), props)
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

	om_sinks:activate()
end

return M
