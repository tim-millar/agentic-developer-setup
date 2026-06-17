#!/usr/bin/env bash
set -euo pipefail

# Mint a short-lived GitHub App installation token for the current repo workflow.
#
# Typical usage:
#
#   GH_TOKEN="$(scripts/mint_gh_app_token.sh)"
#   export GITHUB_TOKEN="$GH_TOKEN"
#
# or:
#
#   GH_TOKEN="$(scripts/mint_gh_app_token.sh)" gh issue view 123
#
# To print the token expiry time to stderr as a convenience:
#
#   GH_TOKEN="$(scripts/mint_gh_app_token.sh --expires)"
#
# Required environment variables:
#   GITHUB_APP_ID
#   GITHUB_APP_INSTALLATION_ID
#   GITHUB_APP_PRIVATE_KEY_PATH

: "${GITHUB_APP_ID:?Set GITHUB_APP_ID (numeric App ID)}"
: "${GITHUB_APP_INSTALLATION_ID:?Set GITHUB_APP_INSTALLATION_ID (numeric installation ID)}"
: "${GITHUB_APP_PRIVATE_KEY_PATH:?Set GITHUB_APP_PRIVATE_KEY_PATH (path to .pem private key)}"

PRINT_EXPIRES="0"
if [[ "${1:-}" == "--expires" ]]; then
  PRINT_EXPIRES="1"
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Error: required command not found: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd jq
require_cmd openssl
require_cmd date

require_numeric_env() {
  local name="$1"
  local value="$2"

  if ! [[ "$value" =~ ^[0-9]+$ ]]; then
    echo "Error: $name must be numeric, got: $value" >&2
    exit 1
  fi
}

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

b64url() {
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now_epoch() {
  date +%s
}

mint_jwt() {
  local app_id="$1"
  local pem_path="$2"
  local now iat exp header payload unsigned signature

  now="$(now_epoch)"
  iat="$((now - 60))" # Backdate slightly to tolerate small clock skew
  exp="$((now + 540))" # 9 minutes from now, safely within GitHub's 10 minute limit

  header='{"alg":"RS256","typ":"JWT"}'
  payload="$(printf '{"iat":%s,"exp":%s,"iss":%s}' "$iat" "$exp" "$app_id")"

  unsigned="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
  signature="$(printf '%s' "$unsigned" | openssl dgst -sha256 -sign "$pem_path" | b64url)"

  printf '%s.%s\n' "$unsigned" "$signature"
}

JWT="$(mint_jwt "$GITHUB_APP_ID" "$GITHUB_APP_PRIVATE_KEY_PATH")"

TOKEN_JSON="$(
  curl -fsSL \
    -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens"
)"

INSTALL_TOKEN="$(printf '%s' "$TOKEN_JSON" | jq -r '.token // empty')"
EXPIRES_AT="$(printf '%s' "$TOKEN_JSON" | jq -r '.expires_at // empty')"

if [[ -z "$INSTALL_TOKEN" ]]; then
  echo "Error: failed to mint installation token." >&2
  echo "Response (token removed if present):" >&2
  printf '%s' "$TOKEN_JSON" | jq 'del(.token)' >&2 || true
  exit 1
fi

if [[ "$PRINT_EXPIRES" == "1" && -n "$EXPIRES_AT" ]]; then
  echo "GitHub App token expires at: $EXPIRES_AT" >&2
fi

printf '%s' "$INSTALL_TOKEN"
