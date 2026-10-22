# OpenCode Nix Flake

This repository packages [OpenCode](https://github.com/anomalyco/opencode), a terminal-based AI assistant for developers, as a Nix flake **built from the upstream source**. There is no release binary and no hand-written hash: the source is the `opencode` flake input, the version is read from that source's `packages/opencode/package.json`, and the dependency tree is derived from that source's `bun.lock`.

Moving upstream means moving the `opencode` input rev and re-locking (`./update.sh`) — there is no version string or platform hash to edit.

## Quick Start

```bash
# Run directly from the flake
nix run github:Bargman-Tech/opencode-flake

# Check the version
nix run github:Bargman-Tech/opencode-flake -- --version

# Install to your profile
nix profile install github:Bargman-Tech/opencode-flake
```

## Installation

### Profile Installation
```bash
nix profile install github:Bargman-Tech/opencode-flake
```

### NixOS/Home Manager Configuration
```nix
{
  inputs.opencode-flake.url = "github:Bargman-Tech/opencode-flake";

  # In your configuration:
  environment.systemPackages = [ inputs.opencode-flake.packages.${pkgs.system}.default ];

  # Or in home-manager:
  home.packages = [ inputs.opencode-flake.packages.${pkgs.system}.default ];
}
```

## Packaging

- **Source build**: compiles the CLI from the `opencode` flake input (a pin on upstream tag v1.19.3) with a `bun` pinned by nixpkgs
- **Version is derived**: read from the source's `packages/opencode/package.json` at evaluation time — never transcribed into this repository
- **Dependencies are lockfile-derived**: `bun2nix.fetchBunDeps` turns upstream's own `bun.lock` into a fetch set using the integrity values already in that lockfile, then `bun install --frozen-lockfile` installs offline. No dependency hash is written here
- **NixOS runtime fixups**:
  - `patchelf` sets the store dynamic linker (Linux), only when the Bun binary carries an interpreter
  - Wrapper sets `OPENCODE_DISABLE_AUTOUPDATE=true` (required under Nix)
  - Wrapper prefixes `PATH` with `ripgrep` (and `sysctl` on Darwin), matching nixpkgs
  - Wrapper sets `OPENCODE_DISABLE_EMBEDDED_WEB_UI=true`: the source build does not embed the web UI bundle (`--skip-embed-web-ui`), so `opencode web` proxies to upstream's UI at runtime. Setting the flag makes that an explicit choice, not an accident of a missing file
- **Lockfile patches**: upstream's `patchedDependencies` are applied with a recorded per-patch fuzz (`@ai-sdk/google@3.0.73` and `@silvia-odwyer/photon-node@0.3.4` need fuzz 3; the rest apply at fuzz 0), and the build fails if any patch produces rejects
- **Cross-platform**: `x86_64-linux`, `aarch64-linux`, `x86_64-darwin`, `aarch64-darwin`

## Development

```bash
# Enter development shell with OpenCode available
nix develop github:Bargman-Tech/opencode-flake

# Build locally
nix build

# Test the package
nix flake check
```

## Automated Maintenance

Maintenance is **manual by design**:

- **Input-rev bump**: `./update.sh [<tag>]` rewrites the `opencode` input rev in `flake.nix` and re-locks. It refuses to write a `version =` line
- **No daily cron**: the scheduled job was disabled because there is no version string or release-asset hash left to refresh; a scheduled sed would reintroduce the pin model this flake removed
- **Validate-before-push**: the dispatched workflow builds and runs `--version` before committing
- **Auto-tagging**: the manual workflow tags and releases the derived version after validation

### Workflow Status

- Check the [workflow runs](https://github.com/Bargman-Tech/opencode-flake/actions/workflows/update-opencode.yml) to see recent updates
- The workflow runs on `workflow_dispatch` only

### Manual Updates

```bash
# Move the opencode input to the latest upstream release (or ./update.sh 1.19.3)
./update.sh

# Build and test
nix build --option builders ''
nix flake check --option builders ''
```

## Supported Systems

- `aarch64-darwin` (macOS on Apple Silicon)
- `x86_64-darwin` (macOS on Intel)
- `aarch64-linux` (Linux on ARM64)
- `x86_64-linux` (Linux on x86_64)

## Repository Structure

- `flake.nix`: Flake outputs — the `opencode` source input, the package, the checks
- `package.nix`: Source-build package definition (version from `package.json`, deps from `bun.lock`)
- `.github/workflows/update-opencode.yml`: Manual input-rev bump (no cron)
- `scripts/update-vendor-hash.sh`: Retired hard-fail stub — the vendor-hash model is gone; use `./update.sh`

## CI/CD & Automation

### GitHub Actions Workflows

1. **Input-rev bump** (`update-opencode.yml`):
   - Runs on `workflow_dispatch` only (the daily 06:15 UTC cron is disabled)
   - Calls `./update.sh`, which moves the `opencode` input rev and re-locks
   - Validates with `nix build` / `nix flake check` before push
   - Auto-creates releases and tags from the derived version

## License

This project is licensed under the MIT License - see the LICENSE file for details.
