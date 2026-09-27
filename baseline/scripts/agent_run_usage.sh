#!/usr/bin/env bash

# Terminal schema-v1 provider usage evidence for framework-managed runs.
# This helper is sourced after agent_run_telemetry.sh.

AGENT_USAGE_MODE="inactive"
AGENT_USAGE_PROVIDER=""
AGENT_USAGE_SOURCE_INTERFACE=""
AGENT_USAGE_CLIENT_VERSION=""
AGENT_USAGE_COLLECTOR_PID=""
AGENT_USAGE_COLLECTOR_SNAPSHOT=""
AGENT_USAGE_READY_FILE=""
AGENT_USAGE_PORT=""
AGENT_USAGE_NONCE=""
AGENT_USAGE_FALLBACK_REASON=""
AGENT_USAGE_EXISTING_RECORD="0"
AGENT_USAGE_PREFER_CHECKPOINT="0"

agent_usage_warning() {
  printf 'AGENT_USAGE_WARNING: %s\n' "$1" >&2
}

agent_usage_start() {
  local provider="$1" source_interface="$2" client_version="$3" collector_source="$4" ruby_bin="$5"
  local attempt port nonce

  [[ "${AGENT_TELEMETRY_ACTIVE:-0}" == 1 && -n "${AGENT_TELEMETRY_RUN_ID:-}" && -n "${AGENT_TELEMETRY_RUN_DIR:-}" ]] || return 0
  AGENT_USAGE_PROVIDER="$provider"
  AGENT_USAGE_SOURCE_INTERFACE="$source_interface"
  AGENT_USAGE_CLIENT_VERSION="$client_version"

  if [[ -e "$AGENT_TELEMETRY_RUN_DIR/usage.json" || -L "$AGENT_TELEMETRY_RUN_DIR/usage.json" ]]; then
    AGENT_USAGE_EXISTING_RECORD="1"
    AGENT_USAGE_MODE="existing"
    agent_usage_warning "terminal usage record already exists; automatic collection skipped"
    return 0
  fi
  if [[ "${AGENT_USAGE_TELEMETRY:-1}" == 0 ]]; then
    AGENT_USAGE_MODE="disabled"
    AGENT_USAGE_SOURCE_INTERFACE=""
    return 0
  fi

  if [[ -z "$ruby_bin" || ! -x "$ruby_bin" || ! -f "$collector_source" || -L "$collector_source" ]]; then
    AGENT_USAGE_MODE="unavailable"
    AGENT_USAGE_FALLBACK_REASON="collector_unavailable"
    agent_usage_warning "trusted local collector dependency is unavailable"
    return 0
  fi

  AGENT_USAGE_COLLECTOR_SNAPSHOT="$AGENT_TELEMETRY_RUN_DIR/.usage.collector.rb"
  AGENT_USAGE_READY_FILE="$AGENT_TELEMETRY_RUN_DIR/.usage.ready"
  if [[ -e "$AGENT_USAGE_COLLECTOR_SNAPSHOT" || -L "$AGENT_USAGE_COLLECTOR_SNAPSHOT" ]] ||
     ! /bin/cp -n "$collector_source" "$AGENT_USAGE_COLLECTOR_SNAPSHOT" 2>/dev/null ||
     [[ ! -f "$AGENT_USAGE_COLLECTOR_SNAPSHOT" || -L "$AGENT_USAGE_COLLECTOR_SNAPSHOT" ]] ||
     ! /bin/chmod 700 "$AGENT_USAGE_COLLECTOR_SNAPSHOT" 2>/dev/null; then
    AGENT_USAGE_MODE="unavailable"
    AGENT_USAGE_FALLBACK_REASON="collector_setup_failed"
    agent_usage_warning "local collector setup failed"
    return 0
  fi

  /usr/bin/env \
    -u RUBYOPT -u RUBYLIB -u BUNDLE_GEMFILE -u GEM_HOME -u GEM_PATH \
    "$ruby_bin" --disable-gems "$AGENT_USAGE_COLLECTOR_SNAPSHOT" \
      --run-dir "$AGENT_TELEMETRY_RUN_DIR" \
      --run-id "$AGENT_TELEMETRY_RUN_ID" \
      --provider "$provider" \
      --source-interface "$source_interface" \
      --client-version "$client_version" \
      --ready-file "$AGENT_USAGE_READY_FILE" \
      </dev/null >/dev/null 2>&1 &
  AGENT_USAGE_COLLECTOR_PID=$!

  for attempt in {1..100}; do
    if [[ -f "$AGENT_USAGE_READY_FILE" && ! -L "$AGENT_USAGE_READY_FILE" ]]; then
      port=$(/usr/bin/sed -n '1p' "$AGENT_USAGE_READY_FILE" 2>/dev/null || true)
      nonce=$(/usr/bin/sed -n '2p' "$AGENT_USAGE_READY_FILE" 2>/dev/null || true)
      if [[ "$port" =~ ^[0-9]+$ && "$port" -ge 1 && "$port" -le 65535 && "$nonce" =~ ^[0-9a-f]{64}$ ]]; then
        AGENT_USAGE_PORT="$port"
        AGENT_USAGE_NONCE="$nonce"
        AGENT_USAGE_MODE="active"
        return 0
      fi
    fi
    kill -0 "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || break
    /bin/sleep 0.05 2>/dev/null || break
  done

  kill -TERM "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
  wait "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
  AGENT_USAGE_COLLECTOR_PID=""
  AGENT_USAGE_MODE="unavailable"
  AGENT_USAGE_FALLBACK_REASON="collector_setup_failed"
  agent_usage_warning "local collector did not become ready"
}

