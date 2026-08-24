#!/bin/bash
set -u
unset BASH_ENV ENV CDPATH
ORIGINAL_PATH=${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
PATH=/usr/bin:/bin:/usr/sbin:/sbin

runtime_error() {
  printf 'claude-explore: %s\n' "$1" >&2
  return 1
}

contains_control_character() {
  printf '%s' "$1" | LC_ALL=C grep -q '[[:cntrl:]]'
}

word_in_list() {
  local list=${2//$'\n'/ }
  case " $list " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

blocked() {
  # Values are fixed identifiers, never raw user arguments.
  printf '%s runtime=%s policy_version=%s category=%s operation=%s rule=%s reason=%s safe_next_action=%s\n' "$CLAUDE_EXPLORE_BLOCKED_PREFIX" \
    "$CLAUDE_EXPLORE_RUNTIME_ID" "$CLAUDE_EXPLORE_POLICY_VERSION" "$1" "$2" "$3" "$4" "$5" >&2
  return "$CLAUDE_EXPLORE_BLOCKED_STATUS"
}

classified() {
  printf '%s runtime=%s policy_version=%s category=%s operation=%s decision=%s rule=%s\n' "$CLAUDE_EXPLORE_CLASSIFICATION_PREFIX" \
    "$CLAUDE_EXPLORE_RUNTIME_ID" "$CLAUDE_EXPLORE_POLICY_VERSION" "$1" "$2" "$3" "$4"
}

require_realpath() {
  if [ -x /usr/bin/realpath ]; then REALPATH_BIN=/usr/bin/realpath
  elif [ -x /bin/realpath ]; then REALPATH_BIN=/bin/realpath
  else return 1
  fi
}

SCRIPT_REAL=""
RUNTIME_ROOT=""
POLICY_FILE=""
initialize_runtime_source() {
  require_realpath || runtime_error "required executable is unavailable: realpath"
  SCRIPT_REAL=$($REALPATH_BIN "${BASH_SOURCE[0]}" 2>/dev/null) || return 1
  RUNTIME_ROOT=$(dirname "$(dirname "$SCRIPT_REAL")")
  DATA_INSTALL_ROOT=$(dirname "$(dirname "$RUNTIME_ROOT")")
  POLICY_FILE="$RUNTIME_ROOT/policy.sh"
  [ -f "$POLICY_FILE" ] && [ ! -L "$POLICY_FILE" ] || { runtime_error "policy is missing or unsafe"; return 1; }
  case "$($REALPATH_BIN "$POLICY_FILE" 2>/dev/null)" in "$RUNTIME_ROOT"/*) ;; *) runtime_error "policy resolves outside runtime"; return 1 ;; esac
  # shellcheck disable=SC1090 -- path is derived and validated above.
  . "$POLICY_FILE"
  [ "$CLAUDE_EXPLORE_RUNTIME_ID" = claude-explore ] || { runtime_error "policy runtime identifier mismatch"; return 1; }
  [ "$CLAUDE_EXPLORE_POLICY_SCHEMA_VERSION" = 1 ] || { runtime_error "unsupported policy schema"; return 1; }
}

version_at_least() {
  local have=$1 need=$2 old_ifs=$IFS h1 h2 h3 n1 n2 n3
  IFS=.; set -- $have; h1=${1:-0}; h2=${2:-0}; h3=${3:-0}
  set -- $need; n1=${1:-0}; n2=${2:-0}; n3=${3:-0}; IFS=$old_ifs
  [ "$h1" -gt "$n1" ] || { [ "$h1" -eq "$n1" ] && { [ "$h2" -gt "$n2" ] || { [ "$h2" -eq "$n2" ] && [ "$h3" -ge "$n3" ]; }; }; }
}

claude_version() {
  local output name; local -a scrub_args
  scrub_args=(-u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH)
  while IFS= read -r name; do scrub_args+=( -u "$name" ); done <<EOF
$CLAUDE_EXPLORE_ENV_UNSET
EOF
  output=$(/usr/bin/env "${scrub_args[@]}" "$1" --version 2>/dev/null) || return 1
  case "$output" in
    *[0-9].[0-9].[0-9]*) ;;
    *) return 1 ;;
  esac
  CLAUDE_VERSION=$(printf '%s\n' "$output" | sed -n 's/^[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*$/\1/p' | head -n 1)
  [ -n "$CLAUDE_VERSION" ]
}

classify_git() {
  local arg command="" seen_command=0
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    if [ "$seen_command" -eq 0 ]; then
      case "$arg" in
        -C) [ "$#" -gt 0 ] || { blocked git malformed git-global missing-value use-valid-git-command; return $?; }; shift ;;
        -C?*) ;;
        --no-pager|--paginate|-p|--no-replace-objects|--literal-pathspecs|--glob-pathspecs|--noglob-pathspecs|--icase-pathspecs|--no-optional-locks) ;;
        -c|-c?*|--config-env|--config-env=*|--git-dir|--git-dir=*|--work-tree|--work-tree=*|--exec-path|--exec-path=*|--namespace|--namespace=*|--super-prefix|--super-prefix=*) blocked git global-override git-global-override authority-changing-global-option use-local-git-without-overrides; return $? ;;
        -*) blocked git unknown-global git-global-closed-set unknown-global-option use-a-documented-global-option; return $? ;;
        *) command=$arg; seen_command=1; break ;;
      esac
    fi
  done
  [ -n "$command" ] || { blocked git malformed git-command-required missing-subcommand use-a-documented-local-subcommand; return $?; }
  if word_in_list "$command" "$CLAUDE_EXPLORE_BLOCKED_GIT"; then
    blocked git "$command" git-remote-deny remote-or-credential-operation use-local-git-only; return $?
  fi
  if word_in_list "$command" "$CLAUDE_EXPLORE_ALLOWED_GIT"; then return 0; fi
  case "$command" in
    branch)
      for arg in "$@"; do case "$arg" in --set-upstream-to|--set-upstream-to=*|-u|--unset-upstream|--track|--track=*|-t|--no-track) blocked git branch git-branch-upstream upstream-mutation use-local-branch-without-upstream; return $? ;; esac; done
      return 0 ;;
    remote)
      [ "$#" -eq 0 ] && return 0
      case "$1" in -v|--verbose) [ "$#" -eq 1 ] && return 0 ;; get-url) shift; [ "$#" -ge 1 ] && return 0 ;; esac
      blocked git remote git-remote-read-only remote-mutation-or-unclassified-form use-git-remote-or-get-url; return $? ;;
    config)
      local read_form=0
      for arg in "$@"; do
        case "$arg" in
          --add|--replace-all|--unset|--unset-all|--rename-section|--remove-section|-e|--edit|--stdin) blocked git config git-config-read-only config-mutation use-an-explicit-config-read-form; return $? ;;
          --get|--get-all|--get-regexp|--get-urlmatch|--list|-l|--get=*|--get-all=*|--get-regexp=*|--list=*) read_form=1 ;;
          --show-origin|--show-scope|--name-only|--includes|--local|--global|--system|--worktree|--fixed-value|-z|--null|--type=*|--default=*) ;;
          -*) blocked git config git-config-read-only unknown-config-option use-an-explicit-config-read-form; return $? ;;
        esac
      done
      [ "$read_form" -eq 1 ] && return 0
      blocked git config git-config-read-only config-mutation-or-unclassified-form use-an-explicit-config-read-form; return $? ;;
    tag)
      [ "$#" -eq 0 ] && return 0
      local query_form=0
      while [ "$#" -gt 0 ]; do arg=$1; shift
        case "$arg" in -l|--list|--list=*|-n|-n[0-9]*|--contains|--contains=*|--no-contains|--no-contains=*|--points-at|--points-at=*|--merged|--merged=*|--no-merged|--no-merged=*|--sort=*|--format=*|--column|--column=*|--no-column|--ignore-case) query_form=1 ;;
          -*) blocked git tag git-tag-query-only tag-mutation-or-unclassified-form use-git-tag-list; return $? ;;
          *) [ "$query_form" -eq 1 ] || { blocked git tag git-tag-query-only tag-mutation-or-unclassified-form use-git-tag-list; return $?; } ;;
        esac
      done
      [ "$query_form" -eq 1 ] && return 0 ;;
  esac
  blocked git unknown-subcommand git-subcommand-closed-set unknown-subcommand use-a-documented-local-subcommand
}

local_pg_host() {
  case "$1" in localhost|127.0.0.1|::1|/*) return 0 ;; *) return 1 ;; esac
}

classify_pg_target() {
  local value=$1 authority host
  case "$value" in
    *\?*|*\#*) return 1 ;;
    postgresql://*|postgres://*)
      authority=${value#*://}; authority=${authority%%/*}
      case "$authority" in *,*|*%*|*'='*) return 1 ;; esac
      authority=${authority##*@}
      case "$authority" in
        \[*\]*) host=${authority#\[}; host=${host%%\]*}; [ "$host" = ::1 ] || return 1 ;;
        \[*\]:*) host=${authority#\[}; host=${host%%\]*}; [ "$host" = ::1 ] || return 1 ;;
        *) host=${authority%%:*}; local_pg_host "$host" || return 1 ;;
      esac
      return 0 ;;
    *=*) return 1 ;;
    *) return 0 ;;
  esac
}

classify_psql() {
  local arg value positional=0
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    case "$arg" in
      -h|--host) [ "$#" -gt 0 ] || { blocked postgresql malformed psql-host missing-value use-an-explicit-local-host; return $?; }; value=$1; shift; local_pg_host "$value" || { blocked postgresql remote-host psql-local-only non-local-host use-localhost-loopback-or-absolute-socket; return $?; } ;;
      --host=*) value=${arg#*=}; local_pg_host "$value" || { blocked postgresql remote-host psql-local-only non-local-host use-localhost-loopback-or-absolute-socket; return $?; } ;;
      -h?*) value=${arg#-h}; local_pg_host "$value" || { blocked postgresql remote-host psql-local-only non-local-host use-localhost-loopback-or-absolute-socket; return $?; } ;;
      -d|--dbname) [ "$#" -gt 0 ] || { blocked postgresql malformed psql-dbname missing-value use-a-local-database-name; return $?; }; value=$1; shift; classify_pg_target "$value" || { blocked postgresql unsafe-target psql-local-only remote-or-ambiguous-target use-a-plain-name-or-local-uri; return $?; } ;;
      -d?*) value=${arg#-d}; classify_pg_target "$value" || { blocked postgresql unsafe-target psql-local-only remote-or-ambiguous-target use-a-plain-name-or-local-uri; return $?; } ;;
      --dbname=*) value=${arg#*=}; classify_pg_target "$value" || { blocked postgresql unsafe-target psql-local-only remote-or-ambiguous-target use-a-plain-name-or-local-uri; return $?; } ;;
      service=*|--service|--service=*) blocked postgresql service psql-no-services ambiguous-service-target use-an-explicit-local-target; return $? ;;
      --) while [ "$#" -gt 0 ]; do positional=$((positional + 1)); classify_pg_target "$1" || { blocked postgresql unsafe-target psql-local-only remote-or-ambiguous-target use-a-plain-name-or-local-uri; return $?; }; shift; done ;;
      -p|--port|-U|--username|-c|--command|-f|--file|-v|--set|--variable|-P|--pset|-F|--field-separator|-R|--record-separator|-L|--log-file|-o|--output) [ "$#" -gt 0 ] || { blocked postgresql malformed psql-option missing-value use-a-complete-local-psql-command; return $?; }; shift ;;
      --port=*|--username=*|--command=*|--file=*|--set=*|--variable=*|--pset=*|--field-separator=*|--record-separator=*|--log-file=*|-p?*|-U?*|-c?*|-f?*|-v?*|-P?*|-F?*|-R?*|-L?*) ;;
      -a|--echo-all|-b|--echo-errors|-e|--echo-queries|-E|--echo-hidden|-n|--no-readline|-q|--quiet|-s|--single-step|-S|--single-line|-V|--version|-w|--no-password|-W|--password|-x|--expanded|-X|--no-psqlrc|-1|--single-transaction|-?|--help) ;;
      -*) blocked postgresql unknown-option psql-option-closed-set ambiguous-option use-a-documented-local-psql-option; return $? ;;
      *) positional=$((positional + 1)); [ "$positional" -le 1 ] || { blocked postgresql ambiguous psql-single-target multiple-positional-targets use-one-database-target; return $?; }; classify_pg_target "$arg" || { blocked postgresql unsafe-target psql-local-only remote-or-ambiguous-target use-a-plain-name-or-local-uri; return $?; } ;;
    esac
  done
  return 0
}

classify_command() {
  [ "$#" -gt 0 ] || { runtime_error "--claude-explore-check-command requires an argv after --"; return 2; }
  local command=$1; shift
  command=${command##*/}
  CLASSIFIED_OPERATION=other-local-command
  if word_in_list "$command" "$CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"; then
    blocked command "$command" executable-category fully-blocked-executable use-a-local-project-command; return $?
  fi
  case "$command" in git) CLASSIFIED_OPERATION=git; classify_git "$@" ;; psql) CLASSIFIED_OPERATION=psql; classify_psql "$@" ;; *) return 0 ;; esac
}

