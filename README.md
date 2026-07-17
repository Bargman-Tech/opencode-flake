# OpenCode Nix Flake

This repository packages [OpenCode](https://github.com/anomalyco/opencode), a terminal-based AI assistant for developers, as a Nix flake using **prebuilt release binaries**.

This flake automatically stays up-to-date with the latest OpenCode releases through an automated workflow that runs daily.

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

- **Prebuilt binaries**: Downloads official release assets from [anomalyco/opencode](https://github.com/anomalyco/opencode)
- **Baseline x86_64 builds**: Uses non-AVX baseline tarballs for broader CPU compatibility
- **NixOS runtime fixups**:
  - `patchelf` sets the store dynamic linker (Linux)
  - Wrapper sets `OPENCODE_DISABLE_AUTOUPDATE=true` (required under Nix)
  - Wrapper prefixes `PATH` with `ripgrep` (and `sysctl` on Darwin), matching nixpkgs
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

This repository features **fully automated maintenance**:

- **Automatic updates**: GitHub Actions workflow runs daily (06:15 UTC) using `nix-update`
- **Version detection**: Detects new OpenCode releases from upstream
- **Validate-before-push**: Builds and runs `--version` before committing
- **Auto-deployment**: Updates are tagged and released after validation

### Workflow Status

- Check the [workflow runs](https://github.com/Bargman-Tech/opencode-flake/actions/workflows/update-opencode.yml) to see recent updates
- **Note**: Scheduled workflows are automatically disabled after 60 days of repository inactivity
- To reactivate: Make any commit or [manually trigger the workflow](https://github.com/Bargman-Tech/opencode-flake/actions/workflows/update-opencode.yml)

### Manual Updates (if needed)

```bash
# Update to latest version (needs nix-update)
nix-update --flake opencode

# If platform hashes need recovery
./scripts/update-vendor-hash.sh

# Build and test
nix build && nix flake check
```

## Supported Systems

- `aarch64-darwin` (macOS on Apple Silicon)
- `x86_64-darwin` (macOS on Intel)
- `aarch64-linux` (Linux on ARM64)
- `x86_64-linux` (Linux on x86_64)

## Repository Structure

- `flake.nix`: Minimal flake packaging outputs
- `package.nix`: Prebuilt binary package definition
- `.github/workflows/update-opencode.yml`: Daily update clockwork
- `scripts/update-vendor-hash.sh`: Hash recovery helper

## CI/CD & Automation

### GitHub Actions Workflows

1. **Automated Updates** (`update-opencode.yml`):
   - Runs daily at 06:15 UTC (semi-regular clockwork)
   - Uses `nix-update` for version detection
   - Validates with `nix build` / `nix flake check` before push
   - Auto-creates releases and tags
   - Can be manually triggered via GitHub Actions UI

## License

This project is licensed under the MIT License - see the LICENSE file for details.
