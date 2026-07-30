local log = Log.open_topic("s-custom-gate-route")

local GATE_NAME = "gate_sentinel"
local ARCTIS_GAME = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game"
local ARCTIS_PREFIX = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00."

local PRIO_BLUEZ      = 3000
local PRIO_HDMI       = 2000
local PRIO_ARCTIS     = 1000
local PRIO_ARCTIS_SUB = 500

local gate_open = false
local initialized = false

local function set_prio(node, prio)
  local cur = tonumber(node.properties["priority.session"]) or 0
  if cur ~= prio then
    for md in om_metadata:iterate() do
      md:set(node.id, "priority.session", "Spa:Int", tostring(prio))
      break
    end
    log:info(string.format("%s prio → %d (was %d)", node.properties["node.name"], prio, cur))
  end
end

local function set_default_pin(node_name)
  for md in om_metadata:iterate() do
    if node_name then
      md:set(0, "default.audio.sink", "Spa:String:JSON",
          Json.Object({ ["name"] = node_name }):to_string())
      log:info("Pinned default sink → " .. node_name)
    else
      md:set(0, "default.audio.sink", "Spa:String:JSON", "{}")
      log:info("Cleared default sink pin (waiting for node)")
    end
    break
  end
end

local function find_hdmi_sink()
  for node in om_sinks:iterate() do
    local name = node.properties["node.name"] or ""
    if name:find("hdmi-stereo", 1, true) and name:find("pci-0000_03_00.1", 1, true) then
      return name
    end
  end
  return nil
end

local function apply_priorities()
  local hdmi_name = find_hdmi_sink()

  for node in om_sinks:iterate() do
    local name = node.properties["node.name"] or ""
    if name:match("^bluez_output%.") then
      set_prio(node, PRIO_BLUEZ)
    elseif name == ARCTIS_GAME then
      set_prio(node, gate_open and 0 or PRIO_ARCTIS)
    elseif name:sub(1, #ARCTIS_PREFIX) == ARCTIS_PREFIX then
      set_prio(node, gate_open and 0 or PRIO_ARCTIS_SUB)
    elseif hdmi_name and name == hdmi_name then
      set_prio(node, gate_open and PRIO_HDMI or 0)
    end
  end

  if gate_open then
    if hdmi_name then
      set_default_pin(hdmi_name)
    else
      log:info("Gate OPEN but HDMI node not yet enumerated; waiting for node event")
      set_default_pin(nil)
    end
  else
    set_default_pin(ARCTIS_GAME)
  end
end

local function gate_count()
  local n = 0
  for _ in om_gate:iterate() do n = n + 1 end
  return n
end

local function set_gate(open)
  if gate_open == open then return end
  gate_open = open
  log:info("Gate " .. (open and "OPEN" or "CLOSED"))
  apply_priorities()
end

SimpleEventHook {
  name = "custom-gate-route/override-default-sink",
  after = { "default-nodes/find-best-default-node" },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
    },
  },
  execute = function (event)
    local props = event:get_properties()
    if props["default-node.type"] == "audio.sink" and gate_open then
      local hdmi = find_hdmi_sink()
      if hdmi then
        event:set_data("selected-node", hdmi)
        event:set_data("selected-node-priority", PRIO_HDMI)
      end
    end
  end
}:register()

om_gate = ObjectManager({ Interest({ type = "node",
    Constraint({ "media.class", "=", "Audio/Sink" }),
    Constraint({ "node.name", "=", GATE_NAME }) }) })

om_sinks = ObjectManager({ Interest({ type = "node",
    Constraint({ "media.class", "=", "Audio/Sink" }) }) })

om_metadata = ObjectManager({ Interest({ type = "metadata",
    Constraint({ "metadata.name", "=", "default" }) }) })

om_gate:connect("object-added", function() if gate_count() >= 1 then set_gate(true) end end)
om_gate:connect("object-removed", function() if gate_count() == 0 then set_gate(false) end end)

om_sinks:connect("object-added", function(_, node)
  if not initialized then return end
  local name = node.properties["node.name"] or ""
  if name:match("^alsa_output%.pci%-0000_03_00_1%.hdmi%-stereo%-") then
    Core.sync(function()
      log:info("HDMI node appeared → re-evaluating routes")
      apply_priorities()
    end)
  else
    apply_priorities()
  end
end)

om_gate:activate()
om_sinks:activate()
om_metadata:activate()

local function do_init()
  if initialized then return end
  initialized = true
  local current_gate_count = gate_count()
  gate_open = current_gate_count > 0
  log:info("Initial gate: " .. (gate_open and "OPEN" or "CLOSED") .. " (count: " .. current_gate_count .. ")")
  apply_priorities()
  log:info("custom-gate-route initialized (post-policy)")
end

om_metadata:connect("object-added", function(_, md)
  md:connect("changed", function(_, key)
    if key == "default.audio.sink" and not initialized then
      do_init()
    end
  end)
end)

Core.sync(function()
  if not initialized then
    log:warning("Metadata listener missed; forcing init")
    do_init()
  end
end)
