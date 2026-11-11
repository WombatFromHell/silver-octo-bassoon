---
name: nix-flake-testing
description: Write fast, lightweight, high-quality tests for Nix flakes using shared fixtures. Use this skill whenever the user is adding, restructuring, reviewing, or debugging tests for Nix code. That includes the flake `checks` output, `nix flake check`, nix-unit, lib.runTests, namaka snapshots, nixtest, runCommand checks, NixOS VM tests (`testers.runNixOSTest`), container tests, test fixtures, or CI jobs for a flake. Also use it when tests are slow, memory-hungry, or evaluate nixpkgs repeatedly, even if the user never says "performance" or "fixture", or when a configuration warning must fail a build instead of merely printing. Pair with the nix-flake-performance skill when both evaluation cost and tests are in play.
---

# Lightweight, Fixture-Driven Tests for Nix Flakes

Pick the **cheapest layer that can catch the bug**, and share setup through **lazy fixtures** instead of rebuilding it per test.

**Contents:** [When to Use](#when-to-use) · [Core Rules](#core-rules) · [Patterns](#patterns) · [Procedure](#procedure) · [Pitfalls](#pitfalls) · [Verification](#verification) · [Sources](#sources)

## When to Use

Adding, restructuring, or reviewing flake tests (`checks`, `nix flake check`, nix-unit, `lib.runTests`, namaka, nixtest, `runCommand`, `testers.runNixOSTest`, container tests, fixtures, CI jobs), or when tests are slow or memory-hungry. Cost is dominated by **how much a test forces** (deep forcing of a module config or a derivation) and by nixpkgs instantiation once instances are forced deeply; VM cost is what makes integration suites slow.

## Core Rules

1. **Test at the cheapest layer that catches the bug.** A regression in a Nix function or module gets an eval test, not a VM test.
2. **One `pkgs` per system.** Never `import nixpkgs` inside tests or fixtures — create `pkgs` once in the flake and pass it in (cost rules live in `nix-flake-performance`).
3. **Fixtures are lazy, so define them and don't force them.** Build one fixture set, `inherit` only what a test uses.
4. **Fixtures are pure and deterministic:** no `builtins.currentTime`, no `<nixpkgs>`, no network, no IFD — pre-generate data and commit it.
5. **One behaviour per test.** Keep VM scripts short; combine a scenario's assertions into one boot.
6. **Assert absence one layer above the package list, and prove the signal exists.** Mapping `pname` over `environment.systemPackages` to ask "is X absent?" forces the whole list; read the namespace, systemd unit or program option the feature writes instead. Namespace keys are what a feature *declares*, not its directory name — so also assert the positive side on the host that has the feature, or a mistyped name makes every absence check pass vacuously.
7. **Report the peak per eval, read while the scope is alive.** systemd drops the unit when the scope exits, so `MemoryPeak` read afterwards is gone; poll `MemoryCurrent`/`MemoryPeak` (20-40ms) while the command runs. A killed eval still reports the peak it reached.

| Layer | Use for | Cost |
|---|---|---|
| **Eval tests** (nix-unit, `lib.runTests`, nixtest, namaka) | Pure functions, library code, module option logic, config assertions | Evaluation only, no builds |
| **`runCommand` / build checks** | Package builds, generated files, CLI behaviour, linting, formatting | One small build |
| **NixOS container tests** (`containers` in `runNixOSTest`) | Service integration without a full VM, where supported | Medium |
| **NixOS VM tests** (`testers.runNixOSTest`) | Real multi-machine, boot, kernel, systemd integration | Slow, memory-heavy |

## Patterns

### Shared fixtures

```nix
# tests/fixtures/default.nix — takes pkgs, lib, self; returns values, not tests
{ pkgs, lib, self }:
{
  sampleConfig = builtins.fromJSON (builtins.readFile ./data/sample.json);
  minimalHost = { system.stateVersion = "25.05"; services.myservice.enable = true; };
  # cached derivation: built once, reused by any check that references it
  sampleInput = pkgs.writeText "sample-input.txt" (builtins.readFile ./data/input.txt);
}
```

Static JSON/TOML/text samples live in `tests/fixtures/data/` and stay small; read only the file a test needs. If a test needs a subset of the repo, scope it with `lib.fileset` (or `lib.cleanSource`) so unrelated edits don't change the input hash and force reruns. Build-time fixtures are derivations (`pkgs.writeText`, `runCommand`) and are cached in the store.

### Eval tests (the default choice)

nix-unit runs at evaluation time; tests are attrsets with `expr` and `expected`, names starting with `test`:

```nix
# tests/unit/lib.nix, flake-parts style
{ self, ... }:
{
  flake.tests = {
    test_add = { expr = builtins.add 40 2; expected = 42; };
    test_parse_sample = {
      expr = (import ../fixtures { inherit (self) pkgs lib; }).sampleConfig.name;
      expected = "demo";
    };
  };
}
```

- Add the `nix-unit` input plus its flake-parts module (`inputs.nix-unit.modules.flake.default`) and import your test files; set `inputs.nixpkgs.follows = "nixpkgs"` on test-tool inputs.
- **Expose eval tests through `checks`** so CI runs them (clan-core pattern: a `test.nix` per area, exposed via a `flake-module.nix`, with a `runCommand` that calls nix-unit).
- **Iterate fast**: run nix-unit directly (`nix-unit --flake .#<tests-attr>`) instead of building every check.
- Test **expected errors** too (`expectedError` in nix-unit — verify the exact name in your version).
- Alternatives: `lib.runTests` (fine when you already depend on nixpkgs; returns failures), **nixtest** (pure Nix, discovers `_test.nix`, runs via `nix eval .#tests`), **namaka** (snapshots built on haumea — the snapshots *are* the fixtures; prefer `nix eval .#checks` over `nix flake check` for review loops). Don't add a heavyweight framework when nix-unit or `runTests` suffices.

**Keeping eval tests low-memory** (single-box measurements, Determinate Nix 2.34.8, multi-host NixOS flake):

- Assert option values and attribute names; don't force derivations (a toplevel's `outPath`/`type` ~700MB; one ordinary package attribute ~250–500MB).
- Never assert `config.warnings == []` — forcing warnings evaluates the host's whole module config (~2.0GB / ~12s per host). "No warnings" is a build-time signal; if it must *fail* a build, gate it through `config.assertions` (see Patterns).
- Mapping `config.environment.systemPackages` costs ~500MB; assert a few names instead.
- One host per test process: forcing several hosts in one eval sums their peaks; separate processes keep the ceiling flat and pay only startup (~0.1–0.6s).
- On a memory-constrained machine run the gate sequentially and cap each eval in a transient systemd scope (`MemoryMax`, `MemorySwapMax` ≈ half of it; never `MemorySwapMax=0` — stalls instead of OOM-killing). Full-config fan-out belongs in `nix-eval-jobs` (`--workers`, `--max-memory-size`).
- `builtins.length [...]` does **not** force elements, so a "check everything" probe built on it measures nothing. Force with strict `lib.foldl'` or map over the list.

