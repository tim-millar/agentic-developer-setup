# frozen_string_literal: true

module AgenticDeveloperSetup
  module FrameworkCatalogue
    BASELINE_ENTRY_FIELDS = %w[name category source_path target_path description].freeze
    COMPONENT_ID_PATTERN = /\A[a-z][a-z0-9_]*\z/

    module_function

    def baseline_entry_shape_valid?(entry)
      return false unless entry.is_a?(Hash)
      return false unless entry.keys.all? { |key| key.is_a?(String) && BASELINE_ENTRY_FIELDS.include?(key) }

      BASELINE_ENTRY_FIELDS.all? do |field|
        entry[field].is_a?(String) && !entry[field].empty?
      end
    end
  end
end
