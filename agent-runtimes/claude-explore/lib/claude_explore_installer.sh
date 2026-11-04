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

# Resolve destination roots without creating them, including missing descendants.
# This permits rejecting ambiguous generic links before populating their target.
canonical_destination() {
  local path=$1 suffix= resolved
  while [ ! -e "$path" ] && [ ! -L "$path" ]; do
    suffix=/$(basename "$path")$suffix
    path=$(dirname "$path")
  done
  resolved=$($REALPATH_BIN "$path" 2>/dev/null) || return 1
  printf '%s%s\n' "$resolved" "$suffix"
}

classify_legacy_launcher() {
  local resolved uid mode
  LEGACY_OWNED=0
  [ -e "$LEGACY_LAUNCHER" ] || [ -L "$LEGACY_LAUNCHER" ] || return 0
  resolved=$($REALPATH_BIN "$LEGACY_LAUNCHER" 2>/dev/null) || die "generic launcher ownership is ambiguous; cannot resolve: $LEGACY_LAUNCHER"
  if [ "$EXISTING_INSTALL" -eq 1 ] && [ -L "$LEGACY_LAUNCHER" ] &&
     [ "$(readlink "$LEGACY_LAUNCHER")" = "$CURRENT_LINK/bin/claude-explore" ]; then
    verify_owned_launcher "$LEGACY_LAUNCHER" claude-explore
    LEGACY_OWNED=1
    return
  fi
  case "$resolved" in
    "$DATA_ROOT_REAL"|"$DATA_ROOT_REAL"/*|"$CONFIG_ROOT_REAL"|"$CONFIG_ROOT_REAL"/*|"$SOURCE_ROOT"|"$SOURCE_ROOT"/*)
      die "generic launcher ownership is ambiguous; target is connected to ADS state: $LEGACY_LAUNCHER" ;;
  esac
  [ "$EXISTING_INSTALL" -eq 0 ] || [ "$QUALIFIED_OWNED" -eq 1 ] || die "legacy launcher ownership cannot be proven without a verified qualified installation"
  [ -f "$resolved" ] && [ -x "$resolved" ] &&
    safe_path_ancestors "$LEGACY_LAUNCHER" && safe_path_ancestors "$resolved" ||
      die "generic launcher ownership is ambiguous; target or hierarchy is unsafe: $LEGACY_LAUNCHER"
  uid=$(file_uid "$resolved") || die "cannot inspect unrelated generic launcher"
  mode=$(file_mode "$resolved") || die "cannot inspect unrelated generic launcher"
  { [ "$uid" = 0 ] || [ "$uid" = "$(id -u)" ]; } && [ $((8#$mode & 022)) -eq 0 ] ||
    die "generic launcher ownership is ambiguous; target owner or mode is unsafe: $LEGACY_LAUNCHER"
  # External executable, never adopted. ADS ownership is proven independently.
}

path_exists() { [ -e "$1" ] || [ -L "$1" ]; }

# lstat identity also captures owner/mode. Renames within one destination
# filesystem retain this identity; a replacement is never cleanup authority.
file_identity() {
  case "$PLATFORM" in
    macos) stat -f '%d:%i:%u:%Lp' "$1" ;;
    linux) stat -c '%d:%i:%u:%a' "$1" ;;
  esac
}

same_object() {
  [ -n "$2" ] && path_exists "$1" &&
    [ "$(file_identity "$1" 2>/dev/null)" = "$2" ]
}

record_installation_identities() {
  ORIGINAL_VERSION_ID= ORIGINAL_CURRENT_ID= ORIGINAL_LAUNCHER_ID= ORIGINAL_METADATA_ID= ORIGINAL_LEGACY_ID=
  ACTIVATION_VERSION_DIR=$VERSIONS_ROOT/$CLAUDE_EXPLORE_RUNTIME_VERSION
  if path_exists "$ACTIVATION_VERSION_DIR"; then
    ORIGINAL_VERSION_ID=$(file_identity "$ACTIVATION_VERSION_DIR") || die "cannot identify previous runtime version"
  fi
  if [ "$EXISTING_INSTALL" -eq 1 ]; then
    ORIGINAL_CURRENT_ID=$(file_identity "$CURRENT_LINK") || die "cannot identify current link"
    ORIGINAL_METADATA_ID=$(file_identity "$METADATA_FILE") || die "cannot identify metadata"
  fi
  if [ "$QUALIFIED_OWNED" -eq 1 ]; then
    ORIGINAL_LAUNCHER_ID=$(file_identity "$STABLE_LAUNCHER") || die "cannot identify qualified launcher"
  fi
  if [ "$LEGACY_OWNED" -eq 1 ]; then
    ORIGINAL_LEGACY_ID=$(file_identity "$LEGACY_LAUNCHER") || die "cannot identify legacy launcher"
  fi
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
    classify_legacy_launcher
    record_installation_identities
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
  classify_legacy_launcher
  [ "$QUALIFIED_OWNED" -eq 1 ] || [ "$LEGACY_OWNED" -eq 1 ] || die "stable launcher is missing or ownership is ambiguous"
  if [ -e "$DATA_ROOT/sessions" ] || [ -L "$DATA_ROOT/sessions" ]; then
    safe_dir "$DATA_ROOT/sessions" || die "existing sessions root is unsafe"
  fi
  record_installation_identities
}

new_transaction_dir() {
  local directory
  directory=$(mktemp -d "$1/.transaction.XXXXXX") || return 1
  safe_dir "$directory" && [ "$(file_mode "$directory")" = 700 ] &&
    [ "$($REALPATH_BIN "$directory" 2>/dev/null)" = "$directory" ] ||
      { printf 'cannot establish ownership of transaction directory: %s\n' "$directory" >&2; return 1; }
  printf '%s\n' "$directory"
}

require_absent() {
  if path_exists "$1"; then
    printf 'ads-claude-explore installer: transaction destination is occupied; preserved: %s\n' "$1" >&2
    return 1
  fi
}

# All slots are direct children of exclusively allocated private directories.
# Check again at each move/write so an occupied destination cannot become an
# mv container, or a redirection/cleanup target owned by someone else.
check_transaction_boundary() {
  local path=$1 root identity
  for root in "$TX_VERSION" "$TX_DATA" "$TX_CONFIG" "$TX_BIN"; do
    [ -n "$root" ] || continue
    case "$path" in "$root"/*)
      case "$root" in
        "$TX_VERSION") identity=$TX_VERSION_ID ;;
        "$TX_DATA") identity=$TX_DATA_ID ;;
        "$TX_CONFIG") identity=$TX_CONFIG_ID ;;
        "$TX_BIN") identity=$TX_BIN_ID ;;
      esac
      [ "$path" = "$root/${path##*/}" ] &&
        [ -d "$root" ] && [ ! -L "$root" ] && same_object "$root" "$identity" &&
        [ "$($REALPATH_BIN "$root" 2>/dev/null)" = "$root" ] || {
          printf 'ads-claude-explore installer: transaction directory ownership changed; preserved: %s\n' "$root" >&2
          return 1
        }
      return 0 ;;
    esac
  done
  # Existing live destinations are separately proven by preflight and identity.
  return 0
}

