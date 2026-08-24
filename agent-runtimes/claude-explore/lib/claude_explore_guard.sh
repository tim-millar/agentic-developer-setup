#!/bin/sh
unset BASH_ENV ENV CDPATH

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
[ -f "$RUNTIME_LIB" ] || guard_fail runtime-library-missing
COMMAND_NAME=$(/usr/bin/basename "$0")
GUARD_DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" 2>/dev/null && pwd -P) || guard_fail guard-directory-unresolvable
exec /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc "$RUNTIME_LIB" --internal-guard "$GUARD_DIR" "$COMMAND_NAME" "$@"
