#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "${REPO_ROOT}" ]]; then
  echo "Error: run_agent.sh must be run from within a Git repository." >&2
  exit 1
fi

cd "$REPO_ROOT"

AGENT_NAME="${AGENT_NAME:-codex}"
AGENT_RUNNER="${AGENT_RUNNER:-codex}"
PROMPT_FILE_DEFAULT="docs/AGENT_PROMPT.txt"
PROMPT_FILE_OVERRIDE=""
ISSUE_NUMBER=""
EXTRA_PROMPT_FILE=""
ALLOW_DIRTY_WORKTREE="0"
SKIP_GITHUB_ISSUE_FETCH="0"
DEVELOPER_NAME="${DEVELOPER_NAME:-$(git config user.name || true)}"
DEVELOPER_EMAIL="${DEVELOPER_EMAIL:-$(git config user.email || true)}"
AGENT_GIT_MODE="${AGENT_GIT_MODE:-developer-author}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_agent.sh [options] [-- <extra runner args>]

Options:
  --issue <number>             Attach GitHub issue context to the prompt
  --prompt-file <path>         Override the default prompt file
  --extra-prompt-file <path>   Append extra local instructions to the prompt
  --allow-dirty                Allow launch with uncommitted changes
  --skip-issue-fetch           Do not fetch issue details from GitHub
  --help                       Show this help text

Environment:
  AGENT_NAME                   Agent name to record for this session (default: codex)
  AGENT_RUNNER                 Executable used to launch the agent (default: codex)
  DEVELOPER_NAME               Developer name to record for this session
  DEVELOPER_EMAIL              Developer email to record for this session
  AGENT_GIT_MODE               Git identity mode: developer-author or agent-author

Preferred GitHub App environment variables:
  GITHUB_APP_ID
  GITHUB_APP_INSTALLATION_ID
  GITHUB_APP_PRIVATE_KEY_PATH
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

resolve_prompt_file() {
  local prompt_file

  prompt_file="${PROMPT_FILE_OVERRIDE:-$PROMPT_FILE_DEFAULT}"

  if [[ ! -f "$prompt_file" ]]; then
    echo "Error: prompt file not found: $prompt_file" >&2
    exit 1
  fi

  printf '%s\n' "$prompt_file"
}

is_default_branch() {
  local branch
  branch="$(git rev-parse --abbrev-ref HEAD)"
  [[ "$branch" == "main" || "$branch" == "master" ]]
}

ensure_safe_args() {
  local arg
  for arg in "$@"; do
    case "$arg" in
      --git-dir=*|--work-tree=*|-C)
        echo "Error: disallowed git path override argument detected: $arg" >&2
        exit 1
        ;;
    esac
  done
}

mint_github_app_token() {
  if [[ -z "${GITHUB_APP_ID:-}" || -z "${GITHUB_APP_INSTALLATION_ID:-}" || -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]]; then
    return 1
  fi

  require_cmd openssl
  require_cmd python3
  require_cmd curl

  python3 - <<'PY'
import base64
import json
import os
import subprocess
import tempfile
import time

app_id = os.environ["GITHUB_APP_ID"]
private_key_path = os.environ["GITHUB_APP_PRIVATE_KEY_PATH"]

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")

header = b64url(json.dumps({"alg": "RS256", "typ": "JWT"}).encode())
payload = b64url(json.dumps({
    "iat": int(time.time()) - 60,
    "exp": int(time.time()) + 540,
    "iss": app_id,
}).encode())

signing_input = f"{header}.{payload}".encode()

with tempfile.NamedTemporaryFile(delete=False) as f:
    f.write(signing_input)
    signing_path = f.name

try:
    signature = subprocess.check_output([
        "openssl", "dgst", "-sha256", "-sign", private_key_path, signing_path
    ])
finally:
    os.unlink(signing_path)

print(f"{header}.{payload}.{b64url(signature)}")
PY
}

fetch_issue_context() {
  local issue_number="$1"

  if [[ "${SKIP_GITHUB_ISSUE_FETCH}" == "1" ]]; then
    return 1
  fi

  if [[ -n "${GITHUB_APP_ID:-}" && -n "${GITHUB_APP_INSTALLATION_ID:-}" && -n "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]]; then
    local jwt token_response token
    jwt="$(mint_github_app_token)"
    token_response="$(
      curl -fsSL \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${jwt}" \
        "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens"
    )"
    token="$(
      python3 - <<'PY' <<<"$token_response"
import json
import sys
print(json.load(sys.stdin)["token"])
PY
    )"
    GITHUB_TOKEN="$token" gh issue view "$issue_number" --json number,title,body,url,labels
    return 0
  fi

  if command -v gh >/dev/null 2>&1; then
    gh issue view "$issue_number" --json number,title,body,url,labels
    return 0
  fi

  return 1
}

