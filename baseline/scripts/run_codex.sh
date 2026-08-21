#!/usr/bin/env bash
set -euo pipefail

# Codex-specific local agent runtime launcher.
# This script assembles repository context and access policy for Codex sessions;
# it is not intended to be a generic wrapper for every coding agent.

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
AGENT_HOST_ENV_HOOK="scripts/agent_host_env.sh"
AGENT_HOST_ENV_SOURCE="inherited"
AGENT_HOST_PATH=""
CODEX_ALLOW_LOGIN_SHELL_CONFIG="allow_login_shell=false"
CODEX_USE_SHELL_PROFILE_CONFIG="shell_environment_policy.experimental_use_profile=false"
CODEX_PATH_CONFIG=""

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
SESSION_CREDENTIAL_DIR=""
CURRENT_TOKEN_FILE=""
CURRENT_TOKEN_META_FILE=""
TOKEN_HELPER=""
RENEWAL_PID=""
RENEWAL_PID_FILE=""
RENEWAL_READY_FILE=""
RENEWAL_RESULT_FILE=""
SESSION_SHUTDOWN_FILE=""
DEBUG_PROMPT_PATH=""
CODEX_PID=""
HOST_ENV_DIR=""

GITHUB_REFRESH_INTERVAL_SECONDS=2700
GITHUB_RETRY_INTERVAL_SECONDS=300
GITHUB_RENEWAL_CONNECT_TIMEOUT_SECONDS=10
GITHUB_RENEWAL_HTTP_TIMEOUT_SECONDS=30
GITHUB_HELPER_WAIT_SECONDS=40
GITHUB_WORKER_READY_WAIT_SECONDS=5

APP_SLUG="disabled"
EXPIRES_AT="n/a"
INSTALL_TOKEN=""
REPO_ID=""
REPO_FULL_NAME="${EXPECTED_OWNER}/${EXPECTED_REPO}"
DEFAULT_BRANCH=""

cleanup() {
  local status=$?

  if [[ -n "$SESSION_SHUTDOWN_FILE" && -n "$SESSION_CREDENTIAL_DIR" && -d "$SESSION_CREDENTIAL_DIR" ]]; then
    : > "$SESSION_SHUTDOWN_FILE" 2>/dev/null || true
    chmod 600 "$SESSION_SHUTDOWN_FILE" 2>/dev/null || true
  fi
  if declare -F stop_renewal_worker >/dev/null; then
    stop_renewal_worker
  fi
  [[ -n "$TMP_ASKPASS" && -f "$TMP_ASKPASS" ]] && rm -f "$TMP_ASKPASS"
  [[ -n "$TMP_GH_CONFIG_DIR" && -d "$TMP_GH_CONFIG_DIR" ]] && rm -rf "$TMP_GH_CONFIG_DIR"
  [[ -n "$SESSION_CREDENTIAL_DIR" && -d "$SESSION_CREDENTIAL_DIR" ]] && rm -rf "$SESSION_CREDENTIAL_DIR"
  [[ -n "$HOST_ENV_DIR" && -d "$HOST_ENV_DIR" ]] && rm -rf "$HOST_ENV_DIR"

  return "$status"
}

trap cleanup EXIT

handle_signal() {
  local signal="$1"
  local status="$2"

  if [[ -n "$CODEX_PID" ]]; then
    kill -s "$signal" "$CODEX_PID" 2>/dev/null || true
    wait "$CODEX_PID" 2>/dev/null || true
    CODEX_PID=""
  fi

  exit "$status"
}

trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

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
  local status

  if [[ -n "$CODEX_PROFILE" ]]; then
    env "${CODEX_ENV[@]}" "$CODEX_BIN" --profile "$CODEX_PROFILE" \
      -c "$CODEX_ALLOW_LOGIN_SHELL_CONFIG" \
      -c "$CODEX_USE_SHELL_PROFILE_CONFIG" \
      -c "$CODEX_PATH_CONFIG" \
      "$@" <&0 &
  else
    env "${CODEX_ENV[@]}" "$CODEX_BIN" \
      -c "$CODEX_ALLOW_LOGIN_SHELL_CONFIG" \
      -c "$CODEX_USE_SHELL_PROFILE_CONFIG" \
      -c "$CODEX_PATH_CONFIG" \
      "$@" <&0 &
  fi

  CODEX_PID=$!
  set +e
  wait "$CODEX_PID"
  status=$?
  set -e
  CODEX_PID=""

  return "$status"
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

