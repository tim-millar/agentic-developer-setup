#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null || true)"

if [[ -z "$REPO_ROOT" ]]; then
  echo "Error: must be run from within a Git repository." >&2
  exit 1
fi

cd "$REPO_ROOT"

EXPECTED_OWNER="${EXPECTED_OWNER:-tim-millar}"
EXPECTED_REPO="${EXPECTED_REPO:-$(basename "$REPO_ROOT")}"
PROMPT_FILE_DEFAULT="docs/AGENT_PROMPT.txt"
CODEX_BIN="${CODEX_BIN:-codex}"
CODEX_PROFILE="${CODEX_PROFILE:-}"

AGENT_NAME="${AGENT_NAME:-codex}"
AGENT_GIT_MODE="${AGENT_GIT_MODE:-developer-author}"
DEVELOPER_NAME="${DEVELOPER_NAME:-$(git config --get user.name || true)}"
DEVELOPER_EMAIL="${DEVELOPER_EMAIL:-$(git config --get user.email || true)}"

GITHUB_ACCESS_MODE="${GITHUB_ACCESS_MODE:-disabled}"

ISSUE_NUMBER=""
RESUME_SESSION=""
PROMPT_FILE_OVERRIDE=""
EXTRA_PROMPT_FILE=""
ALLOW_DIRTY_WORKTREE="0"
SKIP_GITHUB_ISSUE_FETCH="0"
DEBUG_CODEX_PROMPT="${DEBUG_CODEX_PROMPT:-0}"
CODEX_ARGS=()

TMP_GH_CONFIG_DIR=""
TMP_ASKPASS=""
DEBUG_PROMPT_PATH=""

APP_SLUG="disabled"
EXPIRES_AT="n/a"
INSTALL_TOKEN=""
REPO_ID=""
REPO_FULL_NAME="${EXPECTED_OWNER}/${EXPECTED_REPO}"
DEFAULT_BRANCH=""

cleanup() {
  local status=$?

  [[ -n "$TMP_ASKPASS" && -f "$TMP_ASKPASS" ]] && rm -f "$TMP_ASKPASS"
  [[ -n "$TMP_GH_CONFIG_DIR" && -d "$TMP_GH_CONFIG_DIR" ]] && rm -rf "$TMP_GH_CONFIG_DIR"

  return "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

usage() {
  cat <<EOF
Usage:
  scripts/run_codex.sh [options] [-- <extra codex args>]

Options:
  --issue <number>             Attach GitHub issue context to the prompt
  --resume <session-id>        Resume an existing Codex session without injecting a new prompt
  --prompt-file <path>         Override the default prompt file
  --extra-prompt-file <path>   Append extra local instructions to the prompt
  --profile <name>             Codex profile to use
  --allow-dirty                Allow launch with uncommitted changes
  --skip-issue-fetch           Do not fetch issue details from GitHub
  --help                       Show this help text

Environment:
  GITHUB_ACCESS_MODE           GitHub access mode: disabled or app (default: disabled)
  GITHUB_APP_ID                Numeric GitHub App ID (required when GITHUB_ACCESS_MODE=app)
  GITHUB_APP_INSTALLATION_ID   Numeric GitHub App installation ID (required when GITHUB_ACCESS_MODE=app)
  GITHUB_APP_PRIVATE_KEY_PATH  Path to GitHub App private key PEM (required when GITHUB_ACCESS_MODE=app)
  EXPECTED_OWNER               GitHub owner/org for issue lookup (default: tim-millar)
  EXPECTED_REPO                GitHub repo for issue lookup (default: basename of repo root)
  CODEX_BIN                    Codex executable to run (default: codex)
  CODEX_PROFILE                Default Codex profile to use
  AGENT_NAME                   Agent name to record for this session (default: codex)
  AGENT_GIT_MODE               Git identity mode: developer-author or agent-author
  DEVELOPER_NAME               Developer name to record for this session
  DEVELOPER_EMAIL              Developer email to record for this session
  DEBUG_CODEX_PROMPT           If set to 1, save final prompt to TMPDIR or /tmp before launch
EOF
}

die_usage() {
  local message="$1"
  echo "Error: $message" >&2
  usage >&2
  exit 2
}

require_arg() {
  local flag="$1"
  shift

  if [[ $# -eq 0 || "${1:-}" == --* ]]; then
    die_usage "$flag requires a value"
  fi
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

require_numeric_env() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $name must be numeric, got: $value" >&2
    exit 1
  fi
}

run_codex() {
  if [[ -n "$CODEX_PROFILE" ]]; then
    exec env "${CODEX_ENV[@]}" "$CODEX_BIN" --profile "$CODEX_PROFILE" "$@"
  else
    exec env "${CODEX_ENV[@]}" "$CODEX_BIN" "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue)
      shift
      require_arg --issue "$@"
      ISSUE_NUMBER="$1"
      if ! [[ "$ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
        die_usage "--issue expects a numeric value, got: $ISSUE_NUMBER"
      fi
      shift
      ;;
    --resume)
      shift
      require_arg --resume "$@"
      RESUME_SESSION="$1"
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY_WORKTREE="1"
      shift
      ;;
    --skip-issue-fetch)
      SKIP_GITHUB_ISSUE_FETCH="1"
      shift
      ;;
    --prompt-file)
      shift
      require_arg --prompt-file "$@"
      PROMPT_FILE_OVERRIDE="$1"
      shift
      ;;
    --extra-prompt-file)
      shift
      require_arg --extra-prompt-file "$@"
      EXTRA_PROMPT_FILE="$1"
      shift
      ;;
    --profile)
      shift
      require_arg --profile "$@"
      CODEX_PROFILE="$1"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      CODEX_ARGS+=("$@")
      break
      ;;
    *)
      CODEX_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ -n "$RESUME_SESSION" && -n "$ISSUE_NUMBER" ]]; then
  die_usage "--resume cannot be used with --issue"