move_to_empty() {
  local source=$1 destination=$2 identity=$3
  check_transaction_boundary "$source" && check_transaction_boundary "$destination" &&
    same_object "$source" "$identity" && require_absent "$destination" || return 1
  mv "$source" "$destination"
}

check_transaction_slots() {
  local path
  for path in "$STAGE" "$STAGED_METADATA" "$STAGED_CURRENT" "$STAGED_LAUNCHER" \
      "$BACKUP_VERSION" "$BACKUP_CURRENT" "$BACKUP_METADATA" "$BACKUP_LAUNCHER" "$BACKUP_LEGACY"; do
    check_transaction_boundary "$path" && require_absent "$path" || die "transaction path collision; installation unchanged"
  done
}

allocate_transaction() {
  local bin_real
  bin_real=$($REALPATH_BIN "$BIN_ROOT") || die "cannot resolve launcher directory"
  # Each component is renamed within its own trusted destination filesystem.
  TX_VERSION=$(new_transaction_dir "$VERSIONS_ROOT_REAL") || die "cannot allocate version transaction"
  TX_VERSION_ID=$(file_identity "$TX_VERSION") || die "cannot identify version transaction"
  TX_DATA=$(new_transaction_dir "$DATA_ROOT_REAL") || die "cannot allocate link transaction"
  TX_DATA_ID=$(file_identity "$TX_DATA") || die "cannot identify link transaction"
  TX_CONFIG=$(new_transaction_dir "$CONFIG_ROOT_REAL") || die "cannot allocate metadata transaction"
  TX_CONFIG_ID=$(file_identity "$TX_CONFIG") || die "cannot identify metadata transaction"
  TX_BIN=$(new_transaction_dir "$bin_real") || die "cannot allocate launcher transaction"
  TX_BIN_ID=$(file_identity "$TX_BIN") || die "cannot identify launcher transaction"
  STAGE=$TX_VERSION/runtime
  BACKUP_VERSION=$TX_VERSION/previous.version
  STAGED_CURRENT=$TX_DATA/current
  BACKUP_CURRENT=$TX_DATA/previous.current
  STAGED_METADATA=$TX_CONFIG/install.meta
  BACKUP_METADATA=$TX_CONFIG/previous.meta
  STAGED_LAUNCHER=$TX_BIN/launcher
  BACKUP_LAUNCHER=$TX_BIN/previous.launcher
  BACKUP_LEGACY=$TX_BIN/previous.legacy
  check_transaction_slots
}

