#!/usr/bin/env bash
# Recompute fetchzip hashes for all platform release assets.
# Uses a temporary fetchzip expression so hashes match package.nix exactly.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(grep -oP 'version = "\K[^"]+' package.nix | head -1)
echo "Version: ${VERSION}"

BASE="https://github.com/anomalyco/opencode/releases/download/v${VERSION}"

declare -A ASSETS=(
  ["x86_64-linux"]="opencode-linux-x64-baseline.tar.gz"
  ["aarch64-linux"]="opencode-linux-arm64.tar.gz"
  ["aarch64-darwin"]="opencode-darwin-arm64.zip"
  ["x86_64-darwin"]="opencode-darwin-x64-baseline.zip"
)

prefetch_fetchzip_hash() {
  local url="$1"
  local expr
  # empty outputHash forces Nix to report the correct hash
  expr=$(cat <<NIX
let
  pkgs = import <nixpkgs> {};
in
pkgs.fetchzip {
  url = "${url}";
  hash = "";
  stripRoot = false;
}
NIX
)
  local output
  if output=$(nix-build --expr "$expr" --no-out-link 2>&1); then
    echo "Unexpected success prefetching ${url}" >&2
    exit 1
  fi
  local got
  got=$(echo "$output" | grep -oE 'got:[[:space:]]+sha256-[A-Za-z0-9+/=]+' | head -1 | sed 's/got:[[:space:]]*//')
  if [[ -z "$got" ]]; then
    echo "Failed to extract hash for ${url}" >&2
    echo "$output" >&2
    exit 1
  fi
  echo "$got"
}

for system in x86_64-linux aarch64-linux aarch64-darwin x86_64-darwin; do
  asset="${ASSETS[$system]}"
  url="${BASE}/${asset}"
  echo "Prefetching fetchzip hash for ${asset} (${system})..."
  new_hash=$(prefetch_fetchzip_hash "$url")
  echo "  ${system}: ${new_hash}"

  python3 - "$asset" "$new_hash" <<'PY'
import re, sys
asset, new_hash = sys.argv[1], sys.argv[2]
path = "package.nix"
text = open(path).read()
pattern = re.compile(
    r'(url = "[^"]*' + re.escape(asset) + r'";\s*\n(?:\s*#[^\n]*\n)?\s*hash = ")sha256-[^"]+(")',
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

echo "Verifying build for current system..."
nix build .#opencode -L --option builders ''
./result/bin/opencode --version
echo "All platform hashes updated."
