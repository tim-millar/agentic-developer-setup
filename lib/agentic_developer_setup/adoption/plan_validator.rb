# frozen_string_literal: true

require_relative "planner"

module AgenticDeveloperSetup
  module Adoption
    class PlanValidator
      include TransactionSupport

      attr_reader :plan, :context

      def initialize(plan)
        @plan = schema!("plan", plan)
        fail!("plan_identity_mismatch", "semantic plan identity does not match") unless plan["plan_id"] == plan_id(plan)
        fail!("invalid_document", "invalid plan creation timestamp", 2) unless Time.iso8601(plan["created_at"]).utc.iso8601 == plan["created_at"]
      rescue ArgumentError
        fail!("invalid_document", "invalid plan timestamp", 2)
      end

      def self.load(path)
        new(TransactionSupport.load_yaml(path))
      end

      def check!(allow_blocked: false)
        @context = TransactionContext.new(target: plan.dig("target", "root"), source: plan.dig("source", "root"),
          operation: plan["operation"], scope: plan.dig("target", "scope", "path"),
          components: plan.dig("selection", "requested_components"), tier: plan.dig("selection", "requested_tier"),
          exclusions: plan.dig("selection", "excluded_components"), decisions: plan.dig("inputs", "decisions", "path"),
          assessment: plan.dig("inputs", "assessment", "path"), validation_spec: plan.dig("inputs", "validation_spec", "path"),
          effective_date: plan["effective_date"])
        stale!("target identity or HEAD changed") unless context.target_identity == plan["target"]
        stale!("source identity, revision or catalogue changed") unless context.source_identity == plan["source"]
        stale!("input identity changed") unless context.inputs == plan["inputs"]
        stale!("selection changed") unless context.selection == plan["selection"]
        stale!("validation command contract changed") unless context.commands == plan["validation_commands"]
        fail!("invalid_document", "diagnostic order is not canonical", 2) unless sorted_diagnostics(plan["diagnostics"]) == plan["diagnostics"]
        if blocked?
          return self if allow_blocked
          fail!("preflight_failed", "plan contains blocking diagnostics")
        end
        fail!("invalid_metadata", "current metadata is inconsistent") if context.diagnostics.any? { |item| item["severity"] == "error" }
        validate_actions!
        validate_metadata!
        self
      end

      def blocked?
        plan["diagnostics"].any? { |item| item["severity"] == "error" }
      end

      def roots
        [Pathname.new(plan.dig("target", "root")), Pathname.new(plan.dig("source", "root"))]
      end

      def input_paths
        plan["inputs"].values.filter_map { |item| item.is_a?(Hash) && item["path"] } +
          plan["actions"].filter_map { |action| action.dig("reviewed_content", "path") }
      end

      def changed?
        plan["actions"].any? { |action| action["action"] != "no_change" }
      end

      def metadata_expected_digest
        changed? ? plan.dig("proposed_metadata", "digest") : plan.dig("inputs", "metadata", "digest")
      end

      def verify_outputs!
        plan["actions"].each do |action|
          next unless action["target_file"]
          file = action["target_file"]
          path = safe_path(roots.first, file["path"])
          fail!("preflight_failed", "applied file identity differs: #{file["path"]}") unless path.file? && digest(File.binread(path)) == file["result_digest"] && mode(path) == file["result_mode"]
        end
        metadata = safe_path(roots.first, METADATA_PATH)
        fail!("preflight_failed", "applied metadata identity differs") unless metadata.file? && digest(File.binread(metadata)) == metadata_expected_digest
        diagnostics = Validator.new(root: roots.first, framework_root: roots.last, schema_path: ROOT.join("schemas/framework-adoption-v1.schema.json")).validate(plan.dig("proposed_metadata", "document"))
        fail!("invalid_metadata", "applied metadata failed semantic validation") if diagnostics.any? { |item| item.severity == "error" }
        true
      end

      private

      def stale!(message)
        fail!("plan_stale", message)
      end

      def assert!(condition, message)
        fail!("invalid_document", message, 2) unless condition
      end

      def validate_actions!
        assert!(plan["actions"].map { |action| action["component_id"] } == plan.dig("selection", "resolved_components"), "actions must exactly cover resolved selection in order")
        plan["actions"].each do |action|
          id = action["component_id"]
          previous = context.metadata && context.metadata["components"].find { |item| item["id"] == id }
          decision = context.decisions.fetch(id)
          assert!(action["before"]["record"] == previous, "action previous record differs")
          assert!(action["after"]["record"] == action["metadata_record"], "action result record differs")
          expected_metadata = context.metadata ? [File.binread(context.target.join(METADATA_PATH))].pack("m0") : nil
          ["before", "after"].each { |key| assert!(action[key]["metadata_content"] == expected_metadata, "embedded original metadata differs") }
          source_file = context.source_required?(id) ? context.source_file(id) : nil
          stale!("source file identity changed") unless action["source_file"] == source_file
          reviewed = (decision["disposition"] == "specialised") ? context.reviewed_file(decision) : nil
          stale!("reviewed content identity changed") unless action["reviewed_content"] == reviewed
          assert!(!WRITES.include?(action["action"]) || source_file, "executable file actions require approved framework source bytes")
          file = action["target_file"]
          validate_file!(action, file, source_file, reviewed) if file
          record = expected_record(action, previous, decision, source_file)
          assert!(action["metadata_record"] == record, "proposed component record does not follow approved decision")
          if WRITES.include?(action["action"])
            assert!(!file.nil?, "write action requires a target file")
            content = reviewed || source_file
            assert!(file["result_digest"] == content["digest"] && file["result_mode"] == content["mode"], "file output must match approved content and mode")
            assert!(file["path"] == context.effective_target(id), "target does not match catalogue mapping")
          elsif action["action"] == "convert_to_specialised" || (action["action"] == "no_change" && previous && previous["ownership"] == "inherited")
            assert!(file && file["path"] == previous["target_path"], "preserved file requires exact identity preconditions")
            assert!(file["expected_digest"] == file["result_digest"] && file["expected_mode"] == file["result_mode"], "metadata-only action must preserve bytes and mode")
          else
            assert!(file.nil?, "metadata action must not declare file effects")
            ["before", "after"].each { |key| assert!(action[key]["content"].nil? && action[key]["size"].nil?, "metadata-only action must not embed file effects") }
          end
        end
      end

      def validate_file!(action, file, source_file, reviewed)
        path = safe_path(context.target, file["path"])
        if file["expected_type"] == "absent"
          stale!("creation target is no longer absent") if path.exist?
          assert!(file["expected_digest"].nil? && file["expected_mode"].nil?, "absent target cannot have a previous digest or mode")
          assert!(action["before"]["content"].nil? && action["before"]["size"].nil?, "absent file must have absent before content")
        else
          stale!("target existence/content/mode changed") unless path.file? && digest(File.binread(path)) == file["expected_digest"] && mode(path) == file["expected_mode"]
          assert!(snapshot(path) == action["before"].slice("content", "size"), "embedded original file bytes differ")
        end
        after_bytes = bytes(action["after"])
        assert!(after_bytes.bytesize == action["after"]["size"] && digest(after_bytes) == file["result_digest"], "embedded output digest or size differs")
        if WRITES.include?(action["action"])
          content_path = reviewed ? reviewed["path"] : context.source.join(source_file["path"])
          assert!(after_bytes == File.binread(content_path), "embedded output is not exact approved bytes")
        end
      end

      def expected_record(action, previous, decision, source_file)
        type = action["action"]
        id = action["component_id"]
        disposition = decision["disposition"]
        case plan["operation"]
        when "initial_adoption", "add_components"
          assert!(previous.nil?, "existing component records cannot be replaced by adoption/add")
          record = {"id" => id, "status" => "active"}
          case disposition
          when "inherited", "specialised"
            assert!(type == "create_#{disposition}" && action.dig("target_file", "expected_type") == "absent", "adoption requires absent-target creation")
            record.merge!("ownership" => disposition, "update_policy" => (disposition == "inherited") ? "review_required" : "manual_merge",
              "source_path" => source_file["path"], "target_path" => context.effective_target(id), "adopted_revision" => context.revision, "adopted_source_digest" => source_file["digest"])
            record["local_ownership"] = decision["local_ownership"] if disposition == "specialised"
          when "repository_owned"
            assert!(type == "record_repository_owned", "repository-owned decision must be metadata-only")
            record.merge!("ownership" => "repository_owned", "update_policy" => "repository_managed", "equivalent" => decision["equivalent"], "rationale" => decision["rationale"])
          else
            assert!(type == "record_inactive", "inactive decision must be metadata-only")
            record["status"] = disposition
            record["rationale"] = decision["rationale"]
          end
          record
        when "update_inherited", "reconcile_inherited"
          assert!(previous && previous["status"] == "active" && previous["ownership"] == "inherited" && previous["update_policy"] == "review_required", "only active unpinned inherited components are eligible")
          file = action["target_file"]
          assert!(file && file["path"] == previous["target_path"] && file["expected_type"] == "regular", "inherited operation requires existing mapped target")
          if plan["operation"] == "reconcile_inherited"
            committed = committed_regular_file!(context.target, previous["target_path"])
            stale!("reconciliation committed-content identity changed") unless committed == {"digest" => file["expected_digest"], "mode" => file["expected_mode"]}
            assert!(type == "convert_to_specialised" && file["expected_digest"] != previous["adopted_source_digest"], "only inherited local mismatches can be reconciled")
            previous.merge("ownership" => "specialised", "update_policy" => "manual_merge", "local_ownership" => decision["local_ownership"])
          elsif source_file["digest"] == previous["adopted_source_digest"]
            assert!(type == "no_change" && file["expected_digest"] == previous["adopted_source_digest"], "equal candidate bytes require no_change with matching local bytes")
            previous
          else
            assert!(type == "update_inherited" && file["expected_digest"] == previous["adopted_source_digest"], "update requires unchanged inherited target")
            assert!(source_file["path"] == previous["source_path"] && context.effective_target(id) == previous["target_path"], "path migration is unsupported")
            previous.merge("adopted_revision" => context.revision, "adopted_source_digest" => source_file["digest"])
          end
        end
      end

      def validate_metadata!
        document = plan.dig("proposed_metadata", "document")
        assert!(digest(metadata_bytes(document)) == plan.dig("proposed_metadata", "digest"), "proposed metadata serializer digest differs")
        expected = if context.metadata
          Marshal.load(Marshal.dump(context.metadata))
        else
          {"schema_version" => 1, "scope" => context.scope, "framework" => {"source" => SOURCE,
                                                                            "version" => context.source_identity["version"], "revision" => context.revision,
                                                                            "adopted_at" => plan["effective_date"], "updated_at" => plan["effective_date"]}, "components" => []}
        end
        plan["actions"].each do |action|
          next if action["action"] == "no_change"
          index = expected["components"].index { |item| item["id"] == action["component_id"] }
          if index
            expected["components"][index] = action["metadata_record"]
          else
            expected["components"] << action["metadata_record"]
          end
        end
        expected["framework"]["updated_at"] = plan["effective_date"] if changed?
        if plan["actions"].any? { |action| action["action"] == "update_inherited" }
          expected["framework"].merge!("revision" => context.revision, "version" => context.source_identity["version"])
        end
        assert!(expected == document, "metadata contains undeclared changes")
        outputs = plan["actions"].filter_map { |a| [a["target_file"]["path"], a["target_file"]["result_digest"]] if WRITES.include?(a["action"]) }.to_h
        validator = ProposedMetadataValidator.new(root: context.target, framework_root: context.source, schema_path: ROOT.join("schemas/framework-adoption-v1.schema.json"), outputs: outputs)
        fail!("invalid_metadata", "proposed metadata semantic validation failed") if validator.validate(document).any? { |d| d.severity == "error" }
        paths = document["components"].filter_map { |item| item["target_path"] }
        paths.combination(2) { |a, b| assert!(a.downcase != b.downcase && !a.downcase.start_with?("#{b.downcase}/") && !b.downcase.start_with?("#{a.downcase}/"), "managed path collision") }
        paths.each do |path|
          safe_path(context.target, path)
          assert!(path.downcase != METADATA_PATH && !path.downcase.start_with?("#{METADATA_PATH}/") && !METADATA_PATH.start_with?("#{path.downcase}/"), "managed target aliases metadata")
        end
      end
    end
  end
end
