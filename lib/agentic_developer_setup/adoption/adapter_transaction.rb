# frozen_string_literal: true

require_relative "../adapters"
require_relative "adapter_metadata"

module AgenticDeveloperSetup
  module Adoption
    module AdapterSourceVerification
      include TransactionSupport

      # Verify every provider the public assessor will load, before any Ruby is evaluated.
      def verify_adapter_sources!(framework_source)
        committed_regular_file!(framework_source, "framework.yml")
        registry = Adapters::Registry.load(framework_root: framework_source)
        registry.supported.each do |definition|
          %w[manifest provider].each do |kind|
            name = (kind == "manifest") ? "adapter.yml" : "adapter.rb"
            identity = committed_regular_file!(framework_source, "#{definition.source_path}/#{name}")
            fail!("invalid_source", "adapter #{kind} digest differs from committed source") unless identity["digest"] == definition.public_send("#{kind}_digest")
          end
        end
        registry
      rescue Adapters::Error => e
        fail!("invalid_adapter_source", e.message, 3)
      end
    end

    class TransactionContext
      include AdapterSourceVerification

      attr_reader :adapter_assessment, :adapter_decision_document, :adapter_selection_document

      def adapter_transaction(actions, document, date)
        composition = adapter_assessment.fetch("composition")
        previous = metadata && metadata["adapters"]
        selected = adapter_assessment["selected"].map do |item|
          item.slice("category", "id", "version", "manifest_digest", "provider_digest").merge("selection_source" => item["source"])
        end.sort_by { |item| [item["category"], item["id"]] }
        changes = validate_adapter_changes!(previous, selected)
        bindings = approved_bindings(previous)
        contributions = composition.fetch("contributions")
        records = contributions.values.flatten.to_h { |item| [item["id"], item] }
        referenced = bindings.flat_map { |item| item["provenance"].map { |origin| origin["contribution_id"] } }
        reviews = previous ? Adapters::Contracts.copy(previous["reviewed_files"]) : []
        adapter_decision_document["components"].each do |decision|
          action = actions.find { |item| item["component_id"] == decision["id"] }
          ids = decision["contribution_ids"]
          fail!("invalid_decision", "unknown or inapplicable contribution reference", 2) unless ids.all? do |id|
            record = records[id]
            record && (record["component_id"].nil? || record["component_id"] == decision["id"])
          end
          fail!("invalid_decision", "file command reference must be explicitly approved", 2) unless (decision["approved_command_ids"] - bindings.map { |item| item["command_id"] }).empty?
          referenced.concat(ids)
          origins = ids.flat_map { |id| records.fetch(id)["provenance"] }
          origins.concat(bindings.select { |item| decision["approved_command_ids"].include?(item["command_id"]) }.flat_map { |item| item["provenance"] })
          review = {"component_id" => decision["id"], "target_path" => effective_target(decision["id"]),
                    "approved_content_digest" => action["reviewed_content"]["digest"], "approved_mode" => action["reviewed_content"]["mode"],
                    "source_adapter_provenance" => Adapters::Contracts.order(origins.uniq), "contribution_ids" => ids.sort,
                    "approved_command_ids" => decision["approved_command_ids"].sort, "review_state" => "current"}
          reviews.reject! { |item| item["component_id"] == decision["id"] }
          reviews << review
        end
        affected_categories = changes
        if previous && (previous["composition_digest"] != composition["composition_digest"] || previous["command_bindings"] != bindings)
          affected_categories = previous["selected"].map { |item| item["category"] }
        end
        retain_reviewed_files!(reviews, previous, affected_categories, actions)
        approved = contributions.to_h { |domain, items| [domain, items.select { |item| referenced.include?(item["id"]) }.sort_by { |item| item["id"] }] }
        fail!("invalid_composition", "approved command provenance does not resolve to composed contributions") unless (referenced - records.keys).empty?
        proposed = {"source" => source_identity.slice("revision", "catalogue_digest"), "selected" => selected,
                    "inputs" => composition["explicit_inputs"], "resolutions" => adapter_assessment["resolved_decisions"],
                    "command_bindings" => bindings, "reviewed_files" => reviews.sort_by { |item| item["component_id"] },
                    "adapter_set_digest" => composition["adapter_set_digest"], "composition_digest" => composition["composition_digest"],
                    "adopted_at" => previous ? previous["adopted_at"] : date, "updated_at" => date}
        proposed["updated_at"] = previous["updated_at"] if previous && previous.except("updated_at") == proposed.except("updated_at")
        document["schema_version"] = 2
        document["adapters"] = proposed
        changed = metadata.nil? || metadata["schema_version"] != 2 || previous != proposed || actions.any? { |item| item["action"] != "no_change" }
        document["framework"]["updated_at"] = date if changed
        {"previous_adapters" => previous, "proposed_adapters" => proposed,
         "selection_document" => adapter_selection_document, "approved_decisions" => adapter_decision_document,
         "composition" => composition.slice("status", "adapter_set_digest", "composition_digest").merge(
           "selected" => adapter_assessment["selected"], "approved_contributions" => approved, "conflicts" => adapter_assessment["conflicts"]
         )}
      end

      private

      def load_adapter_decision_document
        path = external(@adapter_decisions_path, @roots, present: true)
        document = schema!("adapter-decisions", load_yaml(path))
        %w[adapter_changes commands components retained_files].each do |key|
          field = {"adapter_changes" => "category", "commands" => "command_id", "components" => "id", "retained_files" => "component_id"}.fetch(key)
          ids = document[key].map { |item| item[field] }
          fail!("invalid_decision", "duplicate #{key} decisions", 2) unless ids.uniq == ids
          document[key].sort_by! { |item| item[field] }
        end
        document["components"].each do |item|
          %w[local_ownership contribution_ids approved_command_ids].each { |key| item[key].sort! }
        end
        document
      end

      def adapter_component_selection
        ids = adapter_decision_document["components"].map { |item| item["id"] }.sort
        fail!("unknown_component", "adapter file decisions require declared baseline components", 2) unless (ids - entries.keys).empty?
        {"requested_components" => [], "requested_tier" => nil, "excluded_components" => [], "resolved_components" => ids}
      end

      def adapter_component_decisions
        @inputs["decisions"] = nil
        adapter_decision_document["components"].to_h do |item|
          [item["id"], item.merge("adapter_disposition" => item["disposition"], "disposition" => "specialised")]
        end
      end

      def load_adapter_inputs
        if @operation == "adopt_adapters"
          fail!("unsupported_operation", "existing adapter metadata requires update_adapters", 2) if metadata && metadata["schema_version"] == 2
        else
          fail!("unsupported_operation", "update_adapters requires adopted v2 adapter metadata", 2) unless metadata && metadata["schema_version"] == 2
        end
        document = input("adapter_decisions", @adapter_decisions_path)
        fail!("plan_stale", "adapter decisions changed while reading") unless canonical_decisions(document) == adapter_decision_document
        @adapter_selection_document = input("adapter_selection", @adapter_selection_path)
        verify_adapter_sources!(source)
        @adapter_assessment = Adapters::Assessor.new(target: target, framework_root: source, selection: @adapter_selection_document).assess
        fail!("invalid_decision", "selected adapter scope differs from adoption scope", 2) unless @adapter_assessment["scope"] == scope
        @adapter_selection_document = Adapters::Contracts.copy(@adapter_selection_document)
        @adapter_selection_document["selected"].sort_by! { |item| [item["category"], item["id"]] }
        @adapter_selection_document["inputs"].sort_by! { |item| item["key"] }
        @adapter_selection_document["resolutions"].sort_by! { |item| item["conflict_id"] }
        if @adapter_assessment.dig("composition", "status") != "ready"
          @diagnostics << diagnostic("adapter_composition_blocked", "Adapter composition is blocked; inspect conflicts and supply reviewed compatible inputs.")
        end
      rescue Adapters::Error => e
        fail!("invalid_adapter_request", e.message, 2)
      end

      def canonical_decisions(document)
        # Parse again through the same closed decision contract, preserving raw input identity separately.
        schema!("adapter-decisions", document)
        result = Adapters::Contracts.copy(document)
        {"adapter_changes" => "category", "commands" => "command_id", "components" => "id", "retained_files" => "component_id"}.each { |key, field| result[key].sort_by! { |item| item[field] } }
        result["components"].each { |item| %w[local_ownership contribution_ids approved_command_ids].each { |key| item[key].sort! } }
        result
      end

      def validate_adapter_changes!(previous, selected)
        old = previous ? previous["selected"].to_h { |item| [item["category"], item] } : {}
        proposed = selected.to_h { |item| [item["category"], item] }
        fail!("unsupported_operation", "removing a selected adapter category is unsupported", 2) unless (old.keys - proposed.keys).empty?
        changed = proposed.keys.select { |category| old[category] != proposed[category] }
        decisions = adapter_decision_document["adapter_changes"]
        if previous.nil?
          fail!("invalid_decision", "initial adapter_changes must be empty", 2) unless decisions.empty?
          return []
        end
        fail!("invalid_decision", "adapter changes require exact explicit review", 2) unless decisions.map { |item| item["category"] }.sort == changed.sort
        decisions.each do |item|
          fail!("invalid_decision", "stale adapter change identity", 2) unless item["previous"] == old[item["category"]] && item["proposed"] == proposed[item["category"]]
        end
        changed
      end

      def approved_bindings(previous)
        prior = previous ? previous["command_bindings"] : []
        commands = adapter_assessment.dig("composition", "commands").to_h { |item| [item["id"], item] }
        decisions = adapter_decision_document["commands"]
        approved = decisions.select { |item| item["disposition"] == "approve" }
        retired = decisions.select { |item| item["disposition"] == "retire" }.map { |item| item["command_id"] }
        prior_ids = prior.map { |item| item["command_id"] }
        fail!("invalid_decision", "retirement requires a previously approved binding", 2) unless (retired - prior_ids).empty?
        fail!("invalid_decision", "previous binding omitted without retirement", 2) unless (prior_ids - approved.map { |item| item["command_id"] } - retired).empty?
        approved.map do |item|
          command = commands[item["command_id"]]
          fail!("invalid_decision", "approval requires an effective composed command", 2) unless command
          command.slice("capability", "scope", "argv", "cwd", "env", "profiles", "preconditions", "classification", "provenance")
            .merge("command_id" => item["command_id"], "rationale" => item["rationale"])
        end.sort_by { |item| item["command_id"] }
      end

      def retain_reviewed_files!(reviews, previous, changes, actions)
        replaced = actions.map { |item| item["component_id"] }
        affected = previous ? previous["reviewed_files"].select do |review|
          !replaced.include?(review["component_id"]) && review["source_adapter_provenance"].any? { |origin| changes.include?(origin["category"]) }
        end : []
        retained = adapter_decision_document["retained_files"].map { |item| item["component_id"] }
        fail!("invalid_decision", "affected reviewed files require exact retention or replacement decisions", 2) unless retained.sort == affected.map { |item| item["component_id"] }.sort
        reviews.each { |item| item["review_state"] = "retained_after_adapter_change" if retained.include?(item["component_id"]) }
      end
    end
  end
end
