-- browser-gate-route.lua
-- While gate_sentinel exists, pin Brave/Waterfox streams to Arctis.
-- When gate closes, unpin them.

local fallback_node_name = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"
local gate_sink_name = "gate_sentinel"

local log = Log.open_topic("s-browser-gate-route")

local gate_open = false
local routed_ids = {}

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

local function pin_node(node)
  local metadata
  for m in om_metadata:iterate() do metadata = m; break end
  if not metadata then
    log:warning("no default metadata found, cannot route node")
    return
  end
  local bound_id = node["bound-id"]
  if not bound_id then
    log:warning("node has no bound-id yet, skipping")
    return
  end
  metadata:set(bound_id, "target.object", "Spa:Utf8", fallback_node_name)
  routed_ids[bound_id] = true
  log:info("pinned node " .. bound_id .. " (" .. (node.properties["application.name"] or "") .. ") to " .. fallback_node_name)
end

local function unpin_all()
  local metadata
  for m in om_metadata:iterate() do metadata = m; break end
  if not metadata then return end
  for bound_id in pairs(routed_ids) do
    metadata:clear(bound_id, "target.object")
  end
  routed_ids = {}
end

local function is_target(node)
  local binary = node.properties["application.process.binary"] or ""
  local portal_id = node.properties["pipewire.access.portal.app_id"] or ""
  return target_binaries[binary] or target_ids[portal_id]
end

local function pin_existing_targets()
  for s in om_streams:iterate() do
    if is_target(s) and not routed_ids[s["bound-id"]] then
      pin_node(s)
    end
  end
end

om_gate:connect("object-added", function()
  gate_open = true
  log:info(gate_sink_name .. " detected, gate open")
  pin_existing_targets()
end)
om_gate:connect("object-removed", function()
  gate_open = false
  log:info(gate_sink_name .. " gone, gate closed")
  unpin_all()
end)

om_streams:connect("object-added", function(_, node)
  if not gate_open then return end
  if is_target(node) then pin_node(node) end
end)
om_streams:connect("object-removed", function(_, node)
  routed_ids[node["bound-id"]] = nil
end)

om_gate:activate()
om_streams:activate()
om_metadata:activate()
