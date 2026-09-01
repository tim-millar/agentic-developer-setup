# frozen_string_literal: true

require "pathname"
require "yaml"

module AgenticDeveloperSetup
  module Assessment
    class Catalogue
      def initialize(root)
        @root = Pathname.new(root).expand_path
        @path = @root.join("framework.yml")
        @data = YAML.safe_load(
          @path.read,
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false,
          filename: @path.to_s
        )
        validate_shape
      rescue Psych::Exception, SystemCallError => e
        raise SchemaError, "framework metadata could not be loaded: #{e.message.lines.first.strip}"
      end

      attr_reader :data

      def metadata_schema_version
        data.fetch("schema_version")
      end

      def framework_version
        data.dig("framework", "framework_version")
      end

      def components
        @components ||= data.fetch("baseline").values_at("required", "recommended").flatten.sort_by { |item| item.fetch("name") }
      end

      def tiers
        data.fetch("adoption_tiers").sort_by { |tier| tier.fetch("id") }
      end

      def source_revision
        GitInspector.new(@root).source_revision
      end

      def source_root
        @root
      end

      private

      def validate_shape
        unless data.is_a?(Hash) && data["schema_version"] == 2 && data["framework"].is_a?(Hash) && data.dig("framework", "framework_version")
          raise SchemaError, "framework metadata must be schema version 2 with a framework version"
        end
        unless data.dig("baseline", "required").is_a?(Array) && data.dig("baseline", "recommended").is_a?(Array)
          raise SchemaError, "framework metadata baseline catalogue is malformed"
        end
      end
    end
  end
end