agent_usage_codex_exporter_config() {
  [[ "$AGENT_USAGE_MODE" == active ]] || return 1
  printf 'otel.exporter={ otlp-http = { endpoint = "http://127.0.0.1:%s/v1/logs", protocol = "json", headers = { "x-agent-run-usage-token" = "%s" } } }' \
    "$AGENT_USAGE_PORT" "$AGENT_USAGE_NONCE"
}

agent_usage_stop() {
  local attempt terminal="$AGENT_TELEMETRY_RUN_DIR/.usage.finalized.json"
  [[ "$AGENT_USAGE_MODE" == active && -n "$AGENT_USAGE_COLLECTOR_PID" ]] || return 0

  if ! kill -0 "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null; then
    wait "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
    AGENT_USAGE_COLLECTOR_PID=""
    AGENT_USAGE_PREFER_CHECKPOINT="1"
    AGENT_USAGE_FALLBACK_REASON="collector_shutdown_incomplete"
    return 0
  fi
  kill -TERM "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
  for attempt in {1..100}; do
    [[ -f "$terminal" && ! -L "$terminal" ]] && break
    /bin/sleep 0.05 2>/dev/null || break
  done
  if [[ ! -f "$terminal" || -L "$terminal" ]]; then
    kill -KILL "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
    AGENT_USAGE_FALLBACK_REASON="collector_shutdown_incomplete"
  fi
  wait "$AGENT_USAGE_COLLECTOR_PID" 2>/dev/null || true
  AGENT_USAGE_COLLECTOR_PID=""
}

agent_usage_render_fallback() {
  local state="$1" reason="$2" source_json client_json input_total input_uncached cache_read cache_write output_total output_reasoning
  local timestamp

  timestamp=$(agent_telemetry_timestamp 2>/dev/null || /bin/date -u '+%Y-%m-%dT%H:%M:%S.000Z')
  if [[ -n "$AGENT_USAGE_SOURCE_INTERFACE" ]]; then source_json=$(agent_telemetry_json_string "$AGENT_USAGE_SOURCE_INTERFACE"); else source_json=null; fi
  if [[ -n "$AGENT_USAGE_CLIENT_VERSION" ]]; then client_json=$(agent_telemetry_json_string "$AGENT_USAGE_CLIENT_VERSION"); else client_json=null; fi
  if [[ "$state" == unavailable || -z "$AGENT_USAGE_SOURCE_INTERFACE" ]]; then
    input_total=null; input_uncached=null; cache_read=null; cache_write=null; output_total=null; output_reasoning=null
  else
    input_total=0; input_uncached=0; cache_read=0; cache_write=0; output_total=0
    if [[ "$AGENT_USAGE_PROVIDER" == anthropic ]]; then output_reasoning=null; else output_reasoning=0; fi
  fi
  printf '{\n'
  printf '  "schema_version": 1,\n  "run_id": %s,\n' "$(agent_telemetry_json_string "$AGENT_TELEMETRY_RUN_ID")"
  printf '  "collection": {"state": %s, "source_interface": %s, "client_version": %s, "finalized_at": %s, "reason": %s, "warnings": []},\n' \
    "$(agent_telemetry_json_string "$state")" "$source_json" "$client_json" "$(agent_telemetry_json_string "$timestamp")" "$(agent_telemetry_json_string "$reason")"
  printf '  "provider_sessions": [],\n  "measurements": [],\n'
  printf '  "observed_totals": {"measurement_count": 0, "input_total": %s, "input_uncached": %s, "input_cache_read": %s, "input_cache_write": %s, "output_total": %s, "output_reasoning": %s},\n' \
    "$input_total" "$input_uncached" "$cache_read" "$cache_write" "$output_total" "$output_reasoning"
  printf '  "cost_summary": {"state": "not_applicable", "semantics": null, "currency": null, "observed_usd_micros": null, "priced_measurement_count": 0, "measurement_count": 0, "reason": null}\n'
  printf '}\n'
}

