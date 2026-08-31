# frozen_string_literal: true

require "yaml"

module AgenticDeveloperSetup
  module Assessment
    class Context
      TOP_LEVEL = %w[schema_version repository sensitive_paths approved_agent_runtimes review_requirements known_setup_constraints notes].freeze
      REPOSITORY_FIELDS = %w[criticality deployment_impact].freeze

      attr_reader :values, :path, :evidence_keys

      def self.load(path, evidence)
        return new({}, nil, []) unless path

        file = File.expand_path(path)
        raise InvocationError, "assessor context does not exist: #{path}" unless File.file?(file)

        raw = YAML.safe_load(
          File.read(file),
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false,
          filename: file
        )
        validate(raw, path)
        evidence_keys = []
        raw.each do |field, value|
          next if field == "schema_version"

          if field == "repository"
            value.each_key do |repository_field|
              evidence_keys << evidence.add(type: "assessor_context", path: path.to_s, method: "context_#{repository_field}", summary: "Assessor context supplies #{repository_field}")
            end
          elsif value.is_a?(Array)
            value.each_with_index do |_entry, index|
              evidence_keys << evidence.add(type: "assessor_context", path: path.to_s, method: "context_#{field}", summary: "Assessor context supplies #{field} entry #{index + 1}")
            end
          end
        end
        new(raw, path.to_s, evidence_keys)
      rescue Psych::Exception => e
        raise InvocationError, "assessor context could not be parsed: #{e.message.lines.first.strip}"
      rescue SystemCallError => e
        raise InvocationError, "assessor context could not be read: #{e.message}"
      end

      def self.validate(value, path)
        unless value.is_a?(Hash)
          raise InvocationError, "assessor context must be a YAML mapping: #{path}"
        end
        unknown = value.keys.map(&:to_s) - TOP_LEVEL
        raise InvocationError, "assessor context has unknown fields: #{unknown.sort.join(', ')}" unless unknown.empty?
        unless value["schema_version"] == 1
          raise InvocationError, "assessor context schema_version must be 1"
        end
        if value.key?("repository")
          repository = value["repository"]
          unless repository.is_a?(Hash) && (repository.keys.map(&:to_s) - REPOSITORY_FIELDS).empty?
            raise InvocationError, "assessor context repository must contain only criticality and deployment_impact"
          end
          repository.each { |field, item| string_field(item, "repository.#{field}") }
        end
        %w[sensitive_paths approved_agent_runtimes review_requirements known_setup_constraints notes].each do |field|
          next unless value.key?(field)

          entries = value[field]
          unless entries.is_a?(Array) && entries.all? { |entry| entry.is_a?(String) }
            raise InvocationError, "assessor context #{field} must be an array of strings"
          end
        end
      end

      def initialize(values, path, evidence_keys)
        @values = values
        @path = path
        @evidence_keys = evidence_keys
      end

      def provided?
        !@path.nil?
      end

      def [](key)
        @values[key]
      end

      private

      def self.string_field(value, field)
        raise InvocationError, "assessor context #{field} must be a string" unless value.is_a?(String)
      end
    end
  end
end
