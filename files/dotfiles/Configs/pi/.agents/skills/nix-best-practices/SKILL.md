---
name: nix-best-practices
description: Use when working with Nix flakes, overlays, shell.nix, or flake.nix files.
---

# Nix Best Practices

Conventions for flake layout, `follows`, overlays, unfree packages, binary-overlay repos, and dev shells.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Patterns](#patterns) · [Commands](#commands) · [Pitfalls](#pitfalls) · [Verification](#verification) · [Sources](#sources)

## When to Use

Writing or reviewing `flake.nix`, `devShells`/`shell.nix`, overlay repos, or `.envrc`. For evaluation speed and memory use, pair with the `nix-flake-performance` skill — this skill covers structure and conventions only.

## Core Rules

1. **One nixpkgs.** Every input that carries its own nixpkgs gets `follows`, so a single version is fetched:

   ```nix
   inputs = {
     nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
     some-overlay.url = "github:owner/some-overlay";
     some-overlay.inputs.nixpkgs.follows = "nixpkgs";
     # chains can follow an intermediate input instead
     another-overlay.url = "github:owner/another-overlay";
     another-overlay.inputs.nixpkgs.follows = "some-overlay";
   };
   ```
2. **List every input in the outputs function**, even unused ones, or you get *"unexpected argument"*: `outputs = { self, nixpkgs, some-overlay, ... }:`.
3. **Apply overlays in one `import nixpkgs`**, not per overlay:

   ```nix
   pkgs = import nixpkgs {
     inherit system;
     overlays = [
       overlay1.overlays.default
       (final: prev: { myPackage = prev.myPackage.override { ... }; })
     ];
   };
   ```

## Patterns

### Minimal flake

```nix
{
  description = "Project description";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let pkgs = import nixpkgs { inherit system; };
      in {
        devShells.default = pkgs.mkShell { buildInputs = with pkgs; [ /* packages */ ]; };
      });
}
```

### Unfree packages

| Option | Use when |
|---|---|
| `nixpkgs-unfree` input | Teams, EULA-licensed packages, no per-user config. Chain: `proprietary-tool` → `nixpkgs-unfree` → `nixpkgs`, with `follows` on each hop. |
| User config `~/.config/nixpkgs/config.nix` → `{ allowUnfree = true; }` | Single local machine. |
| `config.allowUnfreePredicate = pkg: builtins.elem (lib.getName pkg) [ "specific-package" ];` | Permit one package only. |

`config.allowUnfree` inside `flake.nix` does **not** propagate to `nix develop` — use `nixpkgs-unfree`, user config, or `NIXPKGS_ALLOW_UNFREE=1 nix develop --impure`.

### Binary overlay repo

When nixpkgs builds a community version that lacks features (common with open-core tools), ship the official binaries. Pattern used by `0xBigBoss/atlas-overlay` and `0xBigBoss/bun-overlay`:

```nix
outputs = { self, nixpkgs, flake-utils }:
  flake-utils.lib.eachDefaultSystem (system:
    let
      version = "1.0.0";
      # one entry per supported system: url + sha256 of the upstream binary
      sources = {
        "x86_64-linux" = { url = "https://example.com/tool-linux-amd64-v${version}"; sha256 = "sha256-AAA...="; };
        "aarch64-linux" = { url = "https://example.com/tool-linux-arm64-v${version}"; sha256 = "sha256-BBB...="; };
      };
      source = sources.${system} or (throw "Unsupported system: ${system}");

      toolPackage = pkgs.stdenv.mkDerivation {
        pname = "tool";
        inherit version;
        src = pkgs.fetchurl { inherit (source) url sha256; };
        sourceRoot = ".";
        dontUnpack = true;
        installPhase = ''
          mkdir -p $out/bin
          cp $src $out/bin/tool
          chmod +x $out/bin/tool
        '';
        meta = with pkgs.lib; {
          description = "Tool description";
          homepage = "https://example.com";
          license = licenses.unfree;
          platforms = builtins.attrNames sources;
        };
      };
    in {
      packages.default = toolPackage;
      packages.tool = toolPackage;
      overlays.default = final: prev: { tool = toolPackage; };
    })
  // {
    # top-level overlay: per-system outputs live under packages
    overlays.default = final: prev: { tool = self.packages.${prev.system}.tool; };
  };
```

Hashes: `nix-prefetch-url <url>` (base32) then `nix hash to-sri --type sha256 <base32>`, or directly `nix-prefetch-url --type sha256 <url>`.

### Dev shells

```nix
devShells.default = pkgs.mkShell {
  buildInputs = with pkgs; [ nodejs python3 ];

  # static env at shell entry; shellHook for values computed at entry
  DATABASE_URL = "postgres://localhost/dev";
  shellHook = ''
    export PROJECT_ROOT="$(pwd)"
  '';
};
```

Native C dependencies — expose headers and libs:

```nix
shellHook = ''
  export C_INCLUDE_PATH="${pkgs.openssl.dev}/include:$C_INCLUDE_PATH"
  export LIBRARY_PATH="${pkgs.openssl.out}/lib:$LIBRARY_PATH"
  export PKG_CONFIG_PATH="${pkgs.openssl.dev}/lib/pkgconfig:$PKG_CONFIG_PATH"
'';
```

### direnv

```bash
use flake                                  # flake project
export NIXPKGS_ALLOW_UNFREE=1; use flake --impure   # unfree without nixpkgs-unfree
```

## Commands

| Command | Does |
|---|---|
| `nix flake update` / `nix flake update <input>` | Update all / one input |
| `nix flake check` / `nix flake metadata` | Validate flake / show inputs and nodes |
| `nix develop` / `nix develop -c <cmd>` | Enter dev shell / run one command in it |
| `nix build .#pkg` / `nix run .#pkg` | Build / run a package |

## Pitfalls

- **Overlay not applied** — it isn't in the `overlays` list of the `import nixpkgs` you actually use.
- **Unfree errors in `nix develop`** — see [Unfree packages](#unfree-packages).
- **Hash mismatch** — re-run `nix-prefetch-url` and update the hash; upstream republishing the same URL changes it.
- **Top-level overlay referencing a per-system derivation** — use `self.packages.${prev.system}.tool`, otherwise the overlay is bound to one system.

## Verification

- [ ] `flake.lock` has a single nixpkgs node and every input uses `follows`.
- [ ] `nix flake check` passes on the systems you support.
- [ ] `nix develop` enters with the expected packages and env vars.
- [ ] Overlay repo: `nix build .#tool` works on every listed system and `pkgs.tool` resolves when the overlay is applied.

## Sources

- `0xBigBoss/atlas-overlay`, `0xBigBoss/bun-overlay` (binary overlay pattern); numtide/nixpkgs-unfree.
