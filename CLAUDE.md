# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This repository packages [OpenCode](https://github.com/anomalyco/opencode), a terminal-based AI assistant for developers, as a Nix flake **built from the upstream source**. The source is the `opencode` flake input; the CLI is compiled in Nix with the flake's own `bun`, and the dependency tree is derived from that source's `bun.lock`.

## Development Environment

This project uses Nix flakes for dependency management and building:

```bash
# Check nix version
nix --version

# Show flake outputs
nix flake show --option builders ''

# Build the flake
nix build --option builders ''

# Develop with the flake
nix develop --option builders ''

# Run opencode
nix run . --option builders '' -- [args]

# Test version
nix run . --option builders '' -- --version
```

## Flake Structure

`flake.nix` defines:

- the unstable nixpkgs input;
- the `opencode` input — **the upstream source**, pinned by rev (`flake = false`), not a release archive and not a binary;
- the `bun2nix` input — a lockfile-aware Bun dependency builder;
- an explicit system list (`aarch64-darwin`, `x86_64-darwin`, `aarch64-linux`, `x86_64-linux`);
- the package, app and devShell outputs, plus the `checks` (package, version, behavioural CLI check, lock round-trip, deadnix, formatting).

`package.nix` is the source-build package definition:

- the `version` is read from the source's own `packages/opencode/package.json` at evaluation time — it is never written in this repository;
- the dependency tree is derived from the source's own `bun.lock` at evaluation time; `bun2nix.fetchBunDeps` turns the lockfile into a fetch set using the integrity values already recorded there, and `bun install --frozen-lockfile` installs offline;
- the CLI is compiled with `bun --bun ./script/build.ts --single --skip-install --skip-embed-web-ui`;
- `patchelf` fixes the store dynamic linker on Linux when the Bun executable carries an interpreter;
- `wrapProgram` sets `OPENCODE_DISABLE_AUTOUPDATE=true`, prefixes `PATH` with `ripgrep` (and `sysctl` on Darwin), and sets `OPENCODE_DISABLE_EMBEDDED_WEB_UI=true` because this build does not embed the web-UI bundle;
- upstream's `patchedDependencies` are applied with a recorded per-patch fuzz, and a rejected hunk fails the build.

The flake creates:

1. A package that can be installed in Nix environments;
2. An app that can be run with `nix run`;
3. A devShell for development;
4. Behavioural checks that exercise the built CLI, not just its version string.

## Current Version

The version is **derived**, never written. The current source input resolves to OpenCode **1.19.3**, read from that source's `packages/opencode/package.json`.

## Updating the Flake

To move to a newer OpenCode:

1. Run `./update.sh` (latest stable release) or `./update.sh 1.19.3` (a specific tag).
2. The script rewrites the `opencode` **input rev** in `flake.nix` and re-locks. It refuses to write a `version =` line.
3. The version then follows from upstream's `packages/opencode/package.json`, and the dependency tree from upstream's `bun.lock`. No dependency hash is written in this repository.
4. Validate before committing:

   ```bash
   nix build --option builders ''
   nix flake check --option builders ''
   ```

There is no per-platform dependency-hash table to edit, no `nix-prefetch-url` step, and no manual hash conversion. Do not add either: the lockfile is the only dependency pin.

## Installation

After building the flake, you can install OpenCode using:

```bash
# Install to your profile
nix profile install . --option builders ''

# Or add to your NixOS configuration
environment.systemPackages = [ inputs.opencode-flake.packages.${system}.default ];
```

## License

The project is licensed under the MIT License.