validate_forwarded_codex_config() {
  local index=0 argument assignment key

  while [[ "$index" -lt "${#CODEX_ARGS[@]}" ]]; do
    argument="${CODEX_ARGS[$index]}"
    assignment=""

    case "$argument" in
      -c|--config)
        index=$((index + 1))
        if [[ "$index" -ge "${#CODEX_ARGS[@]}" ]]; then
          die_usage "forwarded Codex $argument requires a key=value assignment"
        fi
        assignment="${CODEX_ARGS[$index]}"
        ;;
      --config=*)
        assignment="${argument#--config=}"
        ;;
      -c=*)
        assignment="${argument#-c=}"
        ;;
      -c?*)
        assignment="${argument#-c}"
        ;;
    esac

    if [[ -n "$assignment" ]]; then
      if [[ "$assignment" != *=* ]]; then
        die_usage "forwarded Codex config requires a key=value assignment"
      fi
      key="${assignment%%=*}"
      key="${key#"${key%%[![:space:]]*}"}"
      key="${key%"${key##*[![:space:]]}"}"
      case "$key" in
        allow_login_shell|shell_environment_policy|shell_environment_policy.*)
          die_usage "forwarded Codex config cannot override launcher-owned shell-environment policy"
          ;;
      esac
    elif [[ "$argument" == -c || "$argument" == --config || "$argument" == -c=* || "$argument" == --config=* ]]; then
      die_usage "forwarded Codex config requires a key=value assignment"
    fi

    index=$((index + 1))
  done
}

validate_forwarded_codex_config

require_cmd curl
require_cmd jq
require_cmd openssl
require_cmd git
require_cmd mktemp
require_cmd "$CODEX_BIN"
require_cmd bash
require_cmd env
require_cmd chmod

# Fix launcher-owned executable selection before repository bootstrap can
# choose a different PATH for Codex shell commands.
BASH_BIN="$(command -v bash)"
ENV_BIN="$(command -v env)"
CHMOD_BIN="$(command -v chmod)"
CODEX_BIN="$(command -v "$CODEX_BIN")"

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

prepare_agent_host_path() {
  local result_file trailing_byte

  AGENT_HOST_PATH="$PATH"
  if [[ -L "$AGENT_HOST_ENV_HOOK" ]]; then
    echo "Error: agent host environment hook must be a non-symlink regular file: $AGENT_HOST_ENV_HOOK" >&2
    return 1
  fi
  if [[ ! -e "$AGENT_HOST_ENV_HOOK" ]]; then
    return 0
  fi
  if [[ ! -f "$AGENT_HOST_ENV_HOOK" ]]; then
    echo "Error: agent host environment hook must be a non-symlink regular file: $AGENT_HOST_ENV_HOOK" >&2
    return 1
  fi

  AGENT_HOST_ENV_SOURCE="$AGENT_HOST_ENV_HOOK"
  HOST_ENV_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex.host-env.XXXXXX")"
  chmod 700 "$HOST_ENV_DIR"
  result_file="${HOST_ENV_DIR}/path"

  if ! "$ENV_BIN" \
    -u GITHUB_APP_ID \
    -u GITHUB_APP_INSTALLATION_ID \
    -u GITHUB_APP_PRIVATE_KEY_PATH \
    -u GH_TOKEN \
    -u GITHUB_TOKEN \
    -u GITHUB_PAT \
    -u INSTALL_TOKEN \
    -u AGENT_GITHUB_TOKEN_HELPER \
    -u SSH_AUTH_SOCK \
    "$BASH_BIN" -c '
      set -euo pipefail
      readonly __launcher_host_hook="$1"
      readonly __launcher_host_result="$2"
      readonly __launcher_host_chmod="$3"
      source "$__launcher_host_hook"
      builtin printf "%s\0" "$PATH" > "$__launcher_host_result"
      "$__launcher_host_chmod" 600 "$__launcher_host_result"
    ' agent-host-env "$REPO_ROOT/$AGENT_HOST_ENV_HOOK" "$result_file" "$CHMOD_BIN"; then
    echo "Error: agent host environment preparation failed: $AGENT_HOST_ENV_HOOK" >&2
    return 1
  fi

  if [[ ! -f "$result_file" ]]; then
    echo "Error: agent host environment preparation returned no PATH result." >&2
    return 1
  fi

  exec 3< "$result_file"
  if ! IFS= read -r -d '' AGENT_HOST_PATH <&3; then
    exec 3<&-
    echo "Error: agent host environment preparation returned a malformed PATH result." >&2
    return 1
  fi
  if IFS= read -r -n 1 trailing_byte <&3; then
    exec 3<&-
    echo "Error: agent host environment preparation returned extra PATH result data." >&2
    return 1
  fi
  exec 3<&-

  if [[ -z "$AGENT_HOST_PATH" ]]; then
    echo "Error: agent host environment preparation returned an empty PATH." >&2
    return 1
  fi

  rm -rf "$HOST_ENV_DIR"
  HOST_ENV_DIR=""
}