agent_usage_publish() {
  local candidate="$AGENT_TELEMETRY_RUN_DIR/.usage.finalized.json"
  local fallback="$AGENT_TELEMETRY_RUN_DIR/.usage.fallback.$$" reason
  local usage="$AGENT_TELEMETRY_RUN_DIR/usage.json"

  [[ "${AGENT_TELEMETRY_ACTIVE:-0}" == 1 && -n "${AGENT_TELEMETRY_RUN_DIR:-}" ]] || return 0
  [[ "$AGENT_USAGE_EXISTING_RECORD" == 0 ]] || return 0

  if [[ "$AGENT_USAGE_MODE" == disabled ]]; then
    (set -o noclobber; umask 077; agent_usage_render_fallback disabled usage_telemetry_disabled > "$fallback") 2>/dev/null || true
    candidate="$fallback"
  elif [[ "$AGENT_USAGE_MODE" == unavailable ]]; then
    reason=${AGENT_USAGE_FALLBACK_REASON:-collector_unavailable}
    (set -o noclobber; umask 077; agent_usage_render_fallback unavailable "$reason" > "$fallback") 2>/dev/null || true
    candidate="$fallback"
  elif [[ "$AGENT_USAGE_MODE" == inactive ]]; then
    (set -o noclobber; umask 077; agent_usage_render_fallback unavailable source_unavailable > "$fallback") 2>/dev/null || true
    candidate="$fallback"
  elif [[ "$AGENT_USAGE_PREFER_CHECKPOINT" == 1 ]]; then
    candidate="$AGENT_TELEMETRY_RUN_DIR/.usage.checkpoint.json"
    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
      (set -o noclobber; umask 077; agent_usage_render_fallback unavailable collector_shutdown_incomplete > "$fallback") 2>/dev/null || true
      candidate="$fallback"
    fi
  elif [[ ! -f "$candidate" || -L "$candidate" ]]; then
    candidate="$AGENT_TELEMETRY_RUN_DIR/.usage.checkpoint.json"
    if [[ ! -f "$candidate" || -L "$candidate" ]]; then
      reason=${AGENT_USAGE_FALLBACK_REASON:-collector_shutdown_incomplete}
      (set -o noclobber; umask 077; agent_usage_render_fallback unavailable "$reason" > "$fallback") 2>/dev/null || true
      candidate="$fallback"
    fi
  fi

  if [[ -f "$candidate" && ! -L "$candidate" && ! -e "$usage" && ! -L "$usage" ]]; then
    if /bin/ln "$candidate" "$usage" 2>/dev/null; then
      /bin/chmod 600 "$usage" 2>/dev/null || true
    elif [[ ! -e "$usage" && ! -L "$usage" ]]; then
      agent_usage_warning "terminal usage record could not be published"
    fi
  fi
  /bin/rm -f -- \
    "$AGENT_TELEMETRY_RUN_DIR/.usage.ready" \
    "$AGENT_TELEMETRY_RUN_DIR/.usage.collector.rb" \
    "$AGENT_TELEMETRY_RUN_DIR/.usage.checkpoint.json" \
    "$AGENT_TELEMETRY_RUN_DIR/.usage.finalized.json" \
    "$fallback" 2>/dev/null || true
}
