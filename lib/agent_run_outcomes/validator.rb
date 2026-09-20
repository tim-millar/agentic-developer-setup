# frozen_string_literal: true

require "json"

module AgentRunOutcomes
  class Validator
    RUN_ID = /\Arun-\d{8}T\d{6}Z-[0-9a-f]{32}\z/
    TIMESTAMP = /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z\z/
    SHA = /\A[0-9a-f]{40,64}\z/
    REPOSITORY = /\A[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}\z/
    OBSERVATION_STATES = %w[complete partial unavailable not_applicable].freeze
    AUTOMATIC_STATES = %w[active quiescent dormant].freeze
    CORRELATION_STATES = %w[matched unmatched ambiguous unavailable not_applicable].freeze
    ASSOCIATION_KINDS = %w[finish_head_equals_pr_head finish_head_in_pr_commits unique_head_branch].freeze
    SUPPORTING_KINDS = (ASSOCIATION_KINDS + %w[task_issue_link temporal_compatibility]).freeze
    LIFECYCLES = %w[open merged closed_unmerged unavailable].freeze
    EVENT_KINDS = %w[ready_for_review converted_to_draft review_requested review_request_removed review_dismissed head_ref_force_pushed head_ref_deleted head_ref_restored base_ref_changed closed reopened merged cross_referenced].freeze
    ROLLUPS = %w[unobserved pending passing failing incomplete].freeze
    DERIVED_STATES = %w[yes no unavailable not_applicable].freeze
    ERROR_CATEGORIES = %w[authentication authorization network api rate_limit local_io invalid_source_record parse timeout].freeze

    attr_reader :errors

    def initialize(record)
      @record = record
      @errors = []
    end

    def validate
      return error("record", "must be a JSON object") unless @record.is_a?(Hash)

      exact_keys(@record, "record", %w[schema_version run_id source_run_schema_version reconciliation correlation pull_requests])
      equal(@record["schema_version"], 1, "schema_version")
      pattern(@record["run_id"], RUN_ID, "run_id")
      equal(@record["source_run_schema_version"], 1, "source_run_schema_version")
      reconciliation(@record["reconciliation"])
      correlation(@record["correlation"])
      array(@record["pull_requests"], "pull_requests") { |item, index| pull_request(item, "pull_requests[#{index}]") }
      error("pull_requests", "contains duplicate identities") if duplicate?(@record["pull_requests"]) { |item| [item.dig("identity", "repository")&.downcase, item.dig("identity", "number")] }
      errors.empty?
    end

    private

    def reconciliation(value)
      return error("reconciliation", "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, "reconciliation", %w[last_attempted_at last_successful_at attempt_count observation_state automatic_state next_eligible_at last_error])
      timestamp(value["last_attempted_at"], "reconciliation.last_attempted_at")
      nullable_timestamp(value["last_successful_at"], "reconciliation.last_successful_at")
      nonnegative_integer(value["attempt_count"], "reconciliation.attempt_count", positive: true)
      enum(value["observation_state"], OBSERVATION_STATES, "reconciliation.observation_state")
      enum(value["automatic_state"], AUTOMATIC_STATES, "reconciliation.automatic_state")
      nullable_timestamp(value["next_eligible_at"], "reconciliation.next_eligible_at")
      last_error(value["last_error"])
      error("reconciliation.next_eligible_at", "must be present only for active records") if (value["automatic_state"] == "active") != !value["next_eligible_at"].nil?
    end

    def last_error(value)
      return if value.nil?
      return error("reconciliation.last_error", "must be null or an object") unless value.is_a?(Hash)
      allowed_keys(value, "reconciliation.last_error", %w[category http_status], required: %w[category])
      enum(value["category"], ERROR_CATEGORIES, "reconciliation.last_error.category")
      nonnegative_integer(value["http_status"], "reconciliation.last_error.http_status") if value.key?("http_status")
    end

    def correlation(value)
      return error("correlation", "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, "correlation", %w[state associations candidates])
      enum(value["state"], CORRELATION_STATES, "correlation.state")
      array(value["associations"], "correlation.associations") { |item, index| association(item, "correlation.associations[#{index}]") }
      array(value["candidates"], "correlation.candidates") { |item, index| candidate(item, "correlation.candidates[#{index}]") }
      if value["state"] == "matched" && Array(value["associations"]).empty?
        error("correlation.associations", "matched correlation requires an association")
      elsif value["state"] != "matched" && Array(value["associations"]).any?
        error("correlation.state", "preserved associations require matched state")
      end
    end

    def association(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[repository number first_observed_at last_observed_at established_by supporting_evidence])
      repository(value["repository"], "#{location}.repository")
      nonnegative_integer(value["number"], "#{location}.number", positive: true)
      timestamp(value["first_observed_at"], "#{location}.first_observed_at")
      timestamp(value["last_observed_at"], "#{location}.last_observed_at")
      array(value["established_by"], "#{location}.established_by") { |item, index| enum(item, ASSOCIATION_KINDS, "#{location}.established_by[#{index}]") }
      error("#{location}.established_by", "must not be empty") if Array(value["established_by"]).empty?
      array(value["supporting_evidence"], "#{location}.supporting_evidence") do |item, index|
        evidence(item, "#{location}.supporting_evidence[#{index}]")
      end
    end

    def candidate(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[repository number evidence])
      repository(value["repository"], "#{location}.repository")
      nonnegative_integer(value["number"], "#{location}.number", positive: true)
      array(value["evidence"], "#{location}.evidence") { |item, index| enum(item, SUPPORTING_KINDS, "#{location}.evidence[#{index}]") }
    end

    def evidence(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      allowed_keys(value, location, %w[kind commit_sha branch issue], required: %w[kind commit_sha branch])
      enum(value["kind"], SUPPORTING_KINDS, "#{location}.kind")
      nullable_pattern(value["commit_sha"], SHA, "#{location}.commit_sha")
      nullable_string(value["branch"], "#{location}.branch")
      nullable_string(value["issue"], "#{location}.issue") if value.key?("issue")
    end

    def pull_request(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[identity association current head_history commits timeline_events reviews checks_by_sha derived])
      identity(value["identity"], "#{location}.identity")
      association(value["association"], "#{location}.association")
      current(value["current"], "#{location}.current")
      history_array(value["head_history"], "#{location}.head_history", %w[sha observed_at source_kind first_observed_at last_observed_at], sha_keys: %w[sha])
      history_array(value["commits"], "#{location}.commits", %w[sha source_kind first_observed_at last_observed_at], sha_keys: %w[sha])
      history_array(value["timeline_events"], "#{location}.timeline_events", %w[source_id kind timestamp actor_login actor_type before_sha after_sha before_ref after_ref source_kind first_observed_at last_observed_at], sha_keys: %w[before_sha after_sha])
      history_array(value["reviews"], "#{location}.reviews", %w[source_id reviewer_login reviewer_type state commit_id submitted_at dismissed_at source_kind first_observed_at last_observed_at], sha_keys: %w[commit_id])
      array(value["checks_by_sha"], "#{location}.checks_by_sha") { |item, index| check_group(item, "#{location}.checks_by_sha[#{index}]") }
      derived(value["derived"], "#{location}.derived")
      validate_history_semantics(value, location)
      if value["identity"].is_a?(Hash) && value["association"].is_a?(Hash) && value["identity"].values_at("repository", "number") != value["association"].values_at("repository", "number")
        error(location, "identity and association must name the same pull request")
      end
    end

    def identity(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[repository number node_id])
      repository(value["repository"], "#{location}.repository")
      nonnegative_integer(value["number"], "#{location}.number", positive: true)
      nullable_string(value["node_id"], "#{location}.node_id")
    end

    def current(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      keys = %w[lifecycle draft head_repository head_ref head_sha base_repository base_ref base_sha created_at updated_at closed_at merged_at merge_commit_sha observed_at]
      exact_keys(value, location, keys)
      enum(value["lifecycle"], LIFECYCLES, "#{location}.lifecycle")
      error("#{location}.draft", "must be boolean or null") unless value["draft"].nil? || value["draft"] == true || value["draft"] == false
      %w[head_repository base_repository].each { |key| nullable_repository(value[key], "#{location}.#{key}") }
      %w[head_ref base_ref].each { |key| nullable_string(value[key], "#{location}.#{key}") }
      %w[head_sha base_sha merge_commit_sha].each { |key| nullable_pattern(value[key], SHA, "#{location}.#{key}") }
      %w[created_at updated_at closed_at merged_at].each { |key| nullable_timestamp(value[key], "#{location}.#{key}") }
      timestamp(value["observed_at"], "#{location}.observed_at")
    end

    def history_array(value, location, keys, sha_keys: [])
      array(value, location) do |item, index|
        item_location = "#{location}[#{index}]"
        if item.is_a?(Hash)
          exact_keys(item, item_location, keys)
          sha_keys.each { |key| nullable_pattern(item[key], SHA, "#{item_location}.#{key}") }
          timestamp(item["first_observed_at"], "#{item_location}.first_observed_at")
          timestamp(item["last_observed_at"], "#{item_location}.last_observed_at")
        else
          error(item_location, "must be a JSON object")
        end
      end
    end

    def validate_history_semantics(value, location)
      Array(value["head_history"]).each_with_index do |item, index|
        next unless item.is_a?(Hash)
        timestamp(item["observed_at"], "#{location}.head_history[#{index}].observed_at")
        equal(item["source_kind"], "github_pull_snapshot", "#{location}.head_history[#{index}].source_kind")
      end
      Array(value["commits"]).each_with_index do |item, index|
        equal(item["source_kind"], "github_pull_commit", "#{location}.commits[#{index}].source_kind") if item.is_a?(Hash)
      end
      Array(value["timeline_events"]).each_with_index do |item, index|
        next unless item.is_a?(Hash)
        enum(item["kind"], EVENT_KINDS, "#{location}.timeline_events[#{index}].kind")
        timestamp(item["timestamp"], "#{location}.timeline_events[#{index}].timestamp")
        equal(item["source_kind"], "github_timeline_event", "#{location}.timeline_events[#{index}].source_kind")
      end
      reviews = Array(value["reviews"])
      reviews.each_with_index do |item, index|
        next unless item.is_a?(Hash)
        timestamp(item["submitted_at"], "#{location}.reviews[#{index}].submitted_at")
        nullable_timestamp(item["dismissed_at"], "#{location}.reviews[#{index}].dismissed_at")
        equal(item["source_kind"], "github_pull_review", "#{location}.reviews[#{index}].source_kind")
      end
      validate_review_derivations(value["derived"], reviews, location)
    end

    def validate_review_derivations(derived, reviews, location)
      return unless derived.is_a?(Hash)
      reliable = reviews.filter_map { |review| review["commit_id"] if review.is_a?(Hash) }.uniq
      error("#{location}.derived.reviewed_revision_count", "does not match distinct reviewed commit IDs") unless derived["reviewed_revision_count"] == reliable.length
      earliest = reviews.select { |review| review.is_a?(Hash) && review["submitted_at"].is_a?(String) }.min_by { |review| review["submitted_at"] }
      expected_state, expected_sha = if earliest.nil?
        ["not_applicable", nil]
      elsif earliest["commit_id"]
        ["available", earliest["commit_id"]]
      else
        ["unavailable", nil]
      end
      first = derived["first_reviewed_revision"]
      if first.is_a?(Hash) && first.values_at("state", "sha") != [expected_state, expected_sha]
        error("#{location}.derived.first_reviewed_revision", "does not match the earliest submitted review")
      end
    end

    def check_group(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[sha check_runs statuses evidence observed_check_rollup])
      pattern(value["sha"], SHA, "#{location}.sha")
      history_array(value["check_runs"], "#{location}.check_runs", %w[source_id name app_id app_slug head_sha status conclusion started_at completed_at source_kind first_observed_at last_observed_at], sha_keys: %w[head_sha])
      history_array(value["statuses"], "#{location}.statuses", %w[source_id context sha state created_at updated_at creator_login creator_type source_kind first_observed_at last_observed_at], sha_keys: %w[sha])
      Array(value["check_runs"]).each_with_index do |item, index|
        next unless item.is_a?(Hash)
        error("#{location}.check_runs[#{index}].head_sha", "must match its evidence group SHA") unless item["head_sha"] == value["sha"]
        equal(item["source_kind"], "github_check_run", "#{location}.check_runs[#{index}].source_kind")
        nullable_timestamp(item["started_at"], "#{location}.check_runs[#{index}].started_at")
        nullable_timestamp(item["completed_at"], "#{location}.check_runs[#{index}].completed_at")
      end
      Array(value["statuses"]).each_with_index do |item, index|
        next unless item.is_a?(Hash)
        error("#{location}.statuses[#{index}].sha", "must match its evidence group SHA") unless item["sha"] == value["sha"]
        equal(item["source_kind"], "github_commit_status", "#{location}.statuses[#{index}].source_kind")
        nullable_timestamp(item["created_at"], "#{location}.statuses[#{index}].created_at")
        nullable_timestamp(item["updated_at"], "#{location}.statuses[#{index}].updated_at")
      end
      evidence = value["evidence"]
      if evidence.is_a?(Hash)
        exact_keys(evidence, "#{location}.evidence", %w[checks statuses])
        evidence.each { |key, item| enum(item, %w[complete unavailable], "#{location}.evidence.#{key}") }
      else
        error("#{location}.evidence", "must be a JSON object")
      end
      enum(value["observed_check_rollup"], ROLLUPS, "#{location}.observed_check_rollup")
    end

    def derived(value, location)
      return error(location, "must be a JSON object") unless value.is_a?(Hash)
      exact_keys(value, location, %w[reviewed_revision_count first_reviewed_revision post_first_review_change_observed merged_on_first_reviewed_revision])
      nonnegative_integer(value["reviewed_revision_count"], "#{location}.reviewed_revision_count")
      first = value["first_reviewed_revision"]
      if first.is_a?(Hash)
        exact_keys(first, "#{location}.first_reviewed_revision", %w[state sha])
        enum(first["state"], %w[available unavailable not_applicable], "#{location}.first_reviewed_revision.state")
        nullable_pattern(first["sha"], SHA, "#{location}.first_reviewed_revision.sha")
        if first["state"] == "available"
          error("#{location}.first_reviewed_revision.sha", "is required when available") unless first["sha"].is_a?(String)
        elsif first["sha"]
          error("#{location}.first_reviewed_revision.sha", "must be null unless available")
        end
      else
        error("#{location}.first_reviewed_revision", "must be a JSON object")
      end
      enum(value["post_first_review_change_observed"], DERIVED_STATES, "#{location}.post_first_review_change_observed")
      enum(value["merged_on_first_reviewed_revision"], DERIVED_STATES, "#{location}.merged_on_first_reviewed_revision")
    end

    def exact_keys(value, location, keys)
      allowed_keys(value, location, keys, required: keys)
    end

    def allowed_keys(value, location, keys, required:)
      (required - value.keys).each { |key| error("#{location}.#{key}", "is required") }
      (value.keys - keys).each { |key| error("#{location}.#{key}", "is not a v1 field") }
    end

    def array(value, location)
      return error(location, "must be an array") unless value.is_a?(Array)
      value.each_with_index { |item, index| yield item, index }
    end

    def enum(value, values, location)
      error(location, "must be one of: #{values.join(", ")}") unless values.include?(value)
    end

    def equal(value, expected, location)
      error(location, "must equal #{expected.inspect}") unless value == expected
    end

    def pattern(value, regex, location)
      error(location, "has an invalid format") unless value.is_a?(String) && value.match?(regex)
    end

    def nullable_pattern(value, regex, location)
      pattern(value, regex, location) unless value.nil?
    end

    def timestamp(value, location)
      pattern(value, TIMESTAMP, location)
    end

    def nullable_timestamp(value, location)
      timestamp(value, location) unless value.nil?
    end

    def repository(value, location)
      pattern(value, REPOSITORY, location)
    end

    def nullable_repository(value, location)
      repository(value, location) unless value.nil?
    end

    def nullable_string(value, location)
      error(location, "must be a string or null") unless value.nil? || value.is_a?(String)
    end

    def nonnegative_integer(value, location, positive: false)
      valid = value.is_a?(Integer) && value >= (positive ? 1 : 0)
      error(location, "must be #{positive ? "a positive" : "a non-negative"} integer") unless valid
    end

    def duplicate?(items)
      return false unless items.is_a?(Array)
      identities = items.map { |item| yield(item) }
      identities.uniq.length != identities.length
    end

    def error(location, message)
      errors << "#{location}: #{message}"
      false
    end
  end
end
