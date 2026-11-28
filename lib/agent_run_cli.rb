# frozen_string_literal: true

require "json"
require "optparse"
require "stringio"
require "time"
require_relative "agent_run_reporting/markdown"

module AgentRunCLI
  class Error < StandardError; end

  class Catalog
    Entry = Data.define(:id, :path, :run, :started)
    attr_reader :root, :invalid, :entries

    def initialize(root, explicit:, repository:)
      raise AgentRunReporting::InputError, "Telemetry root must be absolute" unless root.start_with?("/")
      @root = AgentRunReporting::Corpus.canonical_path(File.expand_path(root))
      @invalid = 0
      @invalid_ids = []
      @sidecars = {}
      @usage_schema = nil
      @entries = []
      names = begin
        Dir.children(@root)
      rescue Errno::ENOENT
        raise AgentRunReporting::InputError, "Selected telemetry root does not exist" if explicit
        []
      rescue SystemCallError
        raise AgentRunReporting::InputError, "Cannot read selected telemetry root"
      end
      raise AgentRunReporting::InputError, "Cannot search selected telemetry root" unless !File.exist?(@root) || File.executable?(@root)
      names.grep(AgentRunTelemetry::Validator::RUN_ID).sort.each do |id|
        path = File.join(@root, id)
        result = if File.symlink?(path) || !File.directory?(path)
          AgentRunReporting::RecordReader.invalid(path, "run directory is not a regular directory")
        else
          AgentRunReporting::RecordReader.read(path, id, "run.json", AgentRunTelemetry::Validator)
        end
        unless result.state == "valid"
          @invalid += 1
          @invalid_ids << id
          next
        end
        record = result.record
        identity = record.dig("repository", "identity")
        next if repository && (identity["kind"] != "github" || identity["value"].casecmp?(repository) == false)
        time = AgentRunReporting.utc_timestamp(record.dig("timing", "run_started_at"))
        @entries << Entry.new(id, path, record, time)
      end
      @entries.sort! do |left, right|
        if left.started && right.started
          comparison = right.started <=> left.started
          comparison.zero? ? right.id <=> left.id : comparison
        elsif left.started
          -1
        elsif right.started
          1
        else
          right.id <=> left.id
        end
      end
    rescue SystemCallError
      raise AgentRunReporting::InputError, "Cannot read selected telemetry root"
    end

    def select(selector)
      return entries.first if selector == "latest"
      raise Error, "Selected run has unusable base evidence" if @invalid_ids.include?(selector)
      matches = entries.select { |entry| entry.id.start_with?(selector) }
      raise Error, "No valid run matches that selector" if matches.empty?
      raise ArgumentError, "Run selector is ambiguous; provide a longer prefix" if matches.length > 1
      matches.first
    end

    def sidecar(entry, name)
      @sidecars[[entry.id, name]] ||= begin
        validator = (name == "usage.json") ? AgentRunUsage::Validator : AgentRunOutcomes::Validator
        schema = usage_schema if name == "usage.json"
        AgentRunReporting::RecordReader.read(entry.path, entry.id, name, validator, schema: schema)
      end
    end

    def evidence_path(entry, name)
      File.join(entry.path, name)
    end

    private

    def usage_schema
      @usage_schema ||= JSON.parse(File.binread(AgentRunUsage::Validator::SCHEMA_PATH))
    rescue SystemCallError, JSON::ParserError
      raise AgentRunReporting::InputError, "Cannot read bundled usage schema"
    end
  end

  class Command
    def run(argv)
      if argv.empty?
        puts top_help
        return 0
      end
      if %w[-h --help].include?(argv.first)
        raise OptionParser::InvalidArgument, "unexpected arguments after help" unless argv.length == 1
        puts top_help
        return 0
      end
      command = argv.shift
      raise OptionParser::InvalidArgument, "unknown command: #{safe(command)}" unless %w[list show report].include?(command)
      return run_report(argv) if command == "report"
      (command == "list") ? run_list(argv) : run_show(argv)
    rescue OptionParser::ParseError, ArgumentError => e
      warn "ads-agent-runs: #{safe(e.message)}"
      2
    rescue AgentRunReporting::InputError, Error => e
      warn "ads-agent-runs: #{safe(e.message)}"
      1
    rescue SystemCallError
      warn "ads-agent-runs: selected evidence could not be read"
      1
    end

    private

    def parse(args, command, defaults = {}, positionals: 0)
      options = defaults
      parser = OptionParser.new do |p|
        p.banner = if command == "show"
          "Usage: ads-agent-runs show <run_id|unique-prefix|latest> [options]"
        else
          "Usage: ads-agent-runs #{command} [options]"
        end
        p.on("--telemetry-dir ABSOLUTE_PATH") { |v| options[:root] = absolute(v) }
        p.on("--repository OWNER/REPO") do |v|
          raise OptionParser::InvalidArgument, "expected OWNER/REPO" unless AgentRunTelemetry::Validator::GITHUB_REPOSITORY.match?(v)
          options[:repository] = v.downcase
        end
        p.on("-h", "--help", "Show usage") {
          puts p
          options[:help] = true
        }
        yield p, options if block_given?
      end
      parser.require_exact = true
      parser.parse!(args)
      raise OptionParser::InvalidArgument, "unexpected positional arguments" if args.length > positionals
      [options, parser, args.dup]
    end

    def run_list(args)
      options, = parse(args, "list", {limit: 20}) do |p, o|
        p.on("--limit N") { |v|
          o[:limit] = positive(v)
          o[:limit_specified] = true
        }
        p.on("--all") { o[:all] = true }
      end
      return 0 if options[:help]
      raise OptionParser::InvalidArgument, "--limit and --all cannot be combined" if options[:all] && options[:limit_specified]
      catalog = catalog(options)
      selected = options[:all] ? catalog.entries : catalog.entries.first([options[:limit], catalog.entries.length].min)
      if selected.empty?
        puts "No recorded runs in the selected scope."
      else
        rows = selected.map { |entry| list_row(catalog, entry) }
        headers = ["Started UTC", "Run ID", "Repository", "Task", "Runtime", "Execution", "Usage", "Outcome"]
        widths = (rows + [headers]).transpose.map { |column| column.map { |v| safe(v).length }.max }
        puts ([headers] + rows).map { |row| row.each_with_index.map { |v, i| safe(v).ljust(widths[i]) }.join("  ").rstrip }.join("\n")
        omitted = catalog.entries.length - selected.length
        puts "Displayed #{selected.length} run(s); #{omitted} additional valid run(s) omitted." if omitted.positive?
      end
      warn "Skipped #{catalog.invalid} invalid base record(s)." if catalog.invalid.positive?
      0
    end

    def list_row(catalog, entry)
      run = entry.run
      usage = catalog.sidecar(entry, "usage.json")
      outcome = catalog.sidecar(entry, "outcome.json")
      [entry.started&.iso8601(3) || "unavailable", entry.id,
        run.dig("repository", "identity", "value"), run.dig("task", "identifier") || "unavailable",
        run.dig("runtime", "client", "id"), run["state"],
        usage.record&.dig("collection", "state") || sidecar_label(usage),
        outcome.record&.dig("correlation", "state") || sidecar_label(outcome)]
    end

    def run_show(args)
      options, _parser, positionals = parse(args, "show", {}, positionals: 1)
      if options[:help]
        raise OptionParser::InvalidArgument, "invalid run selector" if positionals.any? && !valid_selector?(positionals.first)
        return 0
      end
      raise OptionParser::MissingArgument, "run selector" if positionals.empty?
      selector = positionals.first
      raise OptionParser::InvalidArgument, "invalid run selector" unless valid_selector?(selector)
      catalog = catalog(options)
      entry = catalog.select(selector)
      unless entry
        raise Error, "No valid run matches that selector" if catalog.entries.empty?
        puts "No recorded runs in the selected scope."
        return 0
      end
      usage = catalog.sidecar(entry, "usage.json")
      outcome = catalog.sidecar(entry, "outcome.json")
      puts show_record(catalog, entry, usage, outcome)
      0
    end

    def show_record(catalog, entry, usage_result, outcome_result)
      r = entry.run
      lines = []
      section = ->(title, fields) {
        lines << title.to_s
        fields.each { |k, v| lines << "  #{k}: #{safe(v.nil? ? "unavailable" : v)}" }
        lines << ""
      }
      obs = ->(x) { (x && x["evidence_kind"] != "unavailable" && x["evidence_kind"] != "not_applicable") ? x["value"] : "unavailable" }
      section.call("Run", [["Run ID", entry.id], ["Repository", r.dig("repository", "identity", "value")],
        ["Runtime", "#{r.dig("runtime", "client", "id")} #{obs.call(r.dig("runtime", "client", "version"))}"],
        ["Harness", "#{r.dig("runtime", "harness", "id")} v#{r.dig("runtime", "harness", "version")}"],
        ["Requested model", obs.call(r.dig("configuration", "model", "requested"))], ["Initial effective model", obs.call(r.dig("configuration", "model", "initial_effective"))],
        ["Requested reasoning effort", obs.call(r.dig("configuration", "reasoning_effort", "requested"))], ["Initial effective reasoning effort", obs.call(r.dig("configuration", "reasoning_effort", "initial_effective"))],
        ["Configuration stability", r.dig("configuration", "configuration_stability")]])
      snap = r.dig("task", "snapshot")
      snap_path = snap ? catalog.evidence_path(entry, snap) : nil
      task_evidence_path = catalog.evidence_path(entry, "task.txt")
      snap_state = if !snap
        "not recorded"
      else
        snapshot_state(snap_path)
      end
      task_file_state = snapshot_state(task_evidence_path)
      section.call("Task", [["Source", r.dig("task", "source")], ["Identifier", r.dig("task", "identifier")], ["Snapshot", snap_state], ["Snapshot path", snap_path]])
      timing = r["timing"]
      term = r["termination"]
      repos = r["repository"]
      section.call("Execution", [["Started UTC", timestamp(timing["run_started_at"])], ["Finished UTC", timestamp(timing["run_finished_at"])], ["Calendar elapsed", timing["calendar_elapsed_ms"] && format("%02d:%02d:%02d", *timing["calendar_elapsed_ms"].divmod(3_600_000).then { |h, rem| [h, rem / 60_000, (rem % 60_000) / 1000] })], ["State", (r["state"] == "started") ? "started / not finalised" : r["state"]], ["Child exit code", term["child_exit_code"]], ["Signal", term["signal"]], ["Termination reason", term["reason"]], ["Git start", git(repos["start"])], ["Git finish", git(repos["finish"])]])
      section.call("Usage", usage_fields(usage_result))
      section.call("Outcome", outcome_fields(outcome_result))
      lines << "Evidence"
      %w[run.json usage.json outcome.json task.txt].each do |name|
        path = catalog.evidence_path(entry, name)
        state = if name == "run.json"
          "present and valid"
        elsif name == "task.txt" && snap
          snap_state
        elsif name == "task.txt" && task_file_state == "absent"
          "absent"
        elsif name == "task.txt"
          snap ? snap_state : "unreferenced or unusable"
        else
          result = (name == "usage.json") ? usage_result : outcome_result
          sidecar_label(result)
        end
        lines << "  #{name}: #{safe(path)} (#{state})"
      end
      lines.join("\n") + "\n"
    end

    def usage_fields(result)
      return [["Collection", sidecar_label(result)]] unless result.record
      record = result.record
      totals = record["observed_totals"] || {}
      cost = record["cost_summary"] || {}
      collection_state = record.dig("collection", "state")
      measurement_count = if %w[complete partial].include?(collection_state)
        totals["measurement_count"]
      end
      measurement_label = (collection_state == "partial") ? "Observed successful-response measurements (partial)" : "Successful-response measurements"
      fields = [["Collection", collection_state], ["Reason", record.dig("collection", "reason")], ["Observed provider/model", record["measurements"].map { |m| "#{m["provider"]}/#{m["model"]}" }.uniq.join(", ").then { |s| s.empty? ? "unavailable" : s }], [measurement_label, measurement_count]]
      dimension_labels = {
        "input_total" => "Input total", "input_uncached" => "Input uncached",
        "input_cache_read" => "Input cache read", "input_cache_write" => "Input cache write",
        "output_total" => "Output total", "output_reasoning" => "Output reasoning"
      }
      AgentRunUsage::Validator::TOKEN_FIELDS.each do |key|
        label = dimension_labels.fetch(key)
        label = "Observed #{label.downcase} (partial)" if collection_state == "partial"
        fields << [label, totals[key]]
      end
      fields << ["Runtime monetary evidence", cost["observed_usd_micros"] && "#{cost["observed_usd_micros"]} USD micros (provider-reported/runtime estimate)"]
      fields << ["Cost state", cost["state"]]
      fields << ["Cost semantics", cost["semantics"]]
      fields
    end

    def outcome_fields(result)
      return [["Evidence", sidecar_label(result)]] unless result.record
      record = result.record
      rec = record["reconciliation"]
      corr = record["correlation"]
      fields = [["Observation state", rec["observation_state"]], ["Correlation state", corr["state"]]]
      corr["associations"].each do |a|
        pr = record["pull_requests"].find { |item| item.dig("identity", "repository").casecmp?(a["repository"]) && item.dig("identity", "number") == a["number"] }
        fields << ["Confirmed PR", "#{a["repository"]}##{a["number"]} · #{pr&.dig("current", "lifecycle") || "unavailable"}"]
        if pr
          fields << ["Reviewed revisions", pr.dig("derived", "reviewed_revision_count")]
          fields << ["Post-first-review change observed", pr.dig("derived", "post_first_review_change_observed")]
          head = pr.dig("current", "head_sha")
          group = pr["checks_by_sha"].find { |g| g["sha"] == head }
          fields << ["Current-head checks", group ? group["observed_check_rollup"] : "unavailable"]
        end
      end
      fields += [["Last reconciliation attempt", timestamp(rec["last_attempted_at"])], ["Last successful observation", timestamp(rec["last_successful_at"])], ["Next eligible", timestamp(rec["next_eligible_at"])], ["Last error category", rec.dig("last_error", "category")]]
      fields
    end

    def run_report(args)
      require_relative "../scripts/report_agent_runs"
      return AgentRunReporting::Command.new.run(args) unless args.any? { |arg| %w[-h --help].include?(arg) }

      original_stdout = $stdout
      captured = StringIO.new
      $stdout = captured
      status = AgentRunReporting::Command.new.run(args)
      body = captured.string.sub(/\AUsage: [^\n]+/, "Usage: ads-agent-runs report [options]")
      original_stdout.write(body)
      status
    ensure
      $stdout = original_stdout if original_stdout
    end

    def catalog(options)
      explicit = options.key?(:root)
      Catalog.new(options[:root] || AgentRunReporting::Corpus.default_root, explicit: explicit, repository: options[:repository])
    end

    def absolute(value)
      raise OptionParser::InvalidArgument, "path must be absolute" unless value.start_with?("/")
      value
    end

    def positive(value)
      raise OptionParser::InvalidArgument, "limit must be a positive decimal integer" unless value.match?(/\A[1-9][0-9]*\z/)
      Integer(value, 10)
    end

    def sidecar_label(result)
      case result.state
      when "absent" then "absent"
      when "invalid" then "invalid or unsupported"
      else "present and valid"
      end
    end

    def valid_selector?(selector)
      return true if selector == "latest"
      return false if selector.empty?

      possible_run_id_prefix?(selector)
    end

    def possible_run_id_prefix?(value)
      return "run-".start_with?(value) if value.length <= 4
      return false unless value.start_with?("run-")

      suffix = value.delete_prefix("run-")
      return suffix.match?(/\A\d{1,8}\z/) if suffix.length <= 8
      return false unless suffix[0, 8].match?(/\A\d{8}\z/) && suffix[8] == "T"

      time = suffix[9..]
      return time.match?(/\A\d{1,6}\z/) if time.length <= 6
      return false unless time[0, 6].match?(/\A\d{6}\z/) && time[6] == "Z"

      id_suffix = time[7..]
      return true if id_suffix.empty?
      return false unless id_suffix.start_with?("-")

      id_suffix.delete_prefix("-").match?(/\A[0-9a-f]{0,32}\z/)
    end

    def git(state)
      state ? "#{state["branch"] || "detached"} @ #{state["head_sha"]}" : "unavailable"
    end

    def snapshot_state(path)
      stat = File.lstat(path)
      (stat.file? && File.readable?(path)) ? "available" : "unavailable or unusable"
    rescue Errno::ENOENT
      "absent"
    rescue SystemCallError
      "unavailable or unusable"
    end

    def timestamp(value)
      AgentRunReporting.utc_timestamp(value)&.iso8601(3)
    end

    def safe(value)
      value.to_s.gsub(/[[:cntrl:]]/) { |c| format("\\u%04X", c.ord) }
    end

    def top_help
      "Usage: ads-agent-runs <list|show|report> [options]\n\nCommands:\n  list   List recent recorded runs\n  show   Inspect one recorded run\n  report Generate the longitudinal Markdown report\n"
    end
  end
end