fi

if [[ -n "$RESUME_SESSION" && -n "$EXTRA_PROMPT_FILE" ]]; then
  die_usage "--resume cannot be used with --extra-prompt-file"
fi

if [[ -n "$RESUME_SESSION" && "$SKIP_GITHUB_ISSUE_FETCH" == "1" ]]; then
  die_usage "--resume cannot be used with --skip-issue-fetch"
fi

if [[ -n "$RESUME_SESSION" && -n "$PROMPT_FILE_OVERRIDE" ]]; then
  die_usage "--resume cannot be used with --prompt-file"
fi

case "$GITHUB_ACCESS_MODE" in
  disabled|app)
    ;;
  *)
    die_usage "unsupported GITHUB_ACCESS_MODE: $GITHUB_ACCESS_MODE (supported: disabled, app)"
    ;;
esac

require_cmd curl
require_cmd jq
require_cmd openssl
require_cmd git
require_cmd mktemp
require_cmd "$CODEX_BIN"

PROMPT_FILE="${PROMPT_FILE_OVERRIDE:-$PROMPT_FILE_DEFAULT}"

if [[ -z "$RESUME_SESSION" ]]; then
  if [[ ! -f "$PROMPT_FILE" ]]; then
    echo "Error: prompt file not found: $PROMPT_FILE" >&2
    exit 1
  fi

  if [[ -n "$EXTRA_PROMPT_FILE" ]] && [[ ! -f "$EXTRA_PROMPT_FILE" ]]; then
    echo "Error: extra prompt file not found: $EXTRA_PROMPT_FILE" >&2
    exit 1
  fi
fi

