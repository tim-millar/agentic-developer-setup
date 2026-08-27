#!/bin/sh
unset BASH_ENV ENV CDPATH
unset SHELLOPTS 2>/dev/null || :
unset BASHOPTS 2>/dev/null || :
if [ ! -x /bin/bash ]; then
  echo "claude-explore installer: required executable is unavailable: /bin/bash" >&2
  exit 1
fi
if ! /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc -p -c '[ "$BASH_VERSINFO" -gt 3 ] || { [ "$BASH_VERSINFO" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }' 2>/dev/null; then
  echo "claude-explore installer: /bin/bash >= 3.2 is required" >&2
  exit 1
fi
SCRIPT_DIR=$(/usr/bin/dirname -- "$0")
if [ -x /usr/bin/realpath ]; then REALPATH_BIN=/usr/bin/realpath
elif [ -x /bin/realpath ]; then REALPATH_BIN=/bin/realpath
else
  echo "claude-explore installer: required executable is unavailable: realpath" >&2
  exit 1
fi
SOURCE_ROOT=$($REALPATH_BIN "$SCRIPT_DIR" 2>/dev/null) || exit 1
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
trusted_file "$SOURCE_ROOT/install.sh" executable &&
  trusted_file "$SOURCE_ROOT/bin/claude-explore" executable &&
  trusted_file "$SOURCE_ROOT/lib/claude_explore_installer.sh" executable &&
  trusted_file "$SOURCE_ROOT/lib/claude_explore_runtime.sh" executable &&
  trusted_file "$SOURCE_ROOT/lib/claude_explore_guard.sh" executable &&
  trusted_file "$SOURCE_ROOT/policy.sh" policy || {
    echo "claude-explore installer: source runtime content is missing or unsafe" >&2
    exit 1
  }
exec /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc -p "$SOURCE_ROOT/lib/claude_explore_installer.sh" "$@"
