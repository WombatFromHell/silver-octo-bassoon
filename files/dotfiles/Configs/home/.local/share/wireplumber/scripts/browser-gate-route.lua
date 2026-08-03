-- browser-gate-route.lua
-- WirePlumber 0.5.x | YAGNI/KISS/DRY/SoC/Composable

local log = Log.open_topic("s-browser-gate-route")

-------------------------------------------------------------------------------
-- CONFIGURATION (Single source of truth - KISS/YAGNI)
-------------------------------------------------------------------------------
local CONFIG = {
  gate_sink    = "gate_sentinel",
  target_sink  = "alsa_output.usb-SteelSeries_SteelSeries_Arctis_7-00.stereo-game",
  match_tokens = { "brave", "waterfox" },
}

-------------------------------------------------------------------------------
-- MATCHER MODULE (SoC: Pure function, no side effects, reusable)
-------------------------------------------------------------------------------
local Matcher = {}

--- Build a normalized search string from node properties once
function Matcher.build_haystack(node)
  if not node or not node.properties then return "" end
  local props = node.properties
  return table.concat({
    tostring(props["application.process.binary"] or ""),
    tostring(props["application.name"] or ""),
    tostring(props["node.name"] or ""),
    tostring(props["pipewire.access.portal.app_id"] or ""),
    tostring(props["app.id"] or ""),
  }, " "):lower()
end

--- Check if haystack contains any configured token (DRY: single loop)
function Matcher.is_target(node)
  local haystack = Matcher.build_haystack(node)
  for _, token in ipairs(CONFIG.match_tokens) do
    if haystack:find(token, 1, true) then return true end
  end
  return false
end

-------------------------------------------------------------------------------
-- ROUTER MODULE (SoC: Only knows about metadata + pin/unpin)
-------------------------------------------------------------------------------
local Router      = {}
Router._metadata  = nil
Router._routed    = {}

-- Acquire metadata via ObjectManager (compatible with all 0.5.x builds)
local om_metadata = ObjectManager({
  Interest({
    type = "metadata",
    Constraint({ "metadata.name", "=", "default" }),
  })
})

function Router.init()
  -- Use iterate() instead of lookup() for universal 0.5.x compatibility
  for md in om_metadata:iterate() do
    Router._metadata = md
    break
  end
  if not Router._metadata then
    log:error("Failed to acquire default metadata")
    return false
  end
  return true
end

function Router.pin(node)
  local id = node and node["bound-id"]
  if not id or not Router._metadata then return end

  Router._metadata:set(id, "target.object", "Spa:String", CONFIG.target_sink)
  Router._routed[id] = true
  log:info(string.format("Pinned %d (%s) → %s",
    id,
    tostring(node.properties and node.properties["application.name"] or "?"),
    CONFIG.target_sink))
end

function Router.unpin_all()
  if not Router._metadata then return end
  for id in pairs(Router._routed) do
    Router._metadata:set(id, "target.object", nil, nil)
    log:info(string.format("Unpinned %d", id))
  end
  Router._routed = {} -- DRY: reset in one place
end

function Router.forget(id)
  Router._routed[id] = nil
end

-------------------------------------------------------------------------------
-- GATE CONTROLLER (SoC: Orchestrates Matcher + Router based on gate state)
-------------------------------------------------------------------------------
local Gate = {}
Gate._open = false

local om_gate = ObjectManager({
  Interest({
    type = "node",
    Constraint({ "media.class", "=", "Audio/Sink" }),
    Constraint({ "node.name", "=", CONFIG.gate_sink }),
  })
})

local om_streams = ObjectManager({
  Interest({
    type = "node",
    Constraint({ "media.class", "=", "Stream/Output/Audio" })
  })
})

--- Evaluate all existing streams against current gate state
local function reconcile()
  if not Gate._open then return end
  for node in om_streams:iterate() do
    if Matcher.is_target(node) then
      Router.pin(node)
    end
  end
end

function Gate.open()
  if Gate._open then return end -- KISS: idempotent
  Gate._open = true
  log:info("Gate OPEN → routing browser streams")
  reconcile()
end

function Gate.close()
  if not Gate._open then return end -- KISS: idempotent
  Gate._open = false
  log:info("Gate CLOSED → clearing overrides")
  Router.unpin_all()
end

-- Wire events (thin glue layer - SoC)
om_gate:connect("object-added", function()
  if om_gate:get_n_objects() >= 1 then Gate.open() end
end)

om_gate:connect("object-removed", function()
  if om_gate:get_n_objects() == 0 then Gate.close() end
end)

om_streams:connect("object-added", function(_, node)
  if Gate._open and Matcher.is_target(node) then
    Router.pin(node)
  end
end)

om_streams:connect("object-removed", function(_, node)
  Router.forget(node and node["bound-id"])
end)

-------------------------------------------------------------------------------
-- ACTIVATION (Composition root)
-------------------------------------------------------------------------------
om_gate:activate()
om_streams:activate()
om_metadata:activate()

Core.sync(function()
  if not Router.init() then return end

  if om_gate:get_n_objects() > 0 then
    Gate.open()
    log:info("browser-gate-route initialized (gate OPEN)")
  else
    log:info("browser-gate-route initialized (gate CLOSED)")
  end
end)
