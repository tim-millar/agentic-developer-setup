#!/bin/sh
# Optional, observational implementation-outcome reconciliation. The Ruby
# program is embedded so an adopted repository needs only this one artefact.
if [ "${AGENT_TELEMETRY:-1}" = 0 ]; then
  exit 0
fi
case "$#:$1" in
  0:) ;;
  1:--automatic|1:--all) ;;
  2:--run) ;;
  *) printf '%s\n' 'usage: agent_run_outcomes.sh [--automatic | --all | --run <run_id>]' >&2; exit 2 ;;
esac
OUTCOME_RUBY=${OUTCOME_RUBY_BIN:-$(command -v ruby 2>/dev/null || true)}
if [ -z "$OUTCOME_RUBY" ]; then
  printf '%s\n' 'AGENT_OUTCOME_WARNING: ruby is unavailable; outcome reconciliation skipped' >&2
  exit 1
fi
exec "$OUTCOME_RUBY" -x "$0" "$@"
exit 1
#!ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "open3"
require "securerandom"
require "time"
require "timeout"

module AgentRunOutcomes
  RUN_ID = /\Arun-\d{8}T\d{6}Z-[0-9a-f]{32}\z/
  SHA = /\A[0-9a-f]{40,64}\z/
  SHA256 = /\Asha256:[0-9a-f]{64}\z/
  SOURCE_TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
  TERMINAL_STATES = %w[completed preflight_failed launch_failed runtime_failed launcher_failed interrupted].freeze
  CORRELATION_STATES = %w[matched unmatched ambiguous unavailable not_applicable].freeze
  EVENT_KINDS = %w[ready_for_review converted_to_draft review_requested review_request_removed review_dismissed head_ref_force_pushed head_ref_deleted head_ref_restored base_ref_changed closed reopened merged cross_referenced].freeze
  FAILING_CHECK_CONCLUSIONS = %w[failure cancelled timed_out action_required stale startup_failure].freeze
  NON_FAILING_CHECK_CONCLUSIONS = %w[success neutral skipped].freeze
  ERROR_CATEGORIES = %w[authentication authorization network api rate_limit local_io invalid_source_record parse timeout].freeze
  DAY = 86_400
  HOUR = 3_600
  WINDOW = 30 * DAY
  STALE_STARTED = DAY
  STALE_LOCK = 600

  class Failure < StandardError
    attr_reader :category, :status

    def initialize(category, message = nil, status: nil)
      @category = category
      @status = status
      super(message || category)
    end
  end

  module_function

  def timestamp(time = Time.now.utc)
    time.utc.iso8601(3)
  end

  def parse_time(value)
    Time.iso8601(value)
  rescue ArgumentError, TypeError
    nil
  end

  def normalize_timestamp(value)
    parsed = parse_time(value)
    parsed && timestamp(parsed)
  end

  def merge_by_identity(old_items, new_items, keys, now)
    merged = {}
    Array(old_items).each do |item|
      next unless item.is_a?(Hash)
      identity = keys.map { |key| item[key].to_s }.join("\u0000")
      merged[identity] = item
    end
    Array(new_items).each do |item|
      next unless item.is_a?(Hash)
      identity = keys.map { |key| item[key].to_s }.join("\u0000")
      previous = merged[identity]
      item = item.merge("first_observed_at" => previous&.fetch("first_observed_at", nil) || now, "last_observed_at" => now)
      merged[identity] = previous ? previous.merge(item) : item
    end
    merged.values.sort_by { |item| keys.map { |key| item[key].to_s } }
  end

  class GitHub
    Result = Struct.new(:value, :error, keyword_init: true)

    attr_reader :queries

    def initialize
      @gh = ENV["OUTCOME_GH_BIN"] || which("gh")
      @helper = ENV["AGENT_GITHUB_TOKEN_HELPER"]
      @queries = 0
    end

    def available?
      @gh && File.file?(@gh) && File.executable?(@gh)
    end

    def api(endpoint, paginate: false, accept: nil)
      return Result.new(error: Failure.new("api", "GitHub CLI is unavailable")) unless available?

      token, helper_error = helper_token
      return Result.new(error: helper_error) if helper_error

      command = [@gh, "api"]
      command.concat(["--paginate", "--slurp"]) if paginate
      command.concat(["-H", "Accept: #{accept}"]) if accept
      command << endpoint
      result = invoke(command, token)
      if result.error&.category == "authentication" && token && @helper
        refreshed, refresh_error = helper_token(force: true)
        return Result.new(error: refresh_error) if refresh_error
        result = invoke(command, refreshed)
      end
      result
    end

    private

    def which(name)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def helper_token(force: false)
      return [nil, nil] unless @helper && File.file?(@helper) && File.executable?(@helper)
      arguments = [@helper]
      arguments << "--force-refresh" if force
      output, error, status = Open3.capture3(*arguments)
      return [output.strip, nil] if status.success? && !output.strip.empty?
      [nil, Failure.new("authentication", "credential helper failed", status: status.exitstatus)]
    rescue SystemCallError
      [nil, Failure.new("authentication", "credential helper unavailable")]
    end

    def invoke(command, token)
      environment = {}
      environment["GH_TOKEN"] = token if token
      @queries += 1
      output = error = nil
      status = nil
      Timeout.timeout(Integer(ENV.fetch("AGENT_OUTCOME_API_TIMEOUT", "30"))) do
        output, error, status = Open3.capture3(environment, *command)
      end
      unless status.success?
        return Result.new(error: classify(error.to_s, status.exitstatus))
      end
      Result.new(value: JSON.parse(output))
    rescue Timeout::Error
      Result.new(error: Failure.new("timeout"))
    rescue JSON::ParserError
      Result.new(error: Failure.new("parse"))
    rescue SystemCallError
      Result.new(error: Failure.new("network"))
    end

    def classify(stderr, status)
      text = stderr.downcase
      http_status = text[/\b([1-5]\d\d)\b/, 1]&.to_i
      category = if text.match?(/401|bad credentials|authentication|token.*expired|invalid token/)
        "authentication"
      elsif text.match?(/403|forbidden|resource not accessible|permission/)
        "authorization"
      elsif text.match?(/rate.?limit|429/)
        "rate_limit"
      elsif text.match?(/timed? out/)
        "timeout"
      elsif text.match?(/network|resolve host|connection|tls|eof/)
        "network"
      else
        "api"
      end
      Failure.new(category, status: http_status || status)
    end
  end

  class Reconciler
    include AgentRunOutcomes

    attr_reader :repository, :root

    def initialize
      @now = parse_time(ENV["AGENT_OUTCOME_NOW"]) || Time.now.utc
      @repository_root = repository_root
      @root = telemetry_root
      @repository = repository_identity
      @path_identity = "sha256:#{Digest::SHA256.hexdigest(@repository_root)}"
      @github = GitHub.new
      @timeline_cache = {}
      @warning_emitted = false
    end

    def run(arguments)
      mode, selected = parse_arguments(arguments)
      return 0 if ENV["AGENT_TELEMETRY"] == "0"
      raise Failure.new("local_io", "telemetry root is unavailable") unless root

      records = records_for(mode, selected)
      records = records.first(3) if mode == :automatic
      failures = 0
      records.each do |entry|
        begin
          result = reconcile(entry.fetch(:path), entry.fetch(:run), explicit: %i[selected all].include?(mode))
          failures += 1 unless result
        rescue Failure => error
          failures += 1
          warn_once(error.category) if mode == :automatic
          warn "agent-run-outcomes: #{error.message}" unless mode == :automatic
        end
      end
      failures.zero? ? 0 : 1
    rescue Failure => error
      warn_once(error.category) if arguments.include?("--automatic")
      warn "agent-run-outcomes: #{error.message}" unless arguments.include?("--automatic")
      error.message.start_with?("usage:") ? 2 : 1
    end

    private

    def parse_arguments(arguments)
      return [:due, nil] if arguments.empty?
      return [:automatic, nil] if arguments == ["--automatic"]
      return [:all, nil] if arguments == ["--all"]
      return [:selected, arguments[1]] if arguments.length == 2 && arguments[0] == "--run" && arguments[1].match?(RUN_ID)
      raise Failure.new("invalid_source_record", "usage: agent_run_outcomes.sh [--automatic | --all | --run <run_id>]")
    end

    def telemetry_root
      candidate = if ENV["AGENT_TELEMETRY_DIR"] && !ENV["AGENT_TELEMETRY_DIR"].empty?
        ENV["AGENT_TELEMETRY_DIR"]
      elsif ENV["XDG_DATA_HOME"] && !ENV["XDG_DATA_HOME"].empty?
        File.join(ENV["XDG_DATA_HOME"], "agent-development-framework", "telemetry", "runs")
      elsif ENV["HOME"] && !ENV["HOME"].empty?
        File.join(ENV["HOME"], ".local", "share", "agent-development-framework", "telemetry", "runs")
      end
      return unless candidate&.start_with?(File::SEPARATOR)
      expanded = File.expand_path(candidate)
      canonical = File.directory?(expanded) ? File.realpath(expanded) : expanded
      return if canonical == @repository_root || canonical.start_with?("#{@repository_root}/")
      canonical
    rescue SystemCallError
      nil
    end

    def repository_root
      git = ENV["OUTCOME_GIT_BIN"] || "git"
      output, status = Open3.capture2(git, "rev-parse", "--show-toplevel")
      raise Failure.new("local_io", "not inside a Git repository") unless status.success?
      File.realpath(output.strip)
    rescue SystemCallError
      raise Failure.new("local_io", "Git is unavailable")
    end

    def repository_identity
      git = ENV["OUTCOME_GIT_BIN"] || "git"
      output, status = Open3.capture2(git, "-C", @repository_root, "remote", "get-url", "origin")
      return unless status.success?
      url = output.strip.sub(/\.git\z/, "")
      match = url.match(%r{(?:https://github\.com/|git@github\.com:)([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)\z})
      match && match[1]
    rescue SystemCallError
      nil
    end

    def load_run(path)
      record = JSON.parse(File.binread(path))
      raise Failure.new("invalid_source_record", "#{path}: source record must be an object") unless record.is_a?(Hash)
      run_id = File.basename(File.dirname(path))
      unless record["schema_version"] == 1 && record["run_id"] == run_id && run_id.match?(RUN_ID) && valid_source_record?(record)
        raise Failure.new("invalid_source_record", "#{path}: unsupported or inconsistent source record")
      end
      unless (TERMINAL_STATES + ["started"]).include?(record["state"])
        raise Failure.new("invalid_source_record", "#{path}: unsupported source state")
      end
      identity = record.dig("repository", "identity")
      unless identity.is_a?(Hash) && %w[github path_digest].include?(identity["kind"]) && identity["value"].is_a?(String)
        raise Failure.new("invalid_source_record", "#{path}: malformed repository identity")
      end
      started = parse_time(record.dig("timing", "run_started_at"))
      finished = parse_time(record.dig("timing", "run_finished_at"))
      raise Failure.new("invalid_source_record", "#{path}: malformed source timing") unless started
      if TERMINAL_STATES.include?(record["state"]) && !finished
        raise Failure.new("invalid_source_record", "#{path}: terminal source record lacks finish time")
      end
      record
    rescue JSON::ParserError, Errno::EACCES, Errno::ENOENT
      raise Failure.new("invalid_source_record", "#{path}: unreadable source record")
    end

    def valid_source_record?(record)
      return false unless exact_keys?(record, %w[schema_version run_id state runtime configuration repository task timing termination extensions])
      runtime = record["runtime"]
      configuration = record["configuration"]
      repository_value = record["repository"]
      task = record["task"]
      timing = record["timing"]
      termination = record["termination"]
      return false unless runtime.is_a?(Hash) && exact_keys?(runtime, %w[client harness session])
      client = runtime["client"]
      harness = runtime["harness"]
      return false unless client.is_a?(Hash) && exact_keys?(client, %w[id version]) && %w[codex-cli claude-code].include?(client["id"]) && valid_observation?(client["version"])
      return false unless harness.is_a?(Hash) && exact_keys?(harness, %w[id version revision])
      return false unless %w[agent-development-framework/codex agent-development-framework/claude-explore].include?(harness["id"])
      return false unless harness["version"].is_a?(Integer) && harness["version"].positive? && harness["revision"].is_a?(String) && harness["revision"].match?(SHA256)
      return false unless valid_observation?(runtime["session"])
      return false unless valid_configuration?(configuration)
      return false unless valid_source_repository?(repository_value)
      return false unless valid_source_task?(task)
      return false unless valid_source_timing?(timing, record["state"])
      return false unless valid_source_termination?(termination, record["state"])
      record["extensions"].is_a?(Hash)
    end

    def exact_keys?(value, keys)
      value.is_a?(Hash) && value.keys.sort == keys.sort
    end

    def valid_observation?(value, source: false)
      keys = source ? %w[evidence_kind value source] : %w[evidence_kind value]
      return false unless exact_keys?(value, keys)
      return false if source && !value["source"].nil? && !value["source"].is_a?(String)
      kind = value["evidence_kind"]
      return false unless %w[launcher_requested runtime_observed launcher_guaranteed unavailable not_applicable].include?(kind)
      if %w[unavailable not_applicable].include?(kind)
        value["value"].nil?
      else
        value["value"].is_a?(String)
      end
    end

    def valid_configuration?(value)
      return false unless exact_keys?(value, %w[model reasoning_effort configuration_stability])
      return false unless %w[unchanged changed unknown].include?(value["configuration_stability"])
      %w[model reasoning_effort].all? do |name|
        pair = value[name]
        exact_keys?(pair, %w[requested initial_effective]) && valid_observation?(pair["requested"], source: true) && valid_observation?(pair["initial_effective"], source: true)
      end
    end

    def valid_source_repository?(value)
      return false unless exact_keys?(value, %w[identity start finish])
      identity = value["identity"]
      return false unless exact_keys?(identity, %w[kind value]) && %w[github path_digest].include?(identity["kind"]) && identity["value"].is_a?(String)
      identity_valid = if identity["kind"] == "github"
        identity["value"].match?(%r{\A[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}\z}) && !identity["value"].end_with?(".git")
      else
        identity["value"].match?(SHA256)
      end
      identity_valid && valid_git_state?(value["start"]) && valid_git_state?(value["finish"])
    end

    def valid_git_state?(value)
      return true if value.nil?
      return false unless exact_keys?(value, %w[branch detached head_sha dirty staged_count unstaged_count untracked_count])
      return false unless [true, false].include?(value["detached"]) && [true, false].include?(value["dirty"])
      return false unless value["head_sha"].is_a?(String) && value["head_sha"].match?(SHA)
      return false unless value.values_at("staged_count", "unstaged_count", "untracked_count").all? { |count| count.is_a?(Integer) && count >= 0 }
      return false unless value["detached"] ? value["branch"].nil? : value["branch"].is_a?(String)
      value["dirty"] == value.values_at("staged_count", "unstaged_count", "untracked_count").sum.positive?
    end

    def valid_source_task?(value)
      return false unless exact_keys?(value, %w[source identifier content_sha256 snapshot])
      return false unless %w[github_issue local_prompt composite unavailable].include?(value["source"])
      return false unless value["identifier"].nil? || value["identifier"].is_a?(String)
      return false unless value["content_sha256"].nil? || (value["content_sha256"].is_a?(String) && value["content_sha256"].match?(SHA256))
      return false unless value["snapshot"].nil? || value["snapshot"] == "task.txt"
      return false if value["snapshot"] && !value["content_sha256"]
      return false if value["content_sha256"] && value["snapshot"] != "task.txt"
      value["source"] != "unavailable" || value.values_at("identifier", "content_sha256", "snapshot").all?(&:nil?)
    end

    def valid_source_timing?(value, state)
      return false unless exact_keys?(value, %w[run_started_at child_started_at child_finished_at run_finished_at calendar_elapsed_ms])
      return false unless value["run_started_at"].is_a?(String) && value["run_started_at"].match?(SOURCE_TIMESTAMP)
      return false unless value.values_at("child_started_at", "child_finished_at", "run_finished_at").all? { |item| item.nil? || (item.is_a?(String) && item.match?(SOURCE_TIMESTAMP)) }
      return false unless value["calendar_elapsed_ms"].nil? || (value["calendar_elapsed_ms"].is_a?(Integer) && value["calendar_elapsed_ms"] >= 0)
      terminal = TERMINAL_STATES.include?(state)
      terminal ? (!value["run_finished_at"].nil? && !value["calendar_elapsed_ms"].nil?) : (value["run_finished_at"].nil? && value["calendar_elapsed_ms"].nil?)
    end

    def valid_source_termination?(value, state)
      return false unless exact_keys?(value, %w[child_exit_code signal reason])
      return false unless value["child_exit_code"].nil? || (value["child_exit_code"].is_a?(Integer) && value["child_exit_code"] >= 0)
      return false unless value["signal"].nil? || value["signal"].is_a?(String)
      return false unless value["reason"].nil? || value["reason"].is_a?(String)
      TERMINAL_STATES.include?(state) ? value["reason"].is_a?(String) : value.values.all?(&:nil?)
    end

    def records_for(mode, selected)
      paths = if mode == :selected
        path = File.join(root, selected, "run.json")
        raise Failure.new("invalid_source_record", "selected run does not exist") unless File.file?(path)
        [path]
      else
        Dir.glob(File.join(root, "run-*", "run.json"))
      end
      entries = paths.filter_map do |path|
        begin
          run = load_run(path)
          identity = run.dig("repository", "identity")
          matches = if identity["kind"] == "github"
            repository && identity["value"].casecmp?(repository)
          else
            identity["value"] == @path_identity
          end
          if mode == :selected && !matches
            raise Failure.new("invalid_source_record", "selected run belongs to another repository")
          end
          next unless matches
          unless eligible_source?(run)
            raise Failure.new("invalid_source_record", "selected run is not yet eligible") if mode == :selected
            next
          end
          next if mode == :automatic && run["run_id"] == ENV["AGENT_OUTCOME_CURRENT_RUN_ID"]
          next if %i[due automatic].include?(mode) && !due?(path, run)
          {path: path, run: run, due: due_time(path, run)}
        rescue Failure
          raise if mode == :selected
          nil
        end
      end
      entries.sort_by { |entry| [entry[:due], entry[:run]["run_id"]] }
    end

    def eligible_source?(run)
      return true if TERMINAL_STATES.include?(run["state"])
      run["state"] == "started" && @now - parse_time(run.dig("timing", "run_started_at")) >= STALE_STARTED
    end

    def existing_outcome(path)
      outcome_path = File.join(File.dirname(path), "outcome.json")
      return nil unless File.file?(outcome_path)
      value = JSON.parse(File.binread(outcome_path))
      return value if value.is_a?(Hash) && value["schema_version"] == 1
      nil
    rescue JSON::ParserError, SystemCallError
      nil
    end

    def due_time(path, run)
      existing = existing_outcome(path)
      value = parse_time(existing&.dig("reconciliation", "next_eligible_at"))
      value || parse_time(run.dig("timing", "run_finished_at")) || parse_time(run.dig("timing", "run_started_at"))
    end

    def due?(path, _run)
      existing = existing_outcome(path)
      return true unless existing
      return false unless existing.dig("reconciliation", "automatic_state") == "active"
      value = parse_time(existing.dig("reconciliation", "next_eligible_at"))
      !value || value <= @now
    end

    def reconcile(path, run, explicit:)
      run_dir = File.dirname(path)
      lock = nil
      previous = nil
      begin
        lock = acquire_lock(run_dir, explicit: explicit)
        return true unless lock
        previous = existing_outcome(path)
        outcome = initial_outcome(run, previous)
        Timeout.timeout(Integer(ENV.fetch("AGENT_OUTCOME_RUN_TIMEOUT", "480"))) do
          if run.dig("repository", "identity", "kind") == "path_digest"
            set_not_applicable(outcome)
          else
            collect(outcome, run, previous)
          end
        end
        schedule(outcome, run)
        atomic_write(File.join(run_dir, "outcome.json"), outcome)
        true
      rescue Timeout::Error
        error = Failure.new("timeout")
        persist_failure(run_dir, run, previous, error)
        warn_once(error.category) unless explicit
        raise error if explicit
        false
      rescue Failure => error
        persist_failure(run_dir, run, previous, error)
        warn_once(error.category) unless explicit
        raise if explicit
        false
      ensure
        lock ? release_lock(lock) : release_owned_lock(run_dir)
      end
    end

    def acquire_lock(run_dir, explicit:)
      lock = File.join(run_dir, ".outcome.lock")
      recovery = File.join(run_dir, ".outcome.lock.recovery")
      created = false
      return lock_busy(explicit) if File.exist?(recovery)
      begin
        Dir.mkdir(lock, 0o700)
        created = true
        File.write(File.join(lock, "owner"), "#{Process.pid}\n", mode: "w", perm: 0o600)
        return lock
      rescue Errno::EEXIST
        return lock_busy(explicit) unless @now.to_f - File.mtime(lock).to_f > STALE_LOCK
        recover_stale_lock(lock, recovery, explicit: explicit)
      rescue Errno::ENOENT
        retry
      rescue Interrupt
        release_lock(lock) if created
        raise
      rescue SystemCallError
        raise Failure.new("local_io", "could not acquire outcome lock")
      end
    end

    def recover_stale_lock(lock, recovery, explicit:)
      recovered_lock = false
      Dir.mkdir(recovery, 0o700)
      begin
        return lock_busy(explicit) unless File.directory?(lock) && @now.to_f - File.mtime(lock).to_f > STALE_LOCK
        displaced = "#{lock}.stale.#{Process.pid}.#{SecureRandom.hex(4)}"
        File.rename(lock, displaced)
        FileUtils.remove_entry_secure(displaced)
        Dir.mkdir(lock, 0o700)
        recovered_lock = true
        File.write(File.join(lock, "owner"), "#{Process.pid}\n", mode: "w", perm: 0o600)
        lock
      ensure
        FileUtils.remove_entry_secure(recovery) if File.directory?(recovery)
      end
    rescue Errno::EEXIST, Errno::ENOENT
      lock_busy(explicit)
    rescue Interrupt
      release_lock(lock) if recovered_lock
      raise
    rescue SystemCallError
      raise Failure.new("local_io", "could not recover stale outcome lock")
    end

    def lock_busy(explicit)
      raise Failure.new("local_io", "selected run is busy") if explicit
      nil
    end

    def release_lock(lock)
      return unless lock && File.directory?(lock)
      FileUtils.remove_entry_secure(lock)
    rescue SystemCallError
      nil
    end

    def release_owned_lock(run_dir)
      lock = File.join(run_dir, ".outcome.lock")
      owner = File.join(lock, "owner")
      release_lock(lock) if File.file?(owner) && File.binread(owner).strip == Process.pid.to_s
    rescue SystemCallError
      nil
    end

    def initial_outcome(run, previous)
      previous ||= {}
      reconciliation = previous["reconciliation"].is_a?(Hash) ? previous["reconciliation"].dup : {}
      reconciliation["last_attempted_at"] = timestamp(@now)
      reconciliation["attempt_count"] = reconciliation.fetch("attempt_count", 0).to_i + 1
      reconciliation["observation_state"] ||= "unavailable"
      reconciliation["automatic_state"] ||= "active"
      reconciliation["next_eligible_at"] = nil
      reconciliation["last_error"] = nil
      {
        "schema_version" => 1,
        "run_id" => run["run_id"],
        "source_run_schema_version" => 1,
        "reconciliation" => reconciliation,
        "correlation" => previous["correlation"].is_a?(Hash) ? previous["correlation"] : {"state" => "unavailable", "associations" => [], "candidates" => []},
        "pull_requests" => Array(previous["pull_requests"])
      }
    end

    def set_not_applicable(outcome)
      outcome["correlation"] = {"state" => "not_applicable", "associations" => [], "candidates" => []}
      reconciliation = outcome["reconciliation"]
      reconciliation["observation_state"] = "not_applicable"
      reconciliation["last_successful_at"] = timestamp(@now)
      reconciliation["automatic_state"] = "quiescent"
      reconciliation["next_eligible_at"] = nil
      reconciliation["last_error"] = nil
    end

    def collect(outcome, run, previous)
      finish = run.dig("repository", "finish")
      finish_sha = finish&.dig("head_sha")
      finish_branch = finish && !finish["detached"] ? finish["branch"] : nil
      pulls_result = @github.api("repos/#{repository}/pulls?state=all&per_page=100", paginate: true)
      raise pulls_result.error if pulls_result.error
      pulls = flatten_pages(pulls_result.value).select { |pr| pr.is_a?(Hash) }

      errors = []
      exact_numbers = []
      if finish_sha
        associated = @github.api("repos/#{repository}/commits/#{finish_sha}/pulls?per_page=100", paginate: true, accept: "application/vnd.github+json")
        if associated.error
          errors << associated.error
        else
          exact_numbers.concat(flatten_pages(associated.value).filter_map { |pr| pr["number"] })
        end
      end
      pulls.each do |pr|
        exact_numbers << pr["number"] if finish_sha && pr.dig("head", "sha") == finish_sha
      end
      exact_numbers.compact!
      exact_numbers.uniq!

      branch_candidates = []
      if exact_numbers.empty? && finish_branch
        pulls.each do |pr|
          next unless pr.dig("head", "repo", "full_name")&.casecmp?(repository)
          next unless pr.dig("head", "ref") == finish_branch
          branch_candidates << pr if temporally_compatible?(pr, run)
        end
      end

      establishing = exact_numbers.map do |number|
        pr = pulls.find { |item| item["number"] == number } || {"number" => number}
        method = pr.dig("head", "sha") == finish_sha ? "finish_head_equals_pr_head" : "finish_head_in_pr_commits"
        [number, method]
      end
      establishing << [branch_candidates.first["number"], "unique_head_branch"] if establishing.empty? && branch_candidates.length == 1

      task_issue = task_issue_number(run)
      candidates = branch_candidates.map do |pr|
        evidence = ["temporal_compatibility"]
        evidence << "task_issue_link" if task_issue && task_linked?(pr["number"], task_issue)
        candidate(pr, evidence)
      end

      old_associations = Array(previous&.dig("correlation", "associations"))
      new_associations = establishing.map do |number, method|
        old = old_associations.find { |association| association["repository"]&.casecmp?(repository) && association["number"] == number }
        methods = (Array(old&.dig("established_by")) + [method]).uniq.sort
        {
          "repository" => repository,
          "number" => number,
          "first_observed_at" => old&.dig("first_observed_at") || timestamp(@now),
          "last_observed_at" => timestamp(@now),
          "established_by" => methods,
          "supporting_evidence" => supporting_evidence(run, number, methods, task_issue)
        }
      end
      associations = merge_associations(old_associations, new_associations)
      state = if associations.any?
        "matched"
      elsif branch_candidates.length > 1
        "ambiguous"
      elsif errors.any?
        "unavailable"
      else
        "unmatched"
      end
      outcome["correlation"] = {"state" => state, "associations" => associations, "candidates" => candidates}

      pr_records = Array(outcome["pull_requests"])
      associations.each do |association|
        old = pr_records.find { |item| item["identity"].is_a?(Hash) && item.dig("identity", "repository")&.casecmp?(repository) && item.dig("identity", "number") == association["number"] }
        observed, observed_errors = observe_pull(association, old)
        errors.concat(observed_errors)
        pr_records = pr_records.reject { |item| item.dig("identity", "repository")&.casecmp?(repository) && item.dig("identity", "number") == association["number"] }
        pr_records << observed
      end
      outcome["pull_requests"] = pr_records.sort_by { |item| [item.dig("identity", "repository").to_s, item.dig("identity", "number").to_i] }
      reconciliation = outcome["reconciliation"]
      reconciliation["observation_state"] = errors.empty? ? "complete" : ((associations.any? || candidates.any?) ? "partial" : "unavailable")
      reconciliation["last_successful_at"] = timestamp(@now) unless reconciliation["observation_state"] == "unavailable"
      reconciliation["last_error"] = errors.first && safe_error(errors.first)
    end

    def flatten_pages(value)
      return [] unless value.is_a?(Array)
      value.all? { |item| item.is_a?(Array) } ? value.flatten(1) : value
    end

    def temporally_compatible?(pr, run)
      started = parse_time(run.dig("timing", "run_started_at"))
      finished = parse_time(run.dig("timing", "run_finished_at")) || started
      created = parse_time(pr["created_at"])
      closed = parse_time(pr["closed_at"] || pr["merged_at"])
      return false unless created
      return created <= finished + WINDOW if created > finished
      return true if !closed || closed >= started

      result = timeline_for(pr["number"])
      return false if result.error
      open_since = created
      flatten_pages(result.value).sort_by { |event| parse_time(event["created_at"]) || Time.at(0) }.each do |event|
        observed = parse_time(event["created_at"])
        next unless observed
        case event["event"]
        when "closed", "merged"
          return true if open_since && open_since <= finished && observed >= started
          open_since = nil
        when "reopened"
          open_since = observed
        end
      end
      open_since && open_since <= finished
    end

    def task_issue_number(run)
      identifier = run.dig("task", "identifier")
      match = identifier&.match(/\A#{Regexp.escape(repository)}#(\d+)\z/i)
      match && Integer(match[1])
    end

    def task_linked?(pr_number, issue_number)
      result = timeline_for(pr_number)
      return false if result.error
      flatten_pages(result.value).any? do |event|
        event["event"] == "cross-referenced" && event.dig("source", "issue", "number") == issue_number
      end
    end

    def timeline_for(pr_number)
      @timeline_cache[pr_number] ||= @github.api("repos/#{repository}/issues/#{pr_number}/timeline?per_page=100", paginate: true, accept: "application/vnd.github+json")
    end

    def candidate(pr, evidence)
      {"repository" => repository, "number" => pr["number"], "evidence" => evidence.uniq.sort}
    end

    def supporting_evidence(run, number, methods, task_issue)
      evidence = methods.map do |kind|
        {"kind" => kind, "commit_sha" => kind.start_with?("finish_head") ? run.dig("repository", "finish", "head_sha") : nil, "branch" => kind == "unique_head_branch" ? run.dig("repository", "finish", "branch") : nil}
      end
      if task_issue && task_linked?(number, task_issue)
        evidence << {"kind" => "task_issue_link", "issue" => "#{repository}##{task_issue}", "commit_sha" => nil, "branch" => nil}
      end
      evidence
    end

    def merge_associations(old_items, new_items)
      merged = {}
      (Array(old_items) + Array(new_items)).each do |item|
        key = [item["repository"].to_s.downcase, item["number"]]
        if merged[key]
          merged[key] = merged[key].merge(item)
          merged[key]["first_observed_at"] = [merged[key]["first_observed_at"], item["first_observed_at"]].compact.min
          merged[key]["established_by"] = (Array(merged[key]["established_by"]) + Array(item["established_by"])).uniq.sort
          merged[key]["supporting_evidence"] = (Array(merged[key]["supporting_evidence"]) + Array(item["supporting_evidence"])).uniq
        else
          merged[key] = item
        end
      end
      merged.values.sort_by { |item| [item["repository"].downcase, item["number"]] }
    end

    def observe_pull(association, old)
      errors = []
      number = association["number"]
      details = required_api("repos/#{repository}/pulls/#{number}", errors)
      current = details ? normalize_current(details) : old&.dig("current") || unavailable_current
      commits = optional_collection("repos/#{repository}/pulls/#{number}/commits?per_page=100", errors)
      timeline = optional_collection("repos/#{repository}/issues/#{number}/timeline?per_page=100", errors, accept: "application/vnd.github+json")
      reviews = optional_collection("repos/#{repository}/pulls/#{number}/reviews?per_page=100", errors)
      normalized_commits = commits.map { |commit| {"sha" => commit["sha"], "source_kind" => "github_pull_commit"} }.select { |commit| commit["sha"] }
      commit_history = merge_by_identity(old&.dig("commits"), normalized_commits, ["sha"], timestamp(@now))
      normalized_timeline = timeline.filter_map { |event| normalize_event(event) }
      timeline_history = merge_by_identity(old&.dig("timeline_events"), normalized_timeline, ["source_id", "kind", "timestamp"], timestamp(@now))
      normalized_reviews = reviews.filter_map { |review| normalize_review(review) }
      review_history = merge_by_identity(old&.dig("reviews"), normalized_reviews, ["source_id"], timestamp(@now))
      revision_errors = errors.dup
      head_sha = current["head_sha"]
      head_observation = head_sha ? [{"sha" => head_sha, "observed_at" => timestamp(@now), "source_kind" => "github_pull_snapshot"}] : []
      head_history = merge_by_identity(old&.dig("head_history"), head_observation, ["sha"], timestamp(@now))
      shas = (review_history.map { |item| item["commit_id"] } + head_history.map { |item| item["sha"] }).compact.uniq
      checks = merge_checks(old&.dig("checks_by_sha"), shas, errors)
      record = {
        "identity" => {"repository" => repository, "number" => number, "node_id" => details&.dig("node_id") || old&.dig("identity", "node_id")},
        "association" => association,
        "current" => current,
        "head_history" => head_history,
        "commits" => commit_history,
        "timeline_events" => timeline_history,
        "reviews" => review_history,
        "checks_by_sha" => checks,
        "derived" => derive(current, head_history, commit_history, timeline_history, review_history, revision_errors)
      }
      [record, errors]
    end

    def required_api(endpoint, errors)
      result = @github.api(endpoint)
      errors << result.error if result.error
      result.value
    end

    def optional_collection(endpoint, errors, accept: nil)
      result = @github.api(endpoint, paginate: true, accept: accept)
      if result.error
        errors << result.error
        []
      else
        flatten_pages(result.value)
      end
    end

    def normalize_current(pr)
      lifecycle = if pr["merged_at"] || pr["merged"]
        "merged"
      elsif pr["state"] == "closed"
        "closed_unmerged"
      elsif pr["state"] == "open"
        "open"
      else
        "unavailable"
      end
      {
        "lifecycle" => lifecycle,
        "draft" => pr.key?("draft") ? pr["draft"] : nil,
        "head_repository" => pr.dig("head", "repo", "full_name"), "head_ref" => pr.dig("head", "ref"), "head_sha" => pr.dig("head", "sha"),
        "base_repository" => pr.dig("base", "repo", "full_name"), "base_ref" => pr.dig("base", "ref"), "base_sha" => pr.dig("base", "sha"),
        "created_at" => normalize_timestamp(pr["created_at"]), "updated_at" => normalize_timestamp(pr["updated_at"]), "closed_at" => normalize_timestamp(pr["closed_at"]), "merged_at" => normalize_timestamp(pr["merged_at"]),
        "merge_commit_sha" => pr["merge_commit_sha"], "observed_at" => timestamp(@now)
      }
    end

    def unavailable_current
      {"lifecycle" => "unavailable", "draft" => nil, "head_repository" => nil, "head_ref" => nil, "head_sha" => nil, "base_repository" => nil, "base_ref" => nil, "base_sha" => nil, "created_at" => nil, "updated_at" => nil, "closed_at" => nil, "merged_at" => nil, "merge_commit_sha" => nil, "observed_at" => timestamp(@now)}
    end

    def normalize_event(event)
      kind = event["event"]&.tr("-", "_")
      return unless EVENT_KINDS.include?(kind)
      observed_at = normalize_timestamp(event["created_at"])
      return unless observed_at
      source_id = event["node_id"] || event["id"] || Digest::SHA256.hexdigest([kind, event["created_at"], event.dig("actor", "login")].join("\u0000"))
      {
        "source_id" => source_id.to_s, "kind" => kind, "timestamp" => observed_at,
        "actor_login" => event.dig("actor", "login"), "actor_type" => event.dig("actor", "type"),
        "before_sha" => event["before_commit_id"], "after_sha" => event["after_commit_id"] || event["commit_id"],
        "before_ref" => event.dig("rename", "from"), "after_ref" => event.dig("rename", "to"), "source_kind" => "github_timeline_event"
      }
    end

    def normalize_review(review)
      return unless review["submitted_at"]
      submitted_at = normalize_timestamp(review["submitted_at"])
      return unless submitted_at
      {
        "source_id" => (review["node_id"] || review["id"]).to_s,
        "reviewer_login" => review.dig("user", "login"), "reviewer_type" => review.dig("user", "type"),
        "state" => review["state"], "commit_id" => review["commit_id"], "submitted_at" => submitted_at,
        "dismissed_at" => normalize_timestamp(review["dismissed_at"]), "source_kind" => "github_pull_review"
      }
    end

    def merge_checks(old_groups, shas, errors)
      old_by_sha = Array(old_groups).to_h { |group| [group["sha"], group] }
      all_shas = (old_by_sha.keys + shas).compact.uniq
      all_shas.sort.map do |sha|
        old = old_by_sha[sha] || {}
        checks_result = @github.api("repos/#{repository}/commits/#{sha}/check-runs?per_page=100", paginate: true, accept: "application/vnd.github+json")
        statuses_result = @github.api("repos/#{repository}/commits/#{sha}/status")
        errors << checks_result.error if checks_result.error
        errors << statuses_result.error if statuses_result.error
        raw_checks = if checks_result.value.is_a?(Hash)
          Array(checks_result.value["check_runs"])
        else
          flatten_pages(checks_result.value).flat_map { |page| page.is_a?(Hash) ? Array(page["check_runs"]) : [] }
        end
        raw_statuses = statuses_result.value.is_a?(Hash) ? Array(statuses_result.value["statuses"]) : []
        checks = raw_checks.map { |check| normalize_check(check, sha) }
        statuses = raw_statuses.map { |status| normalize_status(status, sha) }
        check_history = merge_by_identity(old["check_runs"], checks, ["source_id"], timestamp(@now))
        status_history = merge_by_identity(old["statuses"], statuses, ["source_id"], timestamp(@now))
        evidence = {"checks" => checks_result.error ? "unavailable" : "complete", "statuses" => statuses_result.error ? "unavailable" : "complete"}
        {"sha" => sha, "check_runs" => check_history, "statuses" => status_history, "evidence" => evidence, "observed_check_rollup" => check_rollup(check_history, status_history, evidence)}
      end
    end

    def normalize_check(check, sha)
      {"source_id" => check["id"].to_s, "name" => check["name"], "app_id" => check.dig("app", "id"), "app_slug" => check.dig("app", "slug"), "head_sha" => check["head_sha"] || sha, "status" => check["status"], "conclusion" => check["conclusion"], "started_at" => normalize_timestamp(check["started_at"]), "completed_at" => normalize_timestamp(check["completed_at"]), "source_kind" => "github_check_run"}
    end

    def normalize_status(status, sha)
      identity = status["id"] || [status["context"], status["created_at"], status.dig("creator", "login")].join(":")
      {"source_id" => identity.to_s, "context" => status["context"], "sha" => sha, "state" => status["state"], "created_at" => normalize_timestamp(status["created_at"]), "updated_at" => normalize_timestamp(status["updated_at"]), "creator_login" => status.dig("creator", "login"), "creator_type" => status.dig("creator", "type"), "source_kind" => "github_commit_status"}
    end

    def check_rollup(checks, statuses, evidence)
      return "incomplete" unless evidence.values.all? { |value| value == "complete" }
      current_checks = checks.group_by { |item| [item["app_id"], item["app_slug"], item["name"]] }.values.map { |items| items.max_by { |item| parse_time(item["completed_at"] || item["started_at"] || item["last_observed_at"]) || Time.at(0) } }
      current_statuses = statuses.group_by { |item| item["context"] }.values.map { |items| items.max_by { |item| parse_time(item["updated_at"] || item["created_at"] || item["last_observed_at"]) || Time.at(0) } }
      return "unobserved" if current_checks.empty? && current_statuses.empty?
      return "failing" if current_checks.any? { |item| FAILING_CHECK_CONCLUSIONS.include?(item["conclusion"]) } || current_statuses.any? { |item| %w[failure error].include?(item["state"]) }
      return "pending" if current_checks.any? { |item| item["status"] != "completed" || item["conclusion"].nil? } || current_statuses.any? { |item| item["state"] == "pending" }
      return "passing" if current_checks.all? { |item| NON_FAILING_CHECK_CONCLUSIONS.include?(item["conclusion"]) } && current_statuses.all? { |item| item["state"] == "success" }
      "incomplete"
    end

    def derive(current, heads, commits, timeline, reviews, errors)
      ordered_reviews = reviews.sort_by { |review| parse_time(review["submitted_at"]) || Time.at(0) }
      qualifying = ordered_reviews.select { |review| review["submitted_at"] }
      commit_ids = qualifying.map { |review| review["commit_id"] }.compact.uniq
      first = qualifying.first
      first_revision = if first.nil?
        {"state" => "not_applicable", "sha" => nil}
      elsif first["commit_id"]
        {"state" => "available", "sha" => first["commit_id"]}
      else
        {"state" => "unavailable", "sha" => nil}
      end
      later = if first_revision["state"] == "not_applicable"
        "not_applicable"
      elsif first_revision["state"] == "unavailable" || errors.any?
        "unavailable"
      else
        first_submitted_at = parse_time(first["submitted_at"])
        first_index = commits.index { |item| item["sha"] == first_revision["sha"] }
        later_commit = first_index && commits[(first_index + 1)..]&.any?
        later_head = heads.any? do |item|
          observed = parse_time(item["first_observed_at"])
          item["sha"] != first_revision["sha"] && observed && first_submitted_at && observed >= first_submitted_at
        end
        later_transition = timeline.any? do |item|
          observed = parse_time(item["timestamp"])
          item["after_sha"] && item["after_sha"] != first_revision["sha"] && observed && first_submitted_at && observed >= first_submitted_at
        end
        current_changed = current["head_sha"] && current["head_sha"] != first_revision["sha"]
        later_commit || later_head || later_transition || current_changed ? "yes" : "no"
      end
      merged_first = if current["lifecycle"] != "merged" || qualifying.empty?
        "not_applicable"
      elsif first_revision["state"] != "available" || current["head_sha"].nil? || errors.any?
        "unavailable"
      elsif current["head_sha"] == first_revision["sha"] && later == "no"
        "yes"
      else
        "no"
      end
      {"reviewed_revision_count" => commit_ids.length, "first_reviewed_revision" => first_revision, "post_first_review_change_observed" => later, "merged_on_first_reviewed_revision" => merged_first}
    end

    def schedule(outcome, run)
      reconciliation = outcome["reconciliation"]
      return if reconciliation["automatic_state"] == "quiescent"
      finished = parse_time(run.dig("timing", "run_finished_at")) || parse_time(run.dig("timing", "run_started_at"))
      deadline = finished + WINDOW
      state = outcome.dig("correlation", "state")
      complete = reconciliation["observation_state"] == "complete"
      terminal = outcome["pull_requests"].any? && outcome["pull_requests"].all? { |pr| %w[merged closed_unmerged].include?(pr.dig("current", "lifecycle")) }
      if state == "not_applicable" || (state == "matched" && terminal && complete)
        reconciliation["automatic_state"] = "quiescent"
        reconciliation["next_eligible_at"] = nil
      elsif @now >= deadline && %w[unmatched ambiguous unavailable].include?(state)
        reconciliation["automatic_state"] = "dormant"
        reconciliation["next_eligible_at"] = nil
      else
        reconciliation["automatic_state"] = "active"
        delay = reconciliation["observation_state"] == "unavailable" ? HOUR : DAY
        reconciliation["next_eligible_at"] = timestamp(@now + delay)
      end
    end

    def persist_failure(run_dir, run, previous, error)
      outcome = initial_outcome(run, previous)
      reconciliation = outcome["reconciliation"]
      reconciliation["observation_state"] = previous ? "partial" : "unavailable"
      reconciliation["last_error"] = safe_error(error)
      outcome["correlation"]["state"] = "unavailable" unless Array(outcome.dig("correlation", "associations")).any?
      schedule(outcome, run)
      atomic_write(File.join(run_dir, "outcome.json"), outcome)
    rescue Failure
      nil
    end

    def safe_error(error)
      value = {"category" => ERROR_CATEGORIES.include?(error.category) ? error.category : "api"}
      value["http_status"] = error.status if error.status.is_a?(Integer) && (100..599).cover?(error.status)
      value
    end

    def atomic_write(path, value)
      directory = File.dirname(path)
      temporary = File.join(directory, ".outcome.json.tmp.#{Process.pid}.#{SecureRandom.hex(6)}")
      File.open(temporary, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.pretty_generate(value))
        file.write("\n")
        file.flush
        file.fsync
      end
      File.chmod(0o600, temporary)
      File.rename(temporary, path)
    rescue SystemCallError
      File.unlink(temporary) if temporary && File.exist?(temporary)
      raise Failure.new("local_io", "could not atomically write outcome evidence")
    end

    def warn_once(category)
      return if @warning_emitted
      @warning_emitted = true
      warn "AGENT_OUTCOME_WARNING: outcome reconciliation unavailable (#{category})"
    end
  end
end

signal_status = 130
Signal.trap("INT") { signal_status = 130; raise Interrupt }
Signal.trap("TERM") { signal_status = 143; raise Interrupt }
begin
  exit AgentRunOutcomes::Reconciler.new.run(ARGV)
rescue Interrupt
  exit signal_status
end