if [[ "$ALLOW_DIRTY_WORKTREE" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Error: working tree has uncommitted changes. Commit, stash, or rerun with --allow-dirty." >&2
  exit 1
fi

ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [[ -z "$ORIGIN_URL" ]]; then
  echo "Error: origin remote is not configured." >&2
  exit 1
fi

case "$ORIGIN_URL" in
  https://github.com/${EXPECTED_OWNER}/${EXPECTED_REPO}.git|https://github.com/${EXPECTED_OWNER}/${EXPECTED_REPO})
    ;;
  *)
    echo "Error: origin remote must be HTTPS and match ${EXPECTED_OWNER}/${EXPECTED_REPO}." >&2
    echo "Found origin: $ORIGIN_URL" >&2
    exit 1
    ;;
esac

if [[ "$GITHUB_ACCESS_MODE" == "disabled" && -n "$ISSUE_NUMBER" && "$SKIP_GITHUB_ISSUE_FETCH" != "1" ]]; then
  die_usage "--issue requires GITHUB_ACCESS_MODE=app unless --skip-issue-fetch is set"
fi

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now_epoch() {
  date +%s
}

jwt_mint() {
  local app_id="$1"
  local pem="$2"
  local now iat exp header payload unsigned sig

  now="$(now_epoch)"
  iat="$((now - 60))"
  exp="$((now + 540))"

  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$iat" "$exp" "$app_id")"

  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  sig="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem" | b64url)"
  printf '%s.%s\n' "$unsigned" "$sig"
}

github_api() {
  local auth_header="$1"
  local method="$2"
  local url="$3"
  local body="${4:-}"

  if [[ -n "$body" ]]; then
    curl -sS -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body" \
      "$url"
  else
    curl -sS -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
  : "${GITHUB_APP_ID:?Set GITHUB_APP_ID (numeric App ID)}"
  : "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID (numeric installation ID)}"
  : "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH (path to .pem)}"

  require_numeric_env "GITHUB_APP_ID" "$GITHUB_APP_ID"
  require_numeric_env "GITHUB_APP_INSTALLATION_ID" "$GITHUB_APP_INSTALLATION_ID"

  if [[ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]]; then
    echo "Error: private key file not found: $GITHUB_APP_PRIVATE_KEY_PATH" >&2
    exit 1
  fi

  if ! openssl pkey -in "$GITHUB_APP_PRIVATE_KEY_PATH" -check -noout >/dev/null 2>&1; then
    echo "Error: invalid private key file: $GITHUB_APP_PRIVATE_KEY_PATH" >&2
    exit 1
  fi

  JWT="$(jwt_mint "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY_PATH")"

  APP_JSON="$(
    github_api \
      "Authorization: Bearer ${JWT}" \
      GET \
      "https://api.github.com/app"
  )"

  APP_SLUG="$(printf '%s' "$APP_JSON" | jq -r '.slug // empty')"
  if [[ -z "$APP_SLUG" ]]; then
    echo "Error: JWT validation failed." >&2
    echo "Response:" >&2
    printf '%s\n' "$APP_JSON" | jq . >&2 || printf '%s\n' "$APP_JSON" >&2
    exit 1
  fi

  TOKEN_JSON="$(
    github_api \
      "Authorization: Bearer ${JWT}" \
      POST \
      "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens"
  )"

  INSTALL_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.token // empty')"
  EXPIRES_AT="$(printf '%s' "$TOKEN_JSON" | jq -r '.expires_at // empty')"

  if [[ -z "$INSTALL_TOKEN" ]]; then
    echo "Error: failed to mint installation token." >&2
    echo "Response:" >&2
    printf '%s\n' "$TOKEN_JSON" | jq 'del(.token)' >&2 || printf '%s\n' "$TOKEN_JSON" >&2
    exit 1
  fi

  REPO_JSON="$(
    github_api \
      "Authorization: Bearer ${INSTALL_TOKEN}" \
      GET \
      "https://api.github.com/repos/${EXPECTED_OWNER}/${EXPECTED_REPO}"
  )"

  REPO_ID="$(printf '%s' "$REPO_JSON" | jq -r '.id // empty')"
  REPO_FULL_NAME="$(printf '%s' "$REPO_JSON" | jq -r '.full_name // empty')"
  DEFAULT_BRANCH="$(printf '%s' "$REPO_JSON" | jq -r '.default_branch // empty')"

  if [[ -z "$REPO_ID" || -z "$REPO_FULL_NAME" ]]; then
    echo "Error: failed to resolve repository metadata for ${EXPECTED_OWNER}/${EXPECTED_REPO}." >&2
    echo "Response:" >&2
    printf '%s\n' "$REPO_JSON" | jq . >&2 || printf '%s\n' "$REPO_JSON" >&2
    exit 1
  fi

  if [[ "$REPO_FULL_NAME" != "${EXPECTED_OWNER}/${EXPECTED_REPO}" ]]; then
    echo "Error: resolved repository mismatch. Expected ${EXPECTED_OWNER}/${EXPECTED_REPO}, got ${REPO_FULL_NAME}." >&2
    exit 1
  fi
