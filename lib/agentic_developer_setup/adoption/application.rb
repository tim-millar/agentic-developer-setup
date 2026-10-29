# frozen_string_literal: true

require_relative "plan_validator"

module AgenticDeveloperSetup
  module Adoption
    class Application
      include TransactionSupport

      attr_reader :journal

      # The hook is an internal test seam; it is never exposed by the CLI or environment.
      def initialize(validator, hook: nil)
        @validator = validator
        @plan = validator.plan
        @hook = hook || ->(_event, _action) {}
      end

      def apply(accept_plan_id:, result:, plan_path:)
        @result = external(result, @validator.roots, new_file: true)
        @result_argument = result
        identities_distinct!([@result, plan_path, *@validator.input_paths])
        @journal = new_journal
        begin
          fail!("plan_identity_mismatch", "--accept-plan-id must exactly match the validated plan ID") unless accept_plan_id == @plan["plan_id"]
          @validator.check!
          # Preparation uses only the reviewed bytes in this validated plan.
          @prepared = @plan["actions"].to_h { |action| [action["component_id"], WRITES.include?(action["action"]) ? bytes(action["after"]) : nil] }
          persist!(initial: true)
          @plan["actions"].each_with_index { |action, index| perform_action(action, index) }
          write_metadata if @validator.changed?
          @validator.verify_outputs!
          @journal["metadata"]["verified"] = true
          @journal["metadata"]["actual_digest"] = digest(File.binread(@validator.roots.first.join(METADATA_PATH)))
          @hook.call(:after_verify, nil)
          @journal["status"] = @validator.changed? ? "applied_unvalidated" : "no_changes"
          @journal["finished_at"] = now
          @journal["recovery"]["interruption_uncertainty"] = false
          @journal["recovery"]["fresh_plan_required"] = @validator.changed?
          persist!
          [@journal, 0]
        rescue TransactionError, SystemCallError, IOError => e
          record_failure(e)
        end
      end

      private

      def new_journal
        {
          "schema_version" => 1, "plan_id" => @plan["plan_id"], "operation" => @plan["operation"],
          "target" => @plan["target"], "source" => @plan["source"], "started_at" => now, "finished_at" => nil,
          "status" => "in_progress", "actions" => @plan["actions"].map do |action|
            file = action["target_file"]
            {"component_id" => action["component_id"], "action" => action["action"], "target_path" => file && file["path"],
             "previous" => {"digest" => file && file["expected_digest"], "mode" => file && file["expected_mode"]},
             "intended" => {"digest" => file && file["result_digest"], "mode" => file && file["result_mode"]},
             "observed" => nil, "reviewed_content" => action["reviewed_content"], "state" => "pending", "diagnostics" => []}
          end,
          "metadata" => {"attempted" => false, "written" => false, "verified" => false, "expected_digest" => @validator.metadata_expected_digest, "actual_digest" => nil},
          "diagnostics" => [], "recovery" => {"mutation_occurred" => false, "inspect_paths" => [], "metadata_written" => false, "fresh_plan_required" => false, "interruption_uncertainty" => true}
        }
      end

      def persist!(initial: false)
        fail!("unsafe_path", "application-result destination changed") unless external(@result_argument, @validator.roots) == @result
        if initial
          fail!("target_conflict", "application result already exists") if @result.exist?
        else
          fail!("unsafe_path", "application journal identity changed externally") unless @result.file? && digest(File.binread(@result)) == @journal_digest
        end
        schema!("application-result", @journal)
        raw = YAML.dump(canonical(@journal))
        atomic_write(@result, raw, create: initial)
        @journal_digest = digest(raw)
      end

      def mutated!(relative)
        @journal["recovery"]["mutation_occurred"] = true
        @journal["recovery"]["fresh_plan_required"] = true
        @journal["recovery"]["inspect_paths"] |= [relative]
      end

      def parents!(relative)
        root = @validator.roots.first
        relative.split("/")[0...-1].each_with_object([]) do |part, parts|
          parts << part
          current_relative = parts.join("/")
          path = safe_path(root, current_relative)
          next if path.directory?
          Dir.mkdir(path, 0o755)
          mutated!(current_relative)
          sync_directory(path.parent)
        end
      end

      def verify_precondition!(file)
        path = safe_path(@validator.roots.first, file["path"])
        if file["expected_type"] == "absent"
          fail!("plan_stale", "destination no longer absent") if path.exist?
        else
          fail!("plan_stale", "destination precondition changed") unless path.file? && digest(File.binread(path)) == file["expected_digest"] && mode(path) == file["expected_mode"]
        end
        path
      end

      def perform_action(action, index)
        evidence = @journal["actions"][index]
        evidence["state"] = "started"
        persist!
        if WRITES.include?(action["action"])
          @hook.call(:before_file, action)
          file = action["target_file"]
          verify_precondition!(file)
          parents!(file["path"])
          path = verify_precondition!(file)
          atomic_write(path, @prepared.fetch(action["component_id"]), mode: file["result_mode"], create: file["expected_type"] == "absent") { mutated!(file["path"]) }
          @hook.call(:after_file, action)
        end
        if action["target_file"]
          file = action["target_file"]
          path = safe_path(@validator.roots.first, file["path"])
          evidence["observed"] = {"digest" => path.file? ? digest(File.binread(path)) : nil, "mode" => path.file? ? mode(path) : nil}
          fail!("application_failed", "post-write file verification failed", 5) unless evidence["observed"] == evidence["intended"]
        end
        evidence["state"] = "completed"
        persist!
      end

      def write_metadata
        @journal["metadata"]["attempted"] = true
        persist!
        @hook.call(:before_metadata, nil)
        root = @validator.roots.first
        path = safe_path(root, METADATA_PATH)
        input = @plan.dig("inputs", "metadata")
        if input["status"] == "absent"
          fail!("plan_stale", "metadata no longer absent") if path.exist?
        else
          fail!("plan_stale", "metadata bytes changed") unless path.file? && digest(File.binread(path)) == input["digest"]
        end
        parents!(METADATA_PATH)
        path = safe_path(root, METADATA_PATH)
        atomic_write(path, metadata_bytes(@plan.dig("proposed_metadata", "document")), create: input["status"] == "absent") do
          mutated!(METADATA_PATH)
          @journal["metadata"]["written"] = true
          @journal["recovery"]["metadata_written"] = true
        end
        @hook.call(:after_metadata, nil)
        @journal["metadata"]["actual_digest"] = digest(File.binread(path))
        @journal["metadata"]["verified"] = @journal["metadata"]["actual_digest"] == @plan.dig("proposed_metadata", "digest")
        persist!
      end

      def record_failure(error)
        mutated = @journal["recovery"]["mutation_occurred"]
        code = error.is_a?(TransactionError) ? error.code : "application_failed"
        item = diagnostic(code, error.message)
        @journal["status"] = mutated ? "partially_applied" : "refused"
        @journal["finished_at"] = now
        @journal["diagnostics"] << item
        @journal["diagnostics"] << diagnostic("partial_application", "Inspect recorded paths and Git state; no rollback or resume was attempted.") if mutated
        started = @journal["actions"].find { |action| action["state"] == "started" }
        if started
          started["state"] = "failed"
          started["diagnostics"] << item
          path = started["target_path"] && safe_path(@validator.roots.first, started["target_path"])
          started["observed"] = {"digest" => path&.file? ? digest(File.binread(path)) : nil, "mode" => path&.file? ? mode(path) : nil}
        end
        @journal["recovery"]["interruption_uncertainty"] = false
        persist!(initial: @journal_digest.nil?)
        [@journal, if mutated
                     5
                   else
                     error.is_a?(TransactionError) ? error.exit_code : 5
                   end]
      rescue TransactionError, SystemCallError, IOError => journal_error
        # The last successfully synchronised journal is deliberately left intact.
        fail!(mutated ? "partial_application" : "application_failed", "#{error.message}; application evidence could not be finalised: #{journal_error.message}", 5)
      end
    end
  end
end