stage_metadata() {
  check_transaction_boundary "$STAGED_METADATA" && require_absent "$STAGED_METADATA" || die "cannot reserve staged metadata"
  ( set -C; : > "$STAGED_METADATA" ) || die "cannot exclusively create staged metadata"
  STAGED_METADATA_ID=$(file_identity "$STAGED_METADATA") || die "cannot identify staged metadata"
  check_transaction_boundary "$STAGED_METADATA" && same_object "$STAGED_METADATA" "$STAGED_METADATA_ID" || die "staged metadata ownership changed"
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

  check_transaction_boundary "$STAGE" && require_absent "$STAGE" || die "runtime staging path is occupied"
  mkdir "$STAGE" || die "cannot create private staging directory"
  STAGE_ID=$(file_identity "$STAGE") || die "cannot identify private staging directory"
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
  [ "$syntax_valid" -eq 1 ] || die "staged runtime failed syntax validation"
}

remove_owned() {
  local path=$1 identity=$2
  path_exists "$path" || return 0
  check_transaction_boundary "$path" && same_object "$path" "$identity" || {
    printf 'ads-claude-explore installer: cleanup ownership cannot be proven; preserved: %s\n' "$path" >&2
    return 1
  }
  if [ -d "$path" ] && [ ! -L "$path" ]; then rm -rf "$path"; else rm -f "$path"; fi
}

cleanup_staging() {
  local result=0 root identity
  [ -z "$STAGE" ] || remove_owned "$STAGE" "$STAGE_ID" || result=1
  [ -z "$STAGED_CURRENT" ] || remove_owned "$STAGED_CURRENT" "$STAGED_CURRENT_ID" || result=1
  [ -z "$STAGED_LAUNCHER" ] || remove_owned "$STAGED_LAUNCHER" "$STAGED_LAUNCHER_ID" || result=1
  [ -z "$STAGED_METADATA" ] || remove_owned "$STAGED_METADATA" "$STAGED_METADATA_ID" || result=1
  for root in "$TX_VERSION" "$TX_DATA" "$TX_CONFIG" "$TX_BIN"; do
    [ -n "$root" ] || continue
    case "$root" in
      "$TX_VERSION") identity=$TX_VERSION_ID ;;
      "$TX_DATA") identity=$TX_DATA_ID ;;
      "$TX_CONFIG") identity=$TX_CONFIG_ID ;;
      "$TX_BIN") identity=$TX_BIN_ID ;;
    esac
    if [ -d "$root" ] && [ ! -L "$root" ] && same_object "$root" "$identity" &&
       [ "$($REALPATH_BIN "$root" 2>/dev/null)" = "$root" ] && rmdir "$root" 2>/dev/null; then
      :
    else
      printf 'ads-claude-explore installer: transaction retained for inspection/recovery: %s\n' "$root" >&2
      result=1
    fi
  done
  return "$result"
}

