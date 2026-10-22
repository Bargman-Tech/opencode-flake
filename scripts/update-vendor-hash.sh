#!/usr/bin/env bash
# REMOVED MECHANISM — this script is a hard-fail stub, kept only so that an
# old caller (or an old habit) fails loudly instead of silently writing a pin.
#
# The vendor-hash model is gone. There is no release tarball, no per-platform
# release asset and no hand-written hash in this repository. The CLI is a
# source build whose dependency tree is derived from the upstream source's own
# bun.lock (integrity values already recorded there), and whose source is a
# flake input.
#
# The legitimate bump path is therefore an INPUT-REV bump:
#   ./update.sh
# which rewrites the `opencode` input rev in flake.nix and re-locks.
#
# This stub writes nothing and always exits non-zero.
set -euo pipefail

cat >&2 <<'MESSAGE'
error: update-vendor-hash.sh is retired.

The vendor-hash pin model was removed in favour of lockfile-derived pins:
  * source:      the `opencode` flake input (flake.nix / flake.lock)
  * version:     upstream packages/opencode/package.json, read at eval time
  * dependencies: upstream bun.lock via bun2nix.fetchBunDeps (integrity from
                  the lockfile; no hash is written in this repository)

There is no release-asset hash to recompute. To move upstream, bump the input rev:
  ./update.sh

This script intentionally writes no file and exits non-zero.
MESSAGE

exit 1
