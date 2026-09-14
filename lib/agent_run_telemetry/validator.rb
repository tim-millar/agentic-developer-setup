# frozen_string_literal: true

require "json"

module AgentRunTelemetry
  class Validator
    STATES = %w[started completed preflight_failed launch_failed runtime_failed launcher_failed interrupted].freeze
    TERMINAL_STATES = (STATES - ["started"]).freeze
    EVIDENCE_KINDS = %w[launcher_requested runtime_observed launcher_guaranteed unavailable not_applicable].freeze
    TASK_SOURCES = %w[github_issue local_prompt composite unavailable].freeze
    CONFIGURATION_STABILITY = %w[unchanged changed unknown].freeze
    CLIENT_IDS = %w[codex-cli claude-code].freeze
    HARNESS_IDS = %w[agent-development-framework/codex agent-development-framework/claude-explore].freeze
    RUN_ID = /\Arun-\d{8}T\d{6}Z-[0-9a-f]{32}\z/
    SHA256 = /\Asha256:[0-9a-f]{64}\z/
    SHA = /\A[0-9a-f]{40,64}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
    GITHUB_REPOSITORY = /\A[A-Za-z0-9_.-]{1,100}\/(?![A-Za-z0-9_.-]*[.]git\z)[A-Za-z0-9_.-]{1,100}\z/

    attr_reader :errors

    def initialize(record)
      @record = record
      @errors = []
    end

    def validate
      return error("record", "must be a JSON object") unless @record.is_a?(Hash)

      exact_keys(@record, "record", %w[schema_version run_id state runtime configuration repository task timing termination extensions])
      value(@record, "schema_version", Integer, expected: 1)
      pattern(@record["run_id"], "run_id", RUN_ID)
      enum(@record["state"], "state", STATES)
      validate_runtime(@record["runtime"])
      validate_configuration(@record["configuration"])
      validate_repository(@record["repository"])
      validate_task(@record["task"])
      validate_timing(@record["timing"], @record["state"])
      validate_termination(@record["termination"], @record["state"])
      error("extensions", "must be a JSON object") unless @record["extensions"].is_a?(Hash)
      errors.empty?
    end

    private

    def validate_runtime(runtime)
      return error("runtime", "must be a JSON object") unless runtime.is_a?(Hash)

      exact_keys(runtime, "runtime", %w[client harness session])
      client = runtime["client"]
      if client.is_a?(Hash)
        exact_keys(client, "runtime.client", %w[id version])
        enum(client["id"], "runtime.client.id", CLIENT_IDS)
        observation(client["version"], "runtime.client.version", source: false)
      else
        error("runtime.client", "must be a JSON object")
      end
      harness = runtime["harness"]
      if harness.is_a?(Hash)
        exact_keys(harness, "runtime.harness", %w[id version revision])
        enum(harness["id"], "runtime.harness.id", HARNESS_IDS)
        positive_integer(harness["version"], "runtime.harness.version")
        pattern(harness["revision"], "runtime.harness.revision", SHA256)
      else
        error("runtime.harness", "must be a JSON object")
      end
      observation(runtime["session"], "runtime.session", source: false)
    end

    def validate_configuration(configuration)
      return error("configuration", "must be a JSON object") unless configuration.is_a?(Hash)

      exact_keys(configuration, "configuration", %w[model reasoning_effort configuration_stability])
      %w[model reasoning_effort].each do |name|
        group = configuration[name]
        if group.is_a?(Hash)
          exact_keys(group, "configuration.#{name}", %w[requested initial_effective])
          observation(group["requested"], "configuration.#{name}.requested", source: true)
          observation(group["initial_effective"], "configuration.#{name}.initial_effective", source: true)
        else
          error("configuration.#{name}", "must be a JSON object")
        end
      end
      enum(configuration["configuration_stability"], "configuration.configuration_stability", CONFIGURATION_STABILITY)
    end

    def validate_repository(repository)
      return error("repository", "must be a JSON object") unless repository.is_a?(Hash)

      exact_keys(repository, "repository", %w[identity start finish])
      identity = repository["identity"]
      if identity.is_a?(Hash)
        exact_keys(identity, "repository.identity", %w[kind value])
        enum(identity["kind"], "repository.identity.kind", %w[github path_digest])
        if identity["kind"] == "github"
          pattern(identity["value"], "repository.identity.value", GITHUB_REPOSITORY)
        elsif identity["kind"] == "path_digest"
          pattern(identity["value"], "repository.identity.value", SHA256)
        end
      else
        error("repository.identity", "must be a JSON object")
      end
      git_state(repository["start"], "repository.start")
      git_state(repository["finish"], "repository.finish")
    end

    def validate_task(task)
      return error("task", "must be a JSON object") unless task.is_a?(Hash)

      exact_keys(task, "task", %w[source identifier content_sha256 snapshot])
      enum(task["source"], "task.source", TASK_SOURCES)
      nullable_string(task["identifier"], "task.identifier")
      nullable_pattern(task["content_sha256"], "task.content_sha256", SHA256)
      nullable_string(task["snapshot"], "task.snapshot")
      if task["snapshot"]
        error("task.snapshot", "must be task.txt") unless task["snapshot"] == "task.txt"
        error("task.content_sha256", "is required with a snapshot") unless task["content_sha256"]
      elsif task["content_sha256"]
        error("task.snapshot", "is required with a content digest")
      end
      if task["source"] == "unavailable" && task.values_at("identifier", "content_sha256", "snapshot").any?
        error("task", "unavailable task evidence must use null identity, digest, and snapshot")
      end
    end

    def validate_timing(timing, state)
      return error("timing", "must be a JSON object") unless timing.is_a?(Hash)

      exact_keys(timing, "timing", %w[run_started_at child_started_at child_finished_at run_finished_at calendar_elapsed_ms])
      pattern(timing["run_started_at"], "timing.run_started_at", TIMESTAMP)
      %w[child_started_at child_finished_at run_finished_at].each { |name| nullable_pattern(timing[name], "timing.#{name}", TIMESTAMP) }
      nullable_nonnegative_integer(timing["calendar_elapsed_ms"], "timing.calendar_elapsed_ms")
      if TERMINAL_STATES.include?(state)
        error("timing.run_finished_at", "is required for terminal records") unless timing["run_finished_at"]
        error("timing.calendar_elapsed_ms", "is required for terminal records") if timing["calendar_elapsed_ms"].nil?
      elsif state == "started" && (timing["run_finished_at"] || timing["calendar_elapsed_ms"])
        error("timing", "a started record cannot contain terminal timing")
      end
    end

    def validate_termination(termination, state)
      return error("termination", "must be a JSON object") unless termination.is_a?(Hash)

      exact_keys(termination, "termination", %w[child_exit_code signal reason])
      nullable_nonnegative_integer(termination["child_exit_code"], "termination.child_exit_code")
      nullable_string(termination["signal"], "termination.signal")
      nullable_string(termination["reason"], "termination.reason")
      error("termination.reason", "is required for terminal records") if TERMINAL_STATES.include?(state) && termination["reason"].nil?
      error("termination", "a started record cannot contain termination evidence") if state == "started" && termination.values.any?
    end

    def observation(object, location, source:)
      return error(location, "must be a JSON object") unless object.is_a?(Hash)

      required = source ? %w[evidence_kind value source] : %w[evidence_kind value]
      exact_keys(object, location, required)
      enum(object["evidence_kind"], "#{location}.evidence_kind", EVIDENCE_KINDS)
      nullable_string(object["value"], "#{location}.value")
      nullable_string(object["source"], "#{location}.source") if source
      missing = %w[unavailable not_applicable].include?(object["evidence_kind"])
      error("#{location}.value", "must be null for unavailable/not_applicable evidence") if missing && object["value"]
      error("#{location}.value", "must be present for available evidence") if !missing && object["value"].nil?
    end

    def git_state(state, location)
      return if state.nil?
      return error(location, "must be null or a JSON object") unless state.is_a?(Hash)

      exact_keys(state, location, %w[branch detached head_sha dirty staged_count unstaged_count untracked_count])
      nullable_string(state["branch"], "#{location}.branch")
      value(state, "detached", TrueClass, false_class: true, location: location)
      pattern(state["head_sha"], "#{location}.head_sha", SHA)
      value(state, "dirty", TrueClass, false_class: true, location: location)
      %w[staged_count unstaged_count untracked_count].each { |name| nonnegative_integer(state[name], "#{location}.#{name}") }
      error(location, "attached state requires a branch") if state["detached"] == false && state["branch"].nil?
      error(location, "detached state requires a null branch") if state["detached"] == true && state["branch"]
      counts = state.values_at("staged_count", "unstaged_count", "untracked_count")
      if counts.all? { |count| count.is_a?(Integer) && count >= 0 }
        expected_dirty = counts.sum.positive?
        error("#{location}.dirty", "does not match status counts") if [true, false].include?(state["dirty"]) && state["dirty"] != expected_dirty
      end
    end

    def exact_keys(object, location, keys)
      return unless object.is_a?(Hash)
      (keys - object.keys).each { |key| error("#{location}.#{key}", "is required") }
      (object.keys - keys).each { |key| error("#{location}.#{key}", "is not a v1 common field") }
    end

    def value(object, key, klass, expected: nil, false_class: false, location: nil)
      item = object[key]
      valid = item.is_a?(klass) || (false_class && item.is_a?(FalseClass))
      prefix = location ? "#{location}." : ""
      error("#{prefix}#{key}", "has the wrong type") unless valid
      error(key, "must equal #{expected.inspect}") if !expected.nil? && item != expected
    end

    def enum(item, location, values)
      error(location, "must be one of: #{values.join(", ")}") unless values.include?(item)
    end

    def pattern(item, location, regexp)
      error(location, "has an invalid format") unless item.is_a?(String) && regexp.match?(item)
    end

    def nullable_pattern(item, location, regexp)
      pattern(item, location, regexp) unless item.nil?
    end

    def nullable_string(item, location)
      error(location, "must be null or a string") unless item.nil? || item.is_a?(String)
    end

    def positive_integer(item, location)
      error(location, "must be a positive integer") unless item.is_a?(Integer) && item.positive?
    end

    def nonnegative_integer(item, location)
      error(location, "must be a non-negative integer") unless item.is_a?(Integer) && item >= 0
    end

    def nullable_nonnegative_integer(item, location)
      nonnegative_integer(item, location) unless item.nil?
    end

    def error(location, message)
      errors << "#{location}: #{message}"
      false
    end
  end
end
