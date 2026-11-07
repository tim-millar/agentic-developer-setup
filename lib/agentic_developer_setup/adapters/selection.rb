# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    module InputValues
      module_function

      def validate_value!(definition, value)
        valid = case definition.fetch("type")
        when "string", "relative_path" then value.is_a?(String) && !value.empty? && !value.include?("\0")
        when "boolean" then value == true || value == false
        when "integer" then value.is_a?(Integer)
        end
        raise Error, "malformed input value: #{definition["key"]}" unless valid
        Contracts.relative!(value) if definition["type"] == "relative_path"
        if definition["allowed_values"] && !definition["allowed_values"].include?(value)
          raise Error, "input value is not allowed: #{definition["key"]}"
        end
        value
      end

      def validate_declaration!(definition)
        definition["allowed_values"]&.each { |value| validate_value!(definition, value) }
        validate_value!(definition, definition["default"]) if definition.key?("default")
      end
    end

    class Selection
      attr_reader :document, :definitions, :inputs

      def initialize(document, registry:, root: nil)
        @document = Contracts.copy(document)
        Contracts.validate!("selection", @document)
        Contracts.scope!(@document["scope"], root: root)
        selected = @document["selected"]
        categories = selected.map { |item| item["category"] }
        raise Error, "multiple selections in one category" unless categories == categories.uniq
        raise Error, "selected adapter set requires exactly one ecosystem" unless categories.include?("ecosystem")
        @definitions = selected.map do |item|
          entry = registry.fetch(category: item["category"], id: item["id"])
          raise Error, "unknown adapter: #{item["category"]}/#{item["id"]}" unless entry
          raise Error, "unsupported adapter: #{item["id"]} (#{entry.status})" unless entry.status == "supported"
          entry
        end.sort_by { |entry| [entry.category, entry.id] }.freeze
        @inputs = @document["inputs"].to_h { |item| [item["key"], item["value"]] }
        raise Error, "duplicate explicit input" unless @inputs.length == @document["inputs"].length
        ids = @document["resolutions"].map { |item| item["conflict_id"] }
        raise Error, "duplicate conflict resolution" unless ids.uniq == ids
        Contracts.freeze_tree(@document)
        Contracts.freeze_tree(@inputs)
      end

      def scope
        document.fetch("scope")
      end

      def validate_candidates!(candidates)
        document["selected"].each do |item|
          next unless item["source"] == "accepted_detection"
          unless candidates.any? { |candidate| candidate.values_at("category", "id", "scope") == [item["category"], item["id"], scope] }
            raise Error, "accepted_detection requires a current matching candidate: #{item["id"]}"
          end
        end
      end
    end
  end
end
