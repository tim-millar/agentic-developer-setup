# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "socket"
require "tmpdir"
require_relative "../lib/agent_run_usage/validator"

class RunUsageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  COLLECTOR = File.join(ROOT, "baseline/scripts/agent_run_usage_collector.rb")
  USAGE_HELPER = File.join(ROOT, "baseline/scripts/agent_run_usage.sh")
  TELEMETRY_HELPER = File.join(ROOT, "baseline/scripts/agent_run_telemetry.sh")
  VALIDATOR = File.join(ROOT, "scripts/validate_run_usage.rb")
  RUN_ID = "run-20300102T030405Z-0123456789abcdef0123456789abcdef"

  def setup
    @root = Dir.mktmpdir("run-usage-test-")
    @processes = []
  end

  def teardown
    Array(@processes).each do |pid|
      Process.kill("KILL", pid) if process_alive?(pid)
      begin
        Process.wait(pid)
      rescue Errno::ECHILD
        nil
      end
    end
    FileUtils.remove_entry_secure(@root) if @root && File.exist?(@root)
  end

  def test_claude_multiple_requests_models_sessions_cost_and_privacy
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    records = [
      log_record("claude_code.user_prompt", "prompt" => "SECRET PROMPT"),
      log_record("claude_code.api_request", {
        "session.id" => "session-b", "event.sequence" => 9, "model" => "claude-model-a",
        "input_tokens" => 100, "output_tokens" => 20, "cache_read_tokens" => 80,
        "cache_creation_tokens" => 10, "cost_usd_micros" => 12_345,
        "duration_ms" => 900, "speed" => "fast", "query_source" => "compact", "effort" => "high",
        "prompt" => "SECRET PROMPT", "response" => "SECRET RESPONSE", "tool_input" => "SECRET TOOL",
        "user.email" => "private@example.test", "user.account_uuid" => "account-secret"
      }),
      log_record("claude_code.tool_result", "tool_result" => "SECRET RESULT"),
      log_record("claude_code.api_request", {
        "session.id" => "session-a", "event.sequence" => 1, "model" => "claude-model-b",
        "input_tokens" => 7, "output_tokens" => 3, "cache_read_tokens" => 0,
        "cache_creation_tokens" => 2, "cost_usd_micros" => 55,
        "duration_ms" => 50, "speed" => "normal", "query_source" => "agent.builtin.general-purpose"
      })
    ]
    post(collector, payload(records))
    record = stop_collector(collector)

    assert_equal "complete", record.dig("collection", "state")
    assert_equal ["session-a", "session-b"], record["provider_sessions"]
    assert_equal ["claude-model-a", "claude-model-b"], record["measurements"].map { |item| item["model"] }
    assert_equal [1, 2], record["measurements"].map { |item| item["sequence"] }
    assert_equal 199, record.dig("observed_totals", "input_total")
    assert_nil record.dig("observed_totals", "output_reasoning")
    assert_equal 12_400, record.dig("cost_summary", "observed_usd_micros")
    assert_equal "runtime_estimated", record.dig("cost_summary", "semantics")
    persisted = JSON.generate(record)
    %w[SECRET private@example.test account-secret].each { |secret| refute_includes persisted, secret }
    assert_valid(record)
  end

  def test_codex_completed_requests_normalize_tokens_and_leave_cost_unavailable
    collector = start_collector("openai", "codex_otel_response_completed_v1")
    records = [
      log_record("codex.sse_event", {
        "event.kind" => "response.completed", "conversation.id" => "thread-1", "model" => "gpt-a",
        "input_token_count" => 100, "output_token_count" => 30, "cached_token_count" => 60,
        "cache_write_token_count" => 10, "reasoning_token_count" => 12,
        "service_tier" => "priority", "model_reasoning_effort" => "high"
      }),
      log_record("codex.sse_event", {"event.kind" => "response.started", "model" => "ignored"}),
      log_record("codex.sse_event", {
        "event.kind" => "response.completed", "conversation.id" => "thread-1", "model" => "gpt-b",
        "input_token_count" => 20, "output_token_count" => 4, "cached_token_count" => 5,
        "cache_write_token_count" => 0, "reasoning_token_count" => 1
      })
    ]
    post(collector, payload(records))
    record = stop_collector(collector)

    assert_equal "complete", record.dig("collection", "state")
    assert_equal [40, 15], record["measurements"].map { |item| item.dig("tokens", "input_uncached") }
    assert_equal 13, record.dig("observed_totals", "output_reasoning")
    assert_equal "unavailable", record.dig("cost_summary", "state")
    assert_equal "source_does_not_report_cost", record.dig("cost_summary", "reason")
    assert_valid(record)
  end

  def test_codex_cache_write_is_not_subtracted_from_uncached_input
    collector = start_collector("openai", "codex_otel_response_completed_v1")
    post(collector, payload([log_record("codex.sse_event", {
      "event.kind" => "response.completed", "model" => "gpt-current", "input_token_count" => 3,
      "output_token_count" => 5, "cached_token_count" => 1, "cache_write_token_count" => 2,
      "reasoning_token_count" => 2
    })]))
    record = stop_collector(collector)

    assert_equal "complete", record.dig("collection", "state")
    assert_equal({
      "input_total" => 3,
      "input_uncached" => 2,
      "input_cache_read" => 1,
      "input_cache_write" => 2,
      "output_total" => 5,
      "output_reasoning" => 2
    }, record.dig("measurements", 0, "tokens"))
    assert_valid(record)
  end

  def test_claude_cost_is_partial_when_only_some_measurements_report_runtime_cost
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    records = [
      claude_record("session", input: 5, output: 2),
      log_record("claude_code.api_request", {
        "session.id" => "session", "model" => "claude-model", "input_tokens" => 7,
        "output_tokens" => 3, "cache_read_tokens" => 0, "cache_creation_tokens" => 0
      })
    ]
    post(collector, payload(records))
    record = stop_collector(collector)

    assert_equal "complete", record.dig("collection", "state")
    assert_equal "partial", record.dig("cost_summary", "state")
    assert_equal "runtime_cost_missing", record.dig("cost_summary", "reason")
    assert_equal 10, record.dig("cost_summary", "observed_usd_micros")
    assert_equal 1, record.dig("cost_summary", "priced_measurement_count")
    assert_equal 2, record.dig("cost_summary", "measurement_count")
    assert_valid(record)
  end

  def test_inconsistent_codex_cache_counts_are_preserved_and_mark_collection_partial
    collector = start_collector("openai", "codex_otel_response_completed_v1")
    post(collector, payload([log_record("codex.sse_event", {
      "event.kind" => "response.completed", "model" => "gpt-a", "input_token_count" => 10,
      "output_token_count" => 2, "cached_token_count" => 11, "cache_write_token_count" => 4,
      "reasoning_token_count" => 1
    })]))
    record = stop_collector(collector)

    assert_equal "partial", record.dig("collection", "state")
    assert_equal "normalization_inconsistent", record.dig("collection", "reason")
    assert_includes record.dig("collection", "warnings"), "codex_cached_input_exceeds_total"
    assert_nil record.dig("measurements", 0, "tokens", "input_uncached")
    assert_equal 11, record.dig("measurements", 0, "native_usage", "cached_token_count")
    assert_valid(record)
  end

  def test_zero_qualifying_requests_is_complete_not_applicable_usage
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post(collector, payload([log_record("claude_code.tool_result", "tool_result" => "not persisted")]))
    record = stop_collector(collector)

    assert_equal "complete", record.dig("collection", "state")
    assert_empty record["measurements"]
    assert_equal 0, record.dig("observed_totals", "input_total")
    assert_nil record.dig("observed_totals", "output_reasoning")
    assert_equal "not_applicable", record.dig("cost_summary", "state")
    assert_valid(record)
  end

  def test_malformed_otel_containers_are_unavailable_not_zero_usage
    malformed_payloads = [
      {"resourceLogs" => "not-an-array"},
      {"resourceLogs" => ["not-an-object"]},
      {"resourceLogs" => [{"scopeLogs" => "not-an-array"}]},
      {"resourceLogs" => [{"scopeLogs" => ["not-an-object"]}]},
      {"resourceLogs" => [{"scopeLogs" => [{"logRecords" => "not-an-array"}]}]},
      {"resourceLogs" => [{"scopeLogs" => [{"logRecords" => ["not-an-object"]}]}]}
    ]

    malformed_payloads.each_with_index do |malformed_payload, index|
      collector = start_collector(
        "anthropic",
        "claude_code_otel_api_request_v1",
        run_id: distinct_run_id(index + 1)
      )
      post(collector, malformed_payload)
      record = stop_collector(collector)

      assert_equal "unavailable", record.dig("collection", "state"), malformed_payload.inspect
      assert_equal "collector_parse_failed", record.dig("collection", "reason"), malformed_payload.inspect
      assert_includes record.dig("collection", "warnings"), "relevant_event_malformed"
      assert_empty record["measurements"]
      assert_nil record.dig("observed_totals", "input_total")
      assert_nil record.dig("observed_totals", "output_total")
      assert_valid(record)
    end
  end

  def test_structurally_valid_empty_otel_containers_are_complete_zero_usage
    empty_payloads = [
      {},
      {"resourceLogs" => []},
      {"resourceLogs" => [{}]},
      {"resourceLogs" => [{"scopeLogs" => []}]},
      {"resourceLogs" => [{"scopeLogs" => [{}]}]},
      {"resourceLogs" => [{"scopeLogs" => [{"logRecords" => []}]}]}
    ]

    empty_payloads.each_with_index do |empty_payload, index|
      collector = start_collector(
        "anthropic",
        "claude_code_otel_api_request_v1",
        run_id: distinct_run_id(index + 101)
      )
      post(collector, empty_payload)
      record = stop_collector(collector)

      assert_equal "complete", record.dig("collection", "state"), empty_payload.inspect
      assert_nil record.dig("collection", "reason")
      assert_empty record["measurements"]
      assert_equal 0, record.dig("observed_totals", "input_total")
      assert_equal "not_applicable", record.dig("cost_summary", "state")
      assert_valid(record)
    end
  end

  def test_malformed_container_after_valid_record_in_same_payload_retains_partial_measurement
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post(collector, payload([claude_record("same-session", input: 4, output: 2), "not-an-object"]))
    record = stop_collector(collector)

    assert_equal "partial", record.dig("collection", "state")
    assert_equal "collector_parse_failed", record.dig("collection", "reason")
    assert_includes record.dig("collection", "warnings"), "relevant_event_malformed"
    assert_equal 1, record["measurements"].length
    assert_equal "same-session", record.dig("measurements", 0, "provider_session_id")
    assert_equal 4, record.dig("observed_totals", "input_total")
    assert_valid(record)
  end

  def test_malformed_payload_after_valid_evidence_retains_partial_measurement
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post(collector, payload([claude_record("same-session", input: 4, output: 2)]))
    post_raw(collector, "{not-json")
    record = stop_collector(collector)

    assert_equal "partial", record.dig("collection", "state")
    assert_equal "collector_parse_failed", record.dig("collection", "reason")
    assert_equal 1, record["measurements"].length
    assert_valid(record)
  end

  def test_malformed_payload_without_evidence_is_unavailable_not_zero_usage
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post_raw(collector, "{not-json")
    record = stop_collector(collector)

    assert_equal "unavailable", record.dig("collection", "state")
    assert_equal "collector_parse_failed", record.dig("collection", "reason")
    assert_empty record["measurements"]
    assert_nil record.dig("observed_totals", "input_total")
    assert_valid(record)
  end

  def test_abrupt_collector_failure_leaves_normalized_partial_checkpoint
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post(collector, payload([claude_record("session", input: 8, output: 3)]))
    Process.kill("KILL", collector.fetch(:pid))
    begin
      Process.wait(collector.fetch(:pid))
    rescue Errno::ECHILD
      nil
    end
    @processes.delete(collector.fetch(:pid))
    script = <<~BASH
      source "$1"
      source "$2"
      AGENT_TELEMETRY_ACTIVE=1
      AGENT_TELEMETRY_RUN_ID="$3"
      AGENT_TELEMETRY_RUN_DIR="$4"
      AGENT_USAGE_MODE=active
      AGENT_USAGE_PREFER_CHECKPOINT=1
      agent_usage_publish
    BASH
    _stdout, stderr, status = Open3.capture3(
      "/bin/bash", "-c", script, "usage-test", TELEMETRY_HELPER, USAGE_HELPER, RUN_ID, collector.fetch(:directory)
    )
    assert status.success?, stderr
    record = JSON.parse(File.binread(File.join(collector.fetch(:directory), "usage.json")))

    assert_equal "partial", record.dig("collection", "state")
    assert_equal "collector_shutdown_incomplete", record.dig("collection", "reason")
    assert_equal 1, record["measurements"].length
    assert_valid(record)
  end

  def test_same_provider_session_in_separate_runs_is_not_cumulative
    first = start_collector("anthropic", "claude_code_otel_api_request_v1", run_id: RUN_ID)
    post(first, payload([claude_record("resumed-session", input: 5, output: 1)]))
    first_record = stop_collector(first)

    second_id = "run-20300102T030406Z-fedcba9876543210fedcba9876543210"
    second = start_collector("anthropic", "claude_code_otel_api_request_v1", run_id: second_id)
    post(second, payload([claude_record("resumed-session", input: 7, output: 2)]))
    second_record = stop_collector(second)

    assert_equal 5, first_record.dig("observed_totals", "input_uncached")
    assert_equal 7, second_record.dig("observed_totals", "input_uncached")
    assert_equal ["resumed-session"], first_record["provider_sessions"]
    assert_equal ["resumed-session"], second_record["provider_sessions"]
  end

  def test_disabled_collection_writes_valid_restricted_terminal_sidecar
    directory = create_retained_run
    script = <<~BASH
      source "$1"
      source "$2"
      AGENT_TELEMETRY_ACTIVE=1
      AGENT_TELEMETRY_RUN_ID="$3"
      AGENT_TELEMETRY_RUN_DIR="$4"
      AGENT_USAGE_TELEMETRY=0
      agent_usage_start openai codex_otel_response_completed_v1 1.2.3 /missing/collector /missing/ruby
      agent_usage_stop
      agent_usage_publish
    BASH
    _stdout, stderr, status = Open3.capture3("/bin/bash", "-c", script, "usage-test", TELEMETRY_HELPER, USAGE_HELPER, RUN_ID, directory)
    assert status.success?, stderr
    path = File.join(directory, "usage.json")
    record = JSON.parse(File.binread(path))
    assert_equal "disabled", record.dig("collection", "state")
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_valid(record)
  end

  def test_run_finalized_before_collection_setup_records_source_unavailable
    directory = create_retained_run
    script = <<~BASH
      source "$1"
      source "$2"
      AGENT_TELEMETRY_ACTIVE=1
      AGENT_TELEMETRY_RUN_ID="$3"
      AGENT_TELEMETRY_RUN_DIR="$4"
      agent_usage_publish
    BASH
    _stdout, stderr, status = Open3.capture3("/bin/bash", "-c", script, "usage-test", TELEMETRY_HELPER, USAGE_HELPER, RUN_ID, directory)
    assert status.success?, stderr
    record = JSON.parse(File.binread(File.join(directory, "usage.json")))
    assert_equal "unavailable", record.dig("collection", "state")
    assert_equal "source_unavailable", record.dig("collection", "reason")
    assert_nil record.dig("observed_totals", "input_total")
    assert_valid(record)
  end

  def test_existing_terminal_usage_is_not_overwritten
    directory = create_retained_run
    path = File.join(directory, "usage.json")
    File.binwrite(path, "terminal sentinel\n")
    script = <<~BASH
      source "$1"
      source "$2"
      AGENT_TELEMETRY_ACTIVE=1
      AGENT_TELEMETRY_RUN_ID="$3"
      AGENT_TELEMETRY_RUN_DIR="$4"
      AGENT_USAGE_TELEMETRY=0
      agent_usage_start openai codex_otel_response_completed_v1 1.2.3 /missing/collector /missing/ruby
      agent_usage_publish
    BASH
    _stdout, _stderr, status = Open3.capture3("/bin/bash", "-c", script, "usage-test", TELEMETRY_HELPER, USAGE_HELPER, RUN_ID, directory)
    assert status.success?
    assert_equal "terminal sentinel\n", File.binread(path)
  end

  def test_usage_publication_does_not_create_a_sidecar_without_a_retained_run
    script = <<~BASH
      source "$1"
      source "$2"
      AGENT_TELEMETRY_ACTIVE=0
      AGENT_TELEMETRY_RUN_ID=""
      AGENT_TELEMETRY_RUN_DIR=""
      agent_usage_publish
    BASH
    _stdout, stderr, status = Open3.capture3("/bin/bash", "-c", script, "usage-test", TELEMETRY_HELPER, USAGE_HELPER)

    assert status.success?, stderr
    assert_empty Dir.children(@root)
  end

  def test_semantic_validator_rejects_adversarial_inconsistencies_without_crashing
    collector = start_collector("openai", "codex_otel_response_completed_v1")
    post(collector, payload([log_record("codex.sse_event", {
      "event.kind" => "response.completed", "model" => "gpt-a", "input_token_count" => 10,
      "output_token_count" => 2, "cached_token_count" => 2, "cache_write_token_count" => 1,
      "reasoning_token_count" => 1
    })]))
    valid = stop_collector(collector)

    mutations = [
      ->(record) { record["unexpected"] = "secret" },
      ->(record) { record["observed_totals"]["input_total"] = 999 },
      ->(record) { record["measurements"][0]["native_usage"]["input_token_count"] = -1 },
      lambda do |record|
        record["measurements"][0]["native_usage"]["output_token_count"] = nil
        record["measurements"][0]["tokens"]["output_total"] = nil
        record["observed_totals"]["output_total"] = nil
      end,
      ->(record) { record["measurements"][0]["provider"] = "anthropic" },
      ->(record) { record["cost_summary"]["state"] = "complete" }
    ]
    mutations.each do |mutation|
      record = Marshal.load(Marshal.dump(valid))
      mutation.call(record)
      validator = AgentRunUsage::Validator.new(record)
      refute validator.validate
      refute_empty validator.errors
    end
  end

  def test_cli_validator_and_runtime_copies_remain_in_parity
    collector = start_collector("anthropic", "claude_code_otel_api_request_v1")
    post(collector, payload([claude_record("session", input: 3, output: 1)]))
    record = stop_collector(collector)
    path = File.join(@root, "usage.json")
    File.binwrite(path, JSON.pretty_generate(record))
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR, path)
    assert status.success?, stderr
    assert_includes stdout, "validation passed"

    assert_equal File.binread(USAGE_HELPER), File.binread(File.join(ROOT, "agent-runtimes/claude-explore/lib/agent_run_usage.sh"))
    assert_equal File.binread(COLLECTOR), File.binread(File.join(ROOT, "agent-runtimes/claude-explore/lib/agent_run_usage_collector.rb"))
  end

  private

  def distinct_run_id(suffix)
    "run-20300102T030405Z-#{format("%032x", suffix)}"
  end

  def start_collector(provider, source_interface, run_id: RUN_ID)
    directory = create_retained_run(run_id)
    ready = File.join(directory, ".usage.ready")
    pid = Process.spawn(
      RbConfig.ruby, "--disable-gems", COLLECTOR,
      "--run-dir", directory, "--run-id", run_id, "--provider", provider,
      "--source-interface", source_interface, "--client-version", "2.1.224",
      "--ready-file", ready,
      in: File::NULL, out: File::NULL, err: File::NULL
    )
    @processes << pid
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.file?(ready)
      raise "collector did not become ready" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline || !process_alive?(pid)
      sleep 0.01
    end
    port, token = File.readlines(ready, chomp: true)
    {pid:, directory:, port: Integer(port, 10), token:}
  end

  def create_retained_run(run_id = RUN_ID)
    directory = File.join(@root, run_id)
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.binwrite(File.join(directory, "run.json"), "{}\n")
    directory
  end

  def stop_collector(collector)
    Process.kill("TERM", collector.fetch(:pid))
    Process.wait(collector.fetch(:pid))
    @processes.delete(collector.fetch(:pid))
    JSON.parse(File.binread(File.join(collector.fetch(:directory), ".usage.finalized.json")))
  end

  def post(collector, body)
    response = post_raw(collector, JSON.generate(body))
    assert_includes response, "200 OK"
    response
  end

  def post_raw(collector, body)
    socket = TCPSocket.new("127.0.0.1", collector.fetch(:port))
    socket.write("POST /v1/logs HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nx-agent-run-usage-token: #{collector.fetch(:token)}\r\nConnection: close\r\n\r\n#{body}")
    response = socket.read
    socket.close
    response
  end

  def payload(records)
    {"resourceLogs" => [{"resource" => {"attributes" => [{"key" => "user.email", "value" => {"stringValue" => "resource-secret@example.test"}}]}, "scopeLogs" => [{"logRecords" => records}]}]}
  end

  def log_record(name, attributes)
    {
      "body" => {"stringValue" => name},
      "attributes" => attributes.map { |key, value| {"key" => key, "value" => otel_value(value)} }
    }
  end

  def claude_record(session, input:, output:)
    log_record("claude_code.api_request", {
      "session.id" => session, "model" => "claude-model", "input_tokens" => input,
      "output_tokens" => output, "cache_read_tokens" => 0, "cache_creation_tokens" => 0,
      "cost_usd_micros" => 10
    })
  end

  def otel_value(value)
    case value
    when Integer then {"intValue" => value.to_s}
    when Float then {"doubleValue" => value}
    when TrueClass, FalseClass then {"boolValue" => value}
    else {"stringValue" => value.to_s}
    end
  end

  def assert_valid(record)
    validator = AgentRunUsage::Validator.new(record)
    assert validator.validate, validator.errors.join("\n")
  end

  def process_alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH, Errno::ECHILD
    false
  end
end