rollback_problem() {
  ROLLBACK_INCOMPLETE=1
  printf 'ads-claude-explore installer: rollback incomplete: path=%s backup=%s; preserve backups and repair this installation before retrying.\n' "$1" "$2" >&2
}

# Only the five known installation components participate in restoration.
# A replacement at a live destination is preserved, even if it blocks recovery.
restore_component() {
  local destination=$1 backup=$2 activated_id=$3 original_id=$4
  check_transaction_boundary "$backup" || { rollback_problem "$destination" "$backup"; return; }
  if same_object "$destination" "$activated_id"; then
    remove_owned "$destination" "$activated_id" || { rollback_problem "$destination" "$backup"; return; }
  fi
  if [ -n "$original_id" ]; then
    if same_object "$destination" "$original_id"; then
      return
    elif same_object "$backup" "$original_id"; then
      move_to_empty "$backup" "$destination" "$original_id" || rollback_problem "$destination" "$backup"
    else
      rollback_problem "$destination" "$backup"
    fi
  elif path_exists "$destination"; then
    rollback_problem "$destination" "$backup"
  fi
}

rollback_activation() {
  ROLLBACK_INCOMPLETE=0
  if [ "$LEGACY_OWNED" -eq 1 ]; then
    restore_component "$LEGACY_LAUNCHER" "$BACKUP_LEGACY" "" "$ORIGINAL_LEGACY_ID"
  fi
  restore_component "$METADATA_FILE" "$BACKUP_METADATA" "$STAGED_METADATA_ID" "$ORIGINAL_METADATA_ID"
  restore_component "$STABLE_LAUNCHER" "$BACKUP_LAUNCHER" "$STAGED_LAUNCHER_ID" "$ORIGINAL_LAUNCHER_ID"
  restore_component "$CURRENT_LINK" "$BACKUP_CURRENT" "$STAGED_CURRENT_ID" "$ORIGINAL_CURRENT_ID"
  restore_component "$ACTIVATION_VERSION_DIR" "$BACKUP_VERSION" "$STAGE_ID" "$ORIGINAL_VERSION_ID"
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
  trap 'activation_fail "activation interrupted"' HUP INT TERM

  check_transaction_boundary "$STAGED_CURRENT" && require_absent "$STAGED_CURRENT" ||
    activation_fail "active link staging path is occupied"
  ln -s "$ACTIVATION_VERSION_DIR" "$STAGED_CURRENT" || activation_fail "cannot stage active runtime link"
  STAGED_CURRENT_ID=$(file_identity "$STAGED_CURRENT") || activation_fail "cannot identify staged current link"
  check_transaction_boundary "$STAGED_LAUNCHER" && require_absent "$STAGED_LAUNCHER" ||
    activation_fail "qualified launcher staging path is occupied"
  ln -s "$CURRENT_LINK/bin/ads-claude-explore" "$STAGED_LAUNCHER" || activation_fail "cannot stage stable launcher"
  STAGED_LAUNCHER_ID=$(file_identity "$STAGED_LAUNCHER") || activation_fail "cannot identify staged launcher"

  if [ -n "$ORIGINAL_VERSION_ID" ]; then
    move_to_empty "$ACTIVATION_VERSION_DIR" "$BACKUP_VERSION" "$ORIGINAL_VERSION_ID" || activation_fail "cannot preserve existing runtime version"
  fi
  move_to_empty "$STAGE" "$ACTIVATION_VERSION_DIR" "$STAGE_ID" || activation_fail "cannot activate staged runtime"

  if [ -n "$ORIGINAL_CURRENT_ID" ]; then
    move_to_empty "$CURRENT_LINK" "$BACKUP_CURRENT" "$ORIGINAL_CURRENT_ID" || activation_fail "cannot preserve active runtime link"
  fi
  move_to_empty "$STAGED_CURRENT" "$CURRENT_LINK" "$STAGED_CURRENT_ID" || activation_fail "cannot activate runtime link"

  if [ -n "$ORIGINAL_LAUNCHER_ID" ]; then
    move_to_empty "$STABLE_LAUNCHER" "$BACKUP_LAUNCHER" "$ORIGINAL_LAUNCHER_ID" || activation_fail "cannot preserve stable launcher"
  fi
  move_to_empty "$STAGED_LAUNCHER" "$STABLE_LAUNCHER" "$STAGED_LAUNCHER_ID" || activation_fail "cannot activate stable launcher"

  if [ -n "$ORIGINAL_METADATA_ID" ]; then
    move_to_empty "$METADATA_FILE" "$BACKUP_METADATA" "$ORIGINAL_METADATA_ID" || activation_fail "cannot preserve installation metadata"
  fi
  move_to_empty "$STAGED_METADATA" "$METADATA_FILE" "$STAGED_METADATA_ID" || activation_fail "cannot activate installation metadata"

  if [ "$LEGACY_OWNED" -eq 1 ]; then
    move_to_empty "$LEGACY_LAUNCHER" "$BACKUP_LEGACY" "$ORIGINAL_LEGACY_ID" || activation_fail "cannot retire legacy launcher"
  fi
  [ -L "$STABLE_LAUNCHER" ] &&
    [ "$($REALPATH_BIN "$STABLE_LAUNCHER" 2>/dev/null)" = "$VERSIONS_ROOT_REAL/$CLAUDE_EXPLORE_RUNTIME_VERSION/bin/ads-claude-explore" ] &&
    [ "$($REALPATH_BIN "$CURRENT_LINK" 2>/dev/null)" = "$VERSIONS_ROOT_REAL/$CLAUDE_EXPLORE_RUNTIME_VERSION" ] &&
    same_object "$ACTIVATION_VERSION_DIR" "$STAGE_ID" &&
    same_object "$CURRENT_LINK" "$STAGED_CURRENT_ID" &&
    same_object "$STABLE_LAUNCHER" "$STAGED_LAUNCHER_ID" &&
    same_object "$METADATA_FILE" "$STAGED_METADATA_ID" &&
    safe_file "$METADATA_FILE" || activation_fail "final qualified activation verification failed"
  if [ "$LEGACY_OWNED" -eq 1 ]; then
    require_absent "$LEGACY_LAUNCHER" || activation_fail "legacy launcher retirement verification failed"
  fi
  trap - HUP INT TERM
  remove_owned "$BACKUP_VERSION" "$ORIGINAL_VERSION_ID" &&
    remove_owned "$BACKUP_CURRENT" "$ORIGINAL_CURRENT_ID" &&
    remove_owned "$BACKUP_LAUNCHER" "$ORIGINAL_LAUNCHER_ID" &&
    remove_owned "$BACKUP_METADATA" "$ORIGINAL_METADATA_ID" &&
    remove_owned "$BACKUP_LEGACY" "$ORIGINAL_LEGACY_ID" ||
      die "activation committed; backup cleanup incomplete (see preserved paths above)"
  trap - EXIT
  cleanup_staging || die "activation committed; transaction cleanup incomplete (see retained paths above)"
}