### Failing a build on a configuration warning

Warnings are printed, never fatal: `lib.asserts.checkAssertWarn` throws only on **failed
assertions**, and the build path already forces `config.assertions` *and* `config.warnings`. So
convert warnings into an assertion — the cost lands where the build pays it anyway, and an eval
test never touches it:

```nix
# one module, imported by every config namespace you build
{ config, lib, ... }:
{
  assertions = [
    {
      assertion = config.warnings == [];
      message = "configuration warnings:\n${lib.concatStringsSep "\n" config.warnings}";
    }
  ];
}
```

- NixOS: `nixos/modules/system/activation/top-level.nix` wraps the system with
  `checkAssertWarn config.assertions config.warnings baseSystem`, so forcing
  `config.system.build.toplevel` fails on any warning — `nix build`, `nix flake check` and
  `nixos-rebuild` all fail, before a builder runs. Home Manager throws the same way
  (`modules/default.nix`: `collectFailed` throws, `showWarnings` traces) and imports nixpkgs'
  `nixos/modules/misc/assertions.nix`, so `assertions` is declared in the HM namespace too.
- The happy path is free: `checkAssertWarn` forces an assertion's `message` only when it failed.
- Proven on Determinate Nix 2.34.8 with a minimal bootable config plus one deliberate warning: no
  gate → forcing `toplevel.drvPath` succeeds and prints the warning (825MB); with the gate →
  `Failed assertions: - configuration warnings: …`. Forcing only
  `config.networking.hostName` with the gate installed neither throws nor pays for warnings
  (110MB). Home Manager behaved identically via `activationPackage.drvPath`.
- A minimal probe config needs `system.stateVersion`, `fileSystems."/".device` and
  `boot.loader.grub.devices`; otherwise nixpkgs' own assertions fail first and mask the result.
- Gate the module's own logic cheaply in a bare `lib.evalModules` test with a stub `warnings`
  option (no NixOS, no build): no warnings → assertion true, one warning → assertion false and the
  `message` names it.

### Build checks

```nix
checks.${system} = {
  fmt = pkgs.runCommand "fmt-check" { nativeBuildInputs = [ pkgs.nixfmt-rfc-style ]; } ''
    nixfmt --check ${self} && touch $out
  '';
  cli-smoke = pkgs.runCommand "cli-smoke" { nativeBuildInputs = [ self.packages.${system}.default ]; } ''
    mytool --version | grep -q "${self.packages.${system}.default.version}"
    touch $out
  '';
};
```

