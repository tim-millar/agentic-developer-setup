#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "securerandom"
require "socket"
require "time"

class AgentRunUsageCollector
  MAX_BODY_BYTES = 1_048_576
  TOKEN_HEADER = "x-agent-run-usage-token"
  TOKEN_FIELDS = %w[input_total input_uncached input_cache_read input_cache_write output_total output_reasoning].freeze
  CLAUDE_ATTRIBUTES = %w[
    event.name session.id event.sequence model input_tokens output_tokens cache_read_tokens
    cache_creation_tokens cost_usd_micros duration_ms speed query_source effort
  ].freeze
  CODEX_ATTRIBUTES = %w[
    event.name event.kind conversation.id model input_token_count output_token_count
    cached_token_count cache_write_token_count reasoning_token_count service_tier model_reasoning_effort
  ].freeze

  def initialize(arguments)
    @options = parse_arguments(arguments)
    @measurements = []
    @warnings = []
    @failure_reason = nil
    @stopping = false
    @server = nil
    validate_options!
  end

  def run
    umask = File.umask(0o077)
    File.umask(umask)
    @server = TCPServer.new("127.0.0.1", 0)
    @nonce = SecureRandom.hex(32)
    write_checkpoint
    write_ready(@server.addr[1])
    install_signal_handlers
    serve until @stopping
    write_terminal
    0
  rescue => e
    @failure_reason ||= "collector_unavailable"
    warn "AGENT_USAGE_WARNING: collector failed: #{e.class}" if ENV["AGENT_USAGE_COLLECTOR_DEBUG"] == "1"
    write_terminal rescue nil
    1
  ensure
    @server&.close rescue nil
  end

  private

  def parse_arguments(arguments)
    options = {}
    until arguments.empty?
      key = arguments.shift
      raise ArgumentError, "invalid collector argument" unless key&.start_with?("--") && !arguments.empty?
      options[key.delete_prefix("--").tr("-", "_").to_sym] = arguments.shift
    end
    options
  end

  def validate_options!
    required = %i[run_dir run_id provider source_interface client_version ready_file]
    raise ArgumentError, "missing collector argument" unless required.all? { |name| @options.key?(name) }
    raise ArgumentError, "unsupported provider" unless %w[anthropic openai].include?(@options[:provider])
    expected = (@options[:provider] == "anthropic") ? "claude_code_otel_api_request_v1" : "codex_otel_response_completed_v1"
    raise ArgumentError, "source interface mismatch" unless @options[:source_interface] == expected

    run_dir = File.realpath(@options[:run_dir])
    raise ArgumentError, "unsafe run directory" unless File.directory?(run_dir) && !File.symlink?(@options[:run_dir])
    @run_dir = run_dir
    @ready_file = safe_child(@options[:ready_file], ".usage.ready")
    @checkpoint_file = File.join(@run_dir, ".usage.checkpoint.json")
    @terminal_file = File.join(@run_dir, ".usage.finalized.json")
    @usage_file = File.join(@run_dir, "usage.json")
  end

  def safe_child(path, basename)
    expanded = File.expand_path(path)
    parent = File.realpath(File.dirname(expanded))
    raise ArgumentError, "unsafe collector path" unless parent == @run_dir && File.basename(expanded) == basename
    File.join(parent, basename)
  end

  def install_signal_handlers
    %w[INT TERM].each do |signal|
      Signal.trap(signal) do
        @stopping = true
      end
    end
  end

  def serve
    return unless IO.select([@server], nil, nil, 0.2)
    socket = @server.accept_nonblock(exception: false)
    return if socket == :wait_readable
    handle(socket)
  ensure
    socket&.close if socket.respond_to?(:close)
  end

  def handle(socket)
    request_line = socket.gets
    return unless request_line
    method, path, _version = request_line.split(" ", 3)
    headers = read_headers(socket)
    unless method == "POST" && path == "/v1/logs"
      respond(socket, 404, "Not Found")
      return
    end
    unless secure_equal?(headers[TOKEN_HEADER], @nonce)
      respond(socket, 403, "Forbidden")
      return
    end

    length = Integer(headers.fetch("content-length", ""), 10)
    raise ArgumentError, "invalid content length" unless length.between?(0, MAX_BODY_BYTES)
    body = read_exact(socket, length)
    payload = JSON.parse(body)
    process_payload(payload)
    write_checkpoint
    respond(socket, 200, "OK", "{}")
  rescue JSON::ParserError, ArgumentError, KeyError
    record_parse_failure
    write_checkpoint rescue nil
    respond(socket, 400, "Bad Request") rescue nil
  rescue
    @failure_reason ||= "collector_unavailable"
    write_checkpoint rescue nil
    respond(socket, 500, "Internal Server Error") rescue nil
  end

  def read_headers(socket)
    headers = {}
    100.times do
      line = socket.gets
      raise ArgumentError, "truncated headers" unless line
      break if line == "\r\n" || line == "\n"
      key, value = line.split(":", 2)
      raise ArgumentError, "malformed header" unless key && value
      headers[key.downcase] = value.strip
    end
    headers
  end

  def read_exact(socket, length)
    body = +""
    body << socket.readpartial([length - body.bytesize, 16_384].min) while body.bytesize < length
    body
  rescue EOFError
    raise ArgumentError, "truncated request body"
  end

  def respond(socket, status, reason, body = "")
    socket.write("HTTP/1.1 #{status} #{reason}\r\nContent-Type: application/json\r\nContent-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
  end

  def secure_equal?(left, right)
    return false unless left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize
    left.bytes.zip(right.bytes).reduce(0) { |difference, (a, b)| difference | (a ^ b) }.zero?
  end

  def process_payload(payload)
    return record_parse_failure unless payload.is_a?(Hash)

    resource_logs = payload.fetch("resourceLogs", [])
    return record_parse_failure unless resource_logs.is_a?(Array)

    resource_logs.each do |resource_log|
      unless resource_log.is_a?(Hash)
        record_parse_failure
        next
      end

      scope_logs = resource_log.fetch("scopeLogs", [])
      unless scope_logs.is_a?(Array)
        record_parse_failure
        next
      end

      scope_logs.each do |scope_log|
        unless scope_log.is_a?(Hash)
          record_parse_failure
          next
        end

        log_records = scope_log.fetch("logRecords", [])
        unless log_records.is_a?(Array)
          record_parse_failure
          next
        end

        log_records.each { |record| process_record(record) }
      end
    end
  end

  def process_record(record)
    return record_parse_failure unless record.is_a?(Hash)

    allowed = (@options[:provider] == "anthropic") ? CLAUDE_ATTRIBUTES : CODEX_ATTRIBUTES
    attributes = attributes_hash(record["attributes"], allowed)
    event_name = scalar(record["body"]) || attributes["event.name"]
    case @options[:provider]
    when "anthropic"
      return unless event_name == "claude_code.api_request"
      measurement = claude_measurement(attributes)
    when "openai"
      return unless event_name == "codex.sse_event" && attributes["event.kind"] == "response.completed"
      token_keys = %w[input_token_count output_token_count cached_token_count cache_write_token_count reasoning_token_count]
      return if token_keys.none? { |key| attributes.key?(key) }
      measurement = codex_measurement(attributes)
    end
    return record_parse_failure unless measurement

    measurement["sequence"] = @measurements.length + 1
    @measurements << measurement
  end

  def attributes_hash(attributes, allowed)
    case attributes
    when Array
      attributes.each_with_object({}) do |attribute, result|
        next unless attribute.is_a?(Hash) && allowed.include?(attribute["key"])
        result[attribute["key"]] = scalar(attribute["value"])
      end
    when Hash
      attributes.each_with_object({}) do |(key, value), result|
        result[key] = scalar(value) if allowed.include?(key)
      end
    else
      {}
    end
  end

  def scalar(value)
    return value unless value.is_a?(Hash)
    return value["stringValue"] if value.key?("stringValue")
    return integer_value(value["intValue"]) if value.key?("intValue")
    return value["doubleValue"] if value.key?("doubleValue")
    return value["boolValue"] if value.key?("boolValue")
    nil
  end

  def integer_value(value)
    return value if value.is_a?(Integer)
    Integer(value, 10) if value.is_a?(String) && /\A-?\d+\z/.match?(value)
  rescue ArgumentError
    nil
  end

  def nonnegative(attributes, key)
    value = integer_value(attributes[key])
    value if value && value >= 0
  end

  def optional_string(attributes, key)
    value = attributes[key]
    value if value.is_a?(String) && !value.empty?
  end

  def claude_measurement(attributes)
    model = optional_string(attributes, "model")
    input = nonnegative(attributes, "input_tokens")
    output = nonnegative(attributes, "output_tokens")
    return unless model && input && output

    read = nonnegative(attributes, "cache_read_tokens")
    write = nonnegative(attributes, "cache_creation_tokens")
    native = {
      "kind" => "claude_code_api_request",
      "input_tokens" => input,
      "output_tokens" => output,
      "cache_read_tokens" => read,
      "cache_creation_tokens" => write
    }
    cost = nonnegative(attributes, "cost_usd_micros")
    {
      "provider" => "anthropic",
      "provider_session_id" => optional_string(attributes, "session.id"),
      "model" => model,
      "request_source" => optional_string(attributes, "query_source"),
      "service_tier" => optional_string(attributes, "speed"),
      "reasoning_effort" => optional_string(attributes, "effort"),
      "duration_ms" => nonnegative(attributes, "duration_ms"),
      "tokens" => {
        "input_total" => sum_or_nil(input, read, write),
        "input_uncached" => input,
        "input_cache_read" => read,
        "input_cache_write" => write,
        "output_total" => output,
        "output_reasoning" => nil
      },
      "native_usage" => native,
      "runtime_cost" => cost.nil? ? nil : {"semantics" => "runtime_estimated", "currency" => "USD", "usd_micros" => cost}
    }
  end

  def codex_measurement(attributes)
    model = optional_string(attributes, "model")
    input = nonnegative(attributes, "input_token_count")
    output = nonnegative(attributes, "output_token_count")
    return unless model && input && output

    read = nonnegative(attributes, "cached_token_count")
    write = nonnegative(attributes, "cache_write_token_count")
    reasoning = nonnegative(attributes, "reasoning_token_count")
    uncached = nil
    if read.is_a?(Integer)
      if read <= input
        uncached = input - read
      else
        add_warning("codex_cached_input_exceeds_total")
        @failure_reason ||= "normalization_inconsistent"
      end
    end
    {
      "provider" => "openai",
      "provider_session_id" => optional_string(attributes, "conversation.id"),
      "model" => model,
      "request_source" => nil,
      "service_tier" => optional_string(attributes, "service_tier"),
      "reasoning_effort" => optional_string(attributes, "model_reasoning_effort"),
      "duration_ms" => nil,
      "tokens" => {
        "input_total" => input,
        "input_uncached" => uncached,
        "input_cache_read" => read,
        "input_cache_write" => write,
        "output_total" => output,
        "output_reasoning" => reasoning
      },
      "native_usage" => {
        "kind" => "codex_response_completed",
        "input_token_count" => input,
        "output_token_count" => output,
        "cached_token_count" => read,
        "cache_write_token_count" => write,
        "reasoning_token_count" => reasoning
      },
      "runtime_cost" => nil
    }
  end

  def sum_or_nil(*values)
    values.all? { |value| value.is_a?(Integer) } ? values.sum : nil
  end

  def record_parse_failure
    add_warning("relevant_event_malformed")
    @failure_reason ||= "collector_parse_failed"
    nil
  end

  def add_warning(warning)
    @warnings << warning unless @warnings.include?(warning)
  end

  def write_ready(port)
    write_once(@ready_file, "#{port}\n#{@nonce}\n")
  end

  def write_checkpoint
    warnings = (@warnings + ["collector_shutdown_incomplete"]).uniq
    state = @measurements.empty? ? "unavailable" : "partial"
    record = build_record(state:, reason: "collector_shutdown_incomplete", warnings:)
    atomic_replace(@checkpoint_file, JSON.pretty_generate(record) + "\n")
  end

  def write_terminal
    state, reason = terminal_state
    record = build_record(state:, reason:, warnings: @warnings)
    write_once(@terminal_file, JSON.pretty_generate(record) + "\n")
  end

  def terminal_state
    return ["complete", nil] unless @failure_reason
    return ["unavailable", @failure_reason] if @measurements.empty?
    ["partial", @failure_reason]
  end

  def build_record(state:, reason:, warnings:)
    {
      "schema_version" => 1,
      "run_id" => @options[:run_id],
      "collection" => {
        "state" => state,
        "source_interface" => @options[:source_interface],
        "client_version" => empty_to_nil(@options[:client_version]),
        "finalized_at" => Time.now.utc.iso8601(3),
        "reason" => reason,
        "warnings" => warnings
      },
      "provider_sessions" => @measurements.filter_map { |measurement| measurement["provider_session_id"] }.uniq.sort,
      "measurements" => @measurements,
      "observed_totals" => observed_totals(state),
      "cost_summary" => cost_summary(state)
    }
  end

  def observed_totals(collection_state)
    totals = {"measurement_count" => @measurements.length}
    TOKEN_FIELDS.each do |name|
      totals[name] = if @measurements.empty?
        if collection_state == "unavailable"
          nil
        else
          (name == "output_reasoning" && @options[:provider] == "anthropic") ? nil : 0
        end
      else
        values = @measurements.map { |measurement| measurement.dig("tokens", name) }
        values.all? { |value| value.is_a?(Integer) } ? values.sum : nil
      end
    end
    totals
  end

  def cost_summary(collection_state)
    count = @measurements.length
    return cost_record("not_applicable", nil, 0, 0, nil) if count.zero?

    costs = @measurements.filter_map { |measurement| measurement["runtime_cost"] }
    if costs.empty?
      reason = (@options[:provider] == "openai") ? "source_does_not_report_cost" : "runtime_cost_missing"
      return cost_record("unavailable", nil, 0, count, reason)
    end
    amount = costs.sum { |cost| cost["usd_micros"] }
    if costs.length == count && collection_state == "complete"
      cost_record("complete", amount, costs.length, count, nil)
    else
      reason = (costs.length == count) ? "collection_incomplete" : "runtime_cost_missing"
      cost_record("partial", amount, costs.length, count, reason)
    end
  end

  def cost_record(state, amount, priced_count, count, reason)
    {
      "state" => state,
      "semantics" => amount.nil? ? nil : "runtime_estimated",
      "currency" => amount.nil? ? nil : "USD",
      "observed_usd_micros" => amount,
      "priced_measurement_count" => priced_count,
      "measurement_count" => count,
      "reason" => reason
    }
  end

  def empty_to_nil(value)
    value.nil? || value.empty? ? nil : value
  end

  def atomic_replace(path, contents)
    temporary = "#{path}.tmp.#{$$}"
    File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(contents) }
    File.rename(temporary, path)
    File.chmod(0o600, path)
  ensure
    File.unlink(temporary) if defined?(temporary) && File.exist?(temporary)
  end

  def write_once(path, contents)
    temporary = "#{path}.tmp.#{$$}.#{SecureRandom.hex(4)}"
    File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) { |file| file.write(contents) }
    File.link(temporary, path)
    File.unlink(temporary)
  ensure
    File.unlink(temporary) if defined?(temporary) && File.exist?(temporary)
  end
end

exit AgentRunUsageCollector.new(ARGV.dup).run