install_or_upgrade() {
  local selected_public selected_parent
  validate_source
  if [ ! -e "$METADATA_FILE" ] && [ ! -L "$METADATA_FILE" ]; then
    EXISTING_INSTALL=0 QUALIFIED_OWNED=0
    classify_legacy_launcher
  fi
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
  allocate_transaction; stage_metadata; stage_runtime; activate_transaction
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

DATA_ROOT_REAL=$(canonical_destination "$DATA_ROOT") || die "cannot resolve data root hierarchy"
CONFIG_ROOT_REAL=$(canonical_destination "$CONFIG_ROOT") || die "cannot resolve config root hierarchy"

# Cleanup authority comes only from paths allocated by this process.
# Never adopt inherited staging variables on an early preflight failure.
STAGE= STAGED_CURRENT= STAGED_LAUNCHER= STAGED_METADATA=
STAGE_ID= STAGED_CURRENT_ID= STAGED_LAUNCHER_ID= STAGED_METADATA_ID=
TX_VERSION= TX_DATA= TX_CONFIG= TX_BIN=
TX_VERSION_ID= TX_DATA_ID= TX_CONFIG_ID= TX_BIN_ID=
trap cleanup_staging EXIT
case "$OPERATION" in install|upgrade) install_or_upgrade ;; uninstall) uninstall_runtime ;; esac
