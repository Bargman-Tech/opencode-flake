# AGENTS.md - OpenCode Nix Flake Development Guide

## Project Overview
This repository packages OpenCode (terminal-based AI assistant) as a Nix flake using **prebuilt release binaries** from anomalyco/opencode (pattern aligned with noblepayne/opencode-flake).

## Build/Test Commands
- `nix build` - Build the OpenCode package
- `nix flake check` - Run flake checks (package + version test)
- `nix run . -- --version` - Test the built OpenCode binary version
- `nix develop` - Enter development shell with OpenCode available
- `./scripts/update-vendor-hash.sh` - Recompute all platform release hashes for the version in package.nix

## Version Updates
Prefer automated updates:
```bash
nix-update --flake opencode
# or: gh workflow run update-opencode.yml
```
Manual:
1. Bump `version` in `package.nix`
2. Update each platform `fetchzip` hash (`./scripts/update-vendor-hash.sh`)
3. `nix build && nix flake check`

## Code Style & Conventions
- **Language**: Nix expressions with functional programming style
- **Formatting**: 2-space indentation
- **File Structure**: Package definition in `package.nix`, flake config in `flake.nix`
- **Packaging**: Prebuilt binaries only — no source/Bun/Go builds in this flake

## Testing
- All changes must pass `nix flake check` before commit
- Workflow validates build + `--version` before push
