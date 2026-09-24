#!/usr/bin/env bash
set -euo pipefail

# Repository-specific entrypoint. The reusable implementation remains the
# declared baseline artefact.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BASELINE_RECONCILER="$REPO_ROOT/baseline/scripts/agent_run_outcomes.sh"

if [[ ! -f "$BASELINE_RECONCILER" || -L "$BASELINE_RECONCILER" || ! -x "$BASELINE_RECONCILER" ]]; then
  echo "agent-run-outcomes: canonical reconciler is missing or unsafe" >&2
  exit 1
fi

cd "$REPO_ROOT"
exec "$BASELINE_RECONCILER" "$@"
