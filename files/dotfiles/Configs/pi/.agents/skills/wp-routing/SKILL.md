---
name: wp-routing
description: Condensed, docs-verified pointers for working with WirePlumber 0.5.x+ routing/profile scripts (device route & profile selection, linking) and SPA-JSON config files. Use when writing or editing wireplumber.conf.d fragments, ALSA/Bluetooth monitor rules, device.routes.* settings, or Lua scripts/hooks that touch device profiles, routes, or node linking on WirePlumber 0.5+.
---

# wp-routing

Pointers for WirePlumber **0.5.x+** routing/config work, checked against the
official docs (pipewire.pages.freedesktop.org/wireplumber). WirePlumber 0.5
dropped Lua-based configuration entirely — don't reach for `.lua` config
files, `alsa_monitor.rules`, or `main.lua` patterns from 0.4-era guides/blog
posts/Stack Overflow answers found online; they no longer load.

## 1. Big architectural change from 0.4 → 0.5

- **Config files are SPA-JSON only.** Lua is still used for _scripting_
  (event hooks), but no longer for _configuration_. If a `wireplumber.conf`
  still references `config/lua` components (e.g. `main.lua`, `policy.lua`,
  `bluetooth.lua`), WirePlumber will error on startup.
- Old Lua rule tables like:
  ```lua
  table.insert(alsa_monitor.rules, rule)
  ```
  become SPA-JSON `monitor.alsa.rules` (or `monitor.bluez.rules`,
  `device.rules`, `node.rules`) entries — see §3.
- Do not edit files under `/usr/share/wireplumber/` — they belong to the
  package. Drop overrides/fragments in `~/.config/wireplumber/wireplumber.conf.d/`
  (or `/etc/wireplumber/wireplumber.conf.d/`) instead.

## 2. Where config lives, and how fragments merge

- Default entry point: `wireplumber.conf` (override path with
  `wireplumber -c custom.conf`).
- Drop-in fragments: `<confdir>/wireplumber.conf.d/*.conf`, loaded in
  alphanumeric order and merged into the main file. Use numeric prefixes
  (`51-`, `80-`, …) to control ordering.
- User config dir (`~/.config/wireplumber/...`) takes priority over
  `/etc/wireplumber/...`, which takes priority over the system default at
  `/usr/share/wireplumber/wireplumber.conf`.
- A file with the same name in a higher-priority dir **replaces** (not
  merges with) the lower-priority file of that same name — copy the
  original first if you want to tweak one setting in it.

## 3. SPA-JSON syntax (superset of JSON — be permissive, not strict)

- `:` and `=` and a bare space are interchangeable as key/value separators.
- Quotes around bare-word keys/string values are optional.
- `,` between array/object entries is optional (whitespace works).
- `#` starts a line comment.
- So all of these are equivalent:
  ```
  key = value
  key: value
  key value
  ```
  and both of these are equivalent:
  ```
  [val1, val2, val3]
  [val1 val2 val3]
  ```
- Still write valid JSON when in doubt — SPA-JSON accepts strict JSON too,
  and it's what most existing files in `/usr/share/wireplumber/` use.

## 4. Device profile & route rules (the actual "routing" config)

Monitor rules select/patch properties on discovered devices/nodes _before_
routing scripts run. General shape:

```
monitor.alsa.rules = [
  {
    matches = [
      { device.name = "~alsa_card.*" }        # ~ prefix = regex match
    ]
    actions = {
      update-props = {
        api.alsa.use-acp      = true
        device.profile        = "pro-audio"
        api.acp.auto-profile  = false
        api.acp.auto-port     = false
      }
    }
  }
]
```

- Section names by monitor: `monitor.alsa.rules`, `monitor.bluez.rules`,
  `monitor.v4l2.rules`, etc. Generic node/device rules also exist as
  `device.rules` / `node.rules` under `wireplumber.settings` (used e.g. by
  the built-in `device.conf`).
- `matches` is a list of OR'd match-blocks; each block is an AND of
  key/value conditions. A leading `~` on a string value means "regex".
- `actions.update-props` is the common action; it merges/overwrites props
  on the matched object.
- To force a specific route/port default (headphones vs speakers, a
  specific profile) after plugging in a device, match on `device.name`,
  `device.nick`, or `node.name` and set `device.profile` /
  `device.profile-set` in `update-props`.

## 5. Route/volume defaults via Settings (preferred for simple tweaks)

For plain default-volume / route-restore behavior, prefer the
`device.routes.*` settings over writing a custom script:

- `device.routes.default-sink-volume`, `device.routes.default-source-volume`
- Per-device variants: `device.routes.default-{source,sink}-volume`
  (0.5.14+) for device-specific defaults (e.g. quieter default for internal
  speakers).
- `device.use-persistent-storage` — whether route/profile choices persist
  across restarts.

Set at build time in a `.conf` fragment:

```
wireplumber.settings = {
  device.routes.default-sink-volume = 0.5
}
```

(only applied after a restart), or at runtime with `wpctl`:

```bash
wpctl settings device.routes.default-sink-volume 0.5          # session-only
wpctl settings --save device.routes.default-sink-volume 0.5   # persists
wpctl settings --reset device.routes.default-sink-volume      # back to schema default
wpctl settings --delete device.routes.default-sink-volume     # drop saved override
```

A saved (`--save`) value silently overrides whatever the config file says
until `--delete`d — check for stray saved state before debugging a config
fragment that "isn't taking effect."

## 6. How the built-in route/profile selection actually runs (event hooks)

