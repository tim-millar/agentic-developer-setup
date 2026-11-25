# frozen_string_literal: true

require_relative "corpus"

module AgentRunReporting
  class PullRequests
    CURRENT_FIELDS = %w[lifecycle created_at merged_at].freeze
    Observation = Data.define(:run_id, :pull, :reconciliation)
    Pull = Data.define(:identity, :run_ids, :lifecycle, :created_at, :merged_at, :review_count, :no_reviews, :review_incomplete, :post_review_change, :conflicts) do
      def merge_interval
        return unless lifecycle == "merged" && created_at && merged_at && merged_at >= created_at

        merged_at.to_r - created_at.to_r
      end
    end

    attr_reader :pulls, :diagnostics, :latest_observation

    def initialize(runs)
      @diagnostics = []
      @latest_observation = runs.filter_map do |run|
        AgentRunReporting.utc_timestamp(run.outcome&.dig("reconciliation", "last_successful_at")) if %w[complete partial].include?(run.outcome_state)
      end.max
      observations = Hash.new { |hash, identity| hash[identity] = [] }
      runs.each { |run| collect(run, observations) }
      @pulls = observations.sort.map { |identity, snapshots| summarize(identity, snapshots) }
    end

    private

    def collect(run, observations)
      return unless run.github_repository && run.outcome&.dig("correlation", "state") == "matched"

      pulls = run.outcome.fetch("pull_requests").to_h { |pull| [identity(pull.fetch("identity")), pull] }
      run.outcome.dig("correlation", "associations").map { |association| identity(association) }.uniq.each do |key|
        if key.first != run.github_repository
          diagnostics << "#{key.join("#")} · confirmed association is outside the run repository"
          next
        end

        observations[key] << Observation.new(run.run.fetch("run_id"), pulls[key], run.outcome.fetch("reconciliation"))
      end
    end

    def identity(record)
      [record.fetch("repository").downcase, record.fetch("number")]
    end

    def summarize(identity, associations)
      run_ids = associations.map(&:run_id)
      observations = associations.select(&:pull)
      conflicts = []
      current = latest(observations.map { |item| item.pull.fetch("current") }) do |snapshot|
        next if empty_current_snapshot?(snapshot)

        AgentRunReporting.utc_timestamp(snapshot.fetch("observed_at"))
      end
      lifecycle, created_at, merged_at = CURRENT_FIELDS.map do |field|
        values = current.map do |snapshot|
          (field == "lifecycle") ? snapshot[field] : AgentRunReporting.utc_timestamp(snapshot[field])
        end
        consensus(values, field, conflicts)
      end
      lifecycle = "unavailable/conflicting" if lifecycle.nil? || lifecycle == "unavailable"

      review_observations = latest(observations) do |item|
        AgentRunReporting.utc_timestamp(item.reconciliation["last_successful_at"]) ||
          AgentRunReporting.utc_timestamp(item.pull.dig("current", "observed_at"))
      end
      count = consensus(review_observations.map { |item| item.pull.dig("derived", "reviewed_revision_count") }, "reviewed_revision_count", conflicts)
      complete_reviews = !count.nil? && review_observations.all? do |item|
        item.reconciliation["observation_state"] == "complete" && item.pull.fetch("reviews").all? { |review| review["commit_id"] }
      end
      no_reviews = complete_reviews && count.zero?
      observed_count = count if no_reviews || count&.positive?
      post_change = consensus(review_observations.map { |item| item.pull.dig("derived", "post_first_review_change_observed") }, "post_first_review_change_observed", conflicts)

      Pull.new(identity, run_ids, lifecycle, created_at, merged_at,
        observed_count, no_reviews, !complete_reviews, post_change || "unavailable", conflicts)
    end

    def empty_current_snapshot?(snapshot)
      snapshot["lifecycle"] == "unavailable" && snapshot.except("lifecycle", "observed_at").values.all?(&:nil?)
    end

    def latest(items)
      by_time = items.group_by { |item| yield item }
      time = by_time.keys.compact.max
      time ? by_time.fetch(time) : []
    end

    def consensus(values, field, conflicts)
      distinct = values.uniq
      return distinct.first if distinct.length <= 1

      conflicts << field
      nil
    end
  end
end
