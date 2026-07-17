#!/usr/bin/env bash
# Recover platform release hashes in package.nix after a version bump.
# Used when nix-update cannot fill all fetchzip hashes automatically.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "Attempting to update release asset hashes..."

VERSION=$(grep -oP 'version = "\K[^"]+' package.nix | head -1)
echo "Version: $VERSION"

BASE="https://github.com/anomalyco/opencode/releases/download/v${VERSION}"
declare -A ASSETS=(
  ["x86_64-linux"]="opencode-linux-x64-baseline.tar.gz"
  ["aarch64-linux"]="opencode-linux-arm64.tar.gz"
  ["aarch64-darwin"]="opencode-darwin-arm64.zip"
  ["x86_64-darwin"]="opencode-darwin-x64-baseline.zip"
)

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

for system in "${!ASSETS[@]}"; do
  asset="${ASSETS[$system]}"
  echo -e "${YELLOW}Fetching ${asset} for ${system}...${NC}"
  if ! curl -fsSL "${BASE}/${asset}" -o "${tmpdir}/${asset}"; then
    echo -e "${RED}Failed to download ${asset}${NC}"
    exit 1
  fi
  new_hash=$(nix hash file "${tmpdir}/${asset}")
  echo "  hash: ${new_hash}"

  # Replace the hash belonging to this system's fetchzip block.
  # Match the URL line for the asset, then the following hash = "..." line.
  python3 - "$asset" "$new_hash" <<'PY'
import re, sys
asset, new_hash = sys.argv[1], sys.argv[2]
path = "package.nix"
text = open(path).read()
# Within the block that mentions this asset URL, replace hash = "sha256-..."
pattern = re.compile(
    r'(url = "[^"]*' + re.escape(asset) + r'";\s*\n\s*hash = ")sha256-[^"]+(")',
    re.M,
)
new_text, n = pattern.subn(r"\1" + new_hash + r"\2", text, count=1)
if n != 1:
    sys.stderr.write(f"Could not locate hash for asset {asset} (replacements={n})\n")
    sys.exit(1)
open(path, "w").write(new_text)
print(f"Updated hash for {asset}")
PY
done

echo -e "${GREEN}All platform hashes updated. Verifying build...${NC}"
if nix build .#opencode -L; then
  ./result/bin/opencode --version || true
  echo -e "${GREEN}Build successful${NC}"
  exit 0
fi

echo -e "${RED}Build failed after hash update${NC}"
exit 1