configure_git_identity() {
  export AGENT_NAME="$AGENT_NAME"
  export AGENT_LAUNCHED_BY_NAME="$DEVELOPER_NAME"
  export AGENT_LAUNCHED_BY_EMAIL="$DEVELOPER_EMAIL"
  export AGENT_GIT_MODE="$AGENT_GIT_MODE"

  case "$AGENT_GIT_MODE" in
    developer-author)
      if [[ -n "$DEVELOPER_NAME" ]]; then
        export GIT_AUTHOR_NAME="$DEVELOPER_NAME"
        export GIT_COMMITTER_NAME="$DEVELOPER_NAME"
      fi
      if [[ -n "$DEVELOPER_EMAIL" ]]; then
        export GIT_AUTHOR_EMAIL="$DEVELOPER_EMAIL"
        export GIT_COMMITTER_EMAIL="$DEVELOPER_EMAIL"
      fi
      ;;
    agent-author)
      export GIT_AUTHOR_NAME="$AGENT_NAME"
      export GIT_AUTHOR_EMAIL="${AGENT_NAME}@noreply.local"
      export GIT_COMMITTER_NAME="$AGENT_NAME"
      export GIT_COMMITTER_EMAIL="${AGENT_NAME}@noreply.local"
      ;;
    *)
      echo "Error: unsupported AGENT_GIT_MODE: $AGENT_GIT_MODE" >&2
      echo "Supported values: developer-author, agent-author" >&2
      exit 1
      ;;
  esac
}

build_prompt() {
  local prompt_file="$1"
  local issue_json="${2:-}"
  local temp_prompt
  temp_prompt="$(mktemp)"

  cat "$prompt_file" > "$temp_prompt"

  {
    echo
    echo "----"
    echo "Session context:"
    echo "- Repository root: $REPO_ROOT"
    echo "- Current branch: $(git rev-parse --abbrev-ref HEAD)"
    echo "- Agent: $AGENT_NAME"
    if [[ -n "$DEVELOPER_NAME" || -n "$DEVELOPER_EMAIL" ]]; then
      echo "- Launched by: ${DEVELOPER_NAME:-unknown} ${DEVELOPER_EMAIL:+<$DEVELOPER_EMAIL>}"
    fi
  } >> "$temp_prompt"

  if [[ -n "$issue_json" ]]; then
    {
      echo
      echo "----"
      echo "Issue context:"
      python3 - <<'PY' <<<"$issue_json"
import json
import sys

data = json.load(sys.stdin)
labels = ", ".join(label["name"] for label in data.get("labels", []))

print(f"- Issue: #{data.get('number')}")
print(f"- Title: {data.get('title', '').strip()}")
print(f"- URL: {data.get('url', '').strip()}")
if labels:
    print(f"- Labels: {labels}")
print("")
print("Issue body:")
print(data.get("body", "").strip())
PY
    } >> "$temp_prompt"
  fi

  if [[ -n "$EXTRA_PROMPT_FILE" ]]; then
    if [[ ! -f "$EXTRA_PROMPT_FILE" ]]; then
      echo "Error: extra prompt file not found: $EXTRA_PROMPT_FILE" >&2
      rm -f "$temp_prompt"
      exit 1
    fi
    {
      echo
      echo "----"
      echo "Additional instructions:"
      cat "$EXTRA_PROMPT_FILE"
    } >> "$temp_prompt"
  fi

  printf '%s\n' "$temp_prompt"
}

RUNNER_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      ISSUE_NUMBER="${2:-}"
      shift 2
      ;;
    --prompt-file)
      PROMPT_FILE_OVERRIDE="${2:-}"
      shift 2
      ;;
    --extra-prompt-file)
      EXTRA_PROMPT_FILE="${2:-}"
      shift 2
      ;;
    --allow-dirty)
      ALLOW_DIRTY_WORKTREE="1"
      shift
      ;;
    --skip-issue-fetch)
      SKIP_GITHUB_ISSUE_FETCH="1"
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    --)
      shift
      RUNNER_ARGS+=("$@")
      break
      ;;
    *)
      RUNNER_ARGS+=("$1")
      shift
      ;;
  esac
done

require_cmd git
require_cmd "$AGENT_RUNNER"
require_cmd python3

ensure_safe_args "${RUNNER_ARGS[@]}"

if [[ "${ALLOW_DIRTY_WORKTREE}" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree has uncommitted changes. Commit, stash, or rerun with --allow-dirty." >&2
  exit 1
fi

if is_default_branch; then
  echo "Warning: you are currently on the default branch." >&2
  echo "Create or switch to an issue branch before making agent-authored changes." >&2
fi

PROMPT_FILE="$(resolve_prompt_file)"
ISSUE_JSON=""

if [[ -n "$ISSUE_NUMBER" ]]; then
  require_cmd gh
  if ! ISSUE_JSON="$(fetch_issue_context "$ISSUE_NUMBER")"; then
    echo "Warning: failed to fetch GitHub issue #$ISSUE_NUMBER. Continuing without live issue context." >&2
  fi
fi

configure_git_identity
FINAL_PROMPT_FILE="$(build_prompt "$PROMPT_FILE" "$ISSUE_JSON")"
trap 'rm -f "$FINAL_PROMPT_FILE"' EXIT

echo "Launching agent runner from: $REPO_ROOT"
echo "Runner: $AGENT_RUNNER"
echo "Agent: $AGENT_NAME"
echo "Using prompt file: $PROMPT_FILE"
if [[ -n "$ISSUE_NUMBER" ]]; then
  echo "Issue: #$ISSUE_NUMBER"
fi
echo "Git mode: $AGENT_GIT_MODE"

"$AGENT_RUNNER" --prompt-file "$FINAL_PROMPT_FILE" "${RUNNER_ARGS[@]}"
