#!/bin/sh
unset BASH_ENV ENV CDPATH
unset SHELLOPTS 2>/dev/null || :
unset BASHOPTS 2>/dev/null || :

guard_fail() {
  printf '%s\n' "CLAUDE_EXPLORE_BLOCKED runtime=claude-explore policy_version=1 category=guard operation=internal rule=guard-integrity reason=$1 safe_next_action=report-runtime-error" >&2
  exit 125
}

if [ -x /usr/bin/realpath ]; then REALPATH_BIN=/usr/bin/realpath
elif [ -x /bin/realpath ]; then REALPATH_BIN=/bin/realpath
else guard_fail realpath-unavailable
fi
SELF_REAL=$($REALPATH_BIN "$0" 2>/dev/null) || guard_fail guard-unresolvable
RUNTIME_ROOT=$(/usr/bin/dirname "$(/usr/bin/dirname "$SELF_REAL")")
RUNTIME_LIB="$RUNTIME_ROOT/lib/claude_explore_runtime.sh"
file_mode() { if /usr/bin/stat -f '%Lp' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%Lp' "$1"; else /usr/bin/stat -c '%a' "$1"; fi; }
file_uid() { if /usr/bin/stat -f '%u' "$1" >/dev/null 2>&1; then /usr/bin/stat -f '%u' "$1"; else /usr/bin/stat -c '%u' "$1"; fi; }
trusted_file() {
  trusted_path=$1 trusted_kind=$2
  [ -f "$trusted_path" ] && [ ! -L "$trusted_path" ] || return 1
  [ "$(file_uid "$trusted_path" 2>/dev/null)" = "$(/usr/bin/id -u)" ] || return 1
  trusted_mode=$(file_mode "$trusted_path" 2>/dev/null) || return 1
  [ $((0$trusted_mode & 022)) -eq 0 ] || return 1
  [ "$($REALPATH_BIN "$trusted_path" 2>/dev/null)" = "$trusted_path" ] || return 1
  if [ "$trusted_kind" = executable ]; then [ -x "$trusted_path" ]; else [ ! -x "$trusted_path" ]; fi
}
trusted_file "$RUNTIME_ROOT/bin/claude-explore" executable &&
  trusted_file "$RUNTIME_ROOT/lib/claude_explore_runtime.sh" executable &&
  trusted_file "$RUNTIME_ROOT/lib/claude_explore_guard.sh" executable &&
  trusted_file "$RUNTIME_ROOT/policy.sh" policy || guard_fail runtime-content-unsafe
COMMAND_NAME=$(/usr/bin/basename "$0")
GUARD_DIR=$($REALPATH_BIN "$(/usr/bin/dirname -- "$0")" 2>/dev/null) || guard_fail guard-directory-unresolvable
exec /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc -p "$RUNTIME_LIB" --internal-guard "$GUARD_DIR" "$COMMAND_NAME" "$@"
