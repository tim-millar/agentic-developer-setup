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
      end

      def add(type:, method:, summary:, path: nil)
        raise ArgumentError, "unsupported evidence type: #{type}" unless TYPES.include?(type)

        item = { "type" => type, "method" => method, "summary" => summary }
        item["path"] = path unless path.nil?
        key = Digest::SHA256.hexdigest([type, path, method, summary].join("\0"))
        @items[key] ||= item
        key
      end

      def ids_for(keys)
        keys.compact.uniq.map { |key| id_for(key) }.compact.sort_by { |id| id.delete_prefix("E").to_i }
      end

      def id_for(key)
        ordered = @items.keys.sort_by { |item_key| sort_key(@items[item_key]) }
        index = ordered.index(key)
        index ? format("E%03d", index + 1) : nil
      end

      def materialize
        @items.keys.sort_by { |key| sort_key(@items[key]) }.each_with_index.map do |key, index|
          @items[key].merge("id" => format("E%03d", index + 1)).tap do |item|
            item.delete("path") if item["path"].nil?
          end
        end
      end

      private

      def sort_key(item)
        [item["type"], item["path"].to_s, item["method"], item["summary"]]
      end
    end
  end
end
