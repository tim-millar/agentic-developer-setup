#!/bin/bash
set -u
unset BASH_ENV ENV CDPATH
case $- in *p*) ;; *) printf '%s\n' 'claude-explore installer: trusted Bash privileged mode is required' >&2; exit 1 ;; esac
umask 077
ORIGINAL_PATH=${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { printf 'claude-explore installer: %s\n' "$1" >&2; exit "${2:-1}"; }
contains_control_character() { printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; }
if [ -x /usr/bin/realpath ]; then REALPATH_BIN=/usr/bin/realpath
elif [ -x /bin/realpath ]; then REALPATH_BIN=/bin/realpath
else die "required executable is unavailable: realpath"
fi
SCRIPT_REAL=$($REALPATH_BIN "${BASH_SOURCE[0]}" 2>/dev/null) || die "cannot resolve installer source"
SOURCE_ROOT=$(dirname "$(dirname "$SCRIPT_REAL")")
POLICY_FILE=$SOURCE_ROOT/policy.sh
[ -f "$POLICY_FILE" ] && [ ! -L "$POLICY_FILE" ] || die "source policy is missing or unsafe"
case "$($REALPATH_BIN "$POLICY_FILE")" in "$SOURCE_ROOT"/*) ;; *) die "source policy resolves outside runtime" ;; esac
# shellcheck disable=SC1090 -- validated framework-owned source.
. "$POLICY_FILE"

case "$(uname -s)" in Darwin) PLATFORM=macos ;; Linux) PLATFORM=linux ;; *) die "unsupported platform; expected macOS or Linux" ;; esac
[ "$BASH_VERSINFO" -gt 3 ] || { [ "$BASH_VERSINFO" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; } || die "/bin/bash >= 3.2 is required"

file_mode() { if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi; }
file_uid() { if stat -f '%u' "$1" >/dev/null 2>&1; then stat -f '%u' "$1"; else stat -c '%u' "$1"; fi; }
safe_dir() { [ -d "$1" ] && [ ! -L "$1" ] && [ "$(file_uid "$1")" = "$(id -u)" ] && [ $((8#$(file_mode "$1") & 022)) -eq 0 ]; }
safe_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_uid "$1")" = "$(id -u)" ] && [ $((8#$(file_mode "$1") & 022)) -eq 0 ] && [ ! -x "$1" ]; }
safe_executable() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(file_uid "$1")" = "$(id -u)" ] && [ $((8#$(file_mode "$1") & 022)) -eq 0 ] && [ -x "$1" ]; }

safe_path_ancestors() {
  local path=$1 parent uid mode
  parent=$($REALPATH_BIN "$(dirname "$path")" 2>/dev/null) || return 1
  while :; do
    [ -d "$parent" ] || return 1
    uid=$(file_uid "$parent" 2>/dev/null) || return 1
    [ "$uid" = 0 ] || [ "$uid" = "$(id -u)" ] || return 1
    mode=$(file_mode "$parent" 2>/dev/null) || return 1
    [ $((8#$mode & 022)) -eq 0 ] || { [ "$uid" = 0 ] && [ $((8#$mode & 01000)) -ne 0 ]; } || return 1
    [ "$parent" = / ] && break
    parent=$(dirname "$parent")
  done
}

version_at_least() {
  local have=$1 need=$2 old_ifs=$IFS h1 h2 h3 n1 n2 n3
  IFS=.; set -- $have; h1=${1:-0}; h2=${2:-0}; h3=${3:-0}; set -- $need; n1=${1:-0}; n2=${2:-0}; n3=${3:-0}; IFS=$old_ifs
  [ "$h1" -gt "$n1" ] || { [ "$h1" -eq "$n1" ] && { [ "$h2" -gt "$n2" ] || { [ "$h2" -eq "$n2" ] && [ "$h3" -ge "$n3" ]; }; }; }
}

function_environment_names() { /usr/bin/env | sed -n 's/^\(BASH_FUNC_[^=]*%%\)=.*/\1/p'; }

validate_claude_launcher() {
  local launcher=$1 target output mode name; local -a scrub_args
  contains_control_character "$launcher" && die "Claude launcher path contains a control character"
  case "$launcher" in /*) ;; *) die "Claude launcher path must be absolute" ;; esac
  [ -e "$launcher" ] || die "Claude launcher does not exist"
  safe_path_ancestors "$launcher" || die "Claude launcher path hierarchy is unsafe"
  target=$($REALPATH_BIN "$launcher" 2>/dev/null) || die "Claude launcher cannot be resolved (possible symlink loop)"
  case "$target" in "$SOURCE_ROOT"/*|"$DATA_ROOT_REAL"/*) die "Claude launcher recurses into claude-explore" ;; esac
  [ -f "$target" ] && [ -x "$target" ] || die "Claude target is not an executable regular file"
  safe_path_ancestors "$target" || die "Claude target path hierarchy is unsafe"
  name=$(file_uid "$target") || die "cannot inspect Claude target owner"
  [ "$name" = 0 ] || [ "$name" = "$(id -u)" ] || die "Claude target has an untrusted owner"
  mode=$(file_mode "$target") || die "cannot inspect Claude target"
  [ $((8#$mode & 022)) -eq 0 ] || die "Claude target is group/world writable"
  scrub_args=(-u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH)
  while IFS= read -r name; do scrub_args+=( -u "$name" ); done <<EOF
$CLAUDE_EXPLORE_ENV_UNSET
EOF
  while IFS= read -r name; do scrub_args+=( -u "$name" ); done < <(function_environment_names)
  output=$(/usr/bin/env "${scrub_args[@]}" "$target" --version 2>/dev/null) || die "Claude version command failed"
  CLAUDE_VERSION=$(printf '%s\n' "$output" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p' | head -n 1)
  [ -n "$CLAUDE_VERSION" ] || die "could not parse Claude Code version"
  version_at_least "$CLAUDE_VERSION" "$CLAUDE_EXPLORE_MINIMUM_CLIENT_VERSION" || die "Claude Code $CLAUDE_VERSION is below required $CLAUDE_EXPLORE_MINIMUM_CLIENT_VERSION"
  CLAUDE_LAUNCHER=$launcher
  CLAUDE_TARGET=$target
}

ensure_private_dir() {
  local path=$1 parent
  if [ -e "$path" ]; then safe_dir "$path" || die "destination directory is unsafe: $path"; return; fi
  parent=$(dirname "$path")
  [ -d "$parent" ] || mkdir -p "$parent" || die "cannot create parent directory"
  [ ! -L "$parent" ] || die "destination parent is a symlink"
  mkdir "$path" || die "cannot create destination directory: $path"
  chmod 700 "$path" || die "cannot protect destination directory"
}

read_existing_metadata() {
  local line key value count=0 schema= runtime_id= runtime_version= policy_version= launcher= revision=
  safe_file "$METADATA_FILE" || die "existing installation metadata is unsafe"
  [ "$(file_mode "$METADATA_FILE")" = 600 ] || die "existing installation metadata mode must be 0600"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) die "existing installation metadata is malformed" ;; esac
    key=${line%%=*}; value=${line#*=}; [ -n "$value" ] || die "existing installation metadata contains an empty value"
    contains_control_character "$value" && die "existing installation metadata contains an unsafe value"
    case "$key" in
      schema_version) [ -z "$schema" ] || die "duplicate metadata field"; schema=$value ;;
      runtime_id) [ -z "$runtime_id" ] || die "duplicate metadata field"; runtime_id=$value ;;
      runtime_version) [ -z "$runtime_version" ] || die "duplicate metadata field"; runtime_version=$value ;;
      policy_version) [ -z "$policy_version" ] || die "duplicate metadata field"; policy_version=$value ;;
      claude_launcher_path) [ -z "$launcher" ] || die "duplicate metadata field"; launcher=$value ;;
      source_framework_revision) [ -z "$revision" ] || die "duplicate metadata field"; revision=$value ;;
      *) die "unknown existing installation metadata field" ;;
    esac
    count=$((count + 1))
  done < "$METADATA_FILE"
  [ "$count" -eq 6 ] && [ "$schema" = 1 ] && [ "$runtime_id" = "$CLAUDE_EXPLORE_RUNTIME_ID" ] || die "existing installation metadata does not match this runtime"
  case "$runtime_version:$policy_version" in *[!0-9:]*|:|*:|0:*|*:0) die "existing installation metadata has invalid versions" ;; esac
  case "$launcher" in /*) ;; *) die "existing Claude launcher path is not absolute" ;; esac
  EXISTING_CLAUDE_LAUNCHER=$launcher
}

preflight_destination() {
  local version_dir=$VERSIONS_ROOT/$CLAUDE_EXPLORE_RUNTIME_VERSION resolved
  if [ -e "$version_dir" ]; then safe_dir "$version_dir" || die "existing runtime version is unsafe"; fi
  if [ -L "$CURRENT_LINK" ]; then
    resolved=$($REALPATH_BIN "$CURRENT_LINK" 2>/dev/null) || die "active runtime link is broken"
    case "$resolved" in "$VERSIONS_ROOT_REAL"/*) ;; *) die "active runtime link has ambiguous ownership" ;; esac
  elif [ -e "$CURRENT_LINK" ]; then die "active runtime path collision"
  fi
  if [ -L "$STABLE_LAUNCHER" ]; then
    resolved=$($REALPATH_BIN "$STABLE_LAUNCHER" 2>/dev/null) || die "stable launcher link is broken"
    case "$resolved" in "$DATA_ROOT_REAL"/*) ;; *) die "stable launcher symlink is not framework-owned" ;; esac
  elif [ -e "$STABLE_LAUNCHER" ]; then die "stable launcher path already exists and is not framework-owned"
  fi
  if [ -e "$METADATA_FILE" ]; then read_existing_metadata; fi
}

stage_metadata() {
  STAGED_METADATA=$CONFIG_ROOT/.install.meta.tmp.$$
  {
    printf 'schema_version=1\n'
    printf 'runtime_id=%s\n' "$CLAUDE_EXPLORE_RUNTIME_ID"
    printf 'runtime_version=%s\n' "$CLAUDE_EXPLORE_RUNTIME_VERSION"
    printf 'policy_version=%s\n' "$CLAUDE_EXPLORE_POLICY_VERSION"
    printf 'claude_launcher_path=%s\n' "$CLAUDE_LAUNCHER"
    printf 'source_framework_revision=unknown\n'
  } > "$STAGED_METADATA" || die "cannot stage installation metadata"
  chmod 600 "$STAGED_METADATA" || die "cannot protect installation metadata"
}

validate_source() {
  local path
  for path in bin/claude-explore lib/claude_explore_runtime.sh lib/claude_explore_guard.sh; do
    safe_executable "$SOURCE_ROOT/$path" || die "source executable runtime is incomplete or unsafe: $path"
    case "$($REALPATH_BIN "$SOURCE_ROOT/$path")" in "$SOURCE_ROOT"/*) ;; *) die "source file resolves outside runtime: $path" ;; esac
  done
  safe_file "$SOURCE_ROOT/policy.sh" || die "source policy is incomplete or unsafe"
}

stage_runtime() {
  STAGE=$(mktemp -d "$DATA_ROOT/.stage.XXXXXX") || die "cannot create private staging directory"
  chmod 700 "$STAGE" || die "cannot protect private staging directory"
  mkdir "$STAGE/bin" "$STAGE/lib" || die "cannot build staged runtime"
  cp "$SOURCE_ROOT/bin/claude-explore" "$STAGE/bin/claude-explore" || die "cannot stage runtime launcher"
  cp "$SOURCE_ROOT/lib/claude_explore_runtime.sh" "$STAGE/lib/claude_explore_runtime.sh" || die "cannot stage runtime library"
  cp "$SOURCE_ROOT/lib/claude_explore_guard.sh" "$STAGE/lib/claude_explore_guard.sh" || die "cannot stage guard"
  cp "$SOURCE_ROOT/policy.sh" "$STAGE/policy.sh" || die "cannot stage policy"
  chmod 700 "$STAGE/bin/claude-explore" "$STAGE/lib/claude_explore_runtime.sh" "$STAGE/lib/claude_explore_guard.sh" || die "cannot protect executable runtime files"
  chmod 600 "$STAGE/policy.sh" || die "cannot protect policy"
  /bin/sh -n "$STAGE/bin/claude-explore" "$STAGE/lib/claude_explore_guard.sh" && \
    /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc -p -n "$STAGE/lib/claude_explore_runtime.sh" "$STAGE/policy.sh" || {
      rm -rf "$STAGE"; rm -f "${STAGED_METADATA:-}"; die "staged runtime failed syntax validation";
    }
}

rollback_activation() {
  [ "$METADATA_ACTIVATED" -eq 0 ] || rm -f "$METADATA_FILE"
  [ ! -e "$BACKUP_METADATA" ] || mv "$BACKUP_METADATA" "$METADATA_FILE"
  [ "$LAUNCHER_ACTIVATED" -eq 0 ] || rm -f "$STABLE_LAUNCHER"
  [ ! -L "$BACKUP_LAUNCHER" ] || mv "$BACKUP_LAUNCHER" "$STABLE_LAUNCHER"
  [ "$CURRENT_ACTIVATED" -eq 0 ] || rm -f "$CURRENT_LINK"
  [ ! -L "$BACKUP_CURRENT" ] || mv "$BACKUP_CURRENT" "$CURRENT_LINK"
  [ "$VERSION_ACTIVATED" -eq 0 ] || rm -rf "$ACTIVATION_VERSION_DIR"
  [ ! -d "$BACKUP_VERSION" ] || mv "$BACKUP_VERSION" "$ACTIVATION_VERSION_DIR"
  [ -z "$STAGED_CURRENT" ] || rm -f "$STAGED_CURRENT"
  [ -z "$STAGED_LAUNCHER" ] || rm -f "$STAGED_LAUNCHER"
  [ -z "$STAGED_METADATA" ] || rm -f "$STAGED_METADATA"
  [ -z "$STAGE" ] || [ ! -d "$STAGE" ] || rm -rf "$STAGE"
}

activation_fail() {
  local message=$1
  rollback_activation
  die "$message"
}

activate_transaction() {
  ACTIVATION_VERSION_DIR=$VERSIONS_ROOT/$CLAUDE_EXPLORE_RUNTIME_VERSION
  BACKUP_VERSION=$DATA_ROOT/.previous.version.$$
  BACKUP_CURRENT=$DATA_ROOT/.previous.current.$$
  BACKUP_LAUNCHER=$BIN_ROOT/.previous.claude-explore.$$
  BACKUP_METADATA=$CONFIG_ROOT/.previous.install.meta.$$
  STAGED_CURRENT=$DATA_ROOT/.current.$$
  STAGED_LAUNCHER=$BIN_ROOT/.claude-explore.$$
  VERSION_ACTIVATED=0 CURRENT_ACTIVATED=0 LAUNCHER_ACTIVATED=0 METADATA_ACTIVATED=0

  ln -s "$ACTIVATION_VERSION_DIR" "$STAGED_CURRENT" || activation_fail "cannot stage active runtime link"
  ln -s "$CURRENT_LINK/bin/claude-explore" "$STAGED_LAUNCHER" || activation_fail "cannot stage stable launcher"

  if [ -e "$ACTIVATION_VERSION_DIR" ]; then
    safe_dir "$ACTIVATION_VERSION_DIR" || activation_fail "existing runtime version is unsafe"
    mv "$ACTIVATION_VERSION_DIR" "$BACKUP_VERSION" || activation_fail "cannot preserve existing runtime version"
  fi
  mv "$STAGE" "$ACTIVATION_VERSION_DIR" || activation_fail "cannot activate staged runtime"
  STAGE=; VERSION_ACTIVATED=1

  [ ! -L "$CURRENT_LINK" ] || mv "$CURRENT_LINK" "$BACKUP_CURRENT" || activation_fail "cannot preserve active runtime link"
  mv "$STAGED_CURRENT" "$CURRENT_LINK" || activation_fail "cannot activate runtime link"
  STAGED_CURRENT=; CURRENT_ACTIVATED=1

  [ ! -L "$STABLE_LAUNCHER" ] || mv "$STABLE_LAUNCHER" "$BACKUP_LAUNCHER" || activation_fail "cannot preserve stable launcher"
  mv "$STAGED_LAUNCHER" "$STABLE_LAUNCHER" || activation_fail "cannot activate stable launcher"
  STAGED_LAUNCHER=; LAUNCHER_ACTIVATED=1

  [ ! -e "$METADATA_FILE" ] || mv "$METADATA_FILE" "$BACKUP_METADATA" || activation_fail "cannot preserve installation metadata"
  mv "$STAGED_METADATA" "$METADATA_FILE" || activation_fail "cannot activate installation metadata"
  STAGED_METADATA=; METADATA_ACTIVATED=1

  rm -rf "$BACKUP_VERSION"
  rm -f "$BACKUP_CURRENT" "$BACKUP_LAUNCHER" "$BACKUP_METADATA"
}

install_or_upgrade() {
  validate_source
  ensure_private_dir "$DATA_ROOT"; ensure_private_dir "$VERSIONS_ROOT"; ensure_private_dir "$CONFIG_ROOT"; ensure_private_dir "$BIN_ROOT"
  DATA_ROOT_REAL=$($REALPATH_BIN "$DATA_ROOT")
  VERSIONS_ROOT_REAL=$($REALPATH_BIN "$VERSIONS_ROOT")
  preflight_destination
  if [ -n "$REQUESTED_CLAUDE" ]; then
    CLAUDE_LAUNCHER=$REQUESTED_CLAUDE
  elif [ "$OPERATION" = upgrade ] && [ -f "$METADATA_FILE" ]; then
    CLAUDE_LAUNCHER=$EXISTING_CLAUDE_LAUNCHER
  else
    CLAUDE_LAUNCHER=$(PATH=$ORIGINAL_PATH command -v claude 2>/dev/null) || die "Claude was not found on the pre-install PATH; use --claude-bin"
  fi
  case "$CLAUDE_LAUNCHER" in /*) ;; *) CLAUDE_LAUNCHER=$(CDPATH= cd -- "$(dirname "$CLAUDE_LAUNCHER")" && pwd -P)/$(basename "$CLAUDE_LAUNCHER") ;; esac
  validate_claude_launcher "$CLAUDE_LAUNCHER"
  stage_metadata; stage_runtime; activate_transaction
  printf 'claude-explore %s %s\n' "$CLAUDE_EXPLORE_RUNTIME_VERSION" "$OPERATION"
  printf 'launcher=%s\nruntime=%s\nclaude_launcher=%s\nclaude_resolved=%s\nclaude_version=%s\npolicy_version=%s\n' "$STABLE_LAUNCHER" "$CURRENT_LINK" "$CLAUDE_LAUNCHER" "$CLAUDE_TARGET" "$CLAUDE_VERSION" "$CLAUDE_EXPLORE_POLICY_VERSION"
  case ":$ORIGINAL_PATH:" in *":$BIN_ROOT:"*) ;; *) printf 'Add %s to PATH manually.\n' "$BIN_ROOT" ;; esac
}

uninstall_runtime() {
  DATA_ROOT_REAL=$($REALPATH_BIN "$DATA_ROOT" 2>/dev/null) || die "runtime data is missing"
  [ -L "$STABLE_LAUNCHER" ] || die "stable launcher is missing or ownership is ambiguous"
  case "$($REALPATH_BIN "$STABLE_LAUNCHER" 2>/dev/null)" in "$DATA_ROOT_REAL"/*) ;; *) die "stable launcher is not framework-owned" ;; esac
  safe_dir "$DATA_ROOT" && safe_dir "$CONFIG_ROOT" || die "installation ownership cannot be proven"
  rm "$STABLE_LAUNCHER" || die "cannot remove stable launcher"
  rm -rf "$DATA_ROOT" "$CONFIG_ROOT" || die "cannot remove framework-owned runtime state"
  printf 'claude-explore uninstalled; Claude, repositories, and Claude settings were preserved.\n'
}

OPERATION=${1:-}; [ "$#" -gt 0 ] && shift
case "$OPERATION" in install|upgrade|uninstall) ;; *) die "usage: install.sh {install|upgrade|uninstall} [--claude-bin ABSOLUTE_PATH]" 2 ;; esac
REQUESTED_CLAUDE=
while [ "$#" -gt 0 ]; do
  case "$1" in --claude-bin) [ "$#" -ge 2 ] || die "--claude-bin requires a value" 2; REQUESTED_CLAUDE=$2; shift 2 ;; *) die "unknown installer argument" 2 ;; esac
done

if [ -n "${XDG_DATA_HOME:-}" ]; then
  case "$XDG_DATA_HOME" in /*) ;; *) die "XDG_DATA_HOME must be absolute" ;; esac
  DATA_ROOT=$XDG_DATA_HOME/agent-development-framework/claude-explore
else
  DATA_ROOT=$HOME/.local/share/agent-development-framework/claude-explore
fi
VERSIONS_ROOT=$DATA_ROOT/versions
CURRENT_LINK=$DATA_ROOT/current
if [ -n "${XDG_CONFIG_HOME:-}" ]; then
  case "$XDG_CONFIG_HOME" in /*) ;; *) die "XDG_CONFIG_HOME must be absolute" ;; esac
  CONFIG_ROOT=$XDG_CONFIG_HOME/agent-development-framework/claude-explore
else
  CONFIG_ROOT=$HOME/.config/agent-development-framework/claude-explore
fi
METADATA_FILE=$CONFIG_ROOT/install.meta
BIN_ROOT=$HOME/.local/bin
STABLE_LAUNCHER=$BIN_ROOT/claude-explore

for install_path in "$HOME" "$DATA_ROOT" "$CONFIG_ROOT" "$BIN_ROOT"; do
  contains_control_character "$install_path" && die "installation path contains a control character"
done

case "$OPERATION" in install|upgrade) install_or_upgrade ;; uninstall) uninstall_runtime ;; esac
