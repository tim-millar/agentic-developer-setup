# frozen_string_literal: true

require_relative "transaction_context"

module AgenticDeveloperSetup
  module Adoption
    # Reuse every metadata rule, substituting only the planned file identities for
    # the target-file inspection. No target tree is materialised during planning.
    class ProposedMetadataValidator < Validator
      def initialize(outputs:, **options)
        @outputs = outputs
        super(**options)
      end

      private

      def inspect_target(component, scope)
        output = @outputs[component["target_path"]]
        return super unless output
        if component["ownership"] == "inherited" && output != component["adopted_source_digest"]
          error("inherited_digest_mismatch", component["id"], component["target_path"], "planned bytes do not match inherited provenance")
        end
      end
    end

    class Planner
      include TransactionSupport

      attr_reader :context

      def initialize(**options)
        @operation = options.fetch(:operation)
        @date = options.fetch(:effective_date)
        @context = TransactionContext.new(**options)
        @diagnostics = context.diagnostics.dup
      end

      def build
        actions = context.selection["resolved_components"].map { |id| action_for(id) }
        document = proposed_document(actions)
        outputs = actions.filter_map do |action|
          file = action["target_file"]
          [file["path"], file["result_digest"]] if WRITES.include?(action["action"])
        end.to_h
        validator = ProposedMetadataValidator.new(root: context.target, framework_root: context.source, schema_path: ROOT.join("schemas/framework-adoption-v1.schema.json"), outputs: outputs)
        @diagnostics.concat(validator.validate(document).map { |item| item.to_h.merge("code" => "invalid_metadata") })
        check_managed_paths(document)
        plan = {
          "schema_version" => 1, "plan_id" => "sha256:#{"0" * 64}",
          "operation" => @operation, "created_at" => now, "effective_date" => @date,
          "target" => context.target_identity, "source" => context.source_identity,
          "inputs" => context.inputs, "selection" => context.selection,
          "actions" => actions, "proposed_metadata" => {"document" => document, "digest" => digest(metadata_bytes(document))},
          "validation_commands" => context.commands, "diagnostics" => sorted_diagnostics(@diagnostics)
        }
        plan["plan_id"] = plan_id(plan)
        schema!("plan", plan)
      end

      def write(output)
        plan = build
        roots = [context.target, context.source]
        destination = external(output, roots)
        inputs = context.inputs.values.filter_map { |input| input.is_a?(Hash) && input["path"] }
        reviewed = plan["actions"].filter_map { |action| action.dig("reviewed_content", "path") }
        identities_distinct!([destination, *inputs, *reviewed])
        # Revalidate all source/target/input state, including the output identity, before publication.
        PlanValidator.new(plan).check!(allow_blocked: true)
        fail!("unsafe_path", "plan destination changed") unless external(output, roots) == destination
        atomic_write(destination, YAML.dump(canonical(plan)), mode: "0600")
        plan
      end

      private

      def action_for(id)
        previous = context.metadata && context.metadata["components"].find { |item| item["id"] == id }
        decision = context.decisions.fetch(id)
        action = {
          "component_id" => id, "action" => "no_change", "rationale" => decision["rationale"] || "Explicit #{decision["disposition"]} decision.",
          "before" => state(previous), "after" => state(previous), "source_file" => nil, "target_file" => nil,
          "reviewed_content" => context.reviewed_files[id], "metadata_record" => previous
        }
        begin
          action["source_file"] = context.source_file(id) if context.source_required?(id)
          if %w[initial_adoption add_components].include?(@operation)
            adopt(action, previous, decision)
          elsif @operation == "update_inherited"
            update(action, previous)
          else
            reconcile(action, previous, decision)
          end
        rescue TransactionError => e
          raise unless e.exit_code == 4 || e.code == "source_unavailable"
          @diagnostics << diagnostic(e.code, e.message, component_id: id)
          action["action"] = "no_change"
          action["metadata_record"] = previous
          action["after"] = state(previous)
        end
        action
      end

      def state(record, path = nil)
        snapshot(path).merge("record" => record, "metadata_content" => context.metadata ? [File.binread(context.target.join(METADATA_PATH))].pack("m0") : nil)
      end

      def adopt(action, previous, decision)
        fail!("ownership_conflict", "component already exists in metadata") if previous
        id = action["component_id"]
        disposition = decision["disposition"]
        record = {"id" => id, "status" => "active"}
        case disposition
        when "deferred", "declined"
          record["status"] = disposition
          record["rationale"] = decision["rationale"]
          action["action"] = "record_inactive"
        when "repository_owned"
          record.merge!("ownership" => "repository_owned", "update_policy" => "repository_managed", "equivalent" => decision["equivalent"], "rationale" => decision["rationale"])
          action["action"] = "record_repository_owned"
        else
          relative = context.effective_target(id)
          path = safe_path(context.target, relative)
          fail!("target_conflict", "unowned target already exists: #{relative}") if path.exist?
          record.merge!("ownership" => disposition, "update_policy" => (disposition == "inherited") ? "review_required" : "manual_merge",
            "source_path" => action["source_file"]["path"], "target_path" => relative,
            "adopted_revision" => context.revision, "adopted_source_digest" => action["source_file"]["digest"])
          content_file = action["source_file"]
          content_path = context.source.join(content_file["path"])
          if disposition == "specialised"
            reviewed = context.reviewed_files.fetch(id)
            action["reviewed_content"] = reviewed
            content_file = reviewed
            content_path = Pathname.new(reviewed["path"])
            record["local_ownership"] = decision["local_ownership"]
          end
          action["action"] = "create_#{disposition}"
          action["target_file"] = target_file(relative, nil, content_file)
          action["after"] = state(record, content_path)
        end
        action["metadata_record"] = record
        action["after"]["record"] = record
      end

      def eligible_record!(previous)
        fail!("ownership_conflict", "component must be active and inherited") unless previous && previous["status"] == "active" && previous["ownership"] == "inherited"
        fail!("pinned_component", "pinned component cannot change") unless previous["update_policy"] == "review_required"
        path = safe_path(context.target, previous["target_path"])
        fail!("target_conflict", "managed target must be a regular file") unless path.file?
        path
      end

      def update(action, previous)
        path = eligible_record!(previous)
        fail!("local_modification", "inherited target differs from its recorded source digest") unless digest(File.binread(path)) == previous["adopted_source_digest"]
        source_file = action["source_file"]
        action["before"] = state(previous, path)
        if source_file["digest"] == previous["adopted_source_digest"]
          action["rationale"] = "Candidate bytes are unchanged; preserve component provenance."
          action["after"] = state(previous, path)
          action["target_file"] = target_file(previous["target_path"], path, {"digest" => source_file["digest"], "mode" => mode(path)})
          if source_file["mode"] != mode(path)
            @diagnostics << diagnostic("mode_change_requires_review", "Unchanged bytes with different executable mode require separate review; no replacement planned.", component_id: action["component_id"], severity: "warning")
          end
          return
        end
        fail!("path_migration_unsupported", "candidate source/target mapping changed") unless source_file["path"] == previous["source_path"] && context.effective_target(action["component_id"]) == previous["target_path"]
        record = previous.merge("adopted_revision" => context.revision, "adopted_source_digest" => source_file["digest"])
        action["action"] = "update_inherited"
        action["metadata_record"] = record
        action["target_file"] = target_file(previous["target_path"], path, source_file)
        action["after"] = state(record, context.source.join(source_file["path"]))
      end

      def reconcile(action, previous, decision)
        path = eligible_record!(previous)
        committed = committed_regular_file!(context.target, previous["target_path"])
        fail!("unsupported_operation", "reconciliation requires a committed inherited digest mismatch") if committed["digest"] == previous["adopted_source_digest"]
        record = previous.merge("ownership" => "specialised", "update_policy" => "manual_merge", "local_ownership" => decision["local_ownership"])
        action["action"] = "convert_to_specialised"
        action["metadata_record"] = record
        action["target_file"] = target_file(previous["target_path"], path, committed)
        action["before"] = state(previous, path)
        action["after"] = state(record, path)
      end

      def target_file(relative, path, output)
        {"path" => relative, "expected_type" => path ? "regular" : "absent",
         "expected_digest" => path ? digest(File.binread(path)) : nil, "expected_mode" => path ? mode(path) : nil,
         "result_digest" => output["digest"], "result_mode" => output["mode"]}
      end

      def proposed_document(actions)
        document = if context.metadata
          Marshal.load(Marshal.dump(context.metadata))
        else
          {"schema_version" => 1, "framework" => {"source" => SOURCE, "version" => context.source_identity["version"],
                                                  "revision" => context.revision, "adopted_at" => @date, "updated_at" => @date}, "scope" => context.scope, "components" => []}
        end
        actions.each do |action|
          next if action["action"] == "no_change"
          index = document["components"].index { |item| item["id"] == action["component_id"] }
          if index
            document["components"][index] = action["metadata_record"]
          else
            document["components"] << action["metadata_record"]
          end
        end
        if actions.any? { |action| action["action"] != "no_change" }
          document["framework"]["updated_at"] = @date
        end
        if actions.any? { |action| action["action"] == "update_inherited" }
          document["framework"].merge!("version" => context.source_identity["version"], "revision" => context.revision)
        end
        document
      end

      def check_managed_paths(document)
        paths = document["components"].filter_map { |item| item["target_path"] }
        paths.combination(2) do |a, b|
          if a.downcase == b.downcase || a.downcase.start_with?("#{b.downcase}/") || b.downcase.start_with?("#{a.downcase}/")
            @diagnostics << diagnostic("target_conflict", "managed target paths collide: #{a}, #{b}")
          end
        end
        paths.each do |path|
          safe_path(context.target, path)
          if path.downcase == METADATA_PATH || path.downcase.start_with?("#{METADATA_PATH}/") || METADATA_PATH.start_with?("#{path.downcase}/")
            @diagnostics << diagnostic("unsafe_path", "managed target aliases canonical metadata", path: path)
          end
        rescue TransactionError => e
          @diagnostics << diagnostic(e.code, e.message, path: path)
        end
      end
    end
  end
end