fi

ISSUE_TITLE=""
ISSUE_URL=""
ISSUE_BODY=""
ISSUE_LABELS=""

if [[ -n "$ISSUE_NUMBER" && "$SKIP_GITHUB_ISSUE_FETCH" != "1" ]]; then
  ISSUE_JSON="$(
    github_api \
      "Authorization: Bearer ${INSTALL_TOKEN}" \
      GET \
      "https://api.github.com/repos/${EXPECTED_OWNER}/${EXPECTED_REPO}/issues/${ISSUE_NUMBER}"
  )"

  ISSUE_ID="$(printf '%s' "$ISSUE_JSON" | jq -r '.number // empty')"
  if [[ -z "$ISSUE_ID" ]]; then
    echo "Error: failed to fetch issue #$ISSUE_NUMBER." >&2
    echo "Response:" >&2
    printf '%s\n' "$ISSUE_JSON" | jq . >&2 || printf '%s\n' "$ISSUE_JSON" >&2
    exit 1
  fi

  if [[ "$(printf '%s' "$ISSUE_JSON" | jq -r '.pull_request != null')" == "true" ]]; then
    echo "Error: #$ISSUE_NUMBER is a pull request, not an issue." >&2
    exit 1
  fi

  ISSUE_TITLE="$(printf '%s' "$ISSUE_JSON" | jq -r '.title // ""')"
  ISSUE_URL="$(printf '%s' "$ISSUE_JSON" | jq -r '.html_url // .url // ""')"
  ISSUE_BODY="$(printf '%s' "$ISSUE_JSON" | jq -r '.body // ""')"
  ISSUE_LABELS="$(printf '%s' "$ISSUE_JSON" | jq -r '[.labels[].name] | join(", ")')"
fi

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
    die_usage "unsupported AGENT_GIT_MODE: $AGENT_GIT_MODE (supported: developer-author, agent-author)"
    ;;
esac

export AGENT_NAME
export AGENT_GIT_MODE
export AGENT_LAUNCHED_BY_NAME="$DEVELOPER_NAME"
export AGENT_LAUNCHED_BY_EMAIL="$DEVELOPER_EMAIL"
export AGENT_REPO_ROOT="$REPO_ROOT"
export AGENT_GITHUB_ACCESS_MODE="$GITHUB_ACCESS_MODE"

if [[ -z "$RESUME_SESSION" ]]; then
  export AGENT_PROMPT_FILE="$PROMPT_FILE"
fi

if [[ -n "$ISSUE_NUMBER" ]]; then
  export AGENT_ISSUE_NUMBER="$ISSUE_NUMBER"
fi

if [[ -n "$EXTRA_PROMPT_FILE" ]]; then
  export AGENT_EXTRA_PROMPT_FILE="$EXTRA_PROMPT_FILE"
fi

build_github_policy_block() {
  if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
    cat <<EOF
GitHub tool-use policy for this session:
- Use shell tools for GitHub operations.
- Prefer git, gh, and curl with the provided environment credentials.
- Do not use internal GitHub tools, connectors, or built-in GitHub actions for pull requests, issues, branches, labels, comments, or repository mutations.
- Do not fall back to any non-shell GitHub integration if a shell-based GitHub command fails.
- If a GitHub operation cannot be completed through shell tools with the provided credentials, stop and report the failure clearly.
EOF
  else
    cat <<EOF
GitHub tool-use policy for this session:
- GitHub access is disabled for this session.
- Do not use git, gh, curl, SSH, credential helpers, internal GitHub tools, connectors, or built-in GitHub actions to access GitHub.
- Do not attempt to use human developer credentials or ambient machine credentials for GitHub access.
- If GitHub access is required to complete a task, stop and report that this session was launched with GitHub disabled.
EOF
  fi
}

