# frozen_string_literal: true

module AgenticDeveloperSetup
  module FrameworkCatalogue
    BASELINE_ENTRY_FIELDS = %w[name category source_path target_path description].freeze
    COMPONENT_ID_PATTERN = /\A[a-z][a-z0-9_]*\z/

    module_function

    def document_errors(root, document)
      require_relative "../../scripts/validate_framework" unless defined?(::FrameworkValidator)

      validator = ::FrameworkValidator.new(root)
      validator.validate_catalogue_document(document)
      validator.errors
    rescue => e
      ["ERROR: framework.yml: catalogue validation failed: #{e.message.lines.first.strip}"]
    end

    def baseline_entry_shape_valid?(entry)
      return false unless entry.is_a?(Hash)
      return false unless entry.keys.all? { |key| key.is_a?(String) && BASELINE_ENTRY_FIELDS.include?(key) }

      BASELINE_ENTRY_FIELDS.all? do |field|
        entry[field].is_a?(String) && !entry[field].empty?
      end
    end
  end
end
