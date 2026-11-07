# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    class Assessor
      PROJECT_MARKERS = {"package.json" => "node", "pyproject.toml" => "python", "Gemfile" => "ruby", "mix.exs" => "elixir",
                         "Cargo.toml" => "rust", "go.mod" => "go", "composer.json" => "php", "pom.xml" => "java"}.freeze

      def initialize(target:, framework_root: File.expand_path("../../..", __dir__), selection: nil)
        @root = Pathname.new(target).expand_path.realpath
        raise Error, "target must be a directory" unless @root.directory?
        @registry = Registry.load(framework_root: framework_root)
        @selection = selection && Selection.new(selection, registry: @registry, root: @root)
        @scope = @selection ? @selection.scope : {"type" => "repository", "path" => "."}
      rescue SystemCallError => e
        raise Error, "invalid target repository: #{e.message.lines.first.strip}"
      end

      def assess
        prepare_inventory
        @providers = @registry.supported.to_h { |definition| [definition, @registry.provider(definition)] }
        candidates = @providers.flat_map do |definition, provider|
          detected = provider.detect(context)
          raise Error, "provider detect must return an array" unless detected.is_a?(Array)
          detected = Contracts.copy(detected)
          detected.each { |candidate| validate_candidate!(candidate, definition) }
        end
        @selection&.validate_candidates!(candidates)
        record_selection_uncertainties(candidates)
        candidates = Contracts.order(candidates.uniq)
        identities = candidates.map { |candidate| candidate.values_at("category", "id", "scope") }
        raise Error, "duplicate candidate identity for one scope" unless identities.uniq == identities
        result = base_result(candidates)
        if @selection
          contributions = collect_contributions
          evidence_ids = context.generic_evidence.map { |item| item["id"] }
          composed = Composer.new(definitions: @selection.definitions, scope: @scope,
            contributions: contributions, inputs: @selection.inputs, resolutions: @selection.document["resolutions"],
            component_ids: @registry.catalogue.components.map { |item| item["name"] }, evidence_ids: evidence_ids,
            initial_conflicts: scope_conflicts(candidates)).compose
          result.merge!(composed)
        else
          result["conflicts"] = scope_conflicts(candidates).map { |item| unselected_conflict(item) }
        end
        result["evidence"] = context.generic_evidence.sort_by { |item| item["id"] }
        validate_references!(result)
        Contracts.validate!("assessment", result)
        Contracts.copy(result)
      rescue ArgumentError, NoMethodError, KeyError, TypeError => e
        raise Error, "invalid adapter provider result: #{e.message.lines.first.strip}"
      end

      private

      def prepare_inventory
        scope_root = Contracts.contained!(@root, @scope["path"], directory: true)
        @inventory = Assessment::Inventory.new(scope_root).discover
        # Inventory already excludes known unsafe paths; also reject symlinked
        # ancestors of tracked files before generic detection or provider reads.
        @inventory.files.delete_if do |path, _|
          Contracts.contained!(scope_root, path, exists: true)
          false
        rescue Error
          true
        end
        generic = Assessment::Evidence.new
        analysis = Assessment::Detector.new(@inventory, @registry.catalogue, generic).analyze
        @generic_ecosystems = analysis.fetch(:ecosystem)
        @evidence = Assessment::Evidence.new
        generic.materialize.each do |item|
          path = item["path"]
          path = "#{@scope["path"]}/#{path}" if path && @scope["path"] != "."
          @evidence.add(type: item["type"], method: item["method"], summary: item["summary"], path: path)
        end
      end

      def context(inputs: {}, selected: [])
        Context.new(scope: @scope, inventory: @inventory, root: @root, evidence: @evidence, selected: selected, inputs: inputs)
      end

      def validate_candidate!(candidate, definition)
        Contracts.validate!("assessment", candidate, fragment: "candidate")
        unless candidate["category"] == definition.category && candidate["id"] == definition.id
          raise Error, "provider candidate identity must match its adapter"
        end
        Contracts.scope!(candidate["scope"], root: @root)
        candidate_path = candidate["scope"]["path"]
        Contracts.scoped_path!(candidate_path, @scope)
        if candidate["scope"] != @scope && candidate["scope"]["type"] != "workspace"
          raise Error, "nested candidate must identify an explicit workspace"
        end
      end

      def record_selection_uncertainties(candidates)
        return unless @selection
        @selection.definitions.each do |definition|
          matching = candidates.find { |item| item["category"] == definition.category && item["id"] == definition.id && item["scope"] == @scope }
          next if matching && matching["status"] == "detected"
          evidence = context.add_evidence(type: "assessor_context", method: "explicit_selection_without_detection",
            summary: "Selected #{definition.category}/#{definition.id} has no positive static detection in this scope; selection remains an explicit decision.")
          unless matching
            matching = definition.identity.merge("scope" => @scope, "status" => "not_detected", "confidence" => "low", "evidence" => [], "ambiguities" => [], "incompatible_evidence" => [])
            candidates << matching
          end
          matching["ambiguities"] = (matching["ambiguities"] + [evidence]).uniq.sort
        end
      end

      def collect_contributions
        set = Contributions.empty
        declarations = @selection.definitions.flat_map(&:input_definitions)
        known = declarations.to_h { |item| [item["key"], item] }
        @selection.inputs.each do |key, value|
          raise Error, "unknown explicit input: #{key}" unless known[key]
          InputValues.validate_value!(known[key], value)
        end
        selected = @selection.definitions.map(&:identity)
        @selection.definitions.each do |definition|
          own = @selection.inputs.select { |key, _| definition.input_definitions.any? { |item| item["key"] == key } }
          output = @providers.fetch(definition).contribute(context(inputs: own, selected: selected), inputs: Contracts.freeze_tree(Contracts.copy(own)))
          unless output.is_a?(Hash) && (output.keys - DOMAINS).empty? && output.values.all? { |items| items.is_a?(Array) }
            raise Error, "invalid provider contribution set"
          end
          output.each do |domain, records|
            records.each do |record|
              raise Error, "provider contributions must be records with an ID" unless record.is_a?(Hash) && record["id"].is_a?(String)
              raise Error, "provider cannot supply authoritative provenance" if record.key?("provenance")
              set[domain] << record.merge("provenance" => [definition.provenance(record["id"], @scope)])
            end
          end
        end
        # Validate filesystem mappings before the pure composer accepts paths.
        set.each_value do |records|
          records.each do |record|
            %w[path cwd scope].each do |field|
              next unless record[field].is_a?(String)
              directory = %w[cwd scope].include?(field)
              Contracts.contained!(@root, record[field], directory: directory)
            end
          end
        end
        @selection.document["resolutions"].each do |resolution|
          next unless resolution["kind"] == "override_command"
          command = resolution["value"]["command"]
          %w[cwd scope].each { |field| Contracts.contained!(@root, command[field], directory: true) }
        end
        set
      end

      def scope_conflicts(candidates)
        families = @inventory.files.keys.filter_map do |path|
          basename = File.basename(path)
          family = PROJECT_MARKERS[basename]
          family ||= "python" if basename.match?(/\A(?:requirements[^\/]*\.txt|uv\.lock)\z/)
          [path, family] if family
        end.to_h
        markers = families.keys
        roots = markers.map { |path| File.dirname(path) }.uniq
        conflicts = []
        if roots.size > 1 || markers.group_by { |path| File.dirname(path) }.any? { |_, files| files.map { |path| families.fetch(path) }.uniq.size > 1 }
          evidence = context.generic_evidence.select { |item| item["path"] && markers.any? { |path| item["path"] == ((@scope["path"] == ".") ? path : "#{@scope["path"]}/#{path}") } }
          conflicts << {"code" => "scope_conflict", "subject" => "multiple independently configured projects or ecosystems", "evidence_ids" => evidence.map { |item| item["id"] }}
        end
        if @selection
          selected_ecosystem = @selection.definitions.find { |entry| entry.category == "ecosystem" }.id
          @generic_ecosystems.each do |ecosystem|
            name = (ecosystem["name"] == "typescript") ? "node" : ecosystem["name"]
            next if name == "unsupported" || name == selected_ecosystem
            records = context.generic_evidence.select { |item| ecosystem["paths"].any? { |path| item["path"] == ((@scope["path"] == ".") ? path : "#{@scope["path"]}/#{path}") } }
            conflicts << {"code" => "repository_evidence_conflict", "subject" => "generic ecosystem evidence: #{name}", "evidence_ids" => records.map { |item| item["id"] }}
          end
          candidates.each do |candidate|
            contradictory = candidate["incompatible_evidence"].any? ||
              (candidate["category"] == "ecosystem" && candidate["status"] == "detected" && @selection.definitions.none? { |entry| entry.category == "ecosystem" && entry.id == candidate["id"] })
            next unless candidate["scope"] == @scope && contradictory
            conflicts << {"code" => "repository_evidence_conflict", "subject" => "#{candidate["category"]}/#{candidate["id"]}",
                          "evidence_ids" => (candidate["evidence"] + candidate["incompatible_evidence"]).uniq.sort}
          end
        end
        conflicts
      end

      def unselected_conflict(item)
        {"id" => Contracts.digest({"code" => item["code"], "scope" => @scope, "domain" => "compatibility", "subject" => item["subject"], "contributors" => []}),
         "code" => item["code"], "domain" => "compatibility", "scope" => @scope, "subject" => item["subject"], "severity" => "blocking", "blocking" => true,
         "status" => "unresolved", "contributors" => [], "evidence_ids" => item.fetch("evidence_ids", []), "description" => item["subject"], "allowed_resolutions" => [], "resolution" => nil}
      end

      def base_result(candidates)
        catalogue = @registry.catalogue
        {"schema_version" => 1, "kind" => "adapter_assessment",
         "framework" => {"metadata_schema_version" => 2, "version" => catalogue.framework_version, "source_revision" => catalogue.source_revision},
         "scope" => @scope, "candidates" => candidates, "selected" => selected_records,
         "compatibility" => {"status" => "not_selected", "checks" => []},
         "composition" => {"status" => "not_selected", "adapter_set_digest" => nil, "composition_digest" => nil,
                           "contributions" => Contributions.empty, "commands" => [], "explicit_inputs" => []},
         "conflicts" => [], "resolved_decisions" => [], "evidence" => []}
      end

      def selected_records
        return [] unless @selection
        @selection.definitions.map do |entry|
          selection = @selection.document["selected"].find { |item| item["category"] == entry.category && item["id"] == entry.id }
          selection.merge(entry.to_h.slice("version", "manifest_digest", "provider_digest")).merge("scope" => @scope)
        end
      end

      def validate_references!(result)
        ids = result["evidence"].map { |item| item["id"] }
        result["candidates"].each do |candidate|
          if candidate["status"] == "detected" && candidate["evidence"].empty?
            raise Error, "positive adapter detection requires static evidence"
          end
          result["evidence"].select { |item| candidate["evidence"].include?(item["id"]) && item["path"] }.each do |item|
            Contracts.scoped_path!(item["path"], candidate["scope"])
          end
        end
        references = result["candidates"].flat_map { |item| item["evidence"] + item["ambiguities"] + item["incompatible_evidence"] } +
          result["conflicts"].flat_map { |item| item["evidence_ids"] }
        raise Error, "unknown adapter evidence reference" unless (references - ids).empty?
      end
    end
  end
end
