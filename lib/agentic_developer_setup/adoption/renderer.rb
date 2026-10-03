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
        lines = ["# Framework adoption inspection", "", "## Identity", "", "- Repository: `#{@result.dig("repository", "root")}`", "- Metadata: `#{@result.dig("metadata", "path")}` (`#{@result.dig("metadata", "status")}`)", "- Framework: `#{@result.dig("framework", "version") || "unknown"}` at `#{@result.dig("framework", "revision") || "unknown"}`", "- Scope: `#{@result.dig("scope", "type") || "unknown"}` / `#{@result.dig("scope", "path") || "unknown"}`", "", "## Components", "", "| ID | Status | Ownership | Local state | Update state | Target |", "| --- | --- | --- | --- | --- | --- |"]
        @result["components"].each do |component|
          lines << "| `#{component["id"]}` | `#{component["status"]}` | `#{component["ownership"] || "—"}` | `#{component["local_state"]}` | `#{component["update_state"]}` | `#{component["target_path"] || "—"}` |"
        end
        lines.concat(["", "## Diagnostics", ""])
        diagnostics = @result["diagnostics"]
        lines << (if diagnostics.empty?
                    "No diagnostics."
                  else
                    diagnostics.map { |item| "- **#{item["severity"]}** `#{item["code"]}`#{" (`#{item["component_id"]}`)" if item["component_id"]}: #{item["message"]}" }
        end)
        lines.concat(["", "## Summary", "", "- Errors: #{@result.dig("summary", "error_count")}", "- Warnings: #{@result.dig("summary", "warning_count")}", "- Review required: #{@result.dig("summary", "review_required_count")}", "", "## Limitations", "", "- Specialised content is not semantically validated.", "- Repository-owned commands are declared but never executed.", "- Candidate availability is not a safety determination.", "- No network lookup was performed."])
        lines.flatten.join("\n") + "\n"
      end
    end
  end
end