If a settings/rules tweak isn't enough and you need custom logic, know the
real hook pipeline before writing a competing script (files under
`/usr/share/wireplumber/scripts/device/`):

| Trigger                               | Hook                                 | File                 | Does                                                 |
| ------------------------------------- | ------------------------------------ | -------------------- | ---------------------------------------------------- |
| device added / `EnumProfiles` changes | `device/select-profile`              | `select-profile.lua` | schedules a `select-profile` event                   |
| device added / `EnumRoute` changes    | `device/select-route`                | `select-routes.lua`  | updates route cache, schedules `select-routes` event |
| `Profile` param changed by user       | `device/store-user-selected-profile` | `select-profile.lua` | persists profile if `profile.save == true`           |
| `Route` param changed                 | `device/store-or-restore-routes`     | `select-routes.lua`  | stores/restores route selection                      |

`select-profile` event runs, in order: `device/find-stored-routes`
(`state-routes.lua`) → `device/find-best-routes` (`find-best-routes.lua`)
→ `device/apply-route-props` (`state-routes.lua`) → `device/apply-routes`
(`apply-routes.lua`).

Related scripts you may see referenced: `find-best-profile.lua`,
`find-preferred-profile.lua`, `apply-profile.lua`, `state-profile.lua`,
`autoswitch-bluetooth-profile.lua`, `automute-alsa-routes.lua`. Linking
(distinct from routing) lives in `scripts/linking/` — `find-best-target.lua`,
`find-default-target.lua`, `find-defined-target.lua`, `find-media-role-target.lua`.

To extend rather than replace: add your own script as a component with a
`provides`/hook, and slot it into the existing event order rather than
duplicating a stock hook name.

## 7. Writing a custom Lua script (0.5+ component model)

Scripts are **not** auto-loaded; each must be declared as a component and
required by a profile in a `.conf` file.

`~/.local/share/wireplumber/scripts/90-hello-world.lua`:

```lua
log = Log.open_topic("hello-world")
log.info("Hello world")
```

`~/.config/wireplumber/wireplumber.conf.d/90-hello-world.conf`:

```
wireplumber.components = [
  { name = "90-hello-world.lua", type = script/lua, provides = hello-world }
]
wireplumber.profiles = {
  main = { hello-world = required }
}
```

- Lua scripts use the **event dispatcher API** (post-0.4.81 refactor):
  scripts register hooks that react to named events in a defined order,
  rather than one monolithic policy file.
- Reading JSON/config from Lua: `Conf.get_section_as_json()` for config
  sections, `Settings.get()` for a single setting — both return `Json`
  objects (binds `WpSpaJson`). Build JSON with `Json.Object{...}`,
  `Json.Array{...}`, `Json.String()`, `Json.Int()`, etc.
- Matching config against live objects: `JsonUtils` implements the
  `matches`/`actions` rules engine that powers `*.rules` sections — reuse
  it instead of hand-rolling match logic if extending a rules-based script.
- `Core.require_api("mixer", function(mixer) ... end)` — load an API
  plugin (name without the `-api` suffix) before calling into it, e.g. for
  volume/route control via the mixer API.

## 8. Fast triage checklist

1. Confirm the target is WirePlumber **0.5+**, not 0.4 (`wireplumber --version`)
   — 0.4 syntax (Lua config, `alsa_monitor.rules`) is a different world and
   most web results are still 0.4-era.
2. Config not applying? Check `--save`d `wpctl settings` state (§5) before
   blaming the `.conf` fragment.
3. Fragment not loading? Confirm it's under `wireplumber.conf.d/`, has a
   `.conf` extension, and isn't shadowed by a same-named file in a
   higher-priority directory (§2).
4. Wrong route/profile picked automatically? Check `monitor.alsa.rules` /
   `monitor.bluez.rules` matches first (§4), then the
   `find-best-profile.lua` / `find-best-routes.lua` priority logic (§6)
   before writing a new hook.
5. Validate JSON syntax leniently but prefer strict JSON style for
   anything you hand-write, for portability and diffability (§3).

## 9. Primary sources (fetch these for anything not covered above)

- Config file & SPA-JSON: `https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/conf_file.html`
- Modifying configuration / settings + wpctl: `https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/modifying_configuration.html`
- Configuration option types: `https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/configuration_option_types.html`
- 0.4 → 0.5 migration guide: `https://pipewire.pages.freedesktop.org/wireplumber/daemon/configuration/migration.html`
- Device profile/route hooks: `https://pipewire.pages.freedesktop.org/wireplumber/scripting/existing_scripts/device.html`
- Existing scripts index (linking, default nodes): `https://pipewire.pages.freedesktop.org/wireplumber/scripting/existing_scripts.html`
- Custom scripts / component declaration: `https://pipewire.pages.freedesktop.org/wireplumber/scripting/custom_scripts.html`
- Lua JSON API (`Json`, `JsonUtils`): `https://pipewire.pages.freedesktop.org/wireplumber/scripting/lua_api/lua_json_api.html`
- Lua Core API (`Core.require_api`, `Core.sync`, …): `https://pipewire.pages.freedesktop.org/wireplumber/scripting/lua_api/lua_core_api.html`
- Release notes (feature/version cross-check): `https://pipewire.pages.freedesktop.org/wireplumber/resources/releases.html`

When something here seems stale or version-specific, fetch the matching
page above rather than trusting memory or older blog posts — WirePlumber's
config system changed substantially between 0.4 and 0.5.
