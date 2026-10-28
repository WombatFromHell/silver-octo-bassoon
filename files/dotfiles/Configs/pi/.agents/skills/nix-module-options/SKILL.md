---
name: nix-module-options
description: Query NixOS and Home Manager module options programmatically using flake evaluation. Use this skill when the user asks to check if a module exists, explore available options, get option documentation, or verify what options are available in upstream NixOS/Home Manager (not custom user modules). Activates for queries like "does home manager have a module for X", "what options does service Y have", "check nixos options for Z", or "explore available options".
allowed-tools: Bash, Read
---

# Nix Module Options Explorer

Query upstream NixOS/Home Manager module options by evaluating the flake — offline, upstream-pure, and fast because it reuses flake-parts' already-evaluated `pkgs`.

**Contents:** [When to Use](#when-to-use) · [Procedure](#procedure) · [Reference](#reference) · [Pitfalls](#pitfalls) · [Verification](#verification)

## When to Use

"Does Home Manager have a module for X?", "what options does service Y have?", "check NixOS options for Z", "what programs are available?".

Upstream modules **only**: the expressions import HM/NixOS module lists directly, so your custom modules and your own `homeConfigurations`/`nixosConfigurations` are never evaluated. Use [Your own configuration](#your-own-configuration) for that.

## Procedure

Run from inside the flake repo. Shape: `nix eval --impure --expr '<expression>' --json | jq '<filter>'`.

**`opts` for Home Manager** — `args.pkgs` is already instantiated by flake-parts and `args.system` is the current system, so nothing is re-evaluated:

```nix
let
  flake = builtins.getFlake (builtins.toString ./.);
  args  = flake.currentSystem.allModuleArgs;
  hmLib = args.pkgs.lib.extend (self: super: {
    hm = import "${flake.inputs.home-manager}/modules/lib" { lib = self; };
  });
in
  (hmLib.evalModules {
    modules = import "${flake.inputs.home-manager}/modules/modules.nix" {
      lib = hmLib; pkgs = args.pkgs; check = false;
    };
  }).options
```

**`opts` for NixOS** — same wrapper, no `hmLib`:

```nix
in
  (args.pkgs.lib.evalModules {
    modules = import "${flake.inputs.nixpkgs}/nixos/modules/module-list.nix" ++ [
      { nixpkgs.hostPlatform = args.system; }
    ];
  }).options
```

Then swap the tail of `in` and the `jq` filter:

| Question | `in` expression | `jq` filter |
|---|---|---|
| Does the option exist? | `opts.OPTION.PATH or null` | `if . == null then "NOT FOUND" else "EXISTS" end` |
| One option's documentation | `args.pkgs.lib.optionAttrSetToDocList opts.OPTION.PATH` | `map(select(.visible == true)) \| map({name, type, description})` |
| List a category | `builtins.attrNames opts.CATEGORY` | `-r '.[]'` |

Check existence before asking for docs.

### Your own configuration

Custom modules and real values come from the configuration itself, not the upstream option list:

```bash
nix eval --impure --expr '
  (builtins.getFlake (builtins.toString ./.))
  .homeConfigurations.USERNAME.options.OPTION.PATH
' --json
```

## Reference

### Option Categories

Home Manager top-level: `programs.*`, `services.*`, `home.*`, `xdg.*`, `accounts.*`, `systemd.*`, `gtk.*`, `qt.*`, `wayland.*`
NixOS top-level: `services.*`, `programs.*`, `hardware.*`, `boot.*`, `networking.*`, `environment.*`, `systemd.*`, `users.*`, `virtualisation.*`, `security.*`

### Documentation Fields

`lib.optionAttrSetToDocList` returns per option:

- **name** — full path (`programs.git.enable`)
- **description** — what it does (markdown)
- **type** — expected value type (`boolean`, `string`, `list of string`)
- **default** / **example**
- **declarations** — source file where it's defined
- **visible** / **readOnly** / **internal**

## Pitfalls

- *"path does not exist"* — you're not running from inside the flake repo.
- *"attribute does not exist"* — wrong category (`programs` vs `services`), wrong nesting (`programs.git.enable`, not `programs.git`), or the option is a custom module rather than upstream.
- Wrong module system — HM needs `hmLib.evalModules` with HM modules; NixOS needs `pkgs.lib.evalModules` with `module-list.nix`.
- Unfiltered output buries internal options: filter `select(.visible == true)`, and read `declarations` to find the upstream source.
- Repeated queries are worth caching as flake outputs if evaluation gets slow.

## Verification

- [ ] Command ran inside the flake repo and `--json` output parses.
- [ ] Existence checked before requesting docs.
- [ ] Results come from upstream `declarations`, not your custom modules (unless you queried your own configuration).
- [ ] Home Manager vs NixOS expression matches the system you were asked about.
