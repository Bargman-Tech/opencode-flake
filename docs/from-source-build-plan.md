# Plan: From-Source Build of OpenCode for Sandy Bridge Compatibility

**Date:** 2026-07-21
**Status:** Proposed
**Author:** mimo-v2.5-pro (LLM-CORE investigation)

## Problem Statement

The prebuilt "baseline" x86_64 binary from anomalyco/opencode contains **11,845 AVX2-specific instructions** despite the "baseline" label. This causes an illegal instruction crash (signal 4/ILL) on Intel Sandy Bridge CPUs (i5-2520M, 2nd gen Core) which support AVX but not AVX2/BMI2/FMA.

```
kernel: traps: .opencode-wrapp[551075] trap invalid opcode ip:4a5ae00
       in .opencode-wrapped[4743e00,2b20000+3870000]
```

Both `Bargman-tech/opencode-flake` and `numtide/llm-agents.nix#opencode` download the same upstream prebuilt binary. **No upstream variant is truly baseline x86_64.**

### Verified Release Assets (v1.18.4)

| Asset | AVX2 Instructions | Sandy Bridge |
|-------|-------------------|--------------|
| `opencode-linux-x64.tar.gz` | Heavy | Crash |
| `opencode-linux-x64-baseline.tar.gz` | **11,845** | **Crash** |
| `opencode-linux-x64-musl.tar.gz` | Heavy | Crash |
| `opencode-linux-x64-baseline-musl.tar.gz` | Likely similar | Likely crash |

## Goal

Build opencode from source using `bun2nix` with CPU target flags that produce a binary compatible with Sandy Bridge (and older) x86_64 CPUs. Maintain the existing prebuilt binary package as the default, with the source-built package available as an opt-in for legacy hardware.

## Architecture Overview

### Upstream Build System

OpenCode is a **Bun-based monorepo** (Bun 1.3.14):

```
anomalyco/opencode/
├── package.json          # Root workspace, turbo orchestrator
├── packages/
│   ├── opencode/         # CLI package (our target)
│   │   ├── package.json  # v1.18.4, bin: ./bin/opencode
│   │   ├── src/          # TypeScript source
│   │   └── script/
│   │       └── build.ts  # Build script
│   ├── core/             # Shared core library
│   ├── tui/              # Terminal UI (SolidJS + @opentui)
│   ├── desktop/          # Electron desktop app
│   ├── sdk/              # JavaScript SDK
│   └── ...               # Other workspace packages
├── bun.lock              # Bun lockfile (bun2nix input)
└── turbo.json            # Turborepo config
```

### Native Dependencies

These require special handling in Nix:

| Dependency | Type | Notes |
|-----------|------|-------|
| `@parcel/watcher` | Native .node addon | dlopen'd at runtime, needs libstdc++.so.6 |
| `@lydell/node-pty` | Native addon | PTY allocation, builds from source |
| `tree-sitter-bash` | WASM + native | Grammar loading |
| `tree-sitter-powershell` | WASM + native | Grammar loading |
| `web-tree-sitter` | WASM | Runtime tree-sitter |
| `@silvia-odwyer/photon-node` | Native addon | Image processing (patched) |

### CPU Target Strategy

Bun uses Zig as its build system. The CPU target is controlled by:

1. **Bun's `--target` flag**: Controls the Bun runtime's own code generation
2. **`GOAMD64` environment variable**: If any Go code is involved (not applicable here)
3. **Zig's `-target` flag**: Controls native addon compilation
4. **`CFLAGS`/`CXXFLAGS`**: Controls C/C++ addon compilation

For Sandy Bridge compatibility, we need:
- **SSE4.2** (supported on Sandy Bridge)
- **POPCNT** (supported on Sandy Bridge)
- **AVX** (first gen, supported on Sandy Bridge)
- **NO AVX2, BMI1/BMI2, FMA, F16C, MOVBE** (NOT supported on Sandy Bridge)

The Zig target for this would be: `x86_64-linux-gnu.2.38...sse42_popcnt_avx` or equivalent.

## Phased Plan

### Phase 1: Research and Validation

**Objective:** Confirm bun2nix can build opencode from source and identify CPU flag control points.

**Steps:**

