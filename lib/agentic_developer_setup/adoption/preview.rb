# frozen_string_literal: true

require_relative "plan_validator"

module AgenticDeveloperSetup
  module Adoption
    class Preview
      include TransactionSupport

      def initialize(validator)
        @validator = validator
        @plan = validator.plan
      end

      def render
        applicability = begin
          @validator.check!
          "applicable"
        rescue TransactionError => e
          "blocked: #{e.code}: #{e.message}"
        end
        lines = ["Plan #{@plan["plan_id"]}", "Operation: #{@plan["operation"]}",
          "Target: #{@plan.dig("target", "root")} @ #{@plan.dig("target", "head")}",
          "Scope: #{@plan.dig("target", "scope", "path")}",
          "Source: #{@plan.dig("source", "root")} @ #{@plan.dig("source", "revision")}",
          "Applicability: #{applicability}", "Selection: #{@plan.dig("selection", "resolved_components").join(", ")}"]
        @plan["actions"].each do |action|
          lines << "\n#{action["component_id"]}: #{action["action"]} — #{action["rationale"]}"
          record = action["metadata_record"]
          lines << "Ownership/status: #{record && record["ownership"]} / #{record && record["status"]}"
          lines << "Manual specialisation attestation: reviewed: true; semantic suitability is not verified." if action["reviewed_content"]
          file = action["target_file"]
          next unless file
          lines << "#{file["path"]}: #{file["expected_type"]} #{file["expected_digest"]} mode #{file["expected_mode"]} -> #{file["result_digest"]} mode #{file["result_mode"]}"
          before = action["before"]["content"] ? bytes(action["before"]) : "".b
          after = bytes(action["after"])
          lines << diff(file["path"], before, after)
        end
        previous = @plan["actions"].first.dig("before", "metadata_content")
        before_metadata = previous ? previous.unpack1("m0") : "".b
        lines << "\nComplete metadata diff:"
        lines << diff(METADATA_PATH, before_metadata, @validator.changed? ? metadata_bytes(@plan.dig("proposed_metadata", "document")) : before_metadata)
        @plan["diagnostics"].each { |item| lines << "#{item["severity"]} #{item["code"]} #{item["component_id"]}: #{item["message"]}" }
        lines << "\nValidation commands (separate explicit invocation; repository code executes without an additional sandbox):"
        @plan["validation_commands"].each { |command| lines << JSON.generate(command) }
        lines << "No commands approved; validation will be skipped." if @plan["validation_commands"].empty?
        lines << "Expected application state: #{@validator.changed? ? "applied_unvalidated" : "no_changes"}"
        [lines.join("\n") + "\n", (applicability == "applicable") ? 0 : 4]
      end

      private

      def diff(path, before, after)
        return "(unchanged)" if before == after
        unless [before, after].all? { |bytes| bytes.dup.force_encoding(Encoding::UTF_8).valid_encoding? && !bytes.include?("\0") }
          return "Binary/non-text: #{path}; #{before.bytesize} -> #{after.bytesize} bytes; #{digest(before)} -> #{digest(after)}"
        end
        # Emit a deterministic full-context unified hunk without running external code.
        old_lines = before.lines
        new_lines = after.lines
        result = ["--- a/#{path}", "+++ b/#{path}", "@@ -#{old_lines.empty? ? 0 : 1},#{old_lines.length} +#{new_lines.empty? ? 0 : 1},#{new_lines.length} @@"]
        [["-", old_lines], ["+", new_lines]].each do |prefix, lines|
          lines.each do |line|
            result << "#{prefix}#{line.chomp("\n")}"
            result << "\\ No newline at end of file" unless line.end_with?("\n")
          end
        end
        result.join("\n")
      end
    end
  end
end
