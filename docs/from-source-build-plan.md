# SUPERSEDED — From-Source Build of OpenCode (Sandy Bridge investigation)

**Date:** 2026-07-21
**Status:** SUPERSEDED — historical proposal only, not an instruction
**Superseded by:** the `opencode` flake input plus the source build in
`flake.nix` / `package.nix`, and the bump path in `./update.sh`.

> This document used to describe a dual-package flake in which the default was a
> downloaded release artefact and a source-built package was an opt-in. That
> model no longer exists. The repository now builds the CLI from the upstream
> source for every platform; there is no downloaded release package, no
> per-platform dependency-hash table, and no hand-written version. Read this
> file as the record of an investigation, not as guidance.

## What this proposal was

The original investigation measured the x86_64 release artefacts published by
`anomalyco/opencode`. Even the asset labelled "baseline" carried AVX2-specific
instructions and crashed with signal 4 (`ILL`) on Sandy Bridge CPUs (for
example the i5-2520M), which support AVX but not AVX2/BMI2/FMA. The proposal
therefore argued for a source build with CPU-target flags that exclude AVX2 and
friends.

## Why it was superseded

The repository moved to a source build for its own reasons — patchability and a
single, lockfile-derived dependency model — and that build is now the **only**
package. The dual-package plan, the package-selection snippets and the
release-artefact plumbing in the original text all describe a mechanism that was
deliberately removed. Keeping them as live instructions would teach the deleted
model, so they are not reproduced here.

## What survives as a finding

- Upstream's x86_64 release artefacts were not a true baseline. The measurement
  is historical, but the toolchain question is real: a Bun/Zig build still
  inherits a CPU target.
- If a legacy CPU ever becomes a deployment target, CPU-target selection is a
  build-flag question for the **current** source build — not a reason to restore
  a downloaded package or a hash pin.

## The current build in one paragraph

`flake.nix` pins the upstream source as the `opencode` input. `package.nix`
reads `version` from that source's `packages/opencode/package.json`, derives the
dependency tree from that source's `bun.lock` via `bun2nix`, and compiles the CLI
with `bun --bun ./script/build.ts --single --skip-install --skip-embed-web-ui`.
The wrapper sets `OPENCODE_DISABLE_AUTOUPDATE=true`,
`OPENCODE_DISABLE_EMBEDDED_WEB_UI=true`, and puts `ripgrep` on `PATH`. Moving
upstream means moving the input rev with `./update.sh` and re-locking; the
version and the dependency set follow from the source.

See `README.md`, `AGENTS.md` and `CLAUDE.md` for the current mechanism.
