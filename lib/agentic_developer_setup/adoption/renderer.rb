# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adoption
    class Renderer
      def self.render(result)
        new(result).render
      end

      def initialize(result)
        @result = result
      end

      def render
        lines = ["# Framework adoption inspection", "", "## Identity", "", "- Repository: #{markdown_code(@result.dig("repository", "root"))}", "- Metadata: #{markdown_code(@result.dig("metadata", "path"))} (#{markdown_code(@result.dig("metadata", "status"))})", "- Framework: #{markdown_code(@result.dig("framework", "version") || "unknown")} at #{markdown_code(@result.dig("framework", "revision") || "unknown")}", "- Scope: #{markdown_code(@result.dig("scope", "type") || "unknown")} / #{markdown_code(@result.dig("scope", "path") || "unknown")}", "", "## Components", "", "| ID | Status | Ownership | Local state | Update state | Target |", "| --- | --- | --- | --- | --- | --- |"]
        @result["components"].each do |component|
          lines << "| #{markdown_table_code(component["id"])} | #{markdown_table_code(component["status"])} | #{markdown_table_code(component["ownership"] || "—")} | #{markdown_table_code(component["local_state"])} | #{markdown_table_code(component["update_state"])} | #{markdown_table_code(component["target_path"] || "—")} |"
        end
        lines.concat(["", "## Diagnostics", ""])
        diagnostics = @result["diagnostics"]
        lines << (if diagnostics.empty?
                    "No diagnostics."
                  else
                    diagnostics.map { |item| "- **#{markdown_text(item["severity"])}** #{markdown_code(item["code"])}#{" (#{markdown_code(item["component_id"])})" if item["component_id"]}: #{markdown_text(item["message"])}" }
        end)
        lines.concat(["", "## Summary", "", "- Errors: #{@result.dig("summary", "error_count")}", "- Warnings: #{@result.dig("summary", "warning_count")}", "- Review required: #{@result.dig("summary", "review_required_count")}", "", "## Limitations", "", "- Specialised content is not semantically validated.", "- Repository-owned commands are declared but never executed.", "- Candidate availability is not a safety determination.", "- No network lookup was performed."])
        lines.flatten.join("\n") + "\n"
      end

      private

      def markdown_code(value)
        text = value.to_s
        fence_length = [text.scan(/`+/).map(&:length).max.to_i + 1, 1].max
        fence = "`" * fence_length
        "#{fence}#{text}#{fence}"
      end

      def markdown_table_code(value)
        markdown_code(value.to_s.gsub("|", "\\\\|"))
      end

      def markdown_text(value)
        value.to_s.gsub("\\", "\\\\").gsub(/[`*_{}\[\]()#+\-.!|>]/) { |character| "\\#{character}" }.gsub(/[\r\n]+/, " ")
      end
    end
  end
end