toml_basic_string() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\x01'/\\u0001}"
  value="${value//$'\x02'/\\u0002}"
  value="${value//$'\x03'/\\u0003}"
  value="${value//$'\x04'/\\u0004}"
  value="${value//$'\x05'/\\u0005}"
  value="${value//$'\x06'/\\u0006}"
  value="${value//$'\x07'/\\u0007}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\x0b'/\\u000b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\x0e'/\\u000e}"
  value="${value//$'\x0f'/\\u000f}"
  value="${value//$'\x10'/\\u0010}"
  value="${value//$'\x11'/\\u0011}"
  value="${value//$'\x12'/\\u0012}"
  value="${value//$'\x13'/\\u0013}"
  value="${value//$'\x14'/\\u0014}"
  value="${value//$'\x15'/\\u0015}"
  value="${value//$'\x16'/\\u0016}"
  value="${value//$'\x17'/\\u0017}"
  value="${value//$'\x18'/\\u0018}"
  value="${value//$'\x19'/\\u0019}"
  value="${value//$'\x1a'/\\u001a}"
  value="${value//$'\x1b'/\\u001b}"
  value="${value//$'\x1c'/\\u001c}"
  value="${value//$'\x1d'/\\u001d}"
  value="${value//$'\x1e'/\\u001e}"
  value="${value//$'\x1f'/\\u001f}"
  value="${value//$'\x7f'/\\u007f}"

  printf '"%s"' "$value"
}

if prepare_agent_host_path; then
  :
else
  exit 1
fi
if [[ -z "$AGENT_HOST_PATH" ]]; then
  echo "Error: selected agent host PATH is empty." >&2
  exit 1
fi
CODEX_PATH_CONFIG="shell_environment_policy.set.PATH=$(toml_basic_string "$AGENT_HOST_PATH")"

if [[ "$GITHUB_ACCESS_MODE" == "disabled" && -n "$ISSUE_NUMBER" && "$SKIP_GITHUB_ISSUE_FETCH" != "1" ]]; then
  die_usage "--issue requires GITHUB_ACCESS_MODE=app unless --skip-issue-fetch is set"
fi

if [[ "$GITHUB_ACCESS_MODE" == "app" && "${AGENT_LAUNCHER_TEST_MODE:-0}" == "1" ]] &&
   ! command -v launcher-test-sleep >/dev/null 2>&1; then
  echo "Error: AGENT_LAUNCHER_TEST_MODE=1 requires launcher-test-sleep on PATH." >&2
  exit 1
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
  local connect_timeout="${5:-}"
  local max_time="${6:-}"
  local timeout_args=()

  if [[ -n "$connect_timeout" && -n "$max_time" ]]; then
    timeout_args=(--connect-timeout "$connect_timeout" --max-time "$max_time")
  fi

  if [[ -n "$body" ]]; then
    curl -sS "${timeout_args[@]}" -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      -d "$body" \
      "$url"
  else
    curl -sS "${timeout_args[@]}" -X "$method" \
      -H "$auth_header" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url"
  fi
}

mint_installation_token_json() {
  local jwt="${1:-}"
  local connect_timeout="${2:-}"
  local max_time="${3:-}"

  if [[ -z "$jwt" ]]; then
    jwt="$(jwt_mint "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY_PATH")" || return 1
  fi
  github_api \
    "Authorization: Bearer ${jwt}" \
    POST \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" \
    "" \
    "$connect_timeout" \
    "$max_time"
}

atomic_publish() {
  local destination="$1"
  local mode="$2"
  local contents="$3"
  local temporary_file

  temporary_file="$(mktemp "${destination}.tmp.XXXXXX")" || return 1
  if ! printf '%s' "$contents" > "$temporary_file" ||
     ! chmod "$mode" "$temporary_file" ||
     ! mv -f "$temporary_file" "$destination"; then
    rm -f "$temporary_file"
    return 1
  fi
}

METADATA_GENERATION=""
METADATA_PUBLISHED_AT=""