1. Clone anomalyco/opencode source locally
2. Run `bun install` to generate the lockfile
3. Run `bun2nix` to generate the Nix expression from `bun.lock`
4. Identify the build script (`packages/opencode/script/build.ts`) and understand what it produces
5. Test a local `bun run build` to see the output structure
6. Identify where CPU target flags are set in the Bun/Zig toolchain

**Deliverables:**
- Generated `bun2nix.nix` expression
- Documentation of the build pipeline
- Identification of CPU flag injection points

**Verification:**
- `bun2nix` generates without errors
- Local build produces a working binary on modern hardware

### Phase 2: Create Source-Built Derivation

**Objective:** Create a `package-source.nix` that builds opencode from source.

**Steps:**

1. Add `bun2nix` as an input to the opencode-flake:
   ```nix
   inputs.bun2nix.url = "github:nix-community/bun2nix";
   inputs.bun2nix.inputs.nixpkgs.follows = "nixpkgs";
   ```

2. Fetch the opencode source as a derivation:
   ```nix
   src = fetchFromGitHub {
     owner = "anomalyco";
     repo = "opencode";
     rev = "v${version}";
     hash = "...";
   };
   ```

3. Create `package-source.nix` using bun2nix:
   ```nix
   { stdenv, lib, bun2nix, fetchFromGitHub, ... }:
   let
     bun2nixLib = bun2nix.lib.${system};
     deps = bun2nixLib.buildBunDeps {
       src = opencodeSrc;
       lockfile = "${opencodeSrc}/bun.lock";
     };
   in stdenv.mkDerivation {
     pname = "opencode-source";
     version = "...";
     src = opencodeSrc;
     buildInputs = [ deps ];
     buildPhase = ''
       bun run --cwd packages/opencode build
     '';
     # ...
   };
   ```

4. Handle native addon compilation with proper CPU flags

**Deliverables:**
- `package-source.nix` — source-built derivation
- `bun2nix.nix` — generated dependency expression
- Updated `flake.nix` with bun2nix input

**Verification:**
- `nix build .#opencode-source` succeeds
- Output binary runs `opencode --version`

### Phase 3: CPU Target Control

**Objective:** Ensure the built binary contains only Sandy Bridge-compatible instructions.

**Steps:**

1. Investigate Bun's `--target` flag for x86_64 CPU level control
2. Set Zig target to exclude AVX2/BMI2/FMA:
   ```nix
   # In the derivation's build environment:
   BUN_TARGET = "x86_64-linux-gnu";
   # Or via CFLAGS for native addons:
   CFLAGS = "-march=sandybridge -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma";
   CXXFLAGS = "-march=sandybridge -mno-avx2 -mno-bmi -mno-bmi2 -mno-fma";
   ```

3. If Bun doesn't expose CPU target control, investigate:
   - Patching Bun's Zig build config
   - Using `patchelf` to modify the output binary (unlikely to work for instruction replacement)
   - Building with an older Bun version that has broader baseline support

4. Verify the output binary:
   ```bash
   objdump -d opencode | grep -ciE "vbroadcast|vpmovzx|vpsllv|..."
   # Should be 0 for AVX2-specific instructions
   ```

**Deliverables:**
- CPU-flag-controlled build process
- Verification script for instruction set compliance

**Verification:**
- Output binary has 0 AVX2 instructions
- Binary runs on Sandy Bridge hardware (terminal-zero)

### Phase 4: Dual Package Integration

**Objective:** Offer both prebuilt and source-built packages in the flake.

**Steps:**

1. Rename existing `package.nix` to `package-prebuilt.nix`
2. Keep `package-source.nix` from Phase 2/3
3. Update `flake.nix` to expose both:
   ```nix
   packages = forEachSystem ({ pkgs, system }: {
     # Default: prebuilt binary (fast, modern CPUs)
     opencode = pkgs.callPackage ./package-prebuilt.nix {};
     default = self.packages.${system}.opencode;

     # Source-built: Sandy Bridge compatible
     opencode-source = pkgs.callPackage ./package-source.nix {
       bun2nixLib = bun2nix.lib.${system};
     };

     # Aliases for clarity
     opencode-prebuilt = self.packages.${system}.opencode;
   });
   ```

4. Update `README.md` to document both packages and when to use each

**Deliverables:**
- Dual package flake
- Updated documentation

**Verification:**
- `nix build .#opencode` works (prebuilt)
- `nix build .#opencode-source` works (source-built)
- Both produce working binaries

