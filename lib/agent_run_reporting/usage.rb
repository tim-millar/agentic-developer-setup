# frozen_string_literal: true

require_relative "corpus"

module AgentRunReporting
  class Usage
    TOKEN_FIELDS = AgentRunUsage::Validator::TOKEN_FIELDS
    COLLECTED_STATES = %w[complete partial].freeze

    attr_reader :records

    def initialize(runs)
      @records = runs.filter_map(&:usage)
    end

    def by_collection
      COLLECTED_STATES.to_h do |state|
        totals = records.select { |record| record.dig("collection", "state") == state }
          .map { |record| record.fetch("observed_totals") }
        dimensions = TOKEN_FIELDS.to_h do |field|
          values = totals.filter_map { |record| record[field] }
          [field, [sum_if_known(values), values.length]]
        end
        [state, [totals.length, sum_if_known(totals.map { |record| record.fetch("measurement_count") }), dimensions]]
      end
    end

    def models
      @models ||= COLLECTED_STATES.to_h do |state|
        runs_by_model = Hash.new(0)
        measurements_by_model = Hash.new { |hash, key| hash[key] = [] }
        records.each do |record|
          next unless record.dig("collection", "state") == state

          record.fetch("measurements").group_by { |item| item.values_at("provider", "model") }.each do |identity, measurements|
            runs_by_model[identity] += 1
            measurements_by_model[identity].concat(measurements)
          end
        end
        groups = measurements_by_model.sort.to_h do |identity, measurements|
          [identity, [runs_by_model.fetch(identity), measurements]]
        end
        [state, groups]
      end
    end

    def token_dimensions(measurements)
      TOKEN_FIELDS.to_h do |field|
        values = measurements.filter_map { |measurement| measurement.dig("tokens", field) }
        [field, [sum_if_known(values), values.length]]
      end
    end

    def cache_reads(measurements)
      pairs = measurements.filter_map do |measurement|
        read, total = measurement.fetch("tokens").values_at("input_cache_read", "input_total")
        [read, total] if read && total&.positive? && read <= total
      end
      [pairs.sum(&:first), pairs.sum(&:last), pairs.length]
    end

    def measurements(state)
      records.select { |record| record.dig("collection", "state") == state }
        .flat_map { |record| record.fetch("measurements") }
    end

    def cost_summaries
      records.map { |record| record.fetch("cost_summary") }
    end

    def costs
      cost_summaries.reject { |summary| summary["observed_usd_micros"].nil? }
        .group_by { |summary| summary.values_at("state", "semantics", "currency") }.sort.to_h
    end

    private

    def sum_if_known(values)
      values.sum unless values.empty?
    end
  end
end