PROMPT_CONTENT=""
if [[ -z "$RESUME_SESSION" ]]; then
  PROMPT_CONTENT="$(
    cat "$PROMPT_FILE"
    cat <<EOF

----
Session context:
- Repository root: $REPO_ROOT
- Current branch: $(git rev-parse --abbrev-ref HEAD)
- GitHub repository: ${EXPECTED_OWNER}/${EXPECTED_REPO}
- GitHub access mode: ${GITHUB_ACCESS_MODE}
- GitHub App slug: ${APP_SLUG}
- GitHub token expires at: ${EXPIRES_AT}
- Agent: ${AGENT_NAME}
- Git mode: ${AGENT_GIT_MODE}
- Prompt file: ${PROMPT_FILE}
- Issue fetch skipped: ${SKIP_GITHUB_ISSUE_FETCH}
EOF

    build_github_policy_block

    if [[ -n "$EXTRA_PROMPT_FILE" ]]; then
      printf '%s\n' "- Extra prompt file: ${EXTRA_PROMPT_FILE}"
    fi

    if [[ -n "$DEVELOPER_NAME" || -n "$DEVELOPER_EMAIL" ]]; then
      printf '%s\n' "- Launched by: ${DEVELOPER_NAME:-unknown} ${DEVELOPER_EMAIL:+<$DEVELOPER_EMAIL>}"
    fi

    printf '\n----\n'
    printf '%s\n' "Issue context:"

    if [[ -z "$ISSUE_NUMBER" ]]; then
      printf '%s\n' "- No GitHub issue was provided for this session"
    elif [[ "$SKIP_GITHUB_ISSUE_FETCH" == "1" ]]; then
      printf '%s\n' "- Issue: #$ISSUE_NUMBER"
      if [[ "$GITHUB_ACCESS_MODE" == "disabled" ]]; then
        printf '%s\n' "- GitHub issue fetch was skipped because GitHub access is disabled"
      else
        printf '%s\n' "- GitHub issue fetch was skipped by --skip-issue-fetch"
      fi
    else
      printf '%s\n' "- Issue: #$ISSUE_NUMBER"
      printf '%s\n' "- Title: $ISSUE_TITLE"
      printf '%s\n' "- URL: $ISSUE_URL"
      if [[ -n "$ISSUE_LABELS" ]]; then
        printf '%s\n' "- Labels: $ISSUE_LABELS"
      fi
      printf '\n'
      printf '%s\n' "Issue body:"
      printf '%s\n' "$ISSUE_BODY"
    fi

    if [[ -n "$EXTRA_PROMPT_FILE" ]]; then
      printf '\n----\n'
      printf '%s\n' "Additional instructions:"
      cat "$EXTRA_PROMPT_FILE"
    fi
  )"
fi

if [[ "$DEBUG_CODEX_PROMPT" == "1" && -z "$RESUME_SESSION" ]]; then
  DEBUG_PROMPT_PATH="$(mktemp "${TMPDIR:-/tmp}/codex.prompt.XXXXXX")"
  chmod 600 "$DEBUG_PROMPT_PATH"
  printf '%s' "$PROMPT_CONTENT" > "$DEBUG_PROMPT_PATH"
fi

echo "Launching Codex from: $REPO_ROOT"
echo "GitHub repository: ${EXPECTED_OWNER}/${EXPECTED_REPO}"
echo "GitHub access mode: ${GITHUB_ACCESS_MODE}"
echo "GitHub App slug: ${APP_SLUG}"
echo "GitHub token expires at: ${EXPIRES_AT}"
if [[ -n "$RESUME_SESSION" ]]; then
  echo "Resume session: ${RESUME_SESSION}"
elif [[ -n "$ISSUE_NUMBER" ]]; then
  echo "Issue: #$ISSUE_NUMBER"
else
  echo "Issue: none"
fi
echo "Issue fetch skipped: ${SKIP_GITHUB_ISSUE_FETCH}"
echo "Agent: ${AGENT_NAME}"
echo "Git mode: ${AGENT_GIT_MODE}"
if [[ -z "$RESUME_SESSION" ]]; then
  echo "Prompt file: ${PROMPT_FILE}"
