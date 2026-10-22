# AGENTS.md - OpenCode Nix Flake Development Guide

## Project Overview
This repository packages OpenCode (terminal-based AI assistant) as a Nix flake **built from the upstream source**. The source is the `opencode` flake input; the version is read from that source's `packages/opencode/package.json` and the dependency tree from its `bun.lock`. No release binary and no hand-written hash.

## Build/Test Commands
- `nix build --option builders ''` - Build the OpenCode package from source
- `nix flake check --option builders ''` - Run flake checks (package + version test + deadnix + formatting)
- `nix run . -- --version` - Test the built OpenCode binary version
- `nix develop` - Enter development shell with OpenCode available
- `nix run nixpkgs#deadnix -- --no-lambda-pattern-names .` - Find dead Nix code
- `nix run nixpkgs#nixpkgs-fmt -- --check .` - Check Nix formatting

## Version Updates
The version is **derived**, never written: a bump moves the `opencode` input rev in `flake.nix` and re-locks.
```bash
./update.sh            # latest upstream stable release
./update.sh 1.19.3     # a specific tag
```
`update.sh` refuses to write a `version =` line. There is no hash to recompute; `scripts/update-vendor-hash.sh` is a retired hard-fail stub.

## Code Style & Conventions
- **Language**: Nix expressions with functional programming style
- **Formatting**: 2-space indentation, `nixpkgs-fmt`
- **File Structure**: Package definition in `package.nix`, flake config in `flake.nix`
- **Packaging**: Source build only — the CLI compiles from the `opencode` input with a nixpkgs `bun`; dependencies come from upstream's `bun.lock`. No fetchzip and no hand-written hash pins

## Testing
- All changes must pass `nix flake check --option builders ''` before commit
- Workflow validates build + `--version` before push