read_current_token_metadata() {
  local file="${1:-$CURRENT_TOKEN_META_FILE}"
  local key value generation="" published_at="" generation_seen=0 published_seen=0

  [[ -f "$file" && -s "$file" ]] || return 1
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      generation)
        [[ "$generation_seen" -eq 0 ]] || return 1
        generation="$value"
        generation_seen=1
        ;;
      published_at_epoch)
        [[ "$published_seen" -eq 0 ]] || return 1
        published_at="$value"
        published_seen=1
        ;;
      *) return 1 ;;
    esac
  done < "$file"

  [[ "$generation" =~ ^[0-9]+$ && "$generation" -ge 1 ]] || return 1
  [[ "$published_at" =~ ^[0-9]+$ ]] || return 1
  METADATA_GENERATION="$generation"
  METADATA_PUBLISHED_AT="$published_at"
}

current_token_is_fresh() {
  local current age

  [[ -f "$CURRENT_TOKEN_FILE" && -s "$CURRENT_TOKEN_FILE" ]] || return 1
  read_current_token_metadata || return 1
  current="$(now_epoch)"
  [[ "$current" =~ ^[0-9]+$ && "$current" -ge "$METADATA_PUBLISHED_AT" ]] || return 1
  age=$((current - METADATA_PUBLISHED_AT))
  [[ "$age" -lt "$GITHUB_REFRESH_INTERVAL_SECONDS" ]]
}

seconds_until_token_stale() {
  local current age remaining

  if ! current_token_is_fresh; then
    printf '0\n'
    return 0
  fi
  current="$(now_epoch)"
  age=$((current - METADATA_PUBLISHED_AT))
  remaining=$((GITHUB_REFRESH_INTERVAL_SECONDS - age))
  ((remaining > 0)) || remaining=0
  printf '%s\n' "$remaining"
}

publish_token_and_metadata() {
  local token="$1"
  local generation="$2"
  local published_at="$3"
  local temporary_token_file temporary_metadata_file previous_token_file=""

  [[ -n "$token" ]] || return 1
  [[ "$generation" =~ ^[0-9]+$ && "$generation" -ge 1 ]] || return 1
  [[ "$published_at" =~ ^[0-9]+$ ]] || return 1
  temporary_token_file="$(mktemp "${CURRENT_TOKEN_FILE}.tmp.XXXXXX")" || return 1
  temporary_metadata_file="$(mktemp "${CURRENT_TOKEN_META_FILE}.tmp.XXXXXX")" || {
    rm -f "$temporary_token_file"
    return 1
  }

  if ! printf '%s' "$token" > "$temporary_token_file" ||
     ! chmod 600 "$temporary_token_file" ||
     ! printf 'generation=%s\npublished_at_epoch=%s\n' "$generation" "$published_at" > "$temporary_metadata_file" ||
     ! chmod 600 "$temporary_metadata_file"; then
    rm -f "$temporary_token_file" "$temporary_metadata_file"
    return 1
  fi

  if [[ -f "$CURRENT_TOKEN_FILE" ]]; then
    previous_token_file="$(mktemp "${CURRENT_TOKEN_FILE}.previous.XXXXXX")" || {
      rm -f "$temporary_token_file" "$temporary_metadata_file"
      return 1
    }
    if ! cp "$CURRENT_TOKEN_FILE" "$previous_token_file" || ! chmod 600 "$previous_token_file"; then
      rm -f "$temporary_token_file" "$temporary_metadata_file" "$previous_token_file"
      return 1
    fi
  fi

  # Publish credential bytes before freshness evidence. A concurrent reader may
  # conservatively see a new token with old metadata, never the reverse.
  if ! mv -f "$temporary_token_file" "$CURRENT_TOKEN_FILE"; then
    rm -f "$temporary_token_file" "$temporary_metadata_file" "$previous_token_file"
    return 1
  fi
  if ! mv -f "$temporary_metadata_file" "$CURRENT_TOKEN_META_FILE"; then
    rm -f "$temporary_metadata_file"
    if [[ -n "$previous_token_file" ]]; then
      mv -f "$previous_token_file" "$CURRENT_TOKEN_FILE" 2>/dev/null || true
    fi
    return 1
  fi
  [[ -z "$previous_token_file" ]] || rm -f "$previous_token_file"
}

publish_renewal_result() {
  local attempt="$1"
  local outcome="$2"
  local generation="$3"
  local completed_at="$4"
  local contents

  printf -v contents 'attempt=%s\noutcome=%s\ngeneration=%s\ncompleted_at_epoch=%s\n' \
    "$attempt" "$outcome" "$generation" "$completed_at"
  atomic_publish "$RENEWAL_RESULT_FILE" 600 "$contents"
}

