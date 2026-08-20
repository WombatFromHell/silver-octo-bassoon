-- custom-gate-route.lua
-- WirePlumber 0.5.x | Manages system default sink based on gate_sentinel state.
-- YAGNI/KISS/DRY/SoC/Composable

local log = Log.open_topic("s-custom-gate-route")

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------
local CONFIG = {
	gate_sink = "gate_sentinel",
	fallback_sink = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game",
	hdmi_primary = "extra3",
	hdmi_fallback = "hdmi",
	bluez_token = "bluez_output",
	hook_priority = 100000,
}

-------------------------------------------------------------------------------
-- BLUEZ RESOLVER
-------------------------------------------------------------------------------
local BluezResolver = {}
BluezResolver._cached_name = nil
BluezResolver._dirty = true

function BluezResolver._resolve(om_sinks)
	local found = nil
	for node in om_sinks:iterate() do
		local name = node.properties and node.properties["node.name"] or ""
		if name:find(CONFIG.bluez_token, 1, true) then
			found = name
			break
		end
	end
	BluezResolver._cached_name = found
	BluezResolver._dirty = false
	if found then
		log:info(string.format("Bluez sink resolved → %s", found))
	end
end

function BluezResolver.get(om_sinks)
	if BluezResolver._dirty then
		BluezResolver._resolve(om_sinks)
	end
	return BluezResolver._cached_name
end

function BluezResolver.invalidate()
	BluezResolver._dirty = true
end

-------------------------------------------------------------------------------
-- HDMI RESOLVER (SoC: Caches best available HDMI sink, invalidates on change)
-------------------------------------------------------------------------------
local HdmiResolver = {}
HdmiResolver._cached_name = nil
HdmiResolver._dirty = true

--- Re-scan sinks to find best HDMI target (called only when dirty)
function HdmiResolver._resolve(om_sinks)
	local primary, fallback = nil, nil

	for node in om_sinks:iterate() do
		local name = node.properties and node.properties["node.name"] or ""
		if name:find(CONFIG.hdmi_primary, 1, true) then
			primary = name
			break -- Primary found, no need to continue
		elseif not fallback and name:find(CONFIG.hdmi_fallback, 1, true) then
			fallback = name
		end
	end

	HdmiResolver._cached_name = primary or fallback
	HdmiResolver._dirty = false

	if HdmiResolver._cached_name then
		log:info(
			string.format("HDMI resolved → %s (%s)", HdmiResolver._cached_name, primary and "primary" or "fallback")
		)
	else
		log:warning("No HDMI sink available")
	end
end

function HdmiResolver.get(om_sinks)
	if HdmiResolver._dirty then
		HdmiResolver._resolve(om_sinks)
	end
	return HdmiResolver._cached_name
end

function HdmiResolver.invalidate()
	HdmiResolver._dirty = true
end

-------------------------------------------------------------------------------
-- DEFAULT SINK CONTROLLER (SoC: Only knows about metadata mutations)
-------------------------------------------------------------------------------
local DefaultSink = {}
DefaultSink._metadata = nil

-- Acquire metadata via ObjectManager (compatible with all 0.5.x builds)
local om_metadata = ObjectManager({
	Interest({
		type = "metadata",
		Constraint({ "metadata.name", "=", "default" }),
	}),
})

function DefaultSink.init()
	-- Use iterate() instead of lookup() for universal 0.5.x compatibility
	for md in om_metadata:iterate() do
		DefaultSink._metadata = md
		break
	end
	if not DefaultSink._metadata then
		log:error("Failed to acquire default metadata")
		return false
	end
	return true
end

--- Escape a string for safe embedding in a JSON value
local function json_escape(s)
	return s:gsub("\\", "\\\\"):gsub('"', '\\"')
end

--- Set or clear the default.audio.sink metadata pin
function DefaultSink.set(sink_name)
	if not DefaultSink._metadata then
		return
	end

	if sink_name then
		-- Manual JSON construction: avoids dependency on Json global
		local json = string.format('{"name":"%s"}', json_escape(sink_name))
		DefaultSink._metadata:set(0, "default.audio.sink", "Spa:String:JSON", json)
		log:info(string.format("Pinned default.audio.sink → %s", sink_name))
	else
		DefaultSink._metadata:set(0, "default.audio.sink", "Spa:String:JSON", "{}")
		log:info("Cleared default.audio.sink pin")
	end
end

-------------------------------------------------------------------------------
-- GATE ORCHESTRATOR (SoC: Composes Resolver + DefaultSink based on gate state)
-------------------------------------------------------------------------------
local Gate = {}
Gate._open = false
Gate._om_sinks = nil -- Injected reference for resolver

