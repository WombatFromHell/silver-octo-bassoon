-- browser-custom-route.lua
--
-- HDMI is excluded from default audio routing UNLESS a "gate_sentinel"
-- null-sink exists (spawned externally, e.g. via gate-wrap.sh using
-- `pactl load-module module-null-sink sink_name=gate_sentinel`).
--
-- Mechanism: toggle HDMI's own priority.session/priority.driver between
-- its normal value (from 80-output-priorities.conf) and a value below
-- the Arctis wired fallback. This reuses the existing priority-based
-- routing instead of introducing a second routing mechanism.

local hdmi_node_name = "alsa_output.pci-0000_03_00.1.hdmi-stereo-extra3"  -- match your wpctl status name
local hdmi_prio_normal = 1900    -- matches 80-output-priorities.conf
local hdmi_prio_excluded = 1700  -- below Arctis (1800)
local gate_sink_name = "gate_sentinel"

local log = Log.open_topic("s-browser-custom-route")

local hdmi_nodes = {}  -- bound_id -> node
local gate_ids = {}    -- bound_id -> true; presence == gate open

om_hdmi = ObjectManager {
  Interest {
    type = "node",
    Constraint { "node.name", "equals", hdmi_node_name },
  }
}

om_gate = ObjectManager {
  Interest {
    type = "node",
    Constraint { "media.class", "equals", "Audio/Sink" },
    Constraint { "node.name", "equals", gate_sink_name },
  }
}

local function set_hdmi_priority(value)
  for _, node in pairs(hdmi_nodes) do
    node:set_property("priority.session", tostring(value))
    node:set_property("priority.driver", tostring(value))
  end
  log:info("set HDMI priority to " .. value)
end

om_hdmi:connect("object-added", function (_, node)
  hdmi_nodes[node["bound-id"]] = node
  -- new HDMI node appearing while gate is closed should come up excluded
  if not next(gate_ids) then
    set_hdmi_priority(hdmi_prio_excluded)
  end
end)
om_hdmi:connect("object-removed", function (_, node)
  hdmi_nodes[node["bound-id"]] = nil
end)

om_gate:connect("object-added", function (_, node)
  gate_ids[node["bound-id"]] = true
  log:info(gate_sink_name .. " detected, reroute gate open")
  set_hdmi_priority(hdmi_prio_normal)
end)
om_gate:connect("object-removed", function (_, node)
  gate_ids[node["bound-id"]] = nil
  if not next(gate_ids) then
    log:info(gate_sink_name .. " gone, reroute gate closed")
    set_hdmi_priority(hdmi_prio_excluded)
  end
end)

om_hdmi:activate()
om_gate:activate()
