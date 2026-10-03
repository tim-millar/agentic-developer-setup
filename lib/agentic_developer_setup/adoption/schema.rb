# frozen_string_literal: true

require "json"

module AgenticDeveloperSetup
  module Adoption
    class Schema
      attr_reader :errors

      def initialize(schema)
        @schema = schema
        @errors = []
      end

      def self.load(path)
        new(JSON.parse(File.binread(path)))
      rescue JSON::ParserError, Errno::ENOENT, Errno::EACCES => e
        raise Assessment::SchemaError, "adoption schema could not be loaded: #{e.message.lines.first.strip}"
      end

      def validate(value)
        @errors = []
        validate_value(value, @schema, "$")
        @errors
      rescue RegexpError => e
        ["$: schema contains an invalid regular expression: #{e.message}"]
      end

      private

      def validate_value(value, schema, location)
        schema = resolve(schema)
        unless schema.is_a?(Hash)
          @errors << "#{location}: schema reference is invalid"
          return
        end

        schema["allOf"]&.each { |item| validate_value(value, item, location) }
        if schema["anyOf"]&.none? { |item| valid_against?(value, item) }
          @errors << "#{location}: must match at least one allowed structure"
        end
        if schema["oneOf"]
          matches = schema["oneOf"].count { |item| valid_against?(value, item) }
          @errors << "#{location}: must match exactly one allowed structure" unless matches == 1
        end
        if schema["not"] && valid_against?(value, schema["not"])
          @errors << "#{location}: must not match the forbidden structure"
        end

        types = Array(schema["type"])
        if types.any? && types.none? { |type| type_matches?(value, type) }
          @errors << "#{location}: has the wrong JSON type"
          return
        end
        @errors << "#{location}: must equal #{schema["const"].inspect}" if schema.key?("const") && value != schema["const"]
        @errors << "#{location}: is not an allowed value" if schema["enum"] && !schema["enum"].include?(value)

        case value
        when String
          @errors << "#{location}: is too short" if schema["minLength"] && value.length < schema["minLength"]
          @errors << "#{location}: has an invalid format" if schema["pattern"] && !Regexp.new(schema["pattern"]).match?(value)
        when Array
          @errors << "#{location}: has too few items" if schema["minItems"] && value.length < schema["minItems"]
          @errors << "#{location}: must contain unique items" if schema["uniqueItems"] && value.uniq.length != value.length
          value.each_with_index { |item, index| validate_value(item, schema["items"], "#{location}[#{index}]") } if schema["items"]
        when Hash
          Array(schema["required"]).each { |key| @errors << "#{location}.#{key}: is required" unless value.key?(key) }
          @errors << "#{location}: has too few properties" if schema["minProperties"] && value.length < schema["minProperties"]
          properties = schema.fetch("properties", {})
          if schema["additionalProperties"] == false
            (value.keys - properties.keys).sort.each { |key| @errors << "#{location}.#{key}: is not allowed" }
          end
          value.each { |key, item| validate_value(item, properties[key], "#{location}.#{key}") if properties[key] }
        end
      end

      def valid_against?(value, schema)
        saved = @errors
        @errors = []
        validate_value(value, schema, "$internal")
        @errors.empty?
      ensure
        @errors = saved
      end

      def resolve(schema)
        return schema unless schema.is_a?(Hash) && schema["$ref"]

        reference = schema["$ref"]
        return unless reference.start_with?("#/")

        reference.delete_prefix("#/").split("/").reduce(@schema) do |node, component|
          node&.fetch(component.gsub("~1", "/").gsub("~0", "~"), nil)
        end
      end

      def type_matches?(value, type)
        case type
        when "object" then value.is_a?(Hash)
        when "array" then value.is_a?(Array)
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer) && !value.is_a?(TrueClass) && !value.is_a?(FalseClass)
        when "number" then value.is_a?(Numeric)
        when "boolean" then value == true || value == false
        when "null" then value.nil?
        else false
        end
      end
    end
  end
end
