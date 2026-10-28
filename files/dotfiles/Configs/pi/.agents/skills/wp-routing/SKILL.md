---
name: wp-routing
description: Condensed, docs-verified pointers for working with WirePlumber 0.5.x+ routing/profile scripts (device route & profile selection, linking) and SPA-JSON config files. Use when writing or editing wireplumber.conf.d fragments, ALSA/Bluetooth monitor rules, device.routes.* settings, or Lua scripts/hooks that touch device profiles, routes, or node linking on WirePlumber 0.5+.
---

# wp-routing

WirePlumber **0.5.x+** routing and config pointers, checked against the official docs.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Patterns](#patterns) · [Procedure](#procedure) · [Pitfalls](#pitfalls) · [Verification](#verification) · [Sources](#sources)

## When to Use

Editing `wireplumber.conf.d` fragments, ALSA/Bluetooth monitor rules, `device.routes.*` settings, or Lua hooks touching device profiles, routes, or node linking. Confirm the version first (`wireplumber --version`): 0.5 dropped Lua-based configuration, so 0.4-era `.lua` config files, `alsa_monitor.rules`, and `main.lua` patterns found in blogs and Stack Overflow answers **no longer load**.

## Core Rules

1. **Config is SPA-JSON only.** Lua stays for scripting (event hooks), not configuration. A `wireplumber.conf` that still references `config/lua` components (`main.lua`, `policy.lua`, `bluetooth.lua`) errors at startup. Old rule tables such as `table.insert(alsa_monitor.rules, rule)` become SPA-JSON `monitor.alsa.rules` entries ([Patterns](#patterns)).
2. **Never edit `/usr/share/wireplumber/`** — it belongs to the package. Drop overrides/fragments in `~/.config/wireplumber/wireplumber.conf.d/` or `/etc/wireplumber/wireplumber.conf.d/`.
3. **Priority:** user dir > `/etc/wireplumber/` > `/usr/share/wireplumber/wireplumber.conf`. Drop-ins `<confdir>/wireplumber.conf.d/*.conf` load in alphanumeric order and merge into the main file; numeric prefixes (`51-`, `80-`) control ordering. A same-named file in a higher-priority dir **replaces** rather than merges — copy the original first to tweak one setting. `wireplumber -c custom.conf` overrides the entry point.

## Patterns

### SPA-JSON syntax (superset of JSON — be permissive, not strict)

`:` , `=` and a bare space are interchangeable key/value separators; quotes on bare-word keys and string values are optional; `,` between entries is optional; `#` starts a line comment. So these are equivalent:

```
key = value
key: value
key value
```

and `[val1 val2 val3]` ≡ `[val1, val2, val3]`. Still write strict JSON when in doubt — it's accepted, and it's what the files under `/usr/share/wireplumber/` use.

### Device profile & route rules

Monitor rules select/patch properties on discovered devices and nodes **before** routing scripts run:

```
monitor.alsa.rules = [
  {
    matches = [ { device.name = "~alsa_card.*" } ]   # ~ prefix = regex
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

- Section name follows the monitor: `monitor.alsa.rules`, `monitor.bluez.rules`, `monitor.v4l2.rules`; generic `device.rules` / `node.rules` live under `wireplumber.settings` (used by the built-in `device.conf`).
- `matches` is a list of **OR'd** blocks; each block is an **AND** of key/value conditions; a leading `~` on a string value means regex.
- `actions.update-props` merges/overwrites properties on the matched object.
- To pin a route/port/profile after a device is plugged in, match `device.name`, `device.nick`, or `node.name` and set `device.profile` / `device.profile-set`.

### Settings (preferred for simple tweaks)

Prefer settings over a custom script for default-volume and route-restore behaviour:

- `device.routes.default-sink-volume`, `device.routes.default-source-volume`
- Per-device defaults: `device.routes.default-{source,sink}-volume` (0.5.14+) — e.g. a quieter internal-speaker default
- `device.use-persistent-storage` — whether route/profile choices survive restarts

At build time, in a `.conf` fragment (applied only after a restart):

```
wireplumber.settings = {
  device.routes.default-sink-volume = 0.5
}
```

At runtime with `wpctl`:

```bash
wpctl settings device.routes.default-sink-volume 0.5          # session-only
wpctl settings --save   device.routes.default-sink-volume 0.5 # persists
wpctl settings --reset  device.routes.default-sink-volume     # schema default
wpctl settings --delete device.routes.default-sink-volume     # drop the saved override
```

A `--save`d value silently overrides whatever the config file says until it is `--delete`d.

## Procedure

### How built-in profile/route selection runs

Know the real hook pipeline before writing a competing script (files under `/usr/share/wireplumber/scripts/device/`):

| Trigger | Hook | File | Does |
|---|---|---|---|
| device added / `EnumProfiles` changes | `device/select-profile` | `select-profile.lua` | schedules a `select-profile` event |
| device added / `EnumRoute` changes | `device/select-route` | `select-routes.lua` | updates route cache, schedules `select-routes` |
| `Profile` param changed by user | `device/store-user-selected-profile` | `select-profile.lua` | persists profile if `profile.save == true` |
| `Route` param changed | `device/store-or-restore-routes` | `select-routes.lua` | stores/restores route selection |

The `select-profile` event runs in order: `device/find-stored-routes` (`state-routes.lua`) → `device/find-best-routes` (`find-best-routes.lua`) → `device/apply-route-props` (`state-routes.lua`) → `device/apply-routes` (`apply-routes.lua`).

Related scripts you may see: `find-best-profile.lua`, `find-preferred-profile.lua`, `apply-profile.lua`, `state-profile.lua`, `autoswitch-bluetooth-profile.lua`, `automute-alsa-routes.lua`. **Linking** is separate from routing and lives in `scripts/linking/`: `find-best-target.lua`, `find-default-target.lua`, `find-defined-target.lua`, `find-media-role-target.lua`.

To extend rather than replace, declare your own script with a `provides`/hook and slot it into the existing event order — don't duplicate a stock hook name.

### Writing a custom Lua script (0.5+ component model)

Scripts are **not** auto-loaded: each must be declared as a component and required by a profile.

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

API notes:

- Scripts use the **event dispatcher API** (post-0.4.81 refactor): hooks react to named events in a defined order, not one monolithic policy file.
- Config from Lua: `Conf.get_section_as_json()` for sections, `Settings.get()` for one setting — both return `Json` (bound `WpSpaJson`). Build with `Json.Object{...}`, `Json.Array{...}`, `Json.String()`, `Json.Int()`.
- `JsonUtils` implements the `matches`/`actions` rules engine behind `*.rules` — reuse it instead of hand-rolling match logic.
- `Core.require_api("mixer", function(mixer) ... end)` loads an API plugin (name without the `-api` suffix) before calling it, e.g. volume/route control via the mixer API.

## Pitfalls

- Most web results are still 0.4-era; 0.4 syntax (Lua config, `alsa_monitor.rules`) is a different world.
- **Config not applying?** Check `--save`d `wpctl settings` state before blaming the `.conf` fragment.
- **Fragment not loading?** It must be under `wireplumber.conf.d/`, have a `.conf` extension, and not be shadowed by a same-named file in a higher-priority directory.
- **Wrong route/profile picked automatically?** Check `monitor.alsa.rules` / `monitor.bluez.rules` matches first, then the `find-best-profile.lua` / `find-best-routes.lua` priority logic, before writing a new hook.
## Verification

- [ ] `wireplumber --version` reports 0.5+ before any syntax from this skill is used.
- [ ] WirePlumber restarted — settings and fragments only take effect after restart — and its startup log shows no config errors.
- [ ] Anything version-specific was re-checked against the pages below rather than memory.

## Sources

Fetch the matching page for anything not covered here — WirePlumber's config system changed substantially between 0.4 and 0.5. Base: `https://pipewire.pages.freedesktop.org/wireplumber/`

- `daemon/configuration/conf_file.html` — config file & SPA-JSON
- `daemon/configuration/modifying_configuration.html` — settings + `wpctl`
- `daemon/configuration/configuration_option_types.html` — option types
- `daemon/configuration/migration.html` — 0.4 → 0.5 migration
- `scripting/existing_scripts/device.html` — device profile/route hooks
- `scripting/existing_scripts.html` — scripts index (linking, default nodes)
- `scripting/custom_scripts.html` — custom scripts / component declaration
- `scripting/lua_api/lua_json_api.html` — `Json`, `JsonUtils`
- `scripting/lua_api/lua_core_api.html` — `Core.require_api`, `Core.sync`
- `resources/releases.html` — release notes for version cross-checks
