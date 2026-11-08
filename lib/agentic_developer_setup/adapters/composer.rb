# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    # Pure composition: no filesystem, process or network access. The caller
    # supplies definitions from a validated Registry and validated evidence IDs.
    class Composer
      attr_reader :conflicts

      def initialize(definitions:, scope:, contributions:, inputs: {}, resolutions: [], component_ids: [], evidence_ids: [], initial_conflicts: [])
        @definitions, @scope = definitions, Contracts.copy(scope)
        @source_contributions = Contracts.freeze_tree(Contracts.copy(contributions))
        InputValues.validate_supplied!(inputs)
        @inputs, @resolutions = Contracts.copy(inputs), Contracts.copy(resolutions)
        @component_ids, @evidence_ids = component_ids, evidence_ids
        @initial_conflicts = Contracts.copy(initial_conflicts)
      end

      def compose
        @contributions = Contracts.copy(@source_contributions)
        validate_arguments!
        @conflicts, @checks, @used_resolutions = [], [], []
        compatibility
        @initial_conflicts.each do |item|
          conflict(item.fetch("code"), "compatibility", item.fetch("subject"), item.fetch("contributors", []), evidence: item.fetch("evidence_ids", []))
        end
        compose_inputs
        compose_findings
        compose_paths
        compose_services
        commands = compose_commands
        unknown = @resolutions.map { |item| item["conflict_id"] } - @used_resolutions
        raise Error, "stale, unknown or inapplicable resolution: #{unknown.sort.join(", ")}" unless unknown.empty?
        status = (@conflicts.any? { |item| item["blocking"] && item["status"] == "unresolved" }) ? "blocked" : "ready"
        set_digest = Contracts.digest({"scope" => @scope, "selected" => @definitions.map do |entry|
          entry.to_h.slice("category", "id", "version", "manifest_digest", "provider_digest")
        end.sort_by { |item| [item["category"], item["id"]] }})
        @contributions = normalize(@contributions)
        @contributions.each_value { |items| items.sort_by! { |item| item["id"] } }
        decisions = Contracts.order(@conflicts.filter_map { |item| item["resolution"] })
        composition_digest = Contracts.digest({"adapter_set_digest" => set_digest,
          "contributions" => @contributions, "inputs" => @inputs, "resolutions" => normalize(decisions), "status" => status})
        {"compatibility" => {"status" => (@conflicts.any? { |item| item["domain"] == "compatibility" && item["blocking"] }) ? "blocked" : "ready", "checks" => Contracts.order(@checks)},
         "composition" => {"status" => status, "adapter_set_digest" => set_digest, "composition_digest" => composition_digest,
                           "contributions" => @contributions, "commands" => commands.sort_by { |item| item["id"] },
                           "explicit_inputs" => @inputs.sort.map { |key, value| {"key" => key, "value" => value} }},
         "conflicts" => @conflicts.sort_by { |item| item["id"] }, "resolved_decisions" => decisions}
      end

      private

      UNORDERED = %w[profiles preconditions classification classifications evidence_ids related_finding_ids provenance command_ids required_for one_of allowed_values].freeze

      def normalize(value, key = nil)
        case value
        when Hash then value.to_h { |name, item| [name, normalize(item, name)] }
        when Array
          items = value.map { |item| normalize(item) }
          UNORDERED.include?(key) ? Contracts.order(items.uniq) : items
        else value
        end
      end

      def validate_arguments!
        Contracts.scope!(@scope)
        categories = @definitions.map(&:category)
        raise Error, "composition requires one ecosystem and at most one adapter per category" unless categories.include?("ecosystem") && categories.uniq == categories
        raise Error, "unsupported adapter" unless @definitions.all? { |item| item.is_a?(Definition) && item.status == "supported" }
        Contributions.validate!(@contributions, definitions: @definitions, scope: @scope, component_ids: @component_ids, evidence_ids: @evidence_ids)
        ids = @resolutions.map do |item|
          Contracts.validate!("selection", item, fragment: "resolution")
          item["conflict_id"]
        end
        raise Error, "duplicate conflict resolution" unless ids.uniq == ids
      end

      def origins(records)
        Contracts.order(records.flat_map { |record| record.fetch("provenance") }.uniq)
      end

      def conflict(code, domain, subject, contributors, allowed: [], evidence: [])
        identities = contributors.map { |item| item.slice("category", "adapter_id", "adapter_version") }.uniq
        id = Contracts.digest({"code" => code, "scope" => @scope, "domain" => domain, "subject" => subject,
                               "contributors" => Contracts.order(identities)})
        existing = @conflicts.find { |item| item["id"] == id }
        return existing if existing
        record = {"id" => id, "code" => code, "domain" => domain, "scope" => @scope, "subject" => subject,
                  "severity" => "blocking", "blocking" => true, "status" => "unresolved", "contributors" => Contracts.order(contributors.uniq),
                  "evidence_ids" => evidence.uniq.sort, "description" => "#{code}: #{subject}",
                  "allowed_resolutions" => allowed.sort, "resolution" => nil}
        @conflicts << record
        resolution = @resolutions.find { |item| item["conflict_id"] == id }
        if resolution
          raise Error, "forbidden or inapplicable conflict resolution" unless allowed.include?(resolution["kind"])
          @used_resolutions << id
          record["resolution"] = resolution
          record["status"] = "resolved"
        end
        record
      end

      def compatibility
        @definitions.sort_by { |entry| [entry.category, entry.id] }.each do |entry|
          entry.compatibility.each do |kind, requirements|
            requirements.each do |requirement|
              matching = @definitions.select { |other| other.category == requirement["category"] && requirement["one_of"].include?(other.id) }
              eligible = matching.select { |other| Registry.requirement(requirement["version"]).satisfied_by?(Registry.version(other.version)) }
              outcome = if kind == "requires"
                if matching.empty?
                  "missing"
                elsif eligible.empty?
                  "version_incompatible"
                else
                  "satisfied"
                end
              else
                eligible.empty? ? "satisfied" : "incompatible"
              end
              @checks << {"adapter" => entry.identity, "kind" => kind, "requirement" => requirement,
                          "involved_adapters" => matching.map { |other| other.identity.merge("version" => other.version) }, "outcome" => outcome}
              next if outcome == "satisfied"
              code = {"missing" => "missing_required_adapter", "version_incompatible" => "adapter_version_incompatible", "incompatible" => "incompatible_adapters"}.fetch(outcome)
              conflict(code, "compatibility", "#{entry.category}/#{entry.id}:#{kind}:#{Contracts.digest(normalize(requirement))}",
                ([entry] + matching).map { |other| other.provenance("compatibility", @scope) })
            end
          end
        end
      end

      def compose_inputs
        manifest_declarations = @definitions.flat_map do |entry|
          entry.input_definitions.map { |item| item.merge("id" => "#{entry.category}/#{entry.id}:input:#{item["key"]}", "provenance" => [entry.provenance("#{entry.category}/#{entry.id}:input:#{item["key"]}", @scope)]) }
        end
        declarations = manifest_declarations + @contributions["inputs"]
        declarations.each { |item| InputValues.validate_declaration!(item) }
        unknown = @inputs.keys - manifest_declarations.map { |item| item["key"] }
        raise Error, "unknown explicit input: #{unknown.join(", ")}" unless unknown.empty?
        declarations.group_by { |item| item["key"] }.sort.each do |key, items|
          semantic = items.map { |item| normalize(item.except("id", "provenance")) }.uniq
          if semantic.length > 1
            conflict("input_definition_conflict", "inputs", key, origins(items))
          else
            definition = items.first
            InputValues.validate_value!(definition, @inputs[key]) if @inputs.key?(key)
            if definition["required"] && !@inputs.key?(key)
              conflict("unresolved_required_input", "inputs", key, origins(items))
            end
          end
        end
      end

      def compose_findings
        remapped = {}
        groups = @contributions["findings"].group_by { |item| item["equivalence_id"] || item["id"] }
        @contributions["findings"] = groups.values.flat_map do |items|
          semantic = items.map { |item| item.slice("category", "severity", "confidence", "summary") }.uniq
          if items.size > 1 && semantic.size == 1 && items.all? { |item| item["equivalence_id"] }
            chosen = items.min_by { |item| item["id"] }
            items.each { |item| remapped[item["id"]] = chosen["id"] }
            [chosen.merge("provenance" => origins(items), "evidence_ids" => items.flat_map { |item| item["evidence_ids"] }.uniq.sort,
              "related_finding_ids" => items.flat_map { |item| item["related_finding_ids"] }.uniq.sort)]
          else
            items
          end
        end
        @contributions["findings"].each do |item|
          item["related_finding_ids"] = item["related_finding_ids"].map { |id| remapped.fetch(id, id) }.uniq.sort
        end
      end

      def compose_paths
        paths = @contributions["paths"]
        pending = paths.select { |item| item["owner"] }.dup
        until pending.empty?
          group = [pending.shift]
          loop do
            connected = pending.select do |entry|
              group.any? do |other|
                entry["path"] == other["path"] || ancestor?(entry, other) || ancestor?(other, entry)
              end
            end
            break if connected.empty?
            group.concat(connected)
            pending -= connected
          end
          owners = group.map { |item| item["owner"] }.uniq
          next unless owners.size > 1
          subject = JSON.generate(group.map { |item| item["path"] }.uniq.sort)
          record = conflict("path_ownership_conflict", "paths", subject, origins(group), allowed: ["choose_path_owner"])
          if record["resolution"]
            owner = record["resolution"]["value"]["owner"]
            raise Error, "path owner resolution must choose a declared owner" unless owners.include?(owner)
            group.each do |path|
              path["original_owner"] = path["owner"]
              path["owner"] = owner
              path["ownership_resolution_id"] = record["id"]
            end
          end
        end
        # Source records are retained; union classifications on overlapping
        # records so no consumer can mistake an ownership decision for removal
        # of a safety classification.
        original = Contracts.copy(paths)
        paths.each do |path|
          protections = original.select { |other| other["path"] == path["path"] || ancestor?(other, path) }
          path["classifications"] = protections.flat_map { |item| item["classifications"] }.uniq.sort
        end
      end

      def ancestor?(parent, child)
        parent["recursive"] && (parent["path"] == "." || child["path"].start_with?("#{parent["path"]}/"))
      end

      def compose_services
        @contributions["services"].group_by { |item| item["service_id"] }.sort.each do |id, records|
          needs = records.select { |item| item["kind"] == "requirement" }
          bindings = records.select { |item| item["kind"] == "binding" }
          if needs.any? && bindings.empty?
            conflict("unresolved_required_input", "services", id, origins(records))
          elsif bindings.map { |item| item["implementation"] }.uniq.length > 1
            conflict("service_binding_conflict", "services", id, origins(records))
          end
        end
      end

      def compose_commands
        bases, refinements = @contributions["commands"].partition { |item| item["kind"] == "base" }
        command_ids = bases.map { |item| item["id"] }
        (@contributions["command_wrappers"] + refinements).each do |item|
          unless command_ids.include?(item["command_id"])
            conflict("metadata_inconsistency", "commands", "unknown command #{item["command_id"]}", origins([item]))
          end
        end
        @contributions["validation_profiles"].each do |item|
          if (item["command_ids"] - command_ids).any?
            conflict("metadata_inconsistency", "validation_profiles", item["id"], origins([item]))
          end
        end
        bases.group_by { |item| [item["scope"], item["capability"]] }.sort.flat_map do |(scope, capability), proposals|
          command = select_command(proposals, "#{scope}:#{capability}")
          next [] unless command
          applies = refinements.select { |item| item["command_id"] == command["id"] }
          applies.each do |refinement|
            %w[profiles preconditions classification].each { |key| command[key] = (command[key] + refinement[key]).uniq.sort }
          end
          command["provenance"] = origins([command] + applies)
          profiles = @contributions["validation_profiles"].select { |item| item["command_ids"].include?(command["id"]) }
          command["profiles"] = (command["profiles"] + profiles.map { |item| item["profile"] }).uniq.sort
          command["provenance"] = origins([command] + profiles)
          wrap(command)
        end
      end

      def select_command(proposals, subject)
        proposals = proposals.sort_by { |item| item["id"] }
        if proposals.length == 1
          return final_command(proposals.first)
        end
        semantic = proposals.map { |item| normalize(item.except("id", "provenance")) }.uniq
        code = (semantic.size == 1) ? "duplicate_capability_ownership" : "incompatible_command_proposals"
        record = conflict(code, "commands", subject, origins(proposals), allowed: %w[choose_command override_command])
        decision = record["resolution"]
        return nil unless decision
        if decision["kind"] == "choose_command"
          chosen = proposals.find { |item| item["id"] == decision["value"]["contribution_id"] }
          raise Error, "choose_command must identify a conflicting contribution" unless chosen
          final_command(chosen).merge("decision_source" => record["id"], "overridden_contribution_ids" => (proposals - [chosen]).map { |item| item["id"] })
        else
          override = decision["value"]["command"]
          unrelated = @contributions["commands"].any? { |item| item["id"] == override["id"] && !proposals.include?(item) }
          raise Error, "override command ID collides with an unrelated contribution" if unrelated
          Contributions.command!(override, @scope)
          unless override["scope"] == proposals.first["scope"] && override["capability"] == proposals.first["capability"]
            raise Error, "override_command must retain the conflicting scope and capability"
          end
          final_command(override.merge("provenance" => origins(proposals))).merge("decision_source" => record["id"], "overridden_contribution_ids" => proposals.map { |item| item["id"] })
        end
      end

      def final_command(command)
        Contracts.copy(command).merge("wrapper_ids" => [], "decision_source" => nil, "overridden_contribution_ids" => [])
      end

      def wrap(command)
        wrappers = @contributions["command_wrappers"].select { |item| item["command_id"] == command["id"] }.sort_by { |item| item["id"] }
        wrapper = wrappers.first if wrappers.length == 1
        if wrappers.length > 1
          record = conflict("command_wrapper_conflict", "command_wrappers", command["id"], origins(wrappers), allowed: ["choose_wrapper"])
          if record["resolution"]
            wrapper = wrappers.find { |item| item["id"] == record["resolution"]["value"]["contribution_id"] }
            raise Error, "choose_wrapper must identify a conflicting wrapper" unless wrapper
          end
        end
        if wrapper
          env = wrapper.fetch("env", {})
          mismatched = env.keys.select { |key| command["env"].key?(key) && command["env"][key] != env[key] }
          mismatched.each { |key| conflict("command_environment_conflict", "commands", "#{command["id"]}:#{key}", origins([command, wrapper])) }
          if wrapper["cwd"] && wrapper["cwd"] != command["cwd"]
            conflict("metadata_inconsistency", "commands", "cwd:#{command["id"]}", origins([command, wrapper]))
          end
          command["env"] = command["env"].merge(env) if mismatched.empty?
          command["argv"] = wrapper["prefix_argv"] + command["argv"] + wrapper["suffix_argv"]
          command["wrapper_ids"] = [wrapper["id"]]
          command["provenance"] = origins([command, wrapper])
        end
        Contributions.command!(command, @scope)
        [normalize(command)]
      end
    end
  end
end
