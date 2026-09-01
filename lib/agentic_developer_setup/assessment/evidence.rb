# frozen_string_literal: true

require "digest"

module AgenticDeveloperSetup
  module Assessment
    class Evidence
      TYPES = %w[
        assessor_context
        ci_invocation
        configuration
        directory
        documented_command
        file
        framework_metadata
        git
      ].freeze

      def initialize
        @items = {}
        @final_ids = nil
      end

      def add(type:, method:, summary:, path: nil)
        raise InternalError, "evidence collection is already frozen" if @final_ids
        raise ArgumentError, "unsupported evidence type: #{type}" unless TYPES.include?(type)

        item = { "type" => type, "method" => method, "summary" => summary }
        item["path"] = path unless path.nil?
        key = Digest::SHA256.hexdigest([type, path, method, summary].join("\0"))
        @items[key] ||= item
        key
      end

      # References remain internal keys until the assessor has finished
      # collecting evidence. They must never be confused with public E### IDs.
      def references(keys)
        keys.compact.uniq.sort
      end

      # Kept as an internal compatibility name for the existing detector
      # helpers. This returns internal keys, never public E### identifiers.
      alias ids_for references

      def item_for(key)
        @items[key]
      end

      def materialize
        ordered_keys.each_with_index.map do |key, index|
          @items[key].merge("id" => format("E%03d", index + 1)).tap do |item|
            item.delete("path") if item["path"].nil?
          end
        end
      end

      def resolve_references!(result)
        @final_ids = ordered_keys.each_with_index.to_h { |key, index| [key, format("E%03d", index + 1)] }
        resolve_value!(result)
      rescue KeyError => e
        raise InternalError, "unknown internal evidence key: #{e.message}"
      end

      private

      def ordered_keys
        @items.keys.sort_by { |key| sort_key(@items[key]) }
      end

      def resolve_value!(value)
        case value
        when Hash
          value.each do |key, item|
            if key == "evidence_ids"
              value[key] = Array(item).map { |reference| @final_ids.fetch(reference) }
                .sort_by { |identifier| identifier.delete_prefix("E").to_i }
            else
              resolve_value!(item)
            end
          end
        when Array
          value.each { |item| resolve_value!(item) }
        end
      end

      def sort_key(item)
        [item["type"], item["path"].to_s, item["method"], item["summary"]]
      end
    end
  end
end
