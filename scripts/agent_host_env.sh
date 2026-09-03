#!/usr/bin/env bash
set -euo pipefail

validate_ruby_requirement() {
  local version_file=".ruby-version"
  local required_declaration=""
  local extra_line=""
  local first_status=1
  local extra_status=1
  local required_version=""
  local ruby_path=""
  local actual_version=""

  if [[ ! -f "$version_file" || ! -r "$version_file" ]]; then
    echo "Error: .ruby-version is missing or unreadable; it must declare the repository Ruby requirement." >&2
    return 1
  fi

  # Read one logical line while retaining enough information to reject any
  # additional lines. A trailing newline is allowed, as is the current file's
  # absence of a final newline.
  exec 3< "$version_file"
  if IFS= read -r required_declaration <&3; then
    first_status=0
  else
    first_status=$?
  fi
  if IFS= read -r extra_line <&3; then
    extra_status=0
  else
    extra_status=$?
  fi
  exec 3<&-

  if [[ "$first_status" -ne 0 && -z "$required_declaration" ]] || [[ -n "$extra_line" ]] || [[ "$extra_status" -eq 0 ]]; then
    echo "Error: .ruby-version must contain exactly one Ruby version in the form ruby-X.Y.Z." >&2
    return 1
  fi

  if [[ ! "$required_declaration" =~ ^ruby-([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Error: .ruby-version must contain exactly one Ruby version in the form ruby-X.Y.Z." >&2
    return 1
  fi
  required_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.${BASH_REMATCH[3]}"

  if ! ruby_path="$(command -v ruby 2>/dev/null)" || [[ -z "$ruby_path" ]] || [[ ! -x "$ruby_path" ]]; then
    echo "Error: agent host Ruby unavailable: .ruby-version requires Ruby $required_version, but no ruby executable is available through the selected host PATH." >&2
    echo "Prepare the host shell before launching Codex." >&2
    return 1
  fi

  if ! actual_version="$("$ruby_path" -e 'print RUBY_VERSION' 2>/dev/null)"; then
    echo "Error: could not determine the Ruby version for PATH-resolved executable $ruby_path (required Ruby $required_version)." >&2
    echo "Prepare the host shell before launching Codex." >&2
    return 1
  fi
  if [[ ! "$actual_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Error: could not determine the Ruby version for PATH-resolved executable $ruby_path (required Ruby $required_version)." >&2
    echo "Prepare the host shell before launching Codex." >&2
    return 1
  fi

  if [[ "$actual_version" != "$required_version" ]]; then
    echo "Error: agent host Ruby mismatch: .ruby-version requires Ruby $required_version, but PATH resolves $ruby_path as Ruby $actual_version." >&2
    echo "Prepare the host shell before launching Codex." >&2
    return 1
  fi
}

validate_ruby_requirement
