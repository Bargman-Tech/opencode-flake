#!/usr/bin/env bash
# Update package.nix to the latest stable OpenCode release.
# Uses GitHub Releases API (not atom feed) so PR/pre-release tags are ignored.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

CURRENT=$(grep -oP 'version = "\K[^"]+' package.nix | head -1)
echo "Current version: ${CURRENT}"

echo "Fetching latest stable release from anomalyco/opencode..."
LATEST=$(curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r '.tag_name')
LATEST="${LATEST#v}"

if [[ -z "$LATEST" || "$LATEST" == "null" ]]; then
  echo "Failed to determine latest release tag" >&2
  exit 1
fi

# Only accept semver X.Y.Z (optionally with pre-release suffix we still reject pure non-numeric tags)
if ! [[ "$LATEST" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
  echo "Latest tag is not a version: ${LATEST}" >&2
  exit 1
fi

echo "Latest version: ${LATEST}"

if [[ "$CURRENT" == "$LATEST" ]]; then
  echo "Already at latest version (${LATEST})"
  exit 0
fi

echo "Bumping version ${CURRENT} -> ${LATEST}"
sed -i "s/version = \"${CURRENT}\"/version = \"${LATEST}\"/" package.nix

echo "Refreshing platform release hashes..."
./scripts/update-vendor-hash.sh

echo "Update complete: ${LATEST}"
