#!/bin/bash
set -u
unset BASH_ENV ENV CDPATH
case $- in *p*) ;; *) printf '%s\n' 'ads-claude-explore installer: trusted Bash privileged mode is required' >&2; exit 1 ;; esac
umask 077
ORIGINAL_PATH=${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
PATH=/usr/bin:/bin:/usr/sbin:/sbin

die() { printf 'ads-claude-explore installer: %s\n' "$1" >&2; exit "${2:-1}"; }
contains_control_character() { printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'; }
if [ -x /usr/bin/realpath ]; then REALPATH_BIN=/usr/bin/realpath
elif [ -x /bin/realpath ]; then REALPATH_BIN=/bin/realpath
else die "required executable is unavailable: realpath"
fi
SCRIPT_REAL=$($REALPATH_BIN "${BASH_SOURCE[0]}" 2>/dev/null) || die "cannot resolve installer source"
SOURCE_ROOT=$(dirname "$(dirname "$SCRIPT_REAL")")
OUTCOME_SOURCE=$($REALPATH_BIN "$SOURCE_ROOT/lib/agent_run_outcomes.sh" 2>/dev/null) || die "cannot resolve outcome reconciler source"
case "$OUTCOME_SOURCE" in "$SOURCE_ROOT"/*) ;; *) die "outcome reconciler source resolves outside runtime" ;; esac
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

# Names are reserved managed entrypoints, not vendor launchers. Check both the
# selected stable path and its resolved target without executing either wrapper.
reject_managed_claude() {
  case "${1##*/}:${2##*/}" in
    claude-explore:*|ads-claude-explore:*|paf-claude-explore:*|*:claude-explore|*:ads-claude-explore|*:paf-claude-explore)
      die "Claude launcher is a managed wrapper, not vendor Claude" ;;
  esac
}

