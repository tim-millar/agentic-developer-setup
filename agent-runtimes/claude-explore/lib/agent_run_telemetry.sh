#!/usr/bin/env bash

# Common schema-v1 execution telemetry primitives for framework launchers.
# This file is sourced by a runtime-specific launcher; it is not an entrypoint.

AGENT_TELEMETRY_ACTIVE=0
AGENT_TELEMETRY_TERMINAL=0
AGENT_TELEMETRY_PREFLIGHT_COMPLETE=0
AGENT_TELEMETRY_LAUNCH_INTENT=0
AGENT_TELEMETRY_RUN_ID=""
AGENT_TELEMETRY_RUN_DIR=""
AGENT_TELEMETRY_RUN_FILE=""
AGENT_TELEMETRY_STARTED_EPOCH=""
AGENT_TELEMETRY_RUN_STARTED_AT=""
AGENT_TELEMETRY_CHILD_STARTED_AT=""
AGENT_TELEMETRY_CHILD_FINISHED_AT=""
AGENT_TELEMETRY_RUN_FINISHED_AT=""
AGENT_TELEMETRY_CALENDAR_ELAPSED_MS=""
AGENT_TELEMETRY_STATE="started"
AGENT_TELEMETRY_SIGNAL=""
AGENT_TELEMETRY_CHILD_EXIT_CODE=""
AGENT_TELEMETRY_TERMINATION_REASON=""
AGENT_TELEMETRY_CLIENT_ID=""
AGENT_TELEMETRY_CLIENT_VERSION_KIND="unavailable"
AGENT_TELEMETRY_CLIENT_VERSION_VALUE=""
AGENT_TELEMETRY_HARNESS_ID=""
AGENT_TELEMETRY_HARNESS_VERSION=""
AGENT_TELEMETRY_HARNESS_REVISION=""
AGENT_TELEMETRY_SESSION_KIND="unavailable"
AGENT_TELEMETRY_SESSION_VALUE=""
AGENT_TELEMETRY_MODEL_REQUESTED_KIND="unavailable"
AGENT_TELEMETRY_MODEL_REQUESTED_VALUE=""
AGENT_TELEMETRY_MODEL_REQUESTED_SOURCE=""
AGENT_TELEMETRY_EFFORT_REQUESTED_KIND="unavailable"
AGENT_TELEMETRY_EFFORT_REQUESTED_VALUE=""
AGENT_TELEMETRY_EFFORT_REQUESTED_SOURCE=""
AGENT_TELEMETRY_REPOSITORY_KIND="path_digest"
AGENT_TELEMETRY_REPOSITORY_VALUE=""
AGENT_TELEMETRY_TASK_SOURCE="unavailable"
AGENT_TELEMETRY_TASK_IDENTIFIER=""
AGENT_TELEMETRY_TASK_DIGEST=""
AGENT_TELEMETRY_TASK_SNAPSHOT=""
AGENT_TELEMETRY_GIT_START_AVAILABLE=0
AGENT_TELEMETRY_GIT_FINISH_AVAILABLE=0
AGENT_TELEMETRY_WRITE_SEQUENCE=0

agent_telemetry_warning() {
  printf 'AGENT_TELEMETRY_WARNING: %s\n' "$1" >&2
}

agent_telemetry_timestamp() {
  /bin/date -u '+%Y-%m-%dT%H:%M:%S.000Z'
}

agent_telemetry_sha256_file() {
  local path=$1 output
  if [[ -x /usr/bin/shasum ]]; then
    output=$(/usr/bin/shasum -a 256 "$path" 2>/dev/null) || return 1
  elif [[ -x /usr/bin/sha256sum ]]; then
    output=$(/usr/bin/sha256sum "$path" 2>/dev/null) || return 1
  elif [[ -x /bin/sha256sum ]]; then
    output=$(/bin/sha256sum "$path" 2>/dev/null) || return 1
  else
    return 1
  fi
  printf 'sha256:%s' "${output%%[[:space:]]*}"
}

agent_telemetry_sha256_stdin() {
  local output
  if [[ -x /usr/bin/shasum ]]; then
    output=$(/usr/bin/shasum -a 256 2>/dev/null) || return 1
  elif [[ -x /usr/bin/sha256sum ]]; then
    output=$(/usr/bin/sha256sum 2>/dev/null) || return 1
  elif [[ -x /bin/sha256sum ]]; then
    output=$(/bin/sha256sum 2>/dev/null) || return 1
  else
    return 1
  fi
  printf 'sha256:%s' "${output%%[[:space:]]*}"
}