classify_claude_args() {
  local arg flag value positional=0
  while [ "$#" -gt 0 ]; do
    arg=$1; shift
    if [ "$positional" -eq 0 ] && word_in_list "$arg" "$CLAUDE_EXPLORE_CLAUDE_BLOCKED_SUBCOMMANDS"; then
      blocked claude "$arg" claude-subcommand-deny operator-or-noninteractive-subcommand start-an-interactive-session; return $?
    fi
    case "$arg" in
      --claude-explore-*) runtime_error "reserved runtime argument: ${arg%%=*}"; return 2 ;;
    esac
    if word_in_list "$arg" "$CLAUDE_EXPLORE_CLAUDE_BLOCKED_FLAGS"; then
      blocked claude flag claude-startup-deny authority-changing-or-conflicting-option use-a-supported-interactive-option; return $?
    fi
    case "$arg" in
      --dangerously-skip-permissions=*|--allow-dangerously-skip-permissions=*|--settings=*|--setting-sources=*|--mcp-config=*|--strict-mcp-config=*|--permission-prompt-tool=*|--plugin-dir=*|--plugin-url=*|--agent=*|--agents=*|--channels=*|--chrome=*|--cloud=*|--remote=*|--environment=*|--remote-control=*|--rc=*|--add-dir=*|--worktree=*|--from-pr=*|--bg=*|--background=*|--exec=*|--print=*|--safe-mode=*|--bare=*|--system-prompt=*|--system-prompt-file=*|--append-system-prompt=*|--append-system-prompt-file=*|--append-subagent-system-prompt=*|--allowedTools=*|--allowed-tools=*|--disallowedTools=*|--disallowed-tools=*|--tools=*|--init=*|--init-only=*|--maintenance=*|--debug-file=*)
        blocked claude flag claude-startup-deny authority-changing-or-conflicting-option use-a-supported-interactive-option; return $? ;;
      --permission-mode=*) value=${arg#*=}; word_in_list "$value" "$CLAUDE_EXPLORE_ALLOWED_PERMISSION_MODES" || { blocked claude permission-mode claude-permission-mode unsupported-or-bypass-mode use-default-manual-acceptEdits-plan-auto-or-dontAsk; return $?; } ;;
      --debug=*) ;;
      --model=*|--effort=*|--fallback-model=*|--autocompact=*|--name=*|--resume=*|--session-id=*) [ -n "${arg#*=}" ] || { runtime_error "missing value for ${arg%%=*}"; return 2; } ;;
      -*)
        if word_in_list "$arg" "$CLAUDE_EXPLORE_CLAUDE_BOOLEAN_FLAGS"; then :
        elif word_in_list "$arg" "$CLAUDE_EXPLORE_CLAUDE_VALUE_FLAGS"; then
          [ "$#" -gt 0 ] || { runtime_error "missing value for $arg"; return 2; }
          value=$1; shift
          if [ "$arg" = --permission-mode ] && ! word_in_list "$value" "$CLAUDE_EXPLORE_ALLOWED_PERMISSION_MODES"; then
            blocked claude permission-mode claude-permission-mode unsupported-or-bypass-mode use-default-manual-acceptEdits-plan-auto-or-dontAsk; return $?
          fi
        else blocked claude unknown-option claude-option-closed-set unknown-option use-a-documented-supported-option; return $?; fi ;;
      *) positional=$((positional + 1)); [ "$positional" -le 1 ] || { runtime_error "more than one positional initial prompt is not supported"; return 2; } ;;
    esac
  done
  return 0
}