validate_claude_launcher() {
  local launcher=$1 target output mode name; local -a scrub_args
  contains_control_character "$launcher" && die "Claude launcher path contains a control character"
  case "$launcher" in /*) ;; *) die "Claude launcher path must be absolute" ;; esac
  [ -e "$launcher" ] || die "Claude launcher does not exist"
  safe_path_ancestors "$launcher" || die "Claude launcher path hierarchy is unsafe"
  target=$($REALPATH_BIN "$launcher" 2>/dev/null) || die "Claude launcher cannot be resolved (possible symlink loop)"
  case "$target" in "$SOURCE_ROOT"/*|"$DATA_ROOT_REAL"/*) die "Claude launcher recurses into claude-explore" ;; esac
  reject_managed_claude "$launcher" "$target"
  [ -f "$target" ] && [ -x "$target" ] || die "Claude target is not an executable regular file"
  safe_path_ancestors "$target" || die "Claude target path hierarchy is unsafe"
  name=$(file_uid "$target") || die "cannot inspect Claude target owner"
  [ "$name" = 0 ] || [ "$name" = "$(id -u)" ] || die "Claude target has an untrusted owner"
  mode=$(file_mode "$target") || die "cannot inspect Claude target"
  [ $((8#$mode & 022)) -eq 0 ] || die "Claude target is group/world writable"
  scrub_args=(-u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH -u AGENT_TELEMETRY -u AGENT_TELEMETRY_DIR)
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
  if [ -e "$path" ] || [ -L "$path" ]; then safe_dir "$path" || die "destination directory is unsafe: $path"; return; fi
  parent=$(dirname "$path")
  local existing=$parent
  while [ ! -e "$existing" ] && [ ! -L "$existing" ]; do existing=$(dirname "$existing"); done
  [ -d "$existing" ] && safe_path_ancestors "$existing/child" || die "destination path hierarchy is unsafe: $path"
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
  case "$runtime_version" in ''|*[!0-9]*|0) die "existing installation metadata has invalid versions" ;; esac
  case "$policy_version" in ''|*[!0-9]*|0) die "existing installation metadata has invalid versions" ;; esac
  EXISTING_RUNTIME_VERSION=$runtime_version
  EXISTING_POLICY_VERSION=$policy_version
  case "$launcher" in /*) ;; *) die "existing Claude launcher path is not absolute" ;; esac
  EXISTING_CLAUDE_LAUNCHER=$launcher
}

# Classify only positively proven ADS state. A fresh install may coexist with
# an unrelated generic command, but an existing installation must be consistent
# before either public entrypoint or shared state is mutated.
verify_owned_launcher() {
  local path=$1 name=$2 resolved
  [ -L "$path" ] || die "stable launcher path already exists and is not framework-owned: $path"
  [ "$(file_uid "$path")" = "$(id -u)" ] || die "stable launcher owner is unsafe: $path"
  [ "$(readlink "$path")" = "$CURRENT_LINK/bin/$name" ] || die "stable launcher symlink is not framework-owned: $path"
  resolved=$($REALPATH_BIN "$path" 2>/dev/null) || die "stable launcher link is broken: $path"
  [ "$resolved" = "$EXISTING_VERSION_DIR/bin/$name" ] &&
    safe_executable "$EXISTING_VERSION_DIR/bin/$name" || die "stable launcher target is unsafe: $path"
}

preflight_destination() {
  local path resolved version_dir=$VERSIONS_ROOT/$CLAUDE_EXPLORE_RUNTIME_VERSION
  LEGACY_OWNED=0 QUALIFIED_OWNED=0 EXISTING_INSTALL=0
  for path in "$DATA_ROOT" "$VERSIONS_ROOT" "$CONFIG_ROOT" "$BIN_ROOT"; do
    safe_dir "$path" && safe_path_ancestors "$path/child" || die "installation directory or hierarchy is unsafe: $path"
  done
  if [ -e "$version_dir" ] || [ -L "$version_dir" ]; then
    safe_dir "$version_dir" || die "existing runtime version is unsafe"
  fi
  if [ -e "$METADATA_FILE" ] || [ -L "$METADATA_FILE" ]; then
    read_existing_metadata
    EXISTING_INSTALL=1
  elif [ -e "$CURRENT_LINK" ] || [ -L "$CURRENT_LINK" ] ||
       [ -e "$STABLE_LAUNCHER" ] || [ -L "$STABLE_LAUNCHER" ]; then
    die "existing installation metadata is missing; launcher ownership is not framework-owned or cannot be proven"
  else
    # Empty roots can remain after an unsuccessful fresh install. Versioned
    # runtime/session state without metadata cannot establish ADS provenance.
    for path in "$VERSIONS_ROOT"/* "$DATA_ROOT/sessions"; do
      [ ! -e "$path" ] && [ ! -L "$path" ] || die "existing runtime state has no installation metadata"
    done
    if [ -L "$LEGACY_LAUNCHER" ]; then
      resolved=$($REALPATH_BIN "$LEGACY_LAUNCHER" 2>/dev/null) || resolved=
      case "$resolved" in "$DATA_ROOT_REAL"/*) die "legacy launcher ownership cannot be proven without metadata" ;; esac
    fi
    return
  fi

  [ -L "$CURRENT_LINK" ] && [ "$(file_uid "$CURRENT_LINK")" = "$(id -u)" ] || die "active runtime link is missing or unsafe"
  resolved=$($REALPATH_BIN "$CURRENT_LINK" 2>/dev/null) || die "active runtime link is broken"
  EXISTING_VERSION_DIR=$VERSIONS_ROOT_REAL/$EXISTING_RUNTIME_VERSION
  [ "$resolved" = "$EXISTING_VERSION_DIR" ] || die "active runtime and installation metadata are inconsistent"
  for path in "$EXISTING_VERSION_DIR" "$EXISTING_VERSION_DIR/bin" "$EXISTING_VERSION_DIR/lib"; do
    safe_dir "$path" && safe_path_ancestors "$path/child" || die "existing runtime layout is unsafe: $path"
  done
  for path in lib/claude_explore_runtime.sh lib/claude_explore_guard.sh; do
    safe_executable "$EXISTING_VERSION_DIR/$path" || die "existing runtime content is unsafe: $path"
  done
  safe_file "$EXISTING_VERSION_DIR/policy.sh" || die "existing runtime policy is unsafe"
  # Older valid runtime releases predate these optional evidence components.
  for path in lib/agent_run_outcomes.sh lib/agent_run_usage_collector.rb; do
    if [ -e "$EXISTING_VERSION_DIR/$path" ] || [ -L "$EXISTING_VERSION_DIR/$path" ]; then
      safe_executable "$EXISTING_VERSION_DIR/$path" || die "existing evidence executable is unsafe: $path"
    fi
  done
  for path in lib/agent_run_telemetry.sh lib/agent_run_usage.sh; do
    if [ -e "$EXISTING_VERSION_DIR/$path" ] || [ -L "$EXISTING_VERSION_DIR/$path" ]; then
      safe_file "$EXISTING_VERSION_DIR/$path" || die "existing evidence helper is unsafe: $path"
    fi
  done
  grep -Fx "CLAUDE_EXPLORE_RUNTIME_ID=$CLAUDE_EXPLORE_RUNTIME_ID" "$EXISTING_VERSION_DIR/policy.sh" >/dev/null &&
    grep -Fx "CLAUDE_EXPLORE_RUNTIME_VERSION=$EXISTING_RUNTIME_VERSION" "$EXISTING_VERSION_DIR/policy.sh" >/dev/null &&
    grep -Fx "CLAUDE_EXPLORE_POLICY_VERSION=$EXISTING_POLICY_VERSION" "$EXISTING_VERSION_DIR/policy.sh" >/dev/null ||
      die "existing runtime policy and installation metadata are inconsistent"
  reject_managed_claude "$EXISTING_CLAUDE_LAUNCHER" "$EXISTING_CLAUDE_LAUNCHER"
  case "$EXISTING_CLAUDE_LAUNCHER" in "$SOURCE_ROOT"/*|"$DATA_ROOT"/*|"$DATA_ROOT_REAL"/*) die "recorded Claude launcher recurses into claude-explore" ;; esac
  if [ -e "$EXISTING_CLAUDE_LAUNCHER" ]; then
    resolved=$($REALPATH_BIN "$EXISTING_CLAUDE_LAUNCHER" 2>/dev/null) || die "recorded Claude launcher cannot be resolved"
    reject_managed_claude "$EXISTING_CLAUDE_LAUNCHER" "$resolved"
    case "$resolved" in "$SOURCE_ROOT"/*|"$DATA_ROOT_REAL"/*) die "recorded Claude launcher recurses into claude-explore" ;; esac
  fi
  if [ -e "$STABLE_LAUNCHER" ] || [ -L "$STABLE_LAUNCHER" ]; then
    verify_owned_launcher "$STABLE_LAUNCHER" ads-claude-explore
    QUALIFIED_OWNED=1
  fi
  if [ -e "$LEGACY_LAUNCHER" ] || [ -L "$LEGACY_LAUNCHER" ]; then
    verify_owned_launcher "$LEGACY_LAUNCHER" claude-explore
    LEGACY_OWNED=1
  fi
  [ "$QUALIFIED_OWNED" -eq 1 ] || [ "$LEGACY_OWNED" -eq 1 ] || die "stable launcher is missing or ownership is ambiguous"
  if [ -e "$DATA_ROOT/sessions" ] || [ -L "$DATA_ROOT/sessions" ]; then
    safe_dir "$DATA_ROOT/sessions" || die "existing sessions root is unsafe"
  fi
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
  for path in bin/ads-claude-explore lib/claude_explore_runtime.sh lib/claude_explore_guard.sh; do
    safe_executable "$SOURCE_ROOT/$path" || die "source executable runtime is incomplete or unsafe: $path"
    case "$($REALPATH_BIN "$SOURCE_ROOT/$path")" in "$SOURCE_ROOT"/*) ;; *) die "source file resolves outside runtime: $path" ;; esac
  done
  safe_file "$SOURCE_ROOT/lib/agent_run_telemetry.sh" || die "source telemetry helper is incomplete or unsafe"
  safe_file "$SOURCE_ROOT/lib/agent_run_usage.sh" || die "source usage helper is incomplete or unsafe"
  safe_executable "$SOURCE_ROOT/lib/agent_run_usage_collector.rb" || die "source usage collector is incomplete or unsafe"
  safe_executable "$OUTCOME_SOURCE" || die "source outcome reconciler is incomplete or unsafe"
  case "$OUTCOME_SOURCE" in "$SOURCE_ROOT"/*) ;; *) die "outcome reconciler source resolves outside runtime" ;; esac
  safe_file "$SOURCE_ROOT/policy.sh" || die "source policy is incomplete or unsafe"
}

stage_runtime() {
  local path syntax_valid=1

  STAGE=$(mktemp -d "$DATA_ROOT/.stage.XXXXXX") || die "cannot create private staging directory"
  chmod 700 "$STAGE" || die "cannot protect private staging directory"
  mkdir "$STAGE/bin" "$STAGE/lib" || die "cannot build staged runtime"
  cp "$SOURCE_ROOT/bin/ads-claude-explore" "$STAGE/bin/ads-claude-explore" || die "cannot stage runtime launcher"
  cp "$SOURCE_ROOT/lib/claude_explore_runtime.sh" "$STAGE/lib/claude_explore_runtime.sh" || die "cannot stage runtime library"
  cp "$SOURCE_ROOT/lib/claude_explore_guard.sh" "$STAGE/lib/claude_explore_guard.sh" || die "cannot stage guard"
  cp "$SOURCE_ROOT/lib/agent_run_telemetry.sh" "$STAGE/lib/agent_run_telemetry.sh" || die "cannot stage telemetry helper"
  cp "$SOURCE_ROOT/lib/agent_run_usage.sh" "$STAGE/lib/agent_run_usage.sh" || die "cannot stage usage helper"
  cp "$SOURCE_ROOT/lib/agent_run_usage_collector.rb" "$STAGE/lib/agent_run_usage_collector.rb" || die "cannot stage usage collector"
  cp "$OUTCOME_SOURCE" "$STAGE/lib/agent_run_outcomes.sh" || die "cannot stage outcome reconciler"
  cp "$SOURCE_ROOT/policy.sh" "$STAGE/policy.sh" || die "cannot stage policy"
  chmod 700 "$STAGE/bin/ads-claude-explore" "$STAGE/lib/claude_explore_runtime.sh" "$STAGE/lib/claude_explore_guard.sh" "$STAGE/lib/agent_run_usage_collector.rb" "$STAGE/lib/agent_run_outcomes.sh" || die "cannot protect executable runtime files"
  chmod 600 "$STAGE/lib/agent_run_telemetry.sh" "$STAGE/lib/agent_run_usage.sh" "$STAGE/policy.sh" || die "cannot protect policy and telemetry files"
  for path in "$STAGE/bin/ads-claude-explore" "$STAGE/lib/claude_explore_guard.sh"; do
    /bin/sh -n "$path" || { syntax_valid=0; break; }
  done
  if [ "$syntax_valid" -eq 1 ]; then
    for path in "$STAGE/lib/claude_explore_runtime.sh" "$STAGE/lib/agent_run_telemetry.sh" "$STAGE/lib/agent_run_usage.sh" "$STAGE/policy.sh"; do
      /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH \
        /bin/bash --noprofile --norc -p -n "$path" || { syntax_valid=0; break; }
    done
  fi
  [ "$syntax_valid" -eq 1 ] || {
    rm -rf "$STAGE"; rm -f "${STAGED_METADATA:-}"; die "staged runtime failed syntax validation";
  }
}

cleanup_staging() {
  [ -z "${STAGED_CURRENT:-}" ] || rm -f "$STAGED_CURRENT"
  [ -z "${STAGED_LAUNCHER:-}" ] || rm -f "$STAGED_LAUNCHER"
  [ -z "${STAGED_METADATA:-}" ] || rm -f "$STAGED_METADATA"
  [ -z "${STAGE:-}" ] || [ ! -d "$STAGE" ] || rm -rf "$STAGE"
  return 0
}

rollback_problem() {
  ROLLBACK_INCOMPLETE=1
  printf 'ads-claude-explore installer: rollback incomplete: path=%s backup=%s; preserve backups and repair this installation before retrying.\n' "$1" "$2" >&2
}

rollback_activation() {
  ROLLBACK_INCOMPLETE=0
  if [ -L "$BACKUP_LEGACY" ]; then
    mv "$BACKUP_LEGACY" "$LEGACY_LAUNCHER" || rollback_problem "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"
  fi
  if [ "$METADATA_ACTIVATED" -eq 0 ] || rm -f "$METADATA_FILE"; then
    [ ! -e "$BACKUP_METADATA" ] || mv "$BACKUP_METADATA" "$METADATA_FILE" || rollback_problem "$METADATA_FILE" "$BACKUP_METADATA"
  else rollback_problem "$METADATA_FILE" "$BACKUP_METADATA"; fi
  if [ "$LAUNCHER_ACTIVATED" -eq 0 ] || rm -f "$STABLE_LAUNCHER"; then
    [ ! -L "$BACKUP_LAUNCHER" ] || mv "$BACKUP_LAUNCHER" "$STABLE_LAUNCHER" || rollback_problem "$STABLE_LAUNCHER" "$BACKUP_LAUNCHER"
  else rollback_problem "$STABLE_LAUNCHER" "$BACKUP_LAUNCHER"; fi
  if [ "$CURRENT_ACTIVATED" -eq 0 ] || rm -f "$CURRENT_LINK"; then
    [ ! -L "$BACKUP_CURRENT" ] || mv "$BACKUP_CURRENT" "$CURRENT_LINK" || rollback_problem "$CURRENT_LINK" "$BACKUP_CURRENT"
  else rollback_problem "$CURRENT_LINK" "$BACKUP_CURRENT"; fi
  if [ "$VERSION_ACTIVATED" -eq 0 ] || rm -rf "$ACTIVATION_VERSION_DIR"; then
    [ ! -d "$BACKUP_VERSION" ] || mv "$BACKUP_VERSION" "$ACTIVATION_VERSION_DIR" || rollback_problem "$ACTIVATION_VERSION_DIR" "$BACKUP_VERSION"
  else rollback_problem "$ACTIVATION_VERSION_DIR" "$BACKUP_VERSION"; fi
  cleanup_staging
  [ "$ROLLBACK_INCOMPLETE" -eq 0 ]
}

activation_fail() {
  local message=$1
  trap - HUP INT TERM
  if rollback_activation; then
    die "$message; previous installation restored"
  else
    die "$message; rollback incomplete (see paths and retained backups above)"
  fi
}

activate_transaction() {
  ACTIVATION_VERSION_DIR=$VERSIONS_ROOT/$CLAUDE_EXPLORE_RUNTIME_VERSION
  BACKUP_VERSION=$DATA_ROOT/.previous.version.$$
  BACKUP_CURRENT=$DATA_ROOT/.previous.current.$$
  BACKUP_LAUNCHER=$BIN_ROOT/.previous.ads-claude-explore.$$
  BACKUP_METADATA=$CONFIG_ROOT/.previous.install.meta.$$
  BACKUP_LEGACY=$BIN_ROOT/.previous.legacy.claude-explore.$$
  STAGED_CURRENT=$DATA_ROOT/.current.$$
  STAGED_LAUNCHER=$BIN_ROOT/.ads-claude-explore.$$
  VERSION_ACTIVATED=0 CURRENT_ACTIVATED=0 LAUNCHER_ACTIVATED=0 METADATA_ACTIVATED=0
  trap 'activation_fail "activation interrupted"' HUP INT TERM

  ln -s "$ACTIVATION_VERSION_DIR" "$STAGED_CURRENT" || activation_fail "cannot stage active runtime link"
  ln -s "$CURRENT_LINK/bin/ads-claude-explore" "$STAGED_LAUNCHER" || activation_fail "cannot stage stable launcher"

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

  if [ "$LEGACY_OWNED" -eq 1 ]; then
    # Move the proven link itself; never follow it for deletion. Keep this
    # backup until final activation and retirement verification both succeed.
    mv "$LEGACY_LAUNCHER" "$BACKUP_LEGACY" || activation_fail "cannot retire legacy launcher"
  fi
  [ -L "$STABLE_LAUNCHER" ] &&
    [ "$($REALPATH_BIN "$STABLE_LAUNCHER" 2>/dev/null)" = "$VERSIONS_ROOT_REAL/$CLAUDE_EXPLORE_RUNTIME_VERSION/bin/ads-claude-explore" ] &&
    [ "$($REALPATH_BIN "$CURRENT_LINK" 2>/dev/null)" = "$VERSIONS_ROOT_REAL/$CLAUDE_EXPLORE_RUNTIME_VERSION" ] &&
    safe_file "$METADATA_FILE" || activation_fail "final qualified activation verification failed"
  if [ "$LEGACY_OWNED" -eq 1 ]; then
    [ ! -e "$LEGACY_LAUNCHER" ] && [ ! -L "$LEGACY_LAUNCHER" ] || activation_fail "legacy launcher retirement verification failed"
  fi
  trap - HUP INT TERM
  rm -rf "$BACKUP_VERSION" || die "activation committed; cannot remove runtime backup: $BACKUP_VERSION"
  rm -f "$BACKUP_CURRENT" "$BACKUP_LAUNCHER" "$BACKUP_METADATA" "$BACKUP_LEGACY" ||
    die "activation committed; cannot remove transaction backups: $BACKUP_CURRENT $BACKUP_LAUNCHER $BACKUP_METADATA $BACKUP_LEGACY"
}

install_or_upgrade() {
  local selected_public selected_parent
  validate_source
  ensure_private_dir "$DATA_ROOT"; ensure_private_dir "$VERSIONS_ROOT"; ensure_private_dir "$CONFIG_ROOT"; ensure_private_dir "$BIN_ROOT"
  DATA_ROOT_REAL=$($REALPATH_BIN "$DATA_ROOT")
  VERSIONS_ROOT_REAL=$($REALPATH_BIN "$VERSIONS_ROOT")
  preflight_destination
  if [ -n "$REQUESTED_CLAUDE" ]; then
    CLAUDE_LAUNCHER=$REQUESTED_CLAUDE
    CLAUDE_SELECTION_SOURCE=explicit
  elif [ "$EXISTING_INSTALL" -eq 1 ]; then
    CLAUDE_LAUNCHER=$EXISTING_CLAUDE_LAUNCHER
    CLAUDE_SELECTION_SOURCE=recorded
  else
    CLAUDE_LAUNCHER=$(PATH=$ORIGINAL_PATH command -v claude 2>/dev/null) || die "Claude was not found on the pre-install PATH; use --claude-bin"
    CLAUDE_SELECTION_SOURCE=path
  fi
  case "$CLAUDE_LAUNCHER" in /*) ;; *) CLAUDE_LAUNCHER=$(CDPATH= cd -- "$(dirname "$CLAUDE_LAUNCHER")" && pwd -P)/$(basename "$CLAUDE_LAUNCHER") ;; esac
  validate_claude_launcher "$CLAUDE_LAUNCHER"
  stage_metadata; stage_runtime; activate_transaction
  printf 'ads-claude-explore %s %s\n' "$CLAUDE_EXPLORE_RUNTIME_VERSION" "$OPERATION"
  printf 'launcher=%s\nruntime=%s\nclaude_launcher=%s\nclaude_resolved=%s\nclaude_version=%s\nclaude_selection=%s\npolicy_version=%s\n' "$STABLE_LAUNCHER" "$CURRENT_LINK" "$CLAUDE_LAUNCHER" "$CLAUDE_TARGET" "$CLAUDE_VERSION" "$CLAUDE_SELECTION_SOURCE" "$CLAUDE_EXPLORE_POLICY_VERSION"
  if [ "$CLAUDE_SELECTION_SOURCE" = path ]; then
    printf '%s\n' 'Claude was selected from PATH. If that command is wrapped, install again with --claude-bin ABSOLUTE_PATH for the vendor Claude launcher.'
  fi
  case ":$ORIGINAL_PATH:" in *":$BIN_ROOT:"*) ;; *) printf 'Add %s to PATH manually.\n' "$BIN_ROOT" ;; esac
  selected_public=$(PATH=$ORIGINAL_PATH command -v ads-claude-explore 2>/dev/null) || selected_public=
  if [ -n "$selected_public" ]; then
    case "$selected_public" in
      /*) ;;
      *)
        selected_parent=$(CDPATH= cd -- "$(dirname "$selected_public")" 2>/dev/null && pwd -P) || selected_parent=
        [ -n "$selected_parent" ] && selected_public=$selected_parent/$(basename "$selected_public")
        ;;
    esac
  fi
  if [ -n "$selected_public" ] && [ "$selected_public" != "$STABLE_LAUNCHER" ]; then
    printf 'PATH shadowing: installed public launcher=%s; bare ads-claude-explore resolves to=%s. Bare invocation will continue to select the earlier PATH entry; reorder PATH deliberately or invoke the installed launcher by its absolute path.\n' "$STABLE_LAUNCHER" "$selected_public" >&2
  fi
}

uninstall_runtime() {
  DATA_ROOT_REAL=$($REALPATH_BIN "$DATA_ROOT" 2>/dev/null) || die "runtime data is missing"
  VERSIONS_ROOT_REAL=$($REALPATH_BIN "$VERSIONS_ROOT" 2>/dev/null) || die "runtime versions are missing"
  preflight_destination
  [ "$EXISTING_INSTALL" -eq 1 ] || die "installation ownership cannot be proven"
  # All entrypoints have been identified before deleting any shared state.
  # If removing a launcher fails, leave runtime/configuration data in place.
  if [ "$LEGACY_OWNED" -eq 1 ]; then
    rm "$LEGACY_LAUNCHER" || die "cannot remove legacy launcher; runtime state retained"
  fi
  if [ "$QUALIFIED_OWNED" -eq 1 ]; then
    rm "$STABLE_LAUNCHER" || die "cannot remove stable launcher; runtime state retained"
  fi
  rm -rf "$DATA_ROOT" "$CONFIG_ROOT" || die "cannot remove framework-owned runtime state"
  printf 'ads-claude-explore uninstalled; Claude, repositories, and Claude settings were preserved.\n'
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
STABLE_LAUNCHER=$BIN_ROOT/ads-claude-explore
LEGACY_LAUNCHER=$BIN_ROOT/claude-explore

for install_path in "$HOME" "$DATA_ROOT" "$CONFIG_ROOT" "$BIN_ROOT"; do
  contains_control_character "$install_path" && die "installation path contains a control character"
done

# Cleanup authority comes only from paths allocated by this process.
# Never adopt inherited staging variables on an early preflight failure.
STAGE= STAGED_CURRENT= STAGED_LAUNCHER= STAGED_METADATA=
trap cleanup_staging EXIT
case "$OPERATION" in install|upgrade) install_or_upgrade ;; uninstall) uninstall_runtime ;; esac