agent_telemetry_json_escape() {
  local input=$1 output="" char escaped code i=0
  local LC_ALL=C
  while [[ "$i" -lt "${#input}" ]]; do
    char=${input:$i:1}
    case "$char" in
      '"') output=$output'\"' ;;
      '\') output=$output'\\' ;;
      $'\b') output=$output'\b' ;;
      $'\t') output=$output'\t' ;;
      $'\n') output=$output'\n' ;;
      $'\f') output=$output'\f' ;;
      $'\r') output=$output'\r' ;;
      *)
        printf -v code '%d' "'$char"
        if [[ "$code" -lt 32 ]]; then
          printf -v escaped '\\u%04x' "$code"
          output=$output$escaped
        else
          output=$output$char
        fi
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$output"
}

agent_telemetry_json_string() {
  printf '"%s"' "$(agent_telemetry_json_escape "$1")"
}

agent_telemetry_json_nullable_string() {
  if [[ -n "$1" ]]; then agent_telemetry_json_string "$1"; else printf 'null'; fi
}

agent_telemetry_render_observation() {
  local kind=$1 value=$2 source=${3:-} include_source=${4:-0}
  printf '{"evidence_kind":'
  agent_telemetry_json_string "$kind"
  printf ',"value":'
  if [[ "$kind" == unavailable || "$kind" == not_applicable ]]; then
    printf 'null'
  else
    agent_telemetry_json_string "$value"
  fi
  if [[ "$include_source" == 1 ]]; then
    printf ',"source":'
    agent_telemetry_json_nullable_string "$source"
  fi
  printf '}'
}

agent_telemetry_render_git_state() {
  local phase=$1 variable available branch detached head dirty staged unstaged untracked
  variable="AGENT_TELEMETRY_GIT_${phase}_AVAILABLE"; available=${!variable}
  if [[ "$available" != 1 ]]; then printf 'null'; return; fi
  variable="AGENT_TELEMETRY_GIT_${phase}_BRANCH"; branch=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_DETACHED"; detached=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_HEAD"; head=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_DIRTY"; dirty=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_STAGED"; staged=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_UNSTAGED"; unstaged=${!variable}
  variable="AGENT_TELEMETRY_GIT_${phase}_UNTRACKED"; untracked=${!variable}
  printf '{"branch":'; agent_telemetry_json_nullable_string "$branch"
  printf ',"detached":%s,"head_sha":' "$detached"; agent_telemetry_json_string "$head"
  printf ',"dirty":%s,"staged_count":%s,"unstaged_count":%s,"untracked_count":%s}' \
    "$dirty" "$staged" "$unstaged" "$untracked"
}

