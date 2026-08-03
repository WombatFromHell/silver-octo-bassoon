-- hdmi-gamescope-route.lua
-- WirePlumber 0.5.x | Prioritize HDMI sink as default when running under Gamescope.
-- YAGNI/KISS/DRY/SoC/Composable

local log = Log.open_topic("s-hdmi-gamescope-route")

-------------------------------------------------------------------------------
-- CONFIGURATION
-------------------------------------------------------------------------------
local CONFIG = {
  hdmi_pattern    = "alsa_output.pci-0000_03_00.1.hdmi-stereo-*",
  target_priority = 1900,
}

-------------------------------------------------------------------------------
-- SESSION DETECTOR (SoC: Detect once at init, immutable for session lifetime)
-------------------------------------------------------------------------------
local SessionDetector = {}

--- Two-tier Gamescope detection via environment variables only.
-- Env vars are authoritative, race-free, and set before WP starts.
-- Process scanning is intentionally omitted: it races with short-lived PIDs,
-- triggers wp-proc-utils GLib warnings, and adds no real detection coverage
-- since Gamescope always sets at least one of these variables.
function SessionDetector.detect()
  -- Tier 1: Desktop environment variable (set by gamescope-session or compositor)
  local desktop = os.getenv("XDG_CURRENT_DESKTOP") or ""
  if desktop ~= "" then
    return desktop:lower():find("gamescope", 1, true) ~= nil
  end

  -- Tier 2: Gamescope Wayland socket (set by gamescope itself)
  if os.getenv("GAMESCOPE_WAYLAND_DISPLAY") then
    return true
  end

  return false
end

-------------------------------------------------------------------------------
-- HDMI RESOLVER (SoC: Cached lookup, invalidated only on sink topology change)
-------------------------------------------------------------------------------
local HdmiResolver = {}
HdmiResolver._cached_name = nil
HdmiResolver._dirty = true

local om_hdmi = ObjectManager({
  Interest({
    type = "node",
    Constraint({ "media.class", "=", "Audio/Sink" }),
    Constraint({ "node.name", "matches", CONFIG.hdmi_pattern }),
  })
})

function HdmiResolver._resolve()
  for node in om_hdmi:iterate() do
    local name = node.properties and node.properties["node.name"]
    if name then
      HdmiResolver._cached_name = name
      HdmiResolver._dirty = false
      log:info(string.format("HDMI sink resolved → %s", name))
      return
    end
  end
  HdmiResolver._cached_name = nil
  HdmiResolver._dirty = false
  log:warning("No HDMI sink matching pattern currently available")
end

function HdmiResolver.get()
  if HdmiResolver._dirty then
    HdmiResolver._resolve()
  end
  return HdmiResolver._cached_name
end

function HdmiResolver.invalidate()
  HdmiResolver._dirty = true
end

-- React to HDMI sink topology changes
om_hdmi:connect("object-added", function(_, node)
  Core.sync(function()
    HdmiResolver.invalidate()
    local name = node.properties and node.properties["node.name"] or "?"
    log:info(string.format("HDMI sink added (%s) → cache invalidated", name))
  end)
end)

om_hdmi:connect("object-removed", function(_, node)
  Core.sync(function()
    HdmiResolver.invalidate()
    local name = node.properties and node.properties["node.name"] or "?"
    log:info(string.format("HDMI sink removed (%s) → cache invalidated", name))
  end)
end)

-------------------------------------------------------------------------------
-- HOOK (SoC: Read-only consumer of SessionDetector + HdmiResolver)
-------------------------------------------------------------------------------
local gamescope_hook = SimpleEventHook {
  name = "hdmi-gamescope-route/priority-override",
  after = {
    "default-nodes/find-best-default-node",
    "custom-gate-route/override-default-sink",
  },
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "select-default-node" },
    },
  },
  execute = function(event)
    -- Early exit: not in Gamescope session (cached boolean, zero cost)
    if not SessionDetector._is_gamescope then return end

    local props = event:get_properties()
    if props["default-node.type"] ~= "audio.sink" then return end

    local hdmi_name = HdmiResolver.get()
    if hdmi_name then
      event:set_data("selected-node", hdmi_name)
      event:set_data("selected-node-priority", CONFIG.target_priority)
      log:info(string.format("Prioritized HDMI sink → %s (prio %d)", hdmi_name, CONFIG.target_priority))
    end
  end,
}

-------------------------------------------------------------------------------
-- ACTIVATION (Composition root - single deterministic init)
-------------------------------------------------------------------------------
om_hdmi:activate()
gamescope_hook:register()

Core.sync(function()
  -- Detect session type exactly once; immutable for WirePlumber's lifetime
  SessionDetector._is_gamescope = SessionDetector.detect()

  if SessionDetector._is_gamescope then
    log:info("hdmi-gamescope-route initialized (Gamescope DETECTED, hook ACTIVE)")
  else
    log:info("hdmi-gamescope-route initialized (Gamescope NOT detected, hook SKIPPED)")
  end
end)