### Phase 5: LLM-CORE Integration

**Objective:** Update the opencode-fleet NixOS module to support configurable opencode packages.

**Steps:**

1. Add `bun2nix` as an input to LLM-CORE's flake:
   ```nix
   inputs.bun2nix.url = "github:nix-community/bun2nix";
   ```

2. Modify `nix/modules/opencode-fleet.nix` to accept an `opencodePackage` option:
   ```nix
   options.services.opencode-fleet.opencodePackage = lib.mkOption {
     type = lib.types.package;
     default = opencodeFlake.packages.${pkgs.system}.opencode;
     description = "OpenCode package to use. Use opencode-source for Sandy Bridge CPUs.";
   };
   ```

3. In terminal-zero's machine config, override:
   ```nix
   services.opencode-fleet = {
     enable = true;
     shipOverride = [ "voyager" ];
     opencodePackage = LLM-CORE.inputs.opencode-flake.packages.x86_64-linux.opencode-source;
   };
   ```

**Deliverables:**
- Configurable opencode-fleet module
- terminal-zero override for source-built package

**Verification:**
- Fleet builds without errors
- terminal-zero uses source-built package

### Phase 6: Testing and CI

**Objective:** Validate on Sandy Bridge hardware and update CI.

**Steps:**

1. Deploy to terminal-zero and verify:
   ```bash
   ssh John88@10.88.127.20 -p 1108 "opencode --version"
   # Should succeed without illegal instruction
   ```

2. Add instruction set compliance check to CI:
   ```bash
   # In .github/workflows/:
   - name: Verify no AVX2 in source build
     run: |
       AVX2_COUNT=$(objdump -d result/bin/opencode | grep -ciE "vbroadcast|vpmovzx|...")
       if [ "$AVX2_COUNT" -gt 0 ]; then
         echo "FAIL: Source build contains AVX2 instructions"
         exit 1
       fi
   ```

3. Add Sandy Bridge smoke test (if hardware available in CI)

**Deliverables:**
- Verified working deployment on terminal-zero
- CI compliance checks

**Verification:**
- terminal-zero runs opencode without crash
- CI catches AVX2 regressions

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| bun2nix can't handle opencode's complex workspace | Medium | High | Fallback: manual Nix derivation with `bun build` |
| Bun runtime itself contains AVX2 in baseline mode | Medium | Critical | Investigate Bun source; may need older Bun version |
| Native addons override CPU flags | Low | Medium | Per-addon CFLAGS override |
| Build time excessive for CI | Medium | Low | Binary cache, source build only for legacy targets |
| Upstream changes break source build | Medium | Medium | Pin to known-good version, update carefully |

## Dependencies

- `nix-community/bun2nix` — Bun lockfile to Nix expression generator
- `anomalyco/opencode` source — GitHub repository
- Bun 1.3.14 runtime — Required for build
- Zig toolchain — Bundled with Bun, handles native addon compilation
- Sandy Bridge test hardware — terminal-zero (i5-2520M, 10.88.127.20)

## Timeline Estimate

| Phase | Effort | Dependencies |
|-------|--------|-------------|
| 1. Research | 1-2 days | None |
| 2. Source derivation | 2-3 days | Phase 1 |
| 3. CPU target control | 1-2 days | Phase 2 |
| 4. Dual package | 0.5 days | Phase 2 |
| 5. LLM-CORE integration | 0.5 days | Phase 4 |
| 6. Testing | 1 day | Phase 5 |
| **Total** | **6-9 days** | |

## Open Questions

1. **Does Bun respect `CFLAGS` for native addon compilation?** Need to verify.
2. **Can Bun's Zig target be overridden externally?** May require patching.
3. **Is there a Bun version with true x86_64-v1 baseline?** Need to check older releases.
4. **Does `@parcel/watcher` dlopen bypass our CPU flags?** It's loaded at runtime, not compiled in.

## References

- [bun2nix documentation](https://nix-community.github.io/bun2nix/)
- [anomalyco/opencode source](https://github.com/anomalyco/opencode)
- [numtide/llm-agents.nix](https://github.com/numtide/llm-agents.nix) — reference for bun2nix integration
- [Bun CPU baseline builds](https://bun.sh/docs/project/cpu)
- [Zig target specification](https://ziglang.org/documentation/master/#Target)