agent_telemetry_render_record() {
  printf '{\n  "schema_version": 1,\n  "run_id": '
  agent_telemetry_json_string "$AGENT_TELEMETRY_RUN_ID"
  printf ',\n  "state": '; agent_telemetry_json_string "$AGENT_TELEMETRY_STATE"
  printf ',\n  "runtime": {\n    "client": {"id": '; agent_telemetry_json_string "$AGENT_TELEMETRY_CLIENT_ID"
  printf ', "version": '; agent_telemetry_render_observation "$AGENT_TELEMETRY_CLIENT_VERSION_KIND" "$AGENT_TELEMETRY_CLIENT_VERSION_VALUE"
  printf '},\n    "harness": {"id": '; agent_telemetry_json_string "$AGENT_TELEMETRY_HARNESS_ID"
  printf ', "version": %s, "revision": ' "$AGENT_TELEMETRY_HARNESS_VERSION"; agent_telemetry_json_string "$AGENT_TELEMETRY_HARNESS_REVISION"
  printf '},\n    "session": '; agent_telemetry_render_observation "$AGENT_TELEMETRY_SESSION_KIND" "$AGENT_TELEMETRY_SESSION_VALUE"
  printf '\n  },\n  "configuration": {\n    "model": {\n      "requested": '
  agent_telemetry_render_observation "$AGENT_TELEMETRY_MODEL_REQUESTED_KIND" "$AGENT_TELEMETRY_MODEL_REQUESTED_VALUE" "$AGENT_TELEMETRY_MODEL_REQUESTED_SOURCE" 1
  printf ',\n      "initial_effective": '; agent_telemetry_render_observation unavailable "" "" 1
  printf '\n    },\n    "reasoning_effort": {\n      "requested": '
  agent_telemetry_render_observation "$AGENT_TELEMETRY_EFFORT_REQUESTED_KIND" "$AGENT_TELEMETRY_EFFORT_REQUESTED_VALUE" "$AGENT_TELEMETRY_EFFORT_REQUESTED_SOURCE" 1
  printf ',\n      "initial_effective": '; agent_telemetry_render_observation unavailable "" "" 1
  printf '\n    },\n    "configuration_stability": "unknown"\n  },\n  "repository": {\n    "identity": {"kind": '
  agent_telemetry_json_string "$AGENT_TELEMETRY_REPOSITORY_KIND"
  printf ', "value": '; agent_telemetry_json_string "$AGENT_TELEMETRY_REPOSITORY_VALUE"
  printf '},\n    "start": '; agent_telemetry_render_git_state START
  printf ',\n    "finish": '; agent_telemetry_render_git_state FINISH
  printf '\n  },\n  "task": {"source": '; agent_telemetry_json_string "$AGENT_TELEMETRY_TASK_SOURCE"
  printf ', "identifier": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_TASK_IDENTIFIER"
  printf ', "content_sha256": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_TASK_DIGEST"
  printf ', "snapshot": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_TASK_SNAPSHOT"
  printf '},\n  "timing": {"run_started_at": '; agent_telemetry_json_string "$AGENT_TELEMETRY_RUN_STARTED_AT"
  printf ', "child_started_at": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_CHILD_STARTED_AT"
  printf ', "child_finished_at": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_CHILD_FINISHED_AT"
  printf ', "run_finished_at": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_RUN_FINISHED_AT"
  printf ', "calendar_elapsed_ms": '
  if [[ -n "$AGENT_TELEMETRY_CALENDAR_ELAPSED_MS" ]]; then printf '%s' "$AGENT_TELEMETRY_CALENDAR_ELAPSED_MS"; else printf 'null'; fi
  printf '},\n  "termination": {"child_exit_code": '
  if [[ -n "$AGENT_TELEMETRY_CHILD_EXIT_CODE" ]]; then printf '%s' "$AGENT_TELEMETRY_CHILD_EXIT_CODE"; else printf 'null'; fi
  printf ', "signal": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_SIGNAL"
  printf ', "reason": '; agent_telemetry_json_nullable_string "$AGENT_TELEMETRY_TERMINATION_REASON"
  printf '},\n  "extensions": {}\n}\n'
}

agent_telemetry_write_record() {
  local temporary
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 ]] || return 0
  AGENT_TELEMETRY_WRITE_SEQUENCE=$((AGENT_TELEMETRY_WRITE_SEQUENCE + 1))
  temporary="$AGENT_TELEMETRY_RUN_DIR/.run.json.tmp.$$.$AGENT_TELEMETRY_WRITE_SEQUENCE"
  if ! (umask 077; agent_telemetry_render_record > "$temporary") 2>/dev/null; then
    /bin/rm -f -- "$temporary" 2>/dev/null || true
    agent_telemetry_warning "could not stage run record"
    return 1
  fi
  if ! /bin/chmod 600 "$temporary" 2>/dev/null || ! /bin/mv -f "$temporary" "$AGENT_TELEMETRY_RUN_FILE" 2>/dev/null; then
    /bin/rm -f -- "$temporary" 2>/dev/null || true
    agent_telemetry_warning "could not atomically publish run record"
    return 1
  fi
  return 0
}

