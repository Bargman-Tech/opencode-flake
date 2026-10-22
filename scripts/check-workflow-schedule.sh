#!/usr/bin/env bash
# Guard: the OpenCode bump workflow must stay dispatch-only.
#
# The only legitimate bump is the `opencode` flake INPUT REV in flake.nix plus
# a re-lock (./update.sh). A `schedule:`/`cron:` trigger would reintroduce an
# unattended bump — the model this repository removed — so this script is a
# guard, not a diagnostic: it FAILS when the workflow contains either key and
# reports dispatch-only status otherwise.
#
# Usage: ./scripts/check-workflow-schedule.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKFLOW="$ROOT/.github/workflows/update-opencode.yml"

if [[ ! -f "$WORKFLOW" ]]; then
  echo "FAIL: missing workflow: $WORKFLOW" >&2
  exit 1
fi

if grep -nE '(^|[[:space:]])(schedule|cron)[[:space:]]*:' "$WORKFLOW"; then
  echo "FAIL: $WORKFLOW contains a schedule/cron trigger." >&2
  echo "The bump workflow must be dispatch-only; a cron would reintroduce unattended bumps." >&2
  exit 1
fi

if ! grep -qE '^[[:space:]]*workflow_dispatch[[:space:]]*:' "$WORKFLOW"; then
  echo "FAIL: $WORKFLOW has no workflow_dispatch trigger." >&2
  exit 1
fi

echo "OK: $WORKFLOW is dispatch-only (no schedule, no cron)."
echo "    Trigger: workflow_dispatch. Bump path: ./update.sh (input rev + re-lock)."
