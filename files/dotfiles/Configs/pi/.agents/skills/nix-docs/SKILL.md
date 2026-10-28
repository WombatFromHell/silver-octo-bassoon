---
name: nix-docs
description: Use when you need to lookup documentation for NixOS configuration, Nix packaging, Nix functions or anything else related to Nix.
---

# Nix Documentation

Where to look up NixOS config, packaging, and Nix language reference — two local manuals, three upstream doc trees, and two wikis.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Reference](#reference)

## When to Use

You need NixOS configuration options, packaging docs, or Nix language/builtin reference. Prefer these sources over web search; to query module options programmatically, use the `nix-module-options` skill.

## Core Rules

- Prefer module **options** over installing packages directly.
- Keep related configuration in separate files.
- Browse a doc tree's directory listing first, then read only the file you need.
- Two NixOS wikis exist — prefer the official one.

## Reference

**Local manuals**
- `man configuration.nix` — system-level NixOS options
- `man home-configuration.nix` — Home Manager options

**Nixpkgs** — https://github.com/NixOS/nixpkgs/tree/master/doc
- `languages-frameworks/` — 50+ languages (python, rust, go, haskell, javascript, java, …)
- `build-helpers/` — fetchers, testers, trivial-builders, dev-shell-tools, images
- `hooks/` — 40+ build hooks (cmake, meson, python, perl, autopatchelf, …)
- `stdenv/` — standard environment, cross-compilation, `meta`, multiple-output, `passthru`
- `functions/` — Nix library function reference
- `module-system/` — the module system
- `packages/` — package management
- `contributing/` — contribution guidelines
- `toolchains/` — LLVM and cross-compilation

**Nix** — https://github.com/NixOS/nix/tree/master/doc/manual/source
- `language/` — syntax, types, operators, derivations, builtins, string interpolation
- `command-ref/` — nix-build, nix-shell, nix-env, nix-store, experimental commands
- `package-management/` — package handling
- `advanced-topics/` — distributed builds, diff-hook, post-build-hook, eval-profiler
- `architecture/` · `protocols/` · `store/`

**NixOS** — https://github.com/NixOS/nixpkgs/tree/master/nixos/doc/manual
- `configuration/` — config-syntax, package-mgmt, file-systems, networking, user-mgmt, firewall, gpu-accel, linux-kernel, wayland, x-windows, ssh, wireless
- `administration/` · `installation/` · `development/`

**Wiki**
- https://wiki.nixos.org/ — official (preferred)
- https://nixos.wiki/ — community