Always end with `touch $out` (or write a result file). Keep `nativeBuildInputs` minimal so the check doesn't pull large closures. Use `pkgs.testers.testBuildFailure` to assert something *fails*. Passing results are cached in the store, so unchanged inputs rerun nothing.

### NixOS VM tests (sparingly)

```nix
checks.${system}.service-smoke = pkgs.testers.runNixOSTest {
  name = "service-smoke";
  node.pkgs = pkgs;                                    # reuse the shared instance
  defaults = { imports = [ self.nixosModules.default ]; };  # shared by all nodes
  nodes.machine = { ... }: {
    services.myservice.enable = true;
    virtualisation.memorySize = 1024;   # MiB — smallest that passes
    virtualisation.cores = 1;
  };
  testScript = ''
    machine.wait_for_unit("myservice.service")
    machine.succeed("curl -sf localhost:8080/health")
  '';
};
```

- `node.pkgs = pkgs` (nixpkgs does this itself for faster eval) makes `nixpkgs.*` options read-only inside nodes; if a test truly needs them, set `node.pkgsReadOnly = false` and accept the slower eval for that test only.
- Share config via `defaults` or `extraBaseModules`, not per-node copy-paste.
- Right-size VMs; some services need a floor (one project found ~800 MiB minimum to avoid OOM), so raise only when a test needs it.
- Prefer `containers` (systemd-nspawn) for service-level checks; they have extra requirements (e.g. Nix daemon config) — check the NixOS manual for your version.
- VM tests need virtualization support; CI without hardware acceleration is much slower. Gate to `x86_64-linux`/`aarch64-linux` and make them opt-in if needed.
- Debug without rebuilding: run the test driver interactively, `--keep-machine-state` to reuse VM state. To force a rerun, drop the `result` symlink and delete the cached path.

## Procedure

Layout and wiring:

```
flake.nix
tests/
├── default.nix            # collects checks, imported from flake.nix
├── fixtures/
│   ├── default.nix        # lazy fixture set (pkgs, lib, self)
│   └── data/              # small static samples
├── unit/                  # nix-unit / runTests (eval-only)
├── build/                 # runCommand checks
└── integration/           # runNixOSTest (VM/container)
```

1. Expose tests only for systems you support.
2. Keep default `checks` fast (eval + build); put slow VM tests in a separate attrset (`legacyPackages.<system>.integrationTests` or `hydraJobs`) so local `nix flake check` stays quick.
3. `nix flake check` checks the current system by default — add `--all-systems` when you need others (verify behaviour on your Nix version).
4. Don't put fixtures in `packages` (they'd be built/evaluated as products); use `lib`, `legacyPackages`, or an internal attr.
5. Big suites in CI: evaluate in parallel with `nix-eval-jobs`, capped by `--workers` and `--max-memory-size`.

## Pitfalls

- Flags and option names change across versions (`expectedError`, `--all-systems`, `containers` requirements, `extraBaseModules`, nix-unit CLI flags). Check installed Nix/nixpkgs/nix-unit and run a minimal example rather than trusting memory.
- Quoted peak/wall figures are single-box measurements (Determinate Nix 2.34.8, one multi-host flake) and scale with how much the test forces — re-measure before sizing a memory cap. A probe that *throws* reports a low peak because it aborted early; only trust a peak from a run that printed its value.
- A warnings assertion lives on `config.assertions`, so forcing `config.assertions` in an eval test forces `config.warnings` and brings the ~2.0GB penalty back. Keep it out of the eval tier.
- That assertion also fails the build on upstream deprecation warnings after a nixpkgs bump — filter by prefix in the module rather than deleting the assertion.
## Verification

- [ ] Each behaviour is tested at the cheapest possible layer; eval tests cover success **and** expected-error cases.
- [ ] Eval tests assert option values / attribute names — no forced derivations, no `config.warnings`, and no forced `config.assertions`.
- [ ] If a warning must fail a build, it is gated as an assertion in the build tier, and that module's logic has a bare-module test.
- [ ] Multi-host eval tests: one host per process, sequential, capped on memory-constrained machines.
- [ ] No `import nixpkgs` in tests or fixtures; one shared `pkgs` per system.
- [ ] Fixtures: one lazy set, deterministic, small; source inputs scoped with `lib.fileset`.
- [ ] VM tests: `node.pkgs` set, config shared in `defaults`, memory/cores minimized, few scenarios per boot.
- [ ] Slow tests separated from default `checks`; CI runs them deliberately.
- [ ] Test names are descriptive and failures print useful expected/actual output.

## Sources

- clan-core testing docs (layering, nix-unit pattern) and the clan nix-unit blog post
- nix.dev: integration testing with NixOS VMs; NixOS manual / nixpkgs test framework (`node.pkgs`, `node.pkgsReadOnly`, `defaults`, `--keep-machine-state`)
- nix-unit, nixtest, nixt, and namaka project documentation
