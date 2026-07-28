-- browser-custom-route.lua
--
-- Desktop web browser audio (Brave, Waterfox, ...) should NEVER play
-- through the HDMI/TV sink, even though HDMI is the highest-priority
-- sink per monitor.alsa.rules. Everything else (games, gamescope, Steam,
-- etc.) is left alone and simply falls through to the default
-- priority-based routing already defined in 80-output-priorities.conf:
--   Bluetooth (2000) > HDMI (1900) > Arctis wired (1800)
--
-- This script pins matched browser streams to:
--   - the Bluetooth sink, if one is currently active
--   - otherwise, the wired Arctis sink
-- ...and never to HDMI.
--
-- Install:
--   ~/.config/wireplumber/scripts/browser-custom-route.lua
-- Enable via:
--   ~/.config/wireplumber/wireplumber.conf.d/99-browser-custom-route.conf
--     wireplumber.components = [
--       { name = "browser-custom-route.lua", type = "script/lua", provides = "custom.browser-custom-route" }
--     ]

-- EDIT THIS to match your exact wired fallback sink node name (check with `wpctl status`)
local fallback_node_name = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"

local log = Log.open_topic("s-browser-custom-route")

-- Track bluez sink nodes and their state, and their node.name for routing
local bluez_nodes = {}      -- bound_id -> node
local active_bluez_name = nil

om_bluez = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "equals", "Audio/Sink" },
    Constraint { "node.name", "matches", "bluez_output.*" },
  }
}

om_streams = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "equals", "Stream/Output/Audio" },
  }
}

om_metadata = ObjectManager {
  Interest { type = "metadata", Constraint { "metadata.name", "equals", "default" } }
}

function get_active_bluez_sink_name()
  for id, node in pairs(bluez_nodes) do
    local state = node.properties and node.properties["node.state"]
    if state == "running" or state == "idle" then
      return node.properties["node.name"]
    end
  end
  return nil
end

function get_default_metadata()
  for m in om_metadata:iterate() do
    return m
  end
  return nil
end

function route_node_away_from_hdmi(node)
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

  local target = get_active_bluez_sink_name() or fallback_node_name

  metadata:set(bound_id, "target.node", "Spa:Id", target)
  log:info("routed node " .. tostring(bound_id) .. " (" ..
    tostring(node.properties["application.name"]) .. ") to " .. target)
end

om_bluez:connect("object-added", function (_, node)
  bluez_nodes[node["bound-id"]] = node
end)

om_bluez:connect("object-removed", function (_, node)
  bluez_nodes[node["bound-id"]] = nil
end)

-- Match Brave specifically. Using process.binary is the most stable signal.
local target_binaries = {
  ["brave"] = true,
  ["waterfox"] = true,
}

local target_ids = {
  ["com.brave.Browser"] = true,
  ["net.waterfox.waterfox"] = true,
}

om_streams:connect("object-added", function (_, node)
  local app = node.properties["application.name"] or ""
  local binary = node.properties["application.process.binary"] or ""
  local portal_id = node.properties["pipewire.access.portal.app_id"] or ""

  local is_target = target_binaries[binary] or target_ids[portal_id]

  if not is_target then
    log:debug("ignoring stream: app=" .. app .. " binary=" .. binary)
    return
  end

  route_node_away_from_hdmi(node)
end)

om_bluez:activate()
om_streams:activate()
om_metadata:activate()