local om_gate = ObjectManager({
	Interest({
		type = "node",
		Constraint({ "media.class", "=", "Audio/Sink" }),
		Constraint({ "node.name", "=", CONFIG.gate_sink }),
	}),
})

local om_sinks = ObjectManager({
	Interest({
		type = "node",
		Constraint({ "media.class", "=", "Audio/Sink" }),
	}),
})

Gate._om_sinks = om_sinks

--- Apply routing policy based on current gate state
local function apply_policy()
	if Gate._open then
		local bluez = BluezResolver.get(om_sinks)
		if bluez then
			DefaultSink.set(bluez)
			return
		end

		local hdmi = HdmiResolver.get(om_sinks)
		if hdmi then
			DefaultSink.set(hdmi)
		else
			log:warning("Gate OPEN but no bluez/HDMI sink; falling back to stereo-game")
			DefaultSink.set(CONFIG.fallback_sink)
		end
	else
		DefaultSink.set(CONFIG.fallback_sink)
	end
end

function Gate.open()
	if Gate._open then
		return
	end
	Gate._open = true
	log:info("Gate OPEN")
	apply_policy()
end

function Gate.close()
	if not Gate._open then
		return
	end
	Gate._open = false
	log:info("Gate CLOSED")
	apply_policy()
end

function Gate.is_open()
	return Gate._open
end

-- Gate events (thin glue)
om_gate:connect("object-added", function()
	if om_gate:get_n_objects() >= 1 then
		Gate.open()
	end
end)

om_gate:connect("object-removed", function()
	if om_gate:get_n_objects() == 0 then
		Gate.close()
	end
end)

-- Sink hotplug: invalidate cache and re-evaluate
om_sinks:connect("object-added", function(_, node)
	local name = node.properties and node.properties["node.name"] or ""
	local is_hdmi = name:find(CONFIG.hdmi_primary, 1, true) or name:find(CONFIG.hdmi_fallback, 1, true)
	local is_bluez = name:find(CONFIG.bluez_token, 1, true)
	if is_hdmi or is_bluez then
		Core.sync(function()
			if is_hdmi then
				HdmiResolver.invalidate()
			end
			if is_bluez then
				BluezResolver.invalidate()
			end
			log:info(string.format("Sink added (%s) → re-evaluating", name))
			apply_policy()
		end)
	end
end)

om_sinks:connect("object-removed", function(_, node)
	local name = node.properties and node.properties["node.name"] or ""
	local is_hdmi = name:find(CONFIG.hdmi_primary, 1, true) or name:find(CONFIG.hdmi_fallback, 1, true)
	local is_bluez = name:find(CONFIG.bluez_token, 1, true)
	if is_hdmi or is_bluez then
		Core.sync(function()
			if is_hdmi then
				HdmiResolver.invalidate()
			end
			if is_bluez then
				BluezResolver.invalidate()
			end
			log:info(string.format("Sink removed (%s) → re-evaluating", name))
			apply_policy()
		end)
	end
end)

-------------------------------------------------------------------------------
-- OVERRIDE HOOK (SoC: Reads from Gate + Resolver, never mutates state)
-------------------------------------------------------------------------------
local override_hook = SimpleEventHook({
	name = "custom-gate-route/override-default-sink",
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
		if not Gate.is_open() then
			return
		end

		local bluez = BluezResolver.get(om_sinks)
		if bluez then
			event:set_data("selected-node", bluez)
			event:set_data("selected-node-priority", CONFIG.hook_priority)
			log:info(string.format("Override hook enforced → %s (bluez)", bluez))
			return
		end

		local hdmi = HdmiResolver.get(om_sinks)
		if hdmi then
			event:set_data("selected-node", hdmi)
			event:set_data("selected-node-priority", CONFIG.hook_priority)
			log:info(string.format("Override hook enforced → %s (hdmi)", hdmi))
			return
		end

		event:set_data("selected-node", CONFIG.fallback_sink)
		event:set_data("selected-node-priority", CONFIG.hook_priority)
		log:info(string.format("Override hook enforced → %s (fallback)", CONFIG.fallback_sink))
	end,
})

-------------------------------------------------------------------------------
-- ACTIVATION (Composition root - single deterministic init path)
-------------------------------------------------------------------------------
om_gate:activate()
om_sinks:activate()
om_metadata:activate()
override_hook:register()

Core.sync(function()
	if not DefaultSink.init() then
		return
	end

	-- Deterministic initial state: no race, no metadata-changed trigger needed
	if om_gate:get_n_objects() > 0 then
		Gate.open()
		log:info("custom-gate-route initialized (gate OPEN)")
	else
		Gate.close()
		log:info("custom-gate-route initialized (gate CLOSED)")
	end
end)
