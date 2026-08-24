#!/bin/sh
unset BASH_ENV ENV CDPATH
if [ ! -x /bin/bash ]; then
  echo "claude-explore installer: required executable is unavailable: /bin/bash" >&2
  exit 1
fi
if ! /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc -c '[ "$BASH_VERSINFO" -gt 3 ] || { [ "$BASH_VERSINFO" -eq 3 ] && [ "${BASH_VERSINFO[1]}" -ge 2 ]; }' 2>/dev/null; then
  echo "claude-explore installer: /bin/bash >= 3.2 is required" >&2
  exit 1
fi
SCRIPT_DIR=$(CDPATH= cd -- "$(/usr/bin/dirname -- "$0")" 2>/dev/null && pwd -P) || exit 1
exec /usr/bin/env -u BASH_ENV -u ENV -u SHELLOPTS -u BASHOPTS -u CDPATH /bin/bash --noprofile --norc "$SCRIPT_DIR/lib/claude_explore_installer.sh" "$@"