read_delegate() {
  local guard_dir=$1 command=$2 line key value found=0
  [ -f "$guard_dir/delegates" ] && [ ! -L "$guard_dir/delegates" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}; value=${line#*=}
    case "$key" in git|psql) ;; *) return 1 ;; esac
    [ "$key" != "$command" ] || { [ "$found" -eq 0 ] || return 1; DELEGATE=$value; found=1; }
  done < "$guard_dir/delegates"
  [ "$found" -eq 1 ] && [ -x "$DELEGATE" ] && [ "$($REALPATH_BIN "$DELEGATE" 2>/dev/null)" = "$DELEGATE" ]
}

internal_guard() {
  local guard_dir=$1 command=$2; shift 2
  classify_command "$command" "$@" || return $?
  if word_in_list "$command" "$CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"; then return 126; fi
  read_delegate "$guard_dir" "$command" || { runtime_error "guard delegate integrity failure"; return 125; }
  if [ "$command" = psql ]; then
    while IFS= read -r name; do unset "$name"; done <<EOF
$CLAUDE_EXPLORE_PG_ENV
EOF
  fi
  exec "$DELEGATE" "$@"
}

initialize_runtime_source || exit 1
if [ "${1:-}" = --internal-guard ]; then [ "$#" -ge 3 ] || exit 125; internal_guard "$2" "$3" "${@:4}"; exit $?; fi

