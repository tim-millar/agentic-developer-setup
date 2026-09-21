#!/usr/bin/env bash
set -euo pipefail

# Repository-specific entrypoint for Codex sessions in
# tim-millar/agentic-developer-setup.
#
# The canonical launcher implementation remains under baseline/. This wrapper
# owns only repository location and identity defaults.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_LAUNCHER="$REPO_ROOT/baseline/scripts/run_codex.sh"

if [[ ! -f "$BASELINE_LAUNCHER" ]]; then
  echo "Error: canonical Codex launcher not found: $BASELINE_LAUNCHER" >&2
  exit 1
fi

if [[ ! -x "$BASELINE_LAUNCHER" ]]; then
  echo "Error: canonical Codex launcher is not executable: $BASELINE_LAUNCHER" >&2
  exit 1
fi

EXPECTED_OWNER="${EXPECTED_OWNER-tim-millar}"
EXPECTED_REPO="${EXPECTED_REPO-agentic-developer-setup}"
export EXPECTED_OWNER EXPECTED_REPO

cd "$REPO_ROOT"

exec "$BASELINE_LAUNCHER" "$@"
