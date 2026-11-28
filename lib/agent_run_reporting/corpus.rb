# frozen_string_literal: true

require "json"
require "time"
require_relative "../agent_run_telemetry/validator"
require_relative "../agent_run_usage/validator"
require_relative "../agent_run_outcomes/validator"

module AgentRunReporting
  class InputError < StandardError; end

  class RecordReader
    Result = Data.define(:record, :state, :reason, :path)

    def self.read(directory, run_id, name, validator_class, schema: nil)
      path = File.join(directory, name)
      begin
        stat = File.lstat(path)
      rescue Errno::ENOENT
        return Result.new(nil, (name == "run.json") ? "invalid" : "absent",
          (name == "run.json") ? "missing run record" : "sidecar absent", path)
      end
      return invalid(path, "expected a regular file without a symbolic link") unless stat.file?

      nofollow = File.const_defined?(:NOFOLLOW) ? File::NOFOLLOW : 0
      content = File.open(path, File::RDONLY | nofollow) do |file|
        opened = file.stat
        return invalid(path, "evidence changed while opening") unless opened.file? && opened.dev == stat.dev && opened.ino == stat.ino
        file.read.force_encoding(Encoding::UTF_8)
      end
      return invalid(path, "invalid UTF-8") unless content.valid_encoding?

      record = JSON.parse(content)
      return invalid(path, "expected a JSON object") unless record.is_a?(Hash)
      return invalid(path, "run ID does not match its directory") unless record["run_id"] == run_id

      versions = [record["schema_version"]]
      versions << record["source_run_schema_version"] if validator_class == AgentRunOutcomes::Validator
      if versions.any? { |version| version.is_a?(Integer) && version != 1 }
        return invalid(path, "unsupported schema version")
      end
      options = schema ? {schema: schema} : {}
      return invalid(path, "failed v1 field or consistency validation") unless validator_class.new(record, **options).validate

      Result.new(record, "valid", nil, path)
    rescue JSON::ParserError
      invalid(path, "malformed JSON")
    rescue SystemCallError
      invalid(path, "record could not be read")
    end

    def self.invalid(path, reason)
      Result.new(nil, "invalid", reason, path)
    end
  end

  def self.utc_timestamp(value, precision: 3)
    return unless value

    time = Time.iso8601(value).utc
    time if time.iso8601(precision) == value
  rescue ArgumentError
    nil
  end

  class Corpus
    Run = Data.define(:run, :usage, :usage_state, :outcome, :outcome_state) do
      def repository
        run.fetch("repository").fetch("identity")
      end

      def github_repository
        repository.fetch("value").downcase if repository.fetch("kind") == "github"
      end

      def started_at
        AgentRunReporting.utc_timestamp(run.dig("timing", "run_started_at"))
      end
    end

    RUN_VALIDATOR = AgentRunTelemetry::Validator
    USAGE_VALIDATOR = AgentRunUsage::Validator
    OUTCOME_VALIDATOR = AgentRunOutcomes::Validator

    # The launcher and reconciler implement this precedence in self-contained
    # distributable scripts. Resolving it here does not invoke either writer.
    def self.default_root(env = ENV)
      return env["AGENT_TELEMETRY_DIR"] unless env["AGENT_TELEMETRY_DIR"].to_s.empty?

      data_home = env["XDG_DATA_HOME"]
      if data_home.to_s.empty?
        home = env["HOME"]
        raise InputError, "HOME must be absolute to select a telemetry root" unless home&.start_with?("/")

        data_home = File.join(home, ".local/share")
      end
      raise InputError, "XDG_DATA_HOME must be absolute to select a telemetry root" unless data_home.start_with?("/")

      File.join(data_home, "agent-development-framework/telemetry/runs")
    end

    # Resolve existing ancestors even when the implicit root has not been created.
    def self.canonical_path(path)
      File.realpath(path)
    rescue Errno::ENOENT
      raise if File.symlink?(path)

      File.join(canonical_path(File.dirname(path)), File.basename(path))
    end

    attr_reader :root, :runs, :invalid_runs, :diagnostics

    def initialize(path, explicit:, repository:)
      raise InputError, "Telemetry root must be absolute" unless path.start_with?("/")

      @root = self.class.canonical_path(File.expand_path(path))
      @runs = []
      @invalid_runs = 0
      @diagnostics = Hash.new { |hash, reason| hash[reason] = [] }
      entries = root_entries(explicit)
      return if entries.empty?

      @usage_schema = JSON.parse(File.binread(USAGE_VALIDATOR::SCHEMA_PATH))
      entries.each { |name| load_run(name, repository) }
    rescue SystemCallError
      raise InputError, "Cannot read selected telemetry root or bundled schema"
    end

    private

    def root_entries(explicit)
      entries = Dir.children(root)
      raise InputError, "Cannot search selected telemetry root" unless File.executable?(root)

      entries.grep(RUN_VALIDATOR::RUN_ID).sort
    rescue Errno::ENOENT
      raise InputError, "Selected telemetry root does not exist" if explicit

      []
    end

    def load_run(run_id, filter)
      path = File.join(root, run_id)
      run, = if !File.symlink?(path) && File.directory?(path)
        load_record(path, run_id, "run.json", RUN_VALIDATOR)
      else
        record_error(run_id, "run.json", "run directory is not a regular directory")
      end
      unless run
        @invalid_runs += 1
        return
      end

      identity = run.dig("repository", "identity")
      return if filter && (identity["kind"] != "github" || identity["value"].downcase != filter)

      usage, usage_state = load_record(path, run_id, "usage.json", USAGE_VALIDATOR, schema: @usage_schema)
      outcome, outcome_state = load_record(path, run_id, "outcome.json", OUTCOME_VALIDATOR)
      runs << Run.new(
        run, usage, usage&.dig("collection", "state") || usage_state,
        outcome, outcome&.dig("reconciliation", "observation_state") || outcome_state
      )
    end

    def load_record(directory, run_id, name, validator_class, **options)
      result = RecordReader.read(directory, run_id, name, validator_class, **options)
      return [result.record, nil] if result.state == "valid"
      return [nil, "sidecar absent"] if result.state == "absent"

      record_error(run_id, name, result.reason)
    end

    def record_error(run_id, name, reason)
      diagnostics["#{name} · #{reason}"] << run_id
      [nil, "sidecar invalid or unsupported"]
    end
  end
end