create_app_session_credentials() {
  SESSION_CREDENTIAL_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex.credentials.XXXXXX")"
  chmod 700 "$SESSION_CREDENTIAL_DIR"

  CURRENT_TOKEN_FILE="${SESSION_CREDENTIAL_DIR}/current-token"
  CURRENT_TOKEN_META_FILE="${SESSION_CREDENTIAL_DIR}/current-token.meta"
  TOKEN_HELPER="${SESSION_CREDENTIAL_DIR}/current-token-helper"
  TMP_ASKPASS="${SESSION_CREDENTIAL_DIR}/git-askpass"
  RENEWAL_PID_FILE="${SESSION_CREDENTIAL_DIR}/renewal-worker.pid"
  RENEWAL_READY_FILE="${SESSION_CREDENTIAL_DIR}/renewal-worker.ready"
  RENEWAL_RESULT_FILE="${SESSION_CREDENTIAL_DIR}/renewal-result"
  SESSION_SHUTDOWN_FILE="${SESSION_CREDENTIAL_DIR}/.shutting-down"
  TMP_GH_CONFIG_DIR="${SESSION_CREDENTIAL_DIR}/gh-config"
  mkdir "$TMP_GH_CONFIG_DIR"
  chmod 700 "$TMP_GH_CONFIG_DIR"

  publish_token_and_metadata "$INSTALL_TOKEN" 1 "$(now_epoch)"
  publish_renewal_result 0 none 1 0

  cat > "$TOKEN_HELPER" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

credential_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
token_file="${credential_dir}/current-token"
metadata_file="${credential_dir}/current-token.meta"
pid_file="${credential_dir}/renewal-worker.pid"
ready_file="${credential_dir}/renewal-worker.ready"
result_file="${credential_dir}/renewal-result"
shutdown_file="${credential_dir}/.shutting-down"
refresh_interval=2700
wait_bound=40

mode="default"
if [[ $# -eq 1 && "$1" == "--force-refresh" ]]; then
  mode="force"
elif [[ $# -ne 0 ]]; then
  echo "Error: unsupported GitHub token helper arguments." >&2
  exit 2
fi

fail() {
  echo "Error: $1" >&2
  exit 1
}

worker_pid() {
  local pid
  [[ -f "$pid_file" && -s "$pid_file" && -f "$ready_file" && ! -e "$shutdown_file" ]] || return 1
  pid="$(cat "$pid_file" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}

META_GENERATION=""
META_PUBLISHED_AT=""
read_metadata() {
  local key value generation="" published_at="" generation_seen=0 published_seen=0
  [[ -f "$metadata_file" && -s "$metadata_file" ]] || return 1
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      generation) [[ "$generation_seen" -eq 0 ]] || return 1; generation="$value"; generation_seen=1 ;;
      published_at_epoch) [[ "$published_seen" -eq 0 ]] || return 1; published_at="$value"; published_seen=1 ;;
      *) return 1 ;;
    esac
  done < "$metadata_file"
  [[ "$generation" =~ ^[0-9]+$ && "$generation" -ge 1 ]] || return 1
  [[ "$published_at" =~ ^[0-9]+$ ]] || return 1
  META_GENERATION="$generation"
  META_PUBLISHED_AT="$published_at"
}

RESULT_ATTEMPT=""
RESULT_OUTCOME=""
RESULT_GENERATION=""
read_result() {
  local key value attempt="" outcome="" generation="" completed=""
  local attempt_seen=0 outcome_seen=0 generation_seen=0 completed_seen=0
  [[ -f "$result_file" && -s "$result_file" ]] || return 1
  while IFS='=' read -r key value || [[ -n "$key$value" ]]; do
    case "$key" in
      attempt) [[ "$attempt_seen" -eq 0 ]] || return 1; attempt="$value"; attempt_seen=1 ;;
      outcome) [[ "$outcome_seen" -eq 0 ]] || return 1; outcome="$value"; outcome_seen=1 ;;
      generation) [[ "$generation_seen" -eq 0 ]] || return 1; generation="$value"; generation_seen=1 ;;
      completed_at_epoch) [[ "$completed_seen" -eq 0 ]] || return 1; completed="$value"; completed_seen=1 ;;
      *) return 1 ;;
    esac
  done < "$result_file"
  [[ "$attempt" =~ ^[0-9]+$ ]] || return 1
  [[ "$outcome" == none || "$outcome" == success || "$outcome" == failure ]] || return 1
  [[ "$generation" =~ ^[0-9]+$ && "$generation" -ge 1 ]] || return 1
  [[ "$completed" =~ ^[0-9]+$ ]] || return 1
  RESULT_ATTEMPT="$attempt"
  RESULT_OUTCOME="$outcome"
  RESULT_GENERATION="$generation"
}

