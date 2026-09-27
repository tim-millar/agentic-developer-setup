# frozen_string_literal: true

require "json"

module AgentRunUsage
  class Validator
    SCHEMA_PATH = File.expand_path("../../schemas/agent-run-usage-v1.schema.json", __dir__)
    TOKEN_FIELDS = %w[input_total input_uncached input_cache_read input_cache_write output_total output_reasoning].freeze
    RUN_ID = /\Arun-\d{8}T\d{6}Z-[0-9a-f]{32}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
    COLLECTION_STATES = %w[complete partial unavailable disabled].freeze
    COLLECTION_REASONS = %w[
      collector_unavailable collector_setup_failed unsupported_provider_interface
      collector_parse_failed collector_shutdown_incomplete source_unavailable
      normalization_inconsistent usage_telemetry_disabled
    ].freeze

    attr_reader :errors

    def initialize(record, schema: nil)
      @record = record
      @schema = schema || JSON.parse(File.binread(SCHEMA_PATH))
      @errors = []
    rescue JSON::ParserError, Errno::ENOENT => e
      @record = record
      @schema = nil
      @errors = ["schema: #{e.message}"]
    end

    def validate
      return false unless @schema

      @errors.concat(schema_errors(@record, @schema, "record"))
      return false unless @record.is_a?(Hash)

      semantic_validation
      errors.empty?
    rescue => e
      errors << "record: validator failure: #{e.class}: #{e.message}"
      false
    end

    private

    def schema_errors(value, schema, location)
      schema = resolve(schema)
      return ["#{location}: schema reference is invalid"] unless schema.is_a?(Hash)

      if schema.key?("oneOf")
        matches = schema.fetch("oneOf").count { |candidate| schema_errors(value, candidate, location).empty? }
        return ["#{location}: must match exactly one allowed structure"] unless matches == 1
      end

      failures = []
      allowed_types = Array(schema["type"])
      if allowed_types.any? && allowed_types.none? { |type| type_matches?(value, type) }
        return ["#{location}: has the wrong JSON type"]
      end
      failures << "#{location}: must equal #{schema["const"].inspect}" if schema.key?("const") && value != schema["const"]
      failures << "#{location}: is not an allowed value" if schema.key?("enum") && !schema.fetch("enum").include?(value)

      if value.is_a?(String)
        failures << "#{location}: is too short" if schema["minLength"] && value.length < schema["minLength"]
        failures << "#{location}: has an invalid format" if schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
      elsif value.is_a?(Integer) && schema.key?("minimum") && value < schema["minimum"]
        failures << "#{location}: must be at least #{schema["minimum"]}"
      elsif value.is_a?(Array)
        if schema["uniqueItems"] && value.uniq.length != value.length
          failures << "#{location}: must contain unique items"
        end
        if schema["items"]
          value.each_with_index { |item, index| failures.concat(schema_errors(item, schema["items"], "#{location}[#{index}]")) }
        end
      elsif value.is_a?(Hash)
        required = Array(schema["required"])
        required.each { |key| failures << "#{location}.#{key}: is required" unless value.key?(key) }
        properties = schema.fetch("properties", {})
        if schema["additionalProperties"] == false
          (value.keys - properties.keys).each { |key| failures << "#{location}.#{key}: is not allowed" }
        end
        value.each do |key, item|
          failures.concat(schema_errors(item, properties[key], "#{location}.#{key}")) if properties[key]
        end
      end
      failures
    rescue RegexpError
      ["schema: contains an invalid regular expression"]
    end

    def resolve(schema)
      return schema unless schema.is_a?(Hash) && schema["$ref"]

      path = schema.fetch("$ref")
      return unless path.start_with?("#/")

      path.delete_prefix("#/").split("/").reduce(@schema) do |node, component|
        node&.fetch(component.gsub("~1", "/").gsub("~0", "~"), nil)
      end
    end

    def type_matches?(value, type)
      case type
      when "object" then value.is_a?(Hash)
      when "array" then value.is_a?(Array)
      when "string" then value.is_a?(String)
      when "integer" then value.is_a?(Integer)
      when "boolean" then value == true || value == false
      when "null" then value.nil?
      else false
      end
    end

    def semantic_validation
      error("run_id", "has an invalid format") unless RUN_ID.match?(@record["run_id"].to_s)
      collection = @record["collection"]
      measurements = @record["measurements"]
      return unless collection.is_a?(Hash) && measurements.is_a?(Array)

      validate_collection(collection, measurements)
      validate_measurements(collection, measurements)
      validate_sessions(measurements)
      validate_totals(collection, measurements)
      validate_cost_summary(collection, measurements)
    end

    def validate_collection(collection, measurements)
      state = collection["state"]
      reason = collection["reason"]
      error("collection.state", "is invalid") unless COLLECTION_STATES.include?(state)
      error("collection.finalized_at", "has an invalid format") unless TIMESTAMP.match?(collection["finalized_at"].to_s)

      case state
      when "complete"
        error("collection.reason", "must be null for complete collection") unless reason.nil?
        error("collection.warnings", "must be empty for complete collection") unless collection["warnings"] == []
      when "partial"
        error("collection.reason", "must describe partial collection") unless COLLECTION_REASONS.include?(reason) && reason != "usage_telemetry_disabled"
        error("measurements", "must retain at least one measurement when collection is partial") if measurements.empty?
      when "unavailable"
        error("collection.reason", "must describe unavailable collection") unless COLLECTION_REASONS.include?(reason) && reason != "usage_telemetry_disabled"
        error("measurements", "must be empty when collection is unavailable") unless measurements.empty?
      when "disabled"
        error("collection.reason", "must be usage_telemetry_disabled") unless reason == "usage_telemetry_disabled"
        error("collection.source_interface", "must be null when disabled") unless collection["source_interface"].nil?
        error("collection.warnings", "must be empty when disabled") unless collection["warnings"] == []
        error("measurements", "must be empty when collection is disabled") unless measurements.empty?
      end
    end

    def validate_measurements(collection, measurements)
      expected_provider = case collection["source_interface"]
      when "claude_code_otel_api_request_v1" then "anthropic"
      when "codex_otel_response_completed_v1" then "openai"
      end

      measurements.each_with_index do |measurement, index|
        next unless measurement.is_a?(Hash)

        location = "measurements[#{index}]"
        error("#{location}.sequence", "must equal accepted-measurement order") unless measurement["sequence"] == index + 1
        error("#{location}.provider", "does not match collection source") if expected_provider && measurement["provider"] != expected_provider
        validate_native_mapping(measurement, location)
      end
      error("collection.source_interface", "is required when measurements exist") if measurements.any? && expected_provider.nil?
    end

    def validate_native_mapping(measurement, location)
      native = measurement["native_usage"]
      tokens = measurement["tokens"]
      return unless native.is_a?(Hash) && tokens.is_a?(Hash)

      case [measurement["provider"], native["kind"]]
      when ["anthropic", "claude_code_api_request"]
        %w[input_tokens output_tokens].each do |name|
          error("#{location}.native_usage.#{name}", "is required for an accepted Claude request") unless native[name].is_a?(Integer)
        end
        expected = {
          "input_uncached" => native["input_tokens"],
          "input_cache_read" => native["cache_read_tokens"],
          "input_cache_write" => native["cache_creation_tokens"],
          "input_total" => sum_or_nil(native.values_at("input_tokens", "cache_read_tokens", "cache_creation_tokens")),
          "output_total" => native["output_tokens"],
          "output_reasoning" => nil
        }
        expected.each { |name, value| error("#{location}.tokens.#{name}", "does not reproduce native usage") unless tokens[name] == value }
      when ["openai", "codex_response_completed"]
        %w[input_token_count output_token_count].each do |name|
          error("#{location}.native_usage.#{name}", "is required for an accepted Codex response") unless native[name].is_a?(Integer)
        end
        input, read, write = native.values_at("input_token_count", "cached_token_count", "cache_write_token_count")
        uncached = if [input, read, write].all? { |value| value.is_a?(Integer) } && read + write <= input
          input - read - write
        end
        expected = {
          "input_total" => input,
          "input_uncached" => uncached,
          "input_cache_read" => read,
          "input_cache_write" => write,
          "output_total" => native["output_token_count"],
          "output_reasoning" => native["reasoning_token_count"]
        }
        expected.each { |name, value| error("#{location}.tokens.#{name}", "does not reproduce native usage") unless tokens[name] == value }
        inconsistent = [input, read, write].all? { |value| value.is_a?(Integer) } && read + write > input
        warnings = Array(@record.dig("collection", "warnings"))
        error("collection.warnings", "must identify inconsistent Codex input counts") if inconsistent && !warnings.include?("codex_input_cache_exceeds_total")
      else
        error("#{location}.native_usage", "does not match provider")
      end

      if measurement["provider"] == "openai" && measurement["runtime_cost"]
        error("#{location}.runtime_cost", "Codex source does not report runtime dollar cost")
      end
    end

    def validate_sessions(measurements)
      expected = measurements.filter_map { |measurement| measurement["provider_session_id"] if measurement.is_a?(Hash) }.uniq.sort
      error("provider_sessions", "must be the sorted unique sessions derived from measurements") unless @record["provider_sessions"] == expected
    end

    def validate_totals(collection, measurements)
      expected = {"measurement_count" => measurements.length}
      TOKEN_FIELDS.each do |name|
        expected[name] = aggregate(measurements, name, collection["source_interface"], collection["state"])
      end
      error("observed_totals", "does not reproduce measurements") unless @record["observed_totals"] == expected
    end

    def aggregate(measurements, name, source_interface, collection_state)
      if measurements.empty?
        return nil if collection_state == "unavailable"
        return nil if source_interface.nil? || (name == "output_reasoning" && source_interface == "claude_code_otel_api_request_v1")
        return 0
      end

      values = measurements.map { |measurement| measurement.dig("tokens", name) if measurement.is_a?(Hash) }
      (values.all? { |value| value.is_a?(Integer) }) ? values.sum : nil
    end

    def validate_cost_summary(collection, measurements)
      summary = @record["cost_summary"]
      return unless summary.is_a?(Hash)

      costs = measurements.filter_map { |measurement| measurement["runtime_cost"] if measurement.is_a?(Hash) }
      expected = if measurements.empty?
        cost("not_applicable", nil, 0, 0, nil)
      elsif costs.empty?
        reason = (measurements.all? { |measurement| measurement.is_a?(Hash) && measurement["provider"] == "openai" }) ? "source_does_not_report_cost" : "runtime_cost_missing"
        cost("unavailable", nil, 0, measurements.length, reason)
      elsif costs.length == measurements.length && collection["state"] == "complete"
        cost("complete", costs.sum { |item| item["usd_micros"] }, costs.length, measurements.length, nil)
      else
        reason = (costs.length == measurements.length) ? "collection_incomplete" : "runtime_cost_missing"
        cost("partial", costs.sum { |item| item["usd_micros"] }, costs.length, measurements.length, reason)
      end
      error("cost_summary", "is inconsistent with measurements and collection state") unless summary == expected
    end

    def cost(state, amount, priced_count, count, reason)
      has_cost = !amount.nil?
      {
        "state" => state,
        "semantics" => has_cost ? "runtime_estimated" : nil,
        "currency" => has_cost ? "USD" : nil,
        "observed_usd_micros" => amount,
        "priced_measurement_count" => priced_count,
        "measurement_count" => count,
        "reason" => reason
      }
    end

    def sum_or_nil(values)
      (values.all? { |value| value.is_a?(Integer) }) ? values.sum : nil
    end

    def error(location, message)
      errors << "#{location}: #{message}"
    end
  end
end
