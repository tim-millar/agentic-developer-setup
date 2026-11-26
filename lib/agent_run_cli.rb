# frozen_string_literal: true

require "json"
require "optparse"
require "time"
require_relative "agent_run_reporting/markdown"

module AgentRunCLI
  class Error < StandardError; end

  class Catalog
    Entry = Data.define(:id, :path, :run, :started)
    attr_reader :root, :invalid

    def initialize(root, explicit:, repository:)
      raise AgentRunReporting::InputError, "Telemetry root must be absolute" unless root.start_with?("/")
      @root = AgentRunReporting::Corpus.canonical_path(File.expand_path(root))
      @invalid = 0
      @invalid_ids = []
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
        next if File.symlink?(path)
        unless File.directory?(path)
          @invalid += 1
          @invalid_ids << id
          next
        end
        record = read_record(path, id, "run.json", AgentRunTelemetry::Validator)
        unless record
          @invalid += 1
          @invalid_ids << id
          next
        end
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

    attr_reader :entries

    def select(selector)
      return entries.first if selector == "latest"
      matches = entries.select { |entry| entry.id.start_with?(selector) }
      raise Error, "Selected run has unusable base evidence" if matches.empty? && @invalid_ids.include?(selector)
      raise Error, "No valid run matches that selector" if matches.empty?
      raise ArgumentError, "Run selector is ambiguous; provide a longer prefix" if matches.length > 1
      matches.first
    end

    def sidecar(entry, name, validator)
      schema = (name == "usage.json") ? JSON.parse(File.binread(AgentRunUsage::Validator::SCHEMA_PATH)) : nil
      read_record(entry.path, entry.id, name, validator, schema: schema)
    rescue SystemCallError, JSON::ParserError
      nil
    end

    def sidecar_state(entry, name, validator)
      path = File.join(entry.path, name)
      return "absent" unless File.exist?(path) || File.symlink?(path)
      sidecar(entry, name, validator) ? "present and valid" : "invalid or unsupported"
    end

    def evidence_path(entry, name)
      File.join(entry.path, name)
    end

    private

    def read_record(directory, id, name, validator, schema: nil)
      path = File.join(directory, name)
      stat = File.lstat(path)
      return nil unless stat.file?
      content = File.read(path, encoding: "UTF-8")
      return nil unless content.valid_encoding?
      record = JSON.parse(content)
      return nil unless record.is_a?(Hash) && record["run_id"] == id
      versions = [record["schema_version"]]
      versions << record["source_run_schema_version"] if validator == AgentRunOutcomes::Validator
      return nil if versions.any? { |version| version.is_a?(Integer) && version != 1 }
      options = schema ? {schema: schema} : {}
      validator.new(record, **options).validate ? record : nil
    rescue SystemCallError, JSON::ParserError
      nil
    end
  end

  class Command
    def run(argv)
      if argv.empty? || %w[-h --help].include?(argv.first)
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

    def parse(args, command, defaults = {})
      options = defaults
      parser = OptionParser.new do |p|
        p.banner = "Usage: ads-agent-runs #{command} [options]"
        p.on("--telemetry-dir ABSOLUTE_PATH") { |v| options[:root] = absolute(v) }
        p.on("--repository OWNER/REPO") do |v|
          raise OptionParser::InvalidArgument, "expected OWNER/REPO" unless AgentRunTelemetry::Validator::GITHUB_REPOSITORY.match?(v)
          options[:repository] = v.downcase
        end
        p.on("-h", "--help") {
          puts p
          options[:help] = true
        }
        yield p, options if block_given?
      end
      parser.require_exact = true
      parser.parse!(args)
      raise OptionParser::InvalidArgument, "unexpected positional arguments" unless args.empty?
      [options, parser]
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
      selected = options[:all] ? catalog.entries : catalog.entries.first(options[:limit])
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
      usage = catalog.sidecar(entry, "usage.json", AgentRunUsage::Validator)
      outcome = catalog.sidecar(entry, "outcome.json", AgentRunOutcomes::Validator)
      [entry.started&.iso8601(3) || "unavailable", entry.id,
        run.dig("repository", "identity", "value"), run.dig("task", "identifier") || "unavailable",
        run.dig("runtime", "client", "id"), run["state"],
        usage&.dig("collection", "state") || catalog.sidecar_state(entry, "usage.json", AgentRunUsage::Validator),
        outcome&.dig("correlation", "state") || catalog.sidecar_state(entry, "outcome.json", AgentRunOutcomes::Validator)]
    end

    def run_show(args)
      raise OptionParser::MissingArgument, "run selector" if args.empty?
      selector = args.shift
      options, = parse(args, "show")
      return 0 if options[:help]
      catalog = catalog(options)
      entry = catalog.select(selector)
      unless entry
        raise Error, "No valid run matches that selector" if catalog.entries.empty?
        puts "No recorded runs in the selected scope."
        return 0
      end
      usage = catalog.sidecar(entry, "usage.json", AgentRunUsage::Validator)
      outcome = catalog.sidecar(entry, "outcome.json", AgentRunOutcomes::Validator)
      puts show_record(catalog, entry, usage, outcome)
      0
    end

    def show_record(catalog, entry, usage, outcome)
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
      snap_state = if !snap
        "not recorded"
      else
        snapshot_state(snap_path)
      end
      section.call("Task", [["Source", r.dig("task", "source")], ["Identifier", r.dig("task", "identifier")], ["Snapshot", snap_state], ["Snapshot path", snap_path]])
      timing = r["timing"]
      term = r["termination"]
      repos = r["repository"]
      section.call("Execution", [["Started UTC", timestamp(timing["run_started_at"])], ["Finished UTC", timestamp(timing["run_finished_at"])], ["Calendar elapsed", timing["calendar_elapsed_ms"] && format("%02d:%02d:%02d", *timing["calendar_elapsed_ms"].divmod(3_600_000).then { |h, rem| [h, rem / 60_000, (rem % 60_000) / 1000] })], ["State", (r["state"] == "started") ? "started / not finalised" : r["state"]], ["Child exit code", term["child_exit_code"]], ["Signal", term["signal"]], ["Termination reason", term["reason"]], ["Git start", git(repos["start"])], ["Git finish", git(repos["finish"])]])
      section.call("Usage", usage_fields(usage, catalog.sidecar_state(entry, "usage.json", AgentRunUsage::Validator)))
      section.call("Outcome", outcome_fields(outcome, catalog.sidecar_state(entry, "outcome.json", AgentRunOutcomes::Validator)))
      lines << "Evidence"
      %w[run.json usage.json outcome.json task.txt].each do |name|
        path = catalog.evidence_path(entry, name)
        state = if name == "run.json"
          "present and valid"
        elsif name == "task.txt" && snap
          snap_state
        elsif name == "task.txt" && snapshot_state(path) == "absent"
          "absent"
        elsif name == "task.txt"
          "unreferenced or unusable"
        else
          validator = (name == "usage.json") ? AgentRunUsage::Validator : AgentRunOutcomes::Validator
          catalog.sidecar_state(entry, name, validator)
        end
        lines << "  #{name}: #{path} (#{state})"
      end
      lines.join("\n") + "\n"
    end

    def usage_fields(record, absent_state)
      return [["Collection", absent_state]] unless record
      totals = record["observed_totals"] || {}
      cost = record["cost_summary"] || {}
      fields = [["Collection", record.dig("collection", "state")], ["Reason", record.dig("collection", "reason")], ["Observed provider/model", record["measurements"].map { |m| "#{m["provider"]}/#{m["model"]}" }.uniq.join(", ").then { |s| s.empty? ? "unavailable" : s }], ["Successful-response measurements", record["measurements"].length]]
      AgentRunUsage::Validator::TOKEN_FIELDS.each { |key| fields << [key, totals[key]] }
      fields << ["Runtime monetary evidence", cost["observed_usd_micros"] && "#{cost["observed_usd_micros"]} USD micros (provider-reported/runtime estimate)"]
      fields << ["Cost state", cost["state"]]
      fields << ["Cost semantics", cost["semantics"]]
      fields
    end

    def outcome_fields(record, absent_state)
      return [["Evidence", absent_state]] unless record
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
      AgentRunReporting::Command.new.run(args)
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

    def git(state)
      state ? "#{state["branch"] || "detached"} @ #{state["head_sha"]}" : "unavailable"
    end

    def snapshot_state(path)
      stat = File.lstat(path)
      stat.file? ? "available" : "unavailable or unusable"
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