fresh_token() {
  local first_metadata second_metadata token now age
  [[ -f "$token_file" && -s "$token_file" ]] || return 1
  read_metadata || return 1
  first_metadata="${META_GENERATION}:${META_PUBLISHED_AT}"
  token="$(cat "$token_file" 2>/dev/null)" || return 1
  [[ -n "$token" ]] || return 1
  read_metadata || return 1
  second_metadata="${META_GENERATION}:${META_PUBLISHED_AT}"
  [[ "$first_metadata" == "$second_metadata" ]] || return 1
  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ && "$now" -ge "$META_PUBLISHED_AT" ]] || return 1
  age=$((now - META_PUBLISHED_AT))
  [[ "$age" -lt "$refresh_interval" ]] || return 1
  printf '%s\n' "$token"
}

pid="$(worker_pid)" || fail "GitHub credential renewal worker is unavailable."

if [[ "$mode" == "default" ]] && token="$(fresh_token)"; then
  printf '%s\n' "$token"
  exit 0
fi

read_result || fail "GitHub credential renewal state is unavailable."
baseline_attempt="$RESULT_ATTEMPT"
baseline_generation=0
if read_metadata; then
  baseline_generation="$META_GENERATION"
fi
started_at="$(date +%s)"
[[ "$started_at" =~ ^[0-9]+$ ]] || fail "GitHub credential refresh timed out."
deadline=$((started_at + wait_bound))

if [[ "$mode" == "force" ]]; then
  kill -USR2 "$pid" 2>/dev/null || fail "GitHub credential renewal worker is unavailable."
else
  kill -USR1 "$pid" 2>/dev/null || fail "GitHub credential renewal worker is unavailable."
fi

while true; do
  [[ ! -e "$shutdown_file" ]] || fail "GitHub credential session is shutting down."
  pid="$(worker_pid)" || fail "GitHub credential renewal worker is unavailable."

  if [[ "$mode" == "default" ]] && token="$(fresh_token)"; then
    printf '%s\n' "$token"
    exit 0
  fi

  if read_result && [[ "$RESULT_ATTEMPT" -gt "$baseline_attempt" ]]; then
    if [[ "$RESULT_OUTCOME" == failure ]]; then
      fail "GitHub credential renewal failed."
    fi
    if [[ "$mode" == "force" && "$RESULT_OUTCOME" == success && "$RESULT_GENERATION" -gt "$baseline_generation" ]] &&
       token="$(fresh_token)"; then
      printf '%s\n' "$token"
      exit 0
    fi
  fi

  now="$(date +%s)"
  [[ "$now" =~ ^[0-9]+$ ]] || fail "GitHub credential refresh timed out."
  [[ "$now" -lt "$deadline" ]] || fail "GitHub credential refresh timed out."
  sleep 1
done
EOF
  chmod 700 "$TOKEN_HELPER"

  cat > "$TMP_ASKPASS" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

prompt="${1:-}"
credential_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

case "$prompt" in
  *Username*github.com*)
    printf '%s\n' 'x-access-token'
    ;;
  *Password*github.com*)
    exec "${credential_dir}/current-token-helper"
    ;;
  *)
    echo "Error: unsupported askpass prompt." >&2
    exit 1
    ;;
esac
EOF
  chmod 700 "$TMP_ASKPASS"
}

renew_current_token() {
  local next_generation="$1"
  local token_json renewed_token published_at

  token_json="$(
    mint_installation_token_json \
      "" \
      "$GITHUB_RENEWAL_CONNECT_TIMEOUT_SECONDS" \
      "$GITHUB_RENEWAL_HTTP_TIMEOUT_SECONDS" \
      2>/dev/null
  )" || return 1
  renewed_token="$(printf '%s' "$token_json" | jq -r '.token // empty' 2>/dev/null)" || return 1
  [[ -n "$renewed_token" ]] || return 1
  [[ ! -e "$SESSION_SHUTDOWN_FILE" ]] || return 1
  published_at="$(now_epoch)"
  publish_token_and_metadata "$renewed_token" "$next_generation" "$published_at"
}

renewal_wait() {
  local seconds="$1"

  if [[ "${AGENT_LAUNCHER_TEST_MODE:-0}" == "1" ]]; then
    exec launcher-test-sleep "$seconds"
  else
    exec sleep "$seconds"
  fi
}

