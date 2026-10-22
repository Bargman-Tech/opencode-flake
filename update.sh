#!/usr/bin/env bash
# Move the `opencode` flake INPUT — the only thing a version bump touches.
#
# The version is not stored here: it is read from the upstream source's own
# packages/opencode/package.json, and the dependency tree from that source's
# bun.lock. So a bump changes exactly one thing, the `opencode` input rev in
# flake.nix, and then re-locks. This script refuses to write a `version =`
# line anywhere: such a line would be a pin the build does not use, which is
# precisely the failure mode this repository removed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

FLAKE=flake.nix

refuse_version_pin() {
  # A semver `version =` line in either file would be a hand-written pin; the
  # version belongs to the upstream package.json alone. (The patched-source
  # derivations carry `version = "0"`, which is not a package version.)
  if grep -qE '^[[:space:]]*version[[:space:]]*=[[:space:]]*"[0-9]+\.[0-9]+' "$FLAKE" package.nix 2>/dev/null; then
    echo "refusing: a 'version =' pin exists in flake.nix/package.nix." >&2
    echo "the version is derived from the upstream packages/opencode/package.json." >&2
    exit 1
  fi
}

current_rev() {
  grep -oP 'github:anomalyco/opencode/\K[0-9a-f]{40}' "$FLAKE" | head -1
}

refuse_version_pin

CURRENT_REV=$(current_rev)
if [[ -z "$CURRENT_REV" ]]; then
  echo "could not find the opencode input rev in ${FLAKE}" >&2
  exit 1
fi
echo "Current opencode input rev: ${CURRENT_REV}"

if [[ -n "${1:-}" ]]; then
  TAG="${1#v}"
  echo "Using the requested release tag: v${TAG}"
else
  echo "Fetching the latest stable release of anomalyco/opencode..."
  TAG=$(curl -fsSL https://api.github.com/repos/anomalyco/opencode/releases/latest | jq -r '.tag_name')
  TAG="${TAG#v}"
fi

if [[ -z "$TAG" || "$TAG" == "null" ]]; then
  echo "Failed to determine the release tag" >&2
  exit 1
fi

if ! [[ "$TAG" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-].*)?$ ]]; then
  echo "Latest tag is not a version: ${TAG}" >&2
  exit 1
fi

# The release tag is annotated, so peel it to the commit it points at.
LATEST_REV=$(git ls-remote "https://github.com/anomalyco/opencode.git" "refs/tags/v${TAG}^{}" | awk '{print $1}')
if [[ -z "$LATEST_REV" ]]; then
  LATEST_REV=$(git ls-remote "https://github.com/anomalyco/opencode.git" "refs/tags/v${TAG}" | awk '{print $1}')
fi

if [[ -z "$LATEST_REV" ]]; then
  echo "Failed to resolve tag v${TAG} to a commit" >&2
  exit 1
fi

echo "Latest release: v${TAG} -> ${LATEST_REV}"

if [[ "$CURRENT_REV" == "$LATEST_REV" ]]; then
  echo "The opencode input already points at v${TAG} (${LATEST_REV})"
  exit 0
fi

# Replace ONLY the rev, never a version string.
sed -i "s|github:anomalyco/opencode/${CURRENT_REV}|github:anomalyco/opencode/${LATEST_REV}|" "$FLAKE"
refuse_version_pin

# Belt and braces: the diff must not introduce a version pin either.
if git diff -- "$FLAKE" | grep -qE '^[+-].*version[[:space:]]*='; then
  echo "refusing: the bump introduced a 'version =' line in ${FLAKE}." >&2
  exit 1
fi

if ! grep -q "github:anomalyco/opencode/${LATEST_REV}" "$FLAKE"; then
  echo "the input rev replacement did not land in ${FLAKE}" >&2
  exit 1
fi

echo "Re-locking the opencode input..."
nix flake lock --option builders ''

SYSTEM=$(nix eval --raw --impure --expr builtins.currentSystem)
NEW_VERSION=$(nix eval --raw ".#packages.${SYSTEM}.opencode.version" --option builders '')

echo "Update complete: input ${CURRENT_REV} -> ${LATEST_REV} (upstream v${TAG}, derived version ${NEW_VERSION})"
