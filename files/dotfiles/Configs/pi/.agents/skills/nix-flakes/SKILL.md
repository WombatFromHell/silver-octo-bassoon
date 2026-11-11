---
name: nix-flake-performance
description: Write and review Nix flake code that is fast to evaluate, memory-lean, and maintainable. Use this skill whenever the user is writing, refactoring, reviewing, or debugging flake.nix files, NixOS or home-manager configurations, devShells, overlays, or package definitions, and especially when they mention slow evaluation, high memory use, "nix flake check" taking long, out-of-memory errors, multiple nixpkgs instances, `follows`, overlays, `import nixpkgs`, or `legacyPackages`. Use it even if the user does not mention performance, because most evaluation-cost mistakes are made silently while writing ordinary flake code.
---

# Performant, Lightweight Nix Flakes

Evaluation cost is dominated by **what you force**, and secondarily by **how many nixpkgs instances exist**.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Patterns](#patterns) · [Procedure](#procedure) · [Pitfalls](#pitfalls) · [Verification](#verification) · [Sources](#sources)

## When to Use

Any flake you write, review, or debug. Measure both costs in this order:

1. **What gets forced.** Forcing a wide or derived structure — a whole module `config`, `config.warnings`, `config.environment.systemPackages`, a derivation attribute — is what makes an eval cost gigabytes. Measured on a multi-host NixOS-style flake (Determinate Nix 2.34.8): `config.warnings` for one host ~2.0GB / ~12s; the same host's option checks *without* it ~700MB / ~3s; mapping `config.environment.systemPackages` for names ~500MB; one derivation attribute 250–700MB; option booleans or `attrNames` of an option set ~0–300MB.
2. **How many nixpkgs instances exist.** Only bites once each instance is forced **deeply**: four separate `import nixpkgs` with one shallow attribute forced measured <256MB / ~1s. The 100-instance ~10x-memory reproduction is the deeply-forced case. Fix duplication anyway — one instance is cheaper to hold than to reason about.

## Core Rules

1. **Instantiate nixpkgs once per system.** `import nixpkgs { ... }` is not cached; identical calls evaluate separately.
2. **Prefer `nixpkgs.legacyPackages.${system}`** over `import nixpkgs { inherit system; }` when no custom config is needed — it uses the flake eval cache (small-case results vary, so measure).
3. **One nixpkgs in `flake.lock`:** `inputs.<dep>.inputs.nixpkgs.follows = "nixpkgs";` for every input carrying its own.
4. **Don't pin extra nixpkgs versions** (stable + unstable + old pins) unless truly required. Inputs are fetched eagerly, so unused pins still cost time (~26s measured for 5 unused pins). Need an old version? Use a lazy `builtins.fetchTree` with `narHash`, not a flake input.
5. **Pass `pkgs` down, never rebuild it.** Create it once in `outputs`, hand it to modules via `specialArgs`, `_module.args`, or function arguments.

## Patterns

### When you must `import nixpkgs` (config, overlays, cross)

`legacyPackages` can't take `config` (e.g. `allowUnfree`) or overlays. Instantiate **once** per system and reuse:

```nix
outputs = { self, nixpkgs, ... }: let
  systems = [ "x86_64-linux" "aarch64-linux" ];
  forAllSystems = nixpkgs.lib.genAttrs systems;
  pkgsFor = forAllSystems (system: import nixpkgs {
    inherit system;
    config.allowUnfree = true;
    overlays = [ self.overlays.default ];
  });
in {
  packages = forAllSystems (system: {
    default = pkgsFor.${system}.callPackage ./package.nix { };
  });
};
```

Alternatives: extend the shared set (`nixpkgs.legacyPackages.${system}.extend overlay`); fold several overlays onto one set with `builtins.foldl' (p: o: p.extend o) base [ o1 o2 o3 ]`. For NixOS, set `nixpkgs.pkgs = pkgs;` and import `nixpkgs.nixosModules.readOnlyPkgs` so hosts reuse the instance.

### Overlays and patches

- Overlays reaching into core packages (`stdenv`, `glibc`, `openssl`, `python3`) rebuild and re-evaluate large closures — keep them narrow.
- `applyPatches` on the whole nixpkgs source, or `overrideAttrs` on very widely used packages, is expensive (~30s saved by removing one `applyPatches`, reported).
- When a flake you consume exposes `packages`, fix its `nixpkgs.follows` rather than re-overlaying its output — re-overlaying also breaks "the flake's package works as published".
- A composable flake exports an **overlay** and takes `pkgs`/`nixpkgs` as input; it does not hard-wire its own `import nixpkgs`.

### Evaluation hygiene

- Output only supported systems.
- Stay lazy: avoid `builtins.attrNames pkgs`, mapping over all of `pkgs`, `lib.attrValues` on big sets when you need one or two attributes.
- Never force `config.warnings` in an eval (~2.0GB / ~12s per host, see [When to Use](#when-to-use)). "No warnings" is a **build-time** signal — `nix build` and `nix flake check` print them.
- Comparing packages by `drvPath`/`outPath` forces derivations; use names or attribute identity.
- Avoid import-from-derivation (IFD): it blocks eval on a build, defeats parallel evaluation, inflates memory. Pre-generate lockfiles/hashes/JSON and commit them.
- Filter sources with `lib.fileset` (or `lib.cleanSource`); don't copy a whole repo into the store on every change.
- Don't `readFile`/`readDir` large files or trees at eval time.
- Prefer `//` over `lib.recursiveUpdate` when a shallow merge is enough; prefer strict `builtins.foldl'` over lazy `foldl` for long folds; use `lib.genAttrs` directly (no flake-utils needed just for per-system iteration).
- Keep `nix flake check` meaningful — don't expose huge numbers of derivations as checks.

## Procedure

Diagnosing slow or memory-hungry evaluation:

1. **Count instances.** Inspect `flake.lock` for duplicate nixpkgs nodes; grep everything you control (and read sources of flakes you depend on) for `import nixpkgs`, `import inputs.nixpkgs`, `legacyPackages` — all count. `follows` can be incomplete across deep input trees. A config evaluating "twice" (warnings printed twice) usually means two instances.
2. **Get stats.** `NIX_SHOW_STATS=1 nix eval ...` (memory + thunk counts); `NIX_COUNT_CALLS=1` for hot functions.
3. **Profile.** Newer Nix ships an evaluation profiler (`--eval-profiler`; confirm the flag in `nix --help` or the manual for your version) — can emit flamegraph data.
4. **Reproduce under a memory cap** with a transient systemd scope, so the cgroup is the unit of measurement:

   ```bash
   systemd-run --user --scope -q --expand-environment=no \
     --unit=probe.scope -p MemoryHigh=2048M -p MemoryMax=2560M -p MemorySwapMax=1280M \
     nix eval --impure --expr '...'
   systemctl --user show probe.scope -p MemoryPeak   # poll while the unit is alive
   ```

   `--expand-environment=no` is required with `--scope` (systemd-run expands `${...}` in its own arguments); pass env vars with `-E/--setenv=`. Never `MemorySwapMax=0`: with little free RAM the kernel stalls the process instead of OOM-killing it, so you get a hang, not a failure. Poll `MemoryPeak` before the first sleep — a fast eval exits before the unit is queried and reports nothing. `ulimit -v $((5*1024*1024))` is the fallback.
   `NIX_SHOW_STATS` and `/usr/bin/time -v` under-report `nix eval` peaks (the CLI process isn't where evaluated values live); the scope's `MemoryPeak` is authoritative. GC knobs are usually not the lever: defaults are `min-free = 0` / `max-free = infinity`, and enabling a pass (`--option min-free 64M --option max-free 512M`) changed peak by <5% on the measured box — the memory is live values, not retained garbage.
5. **Bisect nixpkgs.** `nix flake lock --override-input nixpkgs github:NixOS/nixpkgs/<rev>` when a nixpkgs bump suddenly blows up evaluation.
6. **Update Nix.** Recent releases include memory work (attrset-merge optimization ~20% less allocation on typical nixpkgs evals, AST allocation changes). Upgrades are free wins.

### CI and large evaluations

Use `nix-eval-jobs`: parallel evaluation, restarts workers that exceed a memory limit. Tune `--workers` (lower on memory-limited machines) and `--max-memory-size` (default 4 GiB/worker) — each worker may re-evaluate shared dependencies, so more workers isn't always faster. Wrappers like `nix-fast-build` combine eval-jobs with building.

## Pitfalls

- Exact numbers here (profiler flag names, `lib.fileset` availability, `legacyPackages` vs `import` deltas, the forcing/peak figures) vary by Nix and nixpkgs version and by how much the eval forces. Verify against the user's installed versions and prefer measurement over assumption.

## Verification

Review checklist for a flake you wrote or changed:

- [ ] One nixpkgs node in `flake.lock` (every input uses `follows`); no stray `import nixpkgs` / `import inputs.nixpkgs` anywhere you control.
- [ ] `pkgs` created once per system and passed down (`readOnlyPkgs` for NixOS).
- [ ] Overlays narrow; no `applyPatches` on nixpkgs unless unavoidable.
- [ ] No IFD; `src` filtered; no large eval-time file reads.
- [ ] Outputs limited to supported systems; no needless forcing of whole attrsets or `config.warnings`.
- [ ] `NIX_SHOW_STATS=1` measured if the change claims to help performance.

## Sources

- NixOS Discourse: "MRE for 1000 instances of nixpkgs problem"; "Evaluating twice?"; "How can I speed up nixos-rebuild switch?"; "Selective use of different sets of nixpkgs packages"; "Nix consumes all available memory evaluating a flake using recent nixpkgs"
- nix-community/nix-eval-jobs README; Nix release notes (performance improvements); fzakaria.com on nixpkgs-multiverse (lazy fetching of historical nixpkgs)