run_serial_renewal_attempt() {
  local next_generation="$1"
  local mint_pid status

  renew_current_token "$next_generation" &
  mint_pid=$!
  while true; do
    set +e
    wait "$mint_pid"
    status=$?
    set -e
    if [[ "$status" -ge 128 && "$status" -ne 127 ]]; then
      # A reactive signal interrupts Bash's wait without cancelling the bounded
      # HTTP child. Wait again so that request shares this attempt.
      continue
    fi
    return "$status"
  done
}

renewal_worker() {
  local wait_seconds=""
  local wait_pid=""
  local pending_ensure=0 pending_force=0 shutting_down=0 attempt_in_progress=0
  local retry_after_failure=0 attempt=0 generation=1 completed_at
  local request_ensure=0 request_force=0

  worker_stop() {
    shutting_down=1
    if [[ -n "$wait_pid" ]]; then kill -TERM "$wait_pid" 2>/dev/null || true; fi
  }

  worker_ensure() {
    if [[ "$attempt_in_progress" -eq 0 && "$shutting_down" -eq 0 ]]; then
      pending_ensure=1
      if [[ -n "$wait_pid" ]]; then kill -TERM "$wait_pid" 2>/dev/null || true; fi
    fi
  }

  worker_force() {
    if [[ "$attempt_in_progress" -eq 0 && "$shutting_down" -eq 0 ]]; then
      pending_force=1
      pending_ensure=0
      if [[ -n "$wait_pid" ]]; then kill -TERM "$wait_pid" 2>/dev/null || true; fi
    fi
  }

  trap worker_stop INT TERM
  trap worker_ensure USR1
  trap worker_force USR2

  atomic_publish "$RENEWAL_PID_FILE" 600 "$BASHPID"
  atomic_publish "$RENEWAL_READY_FILE" 600 ready

  while true; do
    [[ "$shutting_down" -eq 0 && ! -e "$SESSION_SHUTDOWN_FILE" ]] || break

    if [[ "$retry_after_failure" -eq 1 ]]; then
      wait_seconds="$GITHUB_RETRY_INTERVAL_SECONDS"
    else
      wait_seconds="$(seconds_until_token_stale)"
    fi

    renewal_wait "$wait_seconds" &
    wait_pid=$!
    wait "$wait_pid" 2>/dev/null || true
    wait_pid=""
    [[ "$shutting_down" -eq 0 && ! -e "$SESSION_SHUTDOWN_FILE" ]] || break

    request_force="$pending_force"
    request_ensure="$pending_ensure"
    pending_force=0
    pending_ensure=0
    attempt_in_progress=1

    if [[ "$request_force" -eq 1 ]]; then
      :
    elif [[ "$request_ensure" -eq 1 ]]; then
      if current_token_is_fresh; then
        attempt_in_progress=0
        continue
      fi
    fi

    if read_current_token_metadata && [[ "$METADATA_PUBLISHED_AT" -le "$(now_epoch)" ]]; then
      generation="$METADATA_GENERATION"
    fi
    attempt=$((attempt + 1))

    if run_serial_renewal_attempt "$((generation + 1))"; then
      attempt_in_progress=0
      [[ "$shutting_down" -eq 0 && ! -e "$SESSION_SHUTDOWN_FILE" ]] || break
      generation=$((generation + 1))
      completed_at="$(now_epoch)"
      if publish_renewal_result "$attempt" success "$generation" "$completed_at"; then
        retry_after_failure=0
      else
        echo "Warning: GitHub credential renewal failed; retaining conservative credential freshness state and retrying in 5 minutes." >&2
        retry_after_failure=1
      fi
    else
      attempt_in_progress=0
      [[ "$shutting_down" -eq 0 && ! -e "$SESSION_SHUTDOWN_FILE" ]] || break
      completed_at="$(now_epoch)"
      publish_renewal_result "$attempt" failure "$generation" "$completed_at" || true
      echo "Warning: GitHub credential renewal failed; retaining the current session token and retrying in 5 minutes." >&2
      retry_after_failure=1
    fi
  done
}

start_renewal_worker() {
  local polls=0 published_pid

  renewal_worker &
  RENEWAL_PID=$!
  while [[ "$polls" -lt 50 ]]; do
    if ! kill -0 "$RENEWAL_PID" 2>/dev/null; then
      echo "Error: GitHub credential renewal worker exited before becoming ready." >&2
      return 1
    fi
    if [[ -s "$RENEWAL_PID_FILE" && -s "$RENEWAL_READY_FILE" ]]; then
      published_pid="$(cat "$RENEWAL_PID_FILE" 2>/dev/null || true)"
      if [[ "$published_pid" == "$RENEWAL_PID" ]]; then
        return 0
      fi
    fi
    sleep 0.1
    polls=$((polls + 1))
  done

  echo "Error: GitHub credential renewal worker did not become ready within ${GITHUB_WORKER_READY_WAIT_SECONDS} seconds." >&2
  stop_renewal_worker
  return 1
}