fi
if [[ -n "$EXTRA_PROMPT_FILE" ]]; then
  echo "Extra prompt file: ${EXTRA_PROMPT_FILE}"
fi
echo "Allow dirty worktree: ${ALLOW_DIRTY_WORKTREE}"
if [[ "$DEBUG_CODEX_PROMPT" == "1" && -z "$RESUME_SESSION" ]]; then
  echo "Debug prompt saved to: ${DEBUG_PROMPT_PATH}"
fi
if [[ -n "$DEVELOPER_NAME" || -n "$DEVELOPER_EMAIL" ]]; then
  echo "Launched by: ${DEVELOPER_NAME:-unknown} ${DEVELOPER_EMAIL:+<$DEVELOPER_EMAIL>}"
fi

TMP_GH_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex.gh.XXXXXX")"
chmod 700 "$TMP_GH_CONFIG_DIR"

CODEX_ENV=()

if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
  TMP_ASKPASS="$(mktemp "${TMPDIR:-/tmp}/codex.askpass.XXXXXX")"
  chmod 700 "$TMP_ASKPASS"

  cat > "$TMP_ASKPASS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"

case "$prompt" in
  *Username*github.com*)
    printf '%s\n' 'x-access-token'
    ;;
  *Password*github.com*)
    if [[ -z "${INSTALL_TOKEN:-}" ]]; then
      echo "Error: INSTALL_TOKEN is not set in askpass environment." >&2
      exit 1
    fi
    printf '%s\n' "${INSTALL_TOKEN}"
    ;;
  *)
    echo "Error: unsupported askpass prompt: ${prompt}" >&2
    exit 1
    ;;
esac
EOF
  chmod 700 "$TMP_ASKPASS"

  CODEX_ENV=(
    "GITHUB_TOKEN=$INSTALL_TOKEN"
    "GH_TOKEN=$INSTALL_TOKEN"
    "GH_CONFIG_DIR=$TMP_GH_CONFIG_DIR"
    "INSTALL_TOKEN=$INSTALL_TOKEN"
    "GIT_ASKPASS=$TMP_ASKPASS"
    "GIT_TERMINAL_PROMPT=0"
    "GCM_INTERACTIVE=never"
    "SSH_AUTH_SOCK="
    "GIT_SSH="
    "GIT_SSH_COMMAND="
    "SSH_ASKPASS="
    "GIT_CONFIG_COUNT=3"
    "GIT_CONFIG_KEY_0=credential.helper"
    "GIT_CONFIG_VALUE_0="
    "GIT_CONFIG_KEY_1=core.askPass"
    "GIT_CONFIG_VALUE_1="
    "GIT_CONFIG_KEY_2=credential.useHttpPath"
    "GIT_CONFIG_VALUE_2=true"
  )
else
  CODEX_ENV=(
    "GH_CONFIG_DIR=$TMP_GH_CONFIG_DIR"
    "GH_TOKEN="
    "GITHUB_TOKEN="
    "GITHUB_PAT="
    "INSTALL_TOKEN="
    "GIT_ASKPASS="
    "GIT_TERMINAL_PROMPT=0"
    "GCM_INTERACTIVE=never"
    "SSH_AUTH_SOCK="
    "GIT_SSH="
    "GIT_SSH_COMMAND="
    "SSH_ASKPASS="
    "GIT_CONFIG_COUNT=3"
    "GIT_CONFIG_KEY_0=credential.helper"
    "GIT_CONFIG_VALUE_0="
    "GIT_CONFIG_KEY_1=core.askPass"
    "GIT_CONFIG_VALUE_1="
    "GIT_CONFIG_KEY_2=credential.useHttpPath"
    "GIT_CONFIG_VALUE_2=true"
  )
fi

if [[ -n "$RESUME_SESSION" ]]; then
  run_codex resume "$RESUME_SESSION" "${CODEX_ARGS[@]}"
fi

run_codex "${CODEX_ARGS[@]}" "$PROMPT_CONTENT"
