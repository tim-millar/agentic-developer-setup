# frozen_string_literal: true

module AgenticDeveloperSetup
  module Assessment
    class MarkdownRenderer
      def self.render(result)
        new(result).render
      end

      def initialize(result)
        @result = result
      end

      def render
        sections = []
        sections << "# Repository assessment"
        sections << executive_summary
        sections << profile
        sections << ecosystem_profile
        sections << readiness
        sections << tier
        sections << components
        sections << gaps
        sections << risks
        sections << roadmap
        sections << list_section("Assumptions", @result["assumptions"])
        sections << list_section("Unknowns", @result["unknowns"])
        sections << evidence
        sections.compact.join("\n\n") + "\n"
      end

      private

      def executive_summary
        tier = @result["tier_recommendation"]
        "## Executive summary\n\n" \
          "- Recommended adoption outcome: **#{tier["outcome"]}** (#{tier["confidence"]} confidence).\n" \
          "- Readiness findings are capability-specific; this report does not assign an aggregate score.\n" \
          "- Gaps: #{@result["gaps"].length}; risks requiring review: #{@result["risks"].length}.\n\n" \
          "An assessment recommends an adoption strategy. It does not authorise repository changes and does not replace repository-owner, architecture, security, or operational review."
      end

      def profile
        repository = @result["repository"]
        git = repository["git"]
        scope = @result["scope"]
        "## Repository profile\n\n" \
          "- Root: `#{repository["root"]}`\n" \
          "- Git: #{git["detected"] ? "detected (#{git["working_tree"]} working tree)" : "not detected"}\n" \
          "- Scope shape: `#{scope["shape"]}`\n" \
          "- Project roots: #{inline_list(scope["project_roots"]) }\n" \
          "- Excluded areas: #{inline_list(scope["excluded_paths"]) }"
      end

      def ecosystem_profile
        entries = @result["ecosystem"]
        tooling = @result["tooling"]
        lines = ["## Ecosystem and tooling profile", ""]
        if entries.empty?
          lines << "No supported ecosystem was detected from recognised metadata."
        else
          entries.each do |entry|
            lines << "- `#{entry["name"]}` (#{entry["role"]}, #{entry["confidence"]} confidence): #{inline_list(entry["paths"])}"
          end
        end
        managers = tooling["package_managers"].to_a.map { |entry| entry["name"] }.join(", ")
        tasks = tooling.dig("command_surface", "commands").to_a.map { |entry| entry["name"] }.join(", ")
        lines << "- Package managers: #{managers.empty? ? "none detected" : managers}"
        lines << "- Command surface: #{tasks.empty? ? "none detected" : tasks}"
        lines.join("\n")
      end

      def readiness
        lines = ["## Readiness overview", "", "| Dimension | Status | Confidence | Consequence |", "| --- | --- | --- | --- |"]
        @result["readiness"].each do |dimension, item|
          lines << "| `#{dimension}` | `#{item["status"]}` | `#{item["confidence"]}` | #{item["consequence"]} |"
        end
        lines.join("\n")
      end

      def tier
        item = @result["tier_recommendation"]
        "## Adoption-tier recommendation\n\n" \
          "Outcome: **#{item["outcome"]}** (#{item["confidence"]} confidence).\n\n" \
          "Blocking gaps: #{inline_list(item["blocking_gap_ids"])}\n\n" \
          "Alternative conditions:\n#{bullet_list(item["alternative_conditions"])}"
      end

      def components
        lines = ["## Component recommendations", "", "| Component | State | Confidence | Rationale |", "| --- | --- | --- | --- |"]
        @result["component_recommendations"].each do |item|
          lines << "| `#{item["component"]}` | `#{item["state"]}` | `#{item["confidence"]}` | #{item["rationale"]} |"
        end
        lines.join("\n")
      end

      def gaps
        lines = ["## Key gaps"]
        if @result["gaps"].empty?
          lines << "\nNo adoption-specific gaps were recorded from the inspected evidence."
        else
          @result["gaps"].each do |item|
            lines << "\n- **#{item["id"]}: #{item["title"]}** (`#{item["severity"]}`) — #{item["recommended_outcome"]}"
          end
        end
        lines.join("\n")
      end

      def risks
        lines = ["## Key risks"]
        if @result["risks"].empty?
          lines << "\nNo adoption-specific risks were recorded from the inspected evidence."
        else
          @result["risks"].each do |item|
            lines << "\n- **#{item["id"]}: #{item["category"]}** (`#{item["severity"]}`) — #{item["impact"]} Mitigation: #{item["mitigation"]}"
          end
        end
        lines.join("\n")
      end

      def roadmap
        lines = ["## Phased roadmap"]
        if @result["roadmap"].empty?
          lines << "\nNo roadmap items were generated because no component or gap recommendation requires a staged action."
        else
          @result["roadmap"].each do |item|
            lines << "\n- **Phase #{item["phase"]} — #{item["title"]}** (`#{item["id"]}`, component `#{item["component"]}`)"
            lines << "  - Gaps: #{inline_list(item["gap_ids"])}"
            lines << "  - Prerequisites: #{inline_list(item["prerequisite_ids"])}"
            lines << "  - #{item["rationale"]}"
          end
        end
        lines.join("\n")
      end

      def list_section(title, values)
        "## #{title}\n\n#{bullet_list(values)}"
      end

      def evidence
        lines = ["## Evidence appendix", ""]
        @result["evidence"].each do |item|
          path = item["path"] ? " (`#{item["path"]}`)" : ""
          lines << "- `#{item["id"]}` — #{item["type"]}/#{item["method"]}#{path}: #{item["summary"]}"
        end
        lines.join("\n")
      end

      def bullet_list(values)
        values = values.to_a
        values.empty? ? "- None recorded." : values.map { |value| "- #{value}" }.join("\n")
      end

      def inline_list(values)
        values = values.to_a
        values.empty? ? "none" : values.map { |value| "`#{value}`" }.join(", ")
      end
    end
  end
end