file_mode() {
  if stat -f '%Lp' "$1" >/dev/null 2>&1; then stat -f '%Lp' "$1"; else stat -c '%a' "$1"; fi
}

file_uid() {
  if stat -f '%u' "$1" >/dev/null 2>&1; then stat -f '%u' "$1"; else stat -c '%u' "$1"; fi
}

safe_owned_file() {
  local path=$1 mode
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(file_uid "$path" 2>/dev/null)" = "$(id -u)" ] || return 1
  mode=$(file_mode "$path" 2>/dev/null) || return 1
  [ $((8#$mode & 022)) -eq 0 ]
}

safe_owned_dir() {
  local path=$1 mode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  [ "$(file_uid "$path" 2>/dev/null)" = "$(id -u)" ] || return 1
  mode=$(file_mode "$path" 2>/dev/null) || return 1
  [ $((8#$mode & 022)) -eq 0 ]
}

metadata_path() {
  CONFIG_ROOT=${XDG_CONFIG_HOME:-"$HOME/.config"}/agent-development-framework/claude-explore
  METADATA_FILE=$CONFIG_ROOT/install.meta
}

read_metadata() {
  local line key value count=0
  metadata_path
  safe_owned_file "$METADATA_FILE" || { runtime_error "installation metadata is missing or unsafe"; return 1; }
  [ "$(file_mode "$METADATA_FILE")" = 600 ] || { runtime_error "installation metadata mode must be 0600"; return 1; }
  META_SCHEMA= META_RUNTIME_ID= META_RUNTIME_VERSION= META_POLICY_VERSION= META_CLAUDE_LAUNCHER= META_REVISION=
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in *=*) ;; *) runtime_error "malformed installation metadata"; return 1 ;; esac
    key=${line%%=*}; value=${line#*=}
    [ -n "$value" ] || { runtime_error "empty installation metadata value"; return 1; }
    contains_control_character "$value" && { runtime_error "unsafe installation metadata value"; return 1; }
    case "$key" in
      schema_version) [ -z "$META_SCHEMA" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_SCHEMA=$value ;;
      runtime_id) [ -z "$META_RUNTIME_ID" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_RUNTIME_ID=$value ;;
      runtime_version) [ -z "$META_RUNTIME_VERSION" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_RUNTIME_VERSION=$value ;;
      policy_version) [ -z "$META_POLICY_VERSION" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_POLICY_VERSION=$value ;;
      claude_launcher_path) [ -z "$META_CLAUDE_LAUNCHER" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_CLAUDE_LAUNCHER=$value ;;
      source_framework_revision) [ -z "$META_REVISION" ] || { runtime_error "duplicate installation metadata field"; return 1; }; META_REVISION=$value ;;
      *) runtime_error "unknown installation metadata field"; return 1 ;;
    esac
    count=$((count + 1))
  done < "$METADATA_FILE"
  [ "$count" -eq 6 ] && [ "$META_SCHEMA" = 1 ] && [ "$META_RUNTIME_ID" = "$CLAUDE_EXPLORE_RUNTIME_ID" ] && \
    [ "$META_RUNTIME_VERSION" = "$CLAUDE_EXPLORE_RUNTIME_VERSION" ] && [ "$META_POLICY_VERSION" = "$CLAUDE_EXPLORE_POLICY_VERSION" ] || {
      runtime_error "installation metadata does not match this runtime"; return 1;
    }
  case "$META_CLAUDE_LAUNCHER" in /*) ;; *) runtime_error "recorded Claude launcher is not absolute"; return 1 ;; esac
  for value in "$HOME" "$CONFIG_ROOT" "$RUNTIME_ROOT"; do
    contains_control_character "$value" && { runtime_error "installation path contains a control character"; return 1; }
  done
  return 0
}

validate_installed_runtime() {
  local path resolved mode stable_launcher current_link
  for path in "$RUNTIME_ROOT/bin/claude-explore" "$RUNTIME_ROOT/lib/claude_explore_runtime.sh" "$RUNTIME_ROOT/lib/claude_explore_guard.sh" "$RUNTIME_ROOT/policy.sh"; do
    safe_owned_file "$path" || { runtime_error "installed runtime file is missing or unsafe"; return 1; }
    resolved=$($REALPATH_BIN "$path" 2>/dev/null) || return 1
    case "$resolved" in "$RUNTIME_ROOT"/*) ;; *) runtime_error "installed runtime file resolves outside installation"; return 1 ;; esac
  done
  safe_owned_dir "$DATA_INSTALL_ROOT" || { runtime_error "installed runtime directory is unsafe"; return 1; }
  current_link=$DATA_INSTALL_ROOT/current
  [ -L "$current_link" ] && [ "$($REALPATH_BIN "$current_link" 2>/dev/null)" = "$RUNTIME_ROOT" ] || { runtime_error "active runtime link is missing or unsafe"; return 1; }
  stable_launcher=$HOME/.local/bin/claude-explore
  [ -L "$stable_launcher" ] && [ "$($REALPATH_BIN "$stable_launcher" 2>/dev/null)" = "$RUNTIME_ROOT/bin/claude-explore" ] || { runtime_error "stable launcher is missing or unsafe"; return 1; }
  read_metadata || return 1
  safe_owned_dir "$CONFIG_ROOT" || { runtime_error "installation metadata directory is unsafe"; return 1; }
}

validate_claude() {
  local launcher=$META_CLAUDE_LAUNCHER target mode uid
  [ -e "$launcher" ] || { runtime_error "recorded Claude launcher is missing"; return 1; }
  target=$($REALPATH_BIN "$launcher" 2>/dev/null) || { runtime_error "recorded Claude launcher cannot be resolved"; return 1; }
  case "$target" in "$RUNTIME_ROOT"/*) runtime_error "recorded Claude launcher recurses into claude-explore"; return 1 ;; esac
  [ "$target" != "$SCRIPT_REAL" ] || { runtime_error "recorded Claude launcher resolves to claude-explore"; return 1; }
  [ -f "$target" ] && [ -x "$target" ] || { runtime_error "resolved Claude target is not an executable regular file"; return 1; }
  mode=$(file_mode "$target" 2>/dev/null) || return 1
  [ $((8#$mode & 022)) -eq 0 ] || { runtime_error "resolved Claude target is group/world writable"; return 1; }
  claude_version "$target" || { runtime_error "could not parse Claude Code version"; return 1; }
  version_at_least "$CLAUDE_VERSION" "$CLAUDE_EXPLORE_MINIMUM_CLIENT_VERSION" || {
    runtime_error "Claude Code $CLAUDE_VERSION is below required $CLAUDE_EXPLORE_MINIMUM_CLIENT_VERSION"; return 1;
  }
  CLAUDE_TARGET=$target
}

json_escape() {
  local input=$1 output="" char i=0
  while [ "$i" -lt "${#input}" ]; do
    char=${input:$i:1}
    case "$char" in
      '"') output=$output'\\"' ;; '\\') output=$output'\\\\' ;;
      $'\b') output=$output'\\b' ;; $'\f') output=$output'\\f' ;; $'\n') output=$output'\\n' ;; $'\r') output=$output'\\r' ;; $'\t') output=$output'\\t' ;;
      *) output=$output$char ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$output"
}

json_credential_files() {
  local path first=1
  while IFS= read -r path; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"path":"%s","mode":"deny"}' "$(json_escape "$path")"
  done <<EOF
$CLAUDE_EXPLORE_CREDENTIAL_PATHS
EOF
}

json_credential_env() {
  local name first=1
  while IFS= read -r name; do
    [ "$first" -eq 1 ] || printf ','
    first=0
    printf '{"name":"%s","mode":"deny"}' "$name"
  done <<EOF
$CLAUDE_EXPLORE_ENV_UNSET
EOF
}

json_permission_denies() {
  local path first=1 pattern
  while IFS= read -r path; do
    [ "$first" -eq 1 ] || printf ','; first=0
    printf '"Read(%s)","Read(%s/**)"' "$(json_escape "$path")" "$(json_escape "$path")"
  done <<EOF
$CLAUDE_EXPLORE_CREDENTIAL_PATHS
EOF
  for path in "$DATA_INSTALL_ROOT" "$CONFIG_ROOT" "$HOME/.local/bin/claude-explore" "$SESSION_DIR"; do
    [ "$first" -eq 1 ] || printf ','; first=0
    pattern=//${path#/}
    printf '"Edit(%s)","Edit(%s/**)"' "$(json_escape "$pattern")" "$(json_escape "$pattern")"
  done
  printf ',"mcp__*","Artifact"'
}

write_settings() {
  {
    printf '{"sandbox":{"enabled":true,"failIfUnavailable":true,"allowUnsandboxedCommands":false,"filesystem":{"disabled":false,"denyWrite":["%s","%s","%s","%s"]},"credentials":{"files":[' \
      "$(json_escape "$DATA_INSTALL_ROOT")" "$(json_escape "$CONFIG_ROOT")" "$(json_escape "$HOME/.local/bin/claude-explore")" "$(json_escape "$SESSION_DIR")"
    json_credential_files
    printf '],"envVars":['; json_credential_env
    printf ']}},"disableAllHooks":true,"disableArtifact":true,"permissions":{"deny":['; json_permission_denies
    printf ']}}\n'
  } > "$SETTINGS_FILE"
  printf '{"mcpServers":{}}\n' > "$MCP_FILE"
}

find_delegate() {
  local name=$1 found resolved
  found=$(PATH=$ORIGINAL_PATH command -v "$name" 2>/dev/null) || return 0
  case "$found" in /*) ;; *) return 0 ;; esac
  resolved=$($REALPATH_BIN "$found" 2>/dev/null) || return 0
  [ -x "$resolved" ] || return 0
  printf '%s=%s\n' "$name" "$resolved" >> "$DELEGATES_FILE"
}

make_session() {
  local base command
  umask 077
  base=${XDG_RUNTIME_DIR:-/tmp}
  case "$base" in /*) ;; *) base=/tmp ;; esac
  SESSION_DIR=$(mktemp -d "$base/claude-explore.XXXXXX") || return 1
  chmod 700 "$SESSION_DIR" || return 1
  GUARD_DIR=$SESSION_DIR/guard; mkdir "$GUARD_DIR" || return 1; chmod 700 "$GUARD_DIR"
  SETTINGS_FILE=$SESSION_DIR/settings.json; MCP_FILE=$SESSION_DIR/mcp.json; DELEGATES_FILE=$GUARD_DIR/delegates
  : > "$DELEGATES_FILE"
  find_delegate git; find_delegate psql
  chmod 600 "$DELEGATES_FILE"
  while IFS= read -r command; do ln -s "$RUNTIME_ROOT/lib/claude_explore_guard.sh" "$GUARD_DIR/$command" || return 1; done <<EOF
$CLAUDE_EXPLORE_GUARDED_EXECUTABLES
EOF
  mkdir "$SESSION_DIR/gh" || return 1
  printf '#!/bin/sh\necho "claude-explore: interactive Git authentication is disabled" >&2\nexit 1\n' > "$SESSION_DIR/askpass"
  chmod 700 "$SESSION_DIR/askpass"
  write_settings || return 1
}

cleanup_session() {
  [ -n "${SESSION_DIR:-}" ] || return 0
  case "$SESSION_DIR" in /tmp/claude-explore.*|"${XDG_RUNTIME_DIR:-/nonexistent}"/claude-explore.*) rm -rf -- "$SESSION_DIR" ;; esac
  SESSION_DIR=
}

strip_environment() {
  local name
  while IFS= read -r name; do unset "$name"; done <<EOF
$CLAUDE_EXPLORE_ENV_UNSET
EOF
  export GIT_TERMINAL_PROMPT=0 GCM_INTERACTIVE=never AWS_EC2_METADATA_DISABLED=true
  export CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1 CLAUDE_CODE_DISABLE_ARTIFACT=1
  export GH_CONFIG_DIR="$SESSION_DIR/gh" GIT_ASKPASS="$SESSION_DIR/askpass"
  export PATH="$GUARD_DIR:$ORIGINAL_PATH"
}

runtime_info() {
  validate_installed_runtime && validate_claude || return 1
  printf 'runtime_id=%s\nruntime_version=%s\npolicy_schema_version=%s\npolicy_version=%s\n' "$CLAUDE_EXPLORE_RUNTIME_ID" "$CLAUDE_EXPLORE_RUNTIME_VERSION" "$CLAUDE_EXPLORE_POLICY_SCHEMA_VERSION" "$CLAUDE_EXPLORE_POLICY_VERSION"
  printf 'installed_runtime_path=%s\nrecorded_claude_launcher_path=%s\nresolved_current_claude_path=%s\nclaude_version=%s\n' "$RUNTIME_ROOT" "$META_CLAUDE_LAUNCHER" "$CLAUDE_TARGET" "$CLAUDE_VERSION"
  case "$(uname -s)" in Darwin) printf 'supported_platform=macos\n' ;; Linux) printf 'supported_platform=linux\n' ;; *) printf 'supported_platform=unsupported\n' ;; esac
  printf 'sandbox_required=true\nunsandboxed_retry_allowed=false\nguarded_commands=%s\n' "$(printf '%s' "$CLAUDE_EXPLORE_GUARDED_EXECUTABLES" | tr '\n' ',')"
  printf 'stripped_environment=%s\ncredential_file_denies=%s\n' "$(printf '%s' "$CLAUDE_EXPLORE_ENV_UNSET" | tr '\n' ',')" "$(printf '%s' "$CLAUDE_EXPLORE_CREDENTIAL_PATHS" | tr '\n' ',')"
  printf 'known_limitations=same-user-bypass,absolute-path-bypass,finite-command-list,sandbox-permitted-network,application-mediated-services\n'
}

run_session() {
  local child_status signal=""; local -a injected_args
  validate_installed_runtime && validate_claude || return 1
  classify_claude_args "$@" || return $?
  make_session || { cleanup_session; runtime_error "could not create private session state"; return 1; }
  trap 'signal=INT; kill -INT "$CHILD_PID" 2>/dev/null || :' INT
  trap 'signal=TERM; kill -TERM "$CHILD_PID" 2>/dev/null || :' TERM
  trap cleanup_session EXIT
  strip_environment
  injected_args=(--settings "$SETTINGS_FILE" --strict-mcp-config --mcp-config "$MCP_FILE" --no-chrome --append-system-prompt "$CLAUDE_EXPLORE_GUIDANCE")
  "$CLAUDE_TARGET" "${injected_args[@]}" "$@" & CHILD_PID=$!
  while :; do
    wait "$CHILD_PID"; child_status=$?
    if [ "$child_status" -gt 128 ] && kill -0 "$CHILD_PID" 2>/dev/null; then continue; fi
    break
  done
  trap - INT TERM
  cleanup_session; trap - EXIT
  return "$child_status"
}

case "${1:-}" in
  --claude-explore-runtime-info) [ "$#" -eq 1 ] || { runtime_error "runtime-info takes no arguments"; exit 2; }; runtime_info; exit $? ;;
  --claude-explore-check-command)
    shift; [ "${1:-}" = -- ] || { runtime_error "check-command requires -- before argv"; exit 2; }; shift
    classify_command "$@"; status=$?
    if [ "$status" -eq 0 ]; then classified command "$CLASSIFIED_OPERATION" allowed policy; fi
    exit "$status" ;;
  --claude-explore-*) runtime_error "unknown reserved runtime operation"; exit 2 ;;
esac
run_session "$@"
exit $?
