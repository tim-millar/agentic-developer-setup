# frozen_string_literal: true

module AgenticDeveloperSetup
  module Assessment
    module Ini
      module_function

      # Bounded ConfigParser subset. Whole-line comments and indented
      # continuations are accepted; interpolation and includes are absent.
      def parse(raw)
        return unless raw && !raw.include?("\0")
        data = {}
        section = key = nil
        raw.each_line do |line|
          value = line.strip
          next if value.empty? || value.start_with?("#", ";")
          if (match = /\A\[([a-zA-Z0-9:_.-]+)\]\z/.match(value))
            section = match[1].downcase
            return nil if data.key?(section)
            data[section] = {}
            key = nil
          elsif section && key && line.match?(/\A[ \t]/)
            data[section][key] << "\n" << value
          elsif section && (match = /\A([a-zA-Z0-9_.-]+)[ \t]*[=:][ \t]*(.*)\z/.match(value))
            key = match[1].downcase
            return nil if data[section].key?(key)
            data[section][key] = match[2]
          else
            return nil
          end
        end
        data
      end
    end
  end
end