agent_telemetry_random_hex() {
  local output
  if [[ -x /usr/bin/od ]]; then
    output=$(/usr/bin/od -An -N16 -tx1 /dev/urandom 2>/dev/null) || return 1
  elif [[ -x /bin/od ]]; then
    output=$(/bin/od -An -N16 -tx1 /dev/urandom 2>/dev/null) || return 1
  else
    return 1
  fi
  output=${output//$'\n'/}
  output=${output// /}
  [[ "$output" =~ ^[0-9a-f]{32}$ ]] || return 1
  printf '%s' "$output"
}

agent_telemetry_start() {
  local client_id=$1 harness_id=$2 harness_version=$3 harness_path=$4 repository_hint=$5
  local root timestamp random run_id candidate digest attempts=0 old_umask
  [[ "${AGENT_TELEMETRY:-1}" != 0 ]] || return 0
  if [[ ${AGENT_TELEMETRY_DIR+x} ]]; then
    root=${AGENT_TELEMETRY_DIR:-}
    case "$root" in /*) ;; *) agent_telemetry_warning "AGENT_TELEMETRY_DIR must be absolute; telemetry disabled"; return 0 ;; esac
  elif [[ ${XDG_DATA_HOME+x} ]]; then
    case "${XDG_DATA_HOME:-}" in /*) root=$XDG_DATA_HOME/agent-development-framework/telemetry/runs ;; *) agent_telemetry_warning "XDG_DATA_HOME must be absolute; telemetry disabled"; return 0 ;; esac
  else
    case "${HOME:-}" in /*) root=$HOME/.local/share/agent-development-framework/telemetry/runs ;; *) agent_telemetry_warning "HOME must be absolute; telemetry disabled"; return 0 ;; esac
  fi
  digest=$(agent_telemetry_sha256_file "$harness_path") || { agent_telemetry_warning "could not identify execution harness; telemetry disabled"; return 0; }
  timestamp=$(/bin/date -u '+%Y%m%dT%H%M%SZ') || { agent_telemetry_warning "could not create run timestamp; telemetry disabled"; return 0; }
  old_umask=$(umask); umask 077
  if ! /bin/mkdir -p "$root" 2>/dev/null; then umask "$old_umask"; agent_telemetry_warning "could not create telemetry run root"; return 0; fi
  while [[ "$attempts" -lt 10 ]]; do
    random=$(agent_telemetry_random_hex) || break
    run_id="run-${timestamp}-${random}"
    candidate=$root/$run_id
    if /bin/mkdir "$candidate" 2>/dev/null; then break; fi
    candidate=""; attempts=$((attempts + 1))
  done
  umask "$old_umask"
  if [[ -z "$candidate" ]]; then agent_telemetry_warning "could not create a unique telemetry run directory"; return 0; fi
  /bin/chmod 700 "$candidate" 2>/dev/null || {
    /bin/rmdir -- "$candidate" 2>/dev/null || true
    agent_telemetry_warning "could not protect telemetry run directory"
    return 0
  }
  AGENT_TELEMETRY_ACTIVE=1
  AGENT_TELEMETRY_RUN_ID=$run_id
  AGENT_TELEMETRY_RUN_DIR=$candidate
  AGENT_TELEMETRY_RUN_FILE=$candidate/run.json
  AGENT_TELEMETRY_STARTED_EPOCH=$(/bin/date '+%s')
  AGENT_TELEMETRY_RUN_STARTED_AT=$(agent_telemetry_timestamp)
  AGENT_TELEMETRY_CLIENT_ID=$client_id
  AGENT_TELEMETRY_HARNESS_ID=$harness_id
  AGENT_TELEMETRY_HARNESS_VERSION=$harness_version
  AGENT_TELEMETRY_HARNESS_REVISION=$digest
  if [[ -n "$repository_hint" ]]; then
    digest=$(printf '%s' "$repository_hint" | agent_telemetry_sha256_stdin) || digest=""
  fi
  AGENT_TELEMETRY_REPOSITORY_VALUE=$digest
  if [[ -z "$AGENT_TELEMETRY_REPOSITORY_VALUE" ]] || ! agent_telemetry_write_record; then
    AGENT_TELEMETRY_ACTIVE=0
    /bin/rm -f -- "$AGENT_TELEMETRY_RUN_FILE" 2>/dev/null || true
    /bin/rmdir -- "$AGENT_TELEMETRY_RUN_DIR" 2>/dev/null || true
    agent_telemetry_warning "could not persist initial run record; telemetry disabled"
  fi
}

agent_telemetry_set_client_version() {
  AGENT_TELEMETRY_CLIENT_VERSION_KIND=runtime_observed
  AGENT_TELEMETRY_CLIENT_VERSION_VALUE=$1
}

agent_telemetry_set_session() {
  AGENT_TELEMETRY_SESSION_KIND=$1
  AGENT_TELEMETRY_SESSION_VALUE=$2
}

agent_telemetry_set_requested_configuration() {
  local kind=$1 value=$2 source=$3
  case "$kind" in
    model) AGENT_TELEMETRY_MODEL_REQUESTED_KIND=launcher_requested; AGENT_TELEMETRY_MODEL_REQUESTED_VALUE=$value; AGENT_TELEMETRY_MODEL_REQUESTED_SOURCE=$source ;;
    reasoning_effort) AGENT_TELEMETRY_EFFORT_REQUESTED_KIND=launcher_requested; AGENT_TELEMETRY_EFFORT_REQUESTED_VALUE=$value; AGENT_TELEMETRY_EFFORT_REQUESTED_SOURCE=$source ;;
  esac
}

agent_telemetry_observe_repository() {
  local git_bin=$1 root=$2 remote remainder owner repository canonical digest
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 ]] || return 0
  if [[ -n "$git_bin" ]]; then remote=$("$git_bin" -C "$root" remote get-url origin 2>/dev/null || true); else remote=""; fi
  case "$remote" in
    https://github.com/*) remainder=${remote#https://github.com/} ;;
    git@github.com:*) remainder=${remote#git@github.com:} ;;
    ssh://git@github.com/*) remainder=${remote#ssh://git@github.com/} ;;
    *) remainder="" ;;
  esac
  if [[ -n "$remainder" ]]; then
    owner=${remainder%%/*}; repository=${remainder#*/}; repository=${repository%.git}
    if [[ -n "$owner" && -n "$repository" && "$repository" != */* ]]; then
      AGENT_TELEMETRY_REPOSITORY_KIND=github
      AGENT_TELEMETRY_REPOSITORY_VALUE=$owner/$repository
      return 0
    fi
  fi
  canonical=$(cd "$root" 2>/dev/null && pwd -P) || return 1
  digest=$(printf '%s' "$canonical" | agent_telemetry_sha256_stdin) || return 1
  AGENT_TELEMETRY_REPOSITORY_KIND=path_digest
  AGENT_TELEMETRY_REPOSITORY_VALUE=$digest
}

agent_telemetry_capture_git() {
  local phase=$1 git_bin=$2 root=$3 status_file record xy x y head branch detached staged=0 unstaged=0 untracked=0 dirty=false
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 ]] || return 0
  [[ -n "$git_bin" ]] || return 1
  head=$("$git_bin" -C "$root" rev-parse HEAD 2>/dev/null) || return 1
  branch=$("$git_bin" -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  if [[ -n "$branch" ]]; then detached=false; else detached=true; fi
  status_file=$AGENT_TELEMETRY_RUN_DIR/.git-status.$$.$phase
  if ! (umask 077; "$git_bin" -C "$root" status --porcelain=v1 -z --untracked-files=all > "$status_file") 2>/dev/null; then
    /bin/rm -f -- "$status_file" 2>/dev/null || true
    return 1
  fi
  exec 8< "$status_file"
  while IFS= read -r -d '' record <&8; do
    xy=${record:0:2}; x=${xy:0:1}; y=${xy:1:1}
    if [[ "$xy" == '??' ]]; then
      untracked=$((untracked + 1))
    else
      [[ "$x" == ' ' || "$x" == '?' ]] || staged=$((staged + 1))
      [[ "$y" == ' ' || "$y" == '?' ]] || unstaged=$((unstaged + 1))
      if [[ "$x" == R || "$x" == C || "$y" == R || "$y" == C ]]; then IFS= read -r -d '' record <&8 || true; fi
    fi
  done
  exec 8<&-
  /bin/rm -f -- "$status_file" 2>/dev/null || true
  [[ "$staged" -eq 0 && "$unstaged" -eq 0 && "$untracked" -eq 0 ]] || dirty=true
  printf -v "AGENT_TELEMETRY_GIT_${phase}_AVAILABLE" '%s' 1
  printf -v "AGENT_TELEMETRY_GIT_${phase}_BRANCH" '%s' "$branch"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_DETACHED" '%s' "$detached"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_HEAD" '%s' "$head"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_DIRTY" '%s' "$dirty"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_STAGED" '%s' "$staged"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_UNSTAGED" '%s' "$unstaged"
  printf -v "AGENT_TELEMETRY_GIT_${phase}_UNTRACKED" '%s' "$untracked"
}

agent_telemetry_set_task() {
  local source=$1 identifier=$2 content=$3 temporary digest
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 ]] || return 0
  temporary=$AGENT_TELEMETRY_RUN_DIR/.task.txt.tmp.$$
  if ! (umask 077; printf '%s' "$content" > "$temporary") 2>/dev/null; then agent_telemetry_warning "could not stage task snapshot"; return 1; fi
  digest=$(agent_telemetry_sha256_file "$temporary") || { /bin/rm -f -- "$temporary"; agent_telemetry_warning "could not digest task snapshot"; return 1; }
  if ! /bin/chmod 600 "$temporary" 2>/dev/null || ! /bin/mv "$temporary" "$AGENT_TELEMETRY_RUN_DIR/task.txt" 2>/dev/null; then
    /bin/rm -f -- "$temporary" 2>/dev/null || true
    agent_telemetry_warning "could not publish task snapshot"
    return 1
  fi
  AGENT_TELEMETRY_TASK_SOURCE=$source
  AGENT_TELEMETRY_TASK_IDENTIFIER=$identifier
  AGENT_TELEMETRY_TASK_DIGEST=$digest
  AGENT_TELEMETRY_TASK_SNAPSHOT=task.txt
}

agent_telemetry_mark_preflight_complete() { AGENT_TELEMETRY_PREFLIGHT_COMPLETE=1; }
agent_telemetry_mark_launch_intent() { AGENT_TELEMETRY_LAUNCH_INTENT=1; }
agent_telemetry_mark_child_started() { AGENT_TELEMETRY_CHILD_STARTED_AT=$(agent_telemetry_timestamp); agent_telemetry_write_record || true; }
agent_telemetry_mark_child_finished() { AGENT_TELEMETRY_CHILD_EXIT_CODE=$1; AGENT_TELEMETRY_CHILD_FINISHED_AT=$(agent_telemetry_timestamp); }

agent_telemetry_finalize() {
  local state=$1 reason=$2 git_bin=$3 root=$4 finished_epoch
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 && "$AGENT_TELEMETRY_TERMINAL" == 0 ]] || return 0
  AGENT_TELEMETRY_TERMINAL=1
  AGENT_TELEMETRY_STATE=$state
  AGENT_TELEMETRY_TERMINATION_REASON=$reason
  if [[ -n "$git_bin" && -n "$root" ]]; then agent_telemetry_capture_git FINISH "$git_bin" "$root" || agent_telemetry_warning "could not observe finish Git state"; fi
  AGENT_TELEMETRY_RUN_FINISHED_AT=$(agent_telemetry_timestamp)
  finished_epoch=$(/bin/date '+%s')
  AGENT_TELEMETRY_CALENDAR_ELAPSED_MS=$(((finished_epoch - AGENT_TELEMETRY_STARTED_EPOCH) * 1000))
  agent_telemetry_write_record || true
}

agent_telemetry_finalize_pending() {
  local process_status=$1 git_bin=$2 root=$3 state reason
  [[ "$AGENT_TELEMETRY_ACTIVE" == 1 && "$AGENT_TELEMETRY_TERMINAL" == 0 ]] || return 0
  if [[ -n "$AGENT_TELEMETRY_SIGNAL" ]]; then
    state=interrupted; reason=signal
    [[ -n "$AGENT_TELEMETRY_CHILD_EXIT_CODE" ]] || AGENT_TELEMETRY_CHILD_EXIT_CODE=$process_status
  elif [[ -n "$AGENT_TELEMETRY_CHILD_FINISHED_AT" ]]; then
    if [[ "$AGENT_TELEMETRY_CHILD_EXIT_CODE" -eq 0 ]]; then state=completed; reason=child_exited_successfully
    elif [[ "$AGENT_TELEMETRY_CHILD_EXIT_CODE" -eq 127 ]]; then state=launch_failed; reason=child_launch_failed
    else state=runtime_failed; reason=child_exited_nonzero; fi
  elif [[ "$AGENT_TELEMETRY_LAUNCH_INTENT" == 1 ]]; then
    state=launch_failed; reason=child_launch_failed
  elif [[ "$AGENT_TELEMETRY_PREFLIGHT_COMPLETE" == 1 ]]; then
    state=launcher_failed; reason=launcher_failed
  else
    state=preflight_failed; reason=preflight_rejected
  fi
  agent_telemetry_finalize "$state" "$reason" "$git_bin" "$root"
}