stop_renewal_worker() {
  if [[ -n "$RENEWAL_PID" ]]; then
    kill -TERM "$RENEWAL_PID" 2>/dev/null || true
    wait "$RENEWAL_PID" 2>/dev/null || true
    RENEWAL_PID=""
  fi
}

unset JWT TOKEN_JSON

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

  TOKEN_JSON="$(mint_installation_token_json "$JWT")"

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

unset JWT TOKEN_JSON

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
- App mode provides repository write capability for this session.
- Autonomous implementation of a supplied issue may activate the repository publication contract in AGENTS.md, including commit, push, pull-request publication, and verification when required.
- Issue context alone does not require publication, and App mode alone does not require publication; determine the working mode from the task, human instructions, and repository state.
- Use shell tools for GitHub operations.
- Prefer git, gh, and curl with the launcher-managed session credentials.
- Git authentication obtains a freshness-aware credential automatically through GIT_ASKPASS.
- For gh and direct GitHub API operations, obtain the authoritative freshness-aware token from "\$AGENT_GITHUB_TOKEN_HELPER" before each operation; launch-time GH_TOKEN, GITHUB_TOKEN, and INSTALL_TOKEN values are compatibility values only.
- If and only if a helper-derived credential receives a clear authentication failure such as HTTP 401 or an explicit invalid/expired-credential response, obtain one replacement with "\$AGENT_GITHUB_TOKEN_HELPER --force-refresh" and retry the exact same operation once.
- HTTP 403, HTTP 404, permission or policy failures, rate limits, network failures, and generic command failures are not sufficient evidence for forced refresh.
- If the exact retry fails, stop. Do not refresh again, change the operation, seek GitHub App source credentials, or use ambient developer credentials.
- GitHub App source credentials remain launcher-only; the helper can request bounded renewal but cannot mint credentials independently.
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
if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
  echo "GitHub credential renewal: launcher-managed"
  echo "GitHub credential refresh interval: 45 minutes"
fi
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
echo "Agent host environment: ${AGENT_HOST_ENV_SOURCE}"
echo "Agent host PATH: preserved for Codex shell commands"
if [[ "$DEBUG_CODEX_PROMPT" == "1" && -z "$RESUME_SESSION" ]]; then
  echo "Debug prompt saved to: ${DEBUG_PROMPT_PATH}"
fi
if [[ -n "$DEVELOPER_NAME" || -n "$DEVELOPER_EMAIL" ]]; then
  echo "Launched by: ${DEVELOPER_NAME:-unknown} ${DEVELOPER_EMAIL:+<$DEVELOPER_EMAIL>}"
fi

CODEX_ENV=()
unset AGENT_GITHUB_TOKEN_HELPER

if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
  create_app_session_credentials

  CODEX_ENV=(
    "PATH=$AGENT_HOST_PATH"
    "GITHUB_TOKEN=$INSTALL_TOKEN"
    "GH_TOKEN=$INSTALL_TOKEN"
    "GITHUB_PAT="
    "GH_CONFIG_DIR=$TMP_GH_CONFIG_DIR"
    "INSTALL_TOKEN=$INSTALL_TOKEN"
    "AGENT_GITHUB_TOKEN_HELPER=$TOKEN_HELPER"
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
  TMP_GH_CONFIG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex.gh.XXXXXX")"
  chmod 700 "$TMP_GH_CONFIG_DIR"

  CODEX_ENV=(
    "PATH=$AGENT_HOST_PATH"
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

if [[ "$GITHUB_ACCESS_MODE" == "app" ]]; then
  start_renewal_worker
fi

unset GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH
unset JWT TOKEN_JSON
unset AGENT_LAUNCHER_TEST_MODE FAKE_RENEWAL_CONTROL_DIR
unset FAKE_TOKEN_SEQUENCE_JSON FAKE_TOKEN_ATTEMPT_FILE FAKE_LAUNCHER_CLOCK

if [[ -n "$RESUME_SESSION" ]]; then
  CODEX_STATUS=0
  run_codex resume "$RESUME_SESSION" "${CODEX_ARGS[@]}" || CODEX_STATUS=$?
  exit "$CODEX_STATUS"
fi

CODEX_STATUS=0
run_codex "${CODEX_ARGS[@]}" "$PROMPT_CONTENT" || CODEX_STATUS=$?
exit "$CODEX_STATUS"
