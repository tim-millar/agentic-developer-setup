# frozen_string_literal: true

require "date"
require "digest"
require_relative "usage"
require_relative "pull_requests"

module AgentRunReporting
  class Markdown
    LIFECYCLES = %w[open merged closed_unmerged unavailable/conflicting].freeze
    SIDECAR_STATES = ["sidecar absent", "sidecar invalid or unsupported"].freeze
    OUTCOME_STATES = AgentRunOutcomes::Validator::OBSERVATION_STATES + SIDECAR_STATES
    USAGE_STATES = AgentRunUsage::Validator::COLLECTION_STATES + SIDECAR_STATES
    UNKNOWN = "unavailable"

    def initialize(corpus, generated_at:, repository:, explicit_root:)
      @corpus = corpus
      @runs = corpus.runs
      @applicable = @runs.select { |run| run.github_repository && run.outcome_state != "not_applicable" }
      @usage = Usage.new(@runs)
      @outcomes = PullRequests.new(@runs)
      @generated_at = generated_at
      @repository = repository
      @explicit_root = explicit_root
    end

    def render
      @lines = []
      heading(1, "ADS agent run report")
      heading(2, "Report metadata")
      bullets({
        "Generated at" => @generated_at.iso8601,
        "Telemetry scope" => @explicit_root ? "explicit telemetry root" : "default telemetry root",
        "Telemetry root identifier" => "sha256:#{Digest::SHA256.hexdigest(@corpus.root)}",
        "Repository filter" => @repository || "all repositories",
        "Source run count" => @runs.length,
        "Recorded run start period" => run_period,
        "Latest available outcome reconciliation" => @outcomes.latest_observation&.iso8601(3) || UNKNOWN
      })
      paragraph("No valid run data in the selected scope.") if @runs.empty?

      heading(2, "Evidence coverage")
      evidence_coverage
      heading(2, "Agent activity")
      activity
      heading(2, "Computational resource consumption")
      resources(@usage)
      models
      costs(@usage)
      heading(2, "Observable engineering outcomes")
      pr_metrics(@outcomes.pulls)
      paragraph(applicable_outcomes)
      heading(2, "Monthly cohorts")
      cohorts
      heading(2, "Data-quality diagnostics and limitations")
      limitations
      @lines.join("\n") + "\n"
    end

    private

    def run_period
      endpoints = @runs.filter_map(&:started_at).minmax
      return UNKNOWN unless endpoints.first

      endpoints.uniq.map { |time| time.iso8601(3) }.join(" through ")
    end

    def evidence_coverage
      usable = @applicable.count { |run| %w[complete partial].include?(run.outcome_state) }
      bullets({
        "Recorded valid runs" => @runs.length,
        "Invalid or skipped run records in selected root (before filtering)" => @corpus.invalid_runs,
        "Complete usage coverage" => percentage(@runs.count { |run| run.usage_state == "complete" }, @runs.length),
        "Usable outcome coverage among applicable GitHub runs" => percentage(usable, @applicable.length)
      })
      paragraph(applicable_outcomes)
      counts("Usage collection state", @runs.map(&:usage_state), USAGE_STATES)
      counts("Outcome reconciliation state", @runs.map(&:outcome_state), OUTCOME_STATES)
      counts("Outcome correlation state", @runs.map { |run| run.outcome&.dig("correlation", "state") || run.outcome_state },
        AgentRunOutcomes::Validator::CORRELATION_STATES + SIDECAR_STATES)
    end

    def applicable_outcomes
      states = @applicable.map(&:outcome_state).tally
      unavailable = states.fetch("unavailable", 0) + SIDECAR_STATES.sum { |state| states.fetch(state, 0) }
      "Applicable runs with unavailable, absent or invalid outcome evidence: #{unavailable}. Applicable runs with partial reconciliation: #{states.fetch("partial", 0)}."
    end

    def activity
      counts("UTC run start month", @runs.map { |run| month_of(run.started_at) })
      counts("Repository", @runs.map do |run|
        run.github_repository || "Local path digest #{run.repository.fetch("value")}"
      end)
      counts("Runtime client", @runs.map { |run| run.run.dig("runtime", "client", "id") })
      counts("Execution state", @runs.map { |run| run.run["state"] })
      rows = @usage.models.flat_map do |state, groups|
        groups.map { |(provider, model), (runs, measurements)| [provider, model, state, runs, measurements.length] }
      end
      table(["Provider", "Observed model", "Collection", "Runs", "Measurements"], rows)
    end

    def resources(usage, heading_level: 3)
      usage.by_collection.each do |state, (run_count, measurement_count, dimensions)|
        heading(heading_level, (state == "complete") ? "Complete recorded usage" : "Partial observed usage")
        bullets({
          "Runs with this collection state" => run_count,
          "Recorded measurements" => number(measurement_count),
          "Cache-read percentage (eligible token totals)" => cache_percentage(usage, usage.measurements(state))
        })
        table(["Token dimension", "Sum", "Contributing runs"], dimensions.map do |field, (sum, contributing)|
          [field, number(sum), "#{contributing}/#{run_count}"]
        end)
      end
    end

    def models
      heading(3, "Resource usage by observed provider and model")
      rows = @usage.models.flat_map do |state, groups|
        groups.map do |(provider, model), (_, measurements)|
          dimensions = @usage.token_dimensions(measurements).values.map do |sum, contributing|
            "#{number(sum)} (#{contributing}/#{measurements.length})"
          end
          [provider, model, state, measurements.length, *dimensions, cache_percentage(@usage, measurements)]
        end
      end
      table(["Provider", "Observed model", "Collection", "Measurements", *Usage::TOKEN_FIELDS, "Cache-read percentage"], rows)
    end

    def costs(usage, heading_level: 3)
      heading(heading_level, "Provider-reported monetary evidence")
      summaries = usage.cost_summaries
      counts("Cost summary state", summaries.map { |summary| summary["state"] }, %w[complete partial unavailable not_applicable])
      observed = summaries.sum { |summary| summary["measurement_count"] }
      priced = summaries.sum { |summary| summary["priced_measurement_count"] }
      paragraph("Measurements with observed cost: #{percentage(priced, observed)}. Runtime estimates describe provider-reported USD micros. Billing and subscription charges are outside the scope.")
      table(["Cost state", "Semantics", "Currency", "Observed USD micros", "Contributing runs", "Priced / recorded measurements in group"],
        usage.costs.map do |(state, semantics, currency), group|
          [state, semantics, currency, group.sum { |summary| summary["observed_usd_micros"] }, group.length,
            "#{group.sum { |summary| summary["priced_measurement_count"] }}/#{group.sum { |summary| summary["measurement_count"] }}"]
        end)
    end

    def pr_metrics(pulls)
      intervals = pulls.filter_map(&:merge_interval).sort
      merged = pulls.count { |pull| pull.lifecycle == "merged" }
      n = intervals.length
      median = (intervals[(n - 1) / 2] + intervals[n / 2]) / 2 if n.positive?
      bullets({
        "Distinct associated PRs" => pulls.length,
        "Runs with confirmed associations in this PR population" => pulls.flat_map(&:run_ids).uniq.length,
        "Confirmed run–PR relationships" => pulls.sum { |pull| pull.run_ids.length },
        "PRs with usable reviewed-revision evidence" => pulls.count { |pull| pull.review_count },
        "PRs with no qualifying submitted review in complete evidence" => pulls.count(&:no_reviews),
        "PRs with incomplete or unavailable review evidence" => pulls.count(&:review_incomplete),
        "Creation-to-merge eligible PRs" => "#{n}/#{merged} merged PRs",
        "Merged PRs excluded for missing or inconsistent timestamps" => merged - n,
        "Creation-to-merge calendar time, median" => interval(median),
        "Creation-to-merge calendar time, minimum" => interval(intervals.first),
        "Creation-to-merge calendar time, maximum" => interval(intervals.last)
      })
      counts("Observed PR lifecycle", pulls.map(&:lifecycle), LIFECYCLES)
      counts("Observed reviewed-revision count", pulls.filter_map(&:review_count))
      counts("Post-first-review change", pulls.map(&:post_review_change), AgentRunOutcomes::Validator::DERIVED_STATES)
    end

    def cohorts
      paragraph("Run cohorts follow UTC run start. PR cohorts follow UTC PR creation. Each PR reflects the latest reliable evidence in the supplied snapshot. The report timestamp describes cohort age and can precede evidence already present.")
      heading(3, "Run start cohorts")
      each_month(@runs.group_by { |run| month_of(run.started_at) }) do |month, runs|
        heading(4, month)
        if runs.empty?
          paragraph("Zero recorded activity.")
          next
        end

        bullets({
          "Recorded runs" => runs.length,
          "Complete usage coverage" => percentage(runs.count { |run| run.usage_state == "complete" }, runs.length)
        })
        usage = Usage.new(runs)
        resources(usage, heading_level: 5)
        costs(usage, heading_level: 5)
      end
      heading(3, "PR creation cohorts")
      each_month(@outcomes.pulls.group_by { |pull| month_of(pull.created_at) }) do |month, pulls|
        heading(4, month)
        paragraph("Cohort maturity: #{maturity(month)}.")
        if pulls.empty?
          paragraph("Zero recorded PR creations in this cohort.")
          next
        end
        pr_metrics(pulls)
      end
    end

    def each_month(cohorts)
      months = cohorts.keys.reject { |month| month == "Unknown cohort" }.sort
      paragraph("No dated cohorts in scope.") if months.empty?
      unless months.empty?
        cursor = Date.iso8601("#{months.first}-01")
        last = Date.iso8601("#{months.last}-01")
        while cursor <= last
          month = cursor.strftime("%Y-%m")
          yield month, cohorts.fetch(month, [])
          cursor = cursor.next_month
        end
      end
      yield "Unknown cohort", cohorts.fetch("Unknown cohort") if cohorts.key?("Unknown cohort")
    end

    def maturity(month)
      return "creation month unavailable" if month == "Unknown cohort"

      start = Date.iso8601("#{month}-01")
      report_date = @generated_at.to_date
      return "creation month is after the report timestamp" if report_date < start

      next_month = start.next_month
      return "creation month is still open as of the report timestamp" if report_date < next_month

      "#{(report_date - next_month).to_i} days since the creation month ended"
    end

    def month_of(time)
      time&.strftime("%Y-%m") || "Unknown cohort"
    end

    def limitations
      bullets({
        "Runs missing a usage sidecar" => @runs.count { |run| run.usage_state == "sidecar absent" },
        "Runs missing an outcome sidecar" => @runs.count { |run| run.outcome_state == "sidecar absent" },
        "Runs with partial observed usage" => @runs.count { |run| run.usage_state == "partial" },
        "Usage sidecars with measurements and incomplete or unavailable cost" => @usage.cost_summaries.count { |summary| %w[partial unavailable].include?(summary["state"]) },
        "PRs with conflicting observations" => @outcomes.pulls.count { |pull| pull.conflicts.any? },
        "Runs with unusable start timestamps" => @runs.count { |run| !run.started_at }
      })
      @corpus.diagnostics.sort.each do |reason, ids|
        paragraph("#{reason} (#{ids.length}): #{ids.join(", ")}")
      end
      @outcomes.diagnostics.uniq.sort.each { |diagnostic| paragraph(diagnostic) }
      @outcomes.pulls.each do |pull|
        if pull.conflicts.any?
          paragraph("#{pull.identity.join("#")} has conflicting observations for #{pull.conflicts.join(", ")}.")
        end
      end
      paragraph("Token sums use only records or measurements that establish the dimension. The contributing counts show missing numeric coverage. Inconsistent cache pairs are excluded from the cache percentage, while retained partial totals remain visible.")
      paragraph("Partial reconciliation can contain confirmed PRs and observed reviewed revisions. Observed revision counts and incomplete review evidence can overlap. Creation-to-merge intervals measure calendar time including waiting. PR states, reviews and execution states describe observations and cannot establish implementation acceptance, quality, productivity or model effectiveness.")
      paragraph("Recent PR cohorts have shorter follow-up and may still be immature. Task complexity, model selection, repository differences, workflow changes and evidence completeness can confound month-to-month comparisons. Zero recorded activity describes only this corpus. Later reconciliation can change the report for the same run and usage records.")
    end

    def cache_percentage(usage, measurements)
      read, total, contributing = usage.cache_reads(measurements)
      "#{percentage(read, total)} · #{contributing}/#{measurements.length} measurements"
    end

    def percentage(numerator, denominator)
      value = denominator.positive? ? format("%.2f%%", Rational(numerator * 100, denominator)) : UNKNOWN
      "#{numerator}/#{denominator} (#{value})"
    end

    def interval(seconds)
      return UNKNOWN unless seconds

      days, remainder = seconds.divmod(86_400)
      hours, remainder = remainder.divmod(3600)
      minutes, remainder = remainder.divmod(60)
      format("%dd %02dh %02dm %07.4fs", days, hours, minutes, remainder)
    end

    def number(value)
      value.nil? ? UNKNOWN : value
    end

    def counts(label, values, categories = nil)
      counts = values.tally
      table([label, "Count"], (categories || counts.keys.sort).map { |key| [key, counts.fetch(key, 0)] })
    end

    def heading(level, title)
      @lines.push("#{"#" * level} #{title}", "")
    end

    def paragraph(value)
      @lines.push(value, "")
    end

    def bullets(items)
      items.each { |label, value| @lines << "- #{label}: #{escape(value)}" }
      @lines << ""
    end

    def table(headers, rows)
      if rows.empty?
        paragraph("No observations.")
        return
      end
      @lines.push(table_row(headers), table_row(headers.map { "---" }))
      rows.each { |row| @lines << table_row(row) }
      @lines << ""
    end

    def table_row(values)
      "| #{values.map { |value| escape(value) }.join(" | ")} |"
    end

    def escape(value)
      value.to_s.gsub(/[[:cntrl:]]/) { |character| format("\\u%04x", character.ord) }
        .gsub(/[&<>|\\`*\[\]!~]/) { |character| "&##{character.ord};" }
    end
  end
end
