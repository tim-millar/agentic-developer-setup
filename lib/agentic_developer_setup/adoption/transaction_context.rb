# frozen_string_literal: true

require_relative "transaction_support"

module AgenticDeveloperSetup
  module Adoption
    class TransactionContext
      include TransactionSupport

      attr_reader :target, :source, :target_head, :revision, :catalogue, :entries, :scope,
        :metadata, :metadata_input, :inputs, :decisions, :commands, :selection, :diagnostics, :reviewed_files

      def initialize(target:, source:, operation:, effective_date:, scope: nil, components: [], tier: nil, exclusions: [],
        decisions: nil, assessment: nil, validation_spec: nil, clean: true)
        @operation = operation
        fail!("unsupported_operation", "unsupported operation: #{operation}", 2) unless OPERATIONS.include?(operation)
        fail!("invalid_invocation", "effective date must be an ISO calendar date", 2) unless effective_date.is_a?(String) && effective_date.match?(DATE_PATTERN) && Date.iso8601(effective_date).iso8601 == effective_date
        @target, @target_head = repository(target, "target", clean: clean)
        @source, @revision = repository(source, "source")
        fail!("unsafe_path", "source and target must be distinct and non-overlapping", 3) if inside?(@target, @source) || inside?(@source, @target)
        @roots = [@target, @source]
        catalogue_path = safe_path(@source, "framework.yml")
        fail!("invalid_catalogue", "framework.yml must be a regular tracked file", 3) unless catalogue_path.file?
        catalogue_entry = git!(@source, "ls-files", "--stage", "-z", "--", "framework.yml").split("\0")
        fail!("invalid_catalogue", "catalogue must be tracked as a regular Git file", 3) unless catalogue_entry.length == 1 && catalogue_entry.first.match?(/\A100(?:644|755) /)
        catalogue_blob = git!(@source, "cat-file", "blob", catalogue_entry.first.split(/\s+/)[1])
        fail!("invalid_catalogue", "catalogue differs from committed source snapshot", 3) unless catalogue_blob.b == File.binread(catalogue_path)
        @catalogue = load_yaml(catalogue_path)
        errors = FrameworkCatalogue.document_errors(@source, @catalogue)
        fail!("invalid_catalogue", errors.join("; "), 3) unless errors.empty?
        @entries = @catalogue.fetch("baseline").values_at("required", "recommended").flatten.to_h { |item| [item["name"], item] }
        unless @entries.values.all? { |entry| FrameworkCatalogue.baseline_entry_shape_valid?(entry) && PathSafety.safe_relative?(entry["source_path"]) && PathSafety.safe_relative?(entry["target_path"]) }
          fail!("invalid_catalogue", "all catalogue component paths must be safe repository-relative paths", 3)
        end
        @diagnostics = []
        load_metadata(scope)
        @selection = resolve_selection(components, tier, exclusions)
        @inputs = {"metadata" => @metadata_input}
        @decisions = load_decisions(decisions)
        @reviewed_files = @decisions.values.select { |item| item["disposition"] == "specialised" }.to_h { |item| [item["id"], reviewed_file(item)] }
        load_assessment(assessment)
        @commands = load_commands(validation_spec)
        identities_distinct!(@inputs.values.filter_map { |input| input.is_a?(Hash) && input["path"] })
        validate_current_metadata
      rescue Date::Error
        fail!("invalid_invocation", "effective date must be an ISO calendar date", 2)
      end

      def source_identity
        {"root" => source.to_s, "revision" => revision, "version" => catalogue.dig("framework", "framework_version"), "catalogue_digest" => digest(File.binread(source.join("framework.yml")))}
      end

      def target_identity
        {"root" => target.to_s, "head" => target_head, "scope" => scope}
      end

      def source_required?(id)
        @operation == "update_inherited" ||
          (%w[initial_adoption add_components].include?(@operation) && %w[inherited specialised].include?(decisions.fetch(id)["disposition"]))
      end

      def source_file(id)
        relative = entries.fetch(id).fetch("source_path")
        path = safe_path(source, relative)
        fail!("source_unavailable", "selected source is not a readable regular file: #{relative}", 3) unless path.file? && path.readable?
        entry = git!(source, "ls-files", "--stage", "-z", "--", relative).split("\0")
        fail!("source_unavailable", "selected source must be tracked: #{relative}", 3) unless entry.length == 1 && entry.first.split("\t", 2).last == relative
        git_mode, object, stage = entry.first.split(/\s+/, 4)
        supported = {"100644" => "0644", "100755" => "0755"}[git_mode]
        fail!("unsafe_path", "source mode must be 0644 or 0755: #{relative}") unless stage == "0" && supported && mode(path) == supported
        # Also compare blob bytes: clean status alone can be hidden by skip-worktree/assume-unchanged.
        blob = git!(source, "cat-file", "blob", object)
        fail!("invalid_source", "source bytes differ from tracked blob: #{relative}", 3) unless blob.b == File.binread(path)
        {"path" => relative, "digest" => digest(blob), "mode" => supported}
      end

      def effective_target(id)
        relative = entries.fetch(id).fetch("target_path")
        (scope["path"] == ".") ? relative : "#{scope["path"]}/#{relative}"
      end

      def reviewed_file(decision)
        path = external(decision.fetch("content_path"), @roots, present: true)
        fail!("invalid_decision", "reviewed content_path must be canonical and absolute", 2) unless decision["content_path"].start_with?("/")
        fail!("invalid_decision", "reviewed content mode must be 0644 or 0755", 2) unless %w[0644 0755].include?(mode(path))
        {"path" => path.to_s, "digest" => digest(File.binread(path)), "mode" => mode(path)}
      end

      private

      def load_metadata(requested_scope)
        path = safe_path(target, METADATA_PATH)
        fail!("invalid_metadata", "metadata is not a regular file", 3) if path.exist? && !path.file?
        if path.file?
          fail!("ownership_conflict", "initial adoption requires absent metadata") if @operation == "initial_adoption"
          walk_yaml(Psych.parse_stream(File.binread(path)))
          @metadata = Metadata.load(target).document
          fail!("invalid_metadata", "metadata could not be read", 3) unless @metadata.is_a?(Hash)
          schema_errors = Schema.load(ROOT.join("schemas/framework-adoption-v1.schema.json")).validate(@metadata)
          fail!("invalid_metadata", schema_errors.join("; "), 3) unless schema_errors.empty?
          @scope = @metadata["scope"]
          @metadata_input = {"status" => "present", "digest" => digest(File.binread(path))}
          fail!("ownership_conflict", "existing scope cannot change") if requested_scope && requested_scope != @scope&.fetch("path", nil)
          if %w[add_components reconcile_inherited].include?(@operation) && @metadata.dig("framework", "revision") != revision
            fail!("provenance_unavailable", "source HEAD must equal the recorded framework revision")
          end
        else
          fail!("invalid_metadata", "operation requires existing adoption metadata", 3) unless @operation == "initial_adoption"
          fail!("invalid_invocation", "--scope is required for initial adoption", 2) unless requested_scope
          @scope = {"type" => (requested_scope == ".") ? "repository" : "workspace", "path" => requested_scope}
          @metadata_input = {"status" => "absent", "digest" => nil}
        end
        fail!("invalid_metadata", "invalid scope", 3) unless scope.is_a?(Hash) && %w[repository workspace].include?(scope["type"]) && ((scope["type"] == "repository") == (scope["path"] == "."))
        scope_path = safe_path(target, scope["path"])
        fail!("unsafe_path", "scope must be an existing directory") unless scope_path.directory?
      end

      def resolve_selection(components, tier, exclusions)
        [components, exclusions].each do |ids|
          fail!("duplicate_component", "selection IDs must not repeat", 2) unless ids.uniq == ids
          ids.each { |id| fail!("unknown_component", "unknown component #{id}", 2) unless entries.key?(id) }
        end
        fail!("ambiguous_selection", "explicit components cannot also be excluded", 2) unless (components & exclusions).empty?
        fail!("invalid_invocation", "select at least one --component or --tier", 2) if components.empty? && tier.nil?
        selected = components.dup
        if tier
          fail!("unsupported_operation", "tiers apply only to initial/add operations", 2) unless %w[initial_adoption add_components].include?(@operation)
          index = %w[tier-1 tier-2 tier-3].index(tier)
          fail!("ambiguous_selection", "unknown tier #{tier}", 2) unless index
          (1..index + 1).each do |number|
            definition = catalogue["adoption_tiers"].find { |item| item["id"] == "tier-#{number}" }
            fail!("ambiguous_selection", "tier mapping is missing", 2) unless definition
            definition["includes"].each do |path|
              matches = entries.values.select { |entry| entry["target_path"] == path }
              fail!("ambiguous_selection", "tier path must resolve exactly once: #{path}", 2) unless matches.length == 1
              selected << matches.first["name"]
            end
          end
        end
        resolved = (selected.uniq - exclusions).sort
        fail!("ambiguous_selection", "selection resolved to no components", 2) if resolved.empty?
        {"requested_components" => components.sort, "requested_tier" => tier, "excluded_components" => exclusions.sort, "resolved_components" => resolved}
      end

      def input(kind, path)
        unless path
          @inputs[kind] = nil
          return nil
        end
        path = external(path, @roots, present: true)
        raw_digest = digest(File.binread(path))
        document = load_yaml(path)
        fail!("plan_stale", "input changed while reading: #{path}") unless digest(File.binread(path)) == raw_digest
        @inputs[kind] = {"path" => path.to_s, "digest" => raw_digest}
        document
      end

      def load_decisions(path)
        document = input("decisions", path)
        if document.nil? && @operation == "update_inherited"
          return selection["resolved_components"].to_h { |id| [id, {"id" => id, "disposition" => "update_inherited"}] }
        end
        fail!("invalid_decision", "explicit decisions are required", 2) unless document
        schema!("decisions", document)
        decisions = document["components"]
        ids = decisions.map { |item| item["id"] }
        fail!("duplicate_component", "duplicate decision IDs", 2) unless ids.uniq == ids
        fail!("invalid_decision", "decisions must exactly cover selection", 2) unless ids.sort == selection["resolved_components"]
        decisions.each do |decision|
          fail!("invalid_decision", "decision strings must not be blank", 2) if decision.values.any? { |value| value.is_a?(String) && value.strip.empty? }
          if decision["local_ownership"]&.any? { |item| item.strip.empty? }
            fail!("invalid_decision", "local_ownership must not be blank", 2)
          end
          expected = case @operation
          when "initial_adoption", "add_components" then %w[inherited specialised repository_owned deferred declined]
          when "update_inherited" then ["update_inherited"]
          when "reconcile_inherited" then ["convert_to_specialised"]
          end
          fail!("unsupported_operation", "decision not supported by selected operation", 2) unless expected.include?(decision["disposition"])
        end
        decisions.to_h { |item| [item["id"], item] }
      end

      def load_assessment(path)
        document = input("assessment", path)
        return unless document
        Assessment::Schema.validate!(document)
        git = document.dig("repository", "git")
        fail!("plan_stale", "assessment does not match target identity and clean Git state") unless document.dig("repository", "root") == target.to_s && git["detected"] && git["commit"] == target_head && git["working_tree"] == "clean"
      rescue Assessment::SchemaError => e
        fail!("invalid_document", e.message, 2)
      end

      def load_commands(path)
        document = input("validation_spec", path)
        return [] unless document
        schema!("validation", document)
        TransactionValidation.validate_commands!(document["commands"])
        document["commands"]
      end

      def validate_current_metadata
        return unless metadata
        validator = Validator.new(root: target, framework_root: source, schema_path: ROOT.join("schemas/framework-adoption-v1.schema.json"))
        diagnostics = validator.validate(metadata)
        diagnostics.each do |item|
          next if @operation == "reconcile_inherited" && item.code == "inherited_digest_mismatch" && selection["resolved_components"].include?(item.component_id)
          @diagnostics << item.to_h.merge("code" => "invalid_metadata")
        end
      rescue Assessment::Error => e
        fail!("invalid_metadata", e.message, 3)
      end
    end
  end
end
