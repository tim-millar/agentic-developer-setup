# frozen_string_literal: true

require "pathname"

module AgenticDeveloperSetup
  module Assessment
    class Schema
      TOP_LEVEL = %w[
        schema_version framework assessment repository scope ecosystem tooling validation
        documentation framework_adoption readiness tier_recommendation component_recommendations
        gaps risks roadmap assessor_context assumptions unknowns evidence
      ].freeze
      CONFIDENCES = %w[high medium low].freeze
      READINESS_STATUSES = %w[ready partial missing blocked not_applicable unknown].freeze
      EVIDENCE_TYPES = Evidence::TYPES
      RECOMMENDATION_STATES = Assessor::RECOMMENDATION_STATES
      SEVERITIES = %w[blocking high medium low].freeze
      ECOSYSTEMS = %w[node typescript python unsupported].freeze
      ECOSYSTEM_ROLES = %w[primary secondary].freeze
      TOOL_STATUSES = %w[detected conflicting not_detected].freeze
      VALIDATION_STATUSES = %w[implementation_detected configuration_detected documented_command_detected ci_invocation_detected not_detected unknown].freeze
      VALIDATION_ALIGNMENT_STATUSES = %w[ready partial blocked not_applicable unknown].freeze
      DOCUMENTATION_STATUSES = %w[present not_detected].freeze
      DISCOVERABILITY = %w[obvious unknown].freeze
      CAPABILITIES = %w[
        tests linting formatting static_type_checking build_compile standard_local_verification
        ci_execution local_hooks validation_documentation
      ].freeze
      DOCUMENTATION_CATEGORIES = %w[
        root_readme development_guide architecture domain testing security deployment_operations
        adrs agent_instructions issue_templates pull_request_template ownership
      ].freeze

      def self.validate!(result)
        errors = new(result).validate
        raise SchemaError, "assessment schema invalid: #{errors.join('; ')}" unless errors.empty?

        true
      end

      def initialize(result)
        @result = result
        @errors = []
      end

      def validate
        validate_schema_shape
        return @errors unless @errors.empty?

        validate_framework
        validate_repository
        validate_scope
        validate_ecosystem
        validate_tooling
        validate_validation
        validate_documentation
        validate_framework_adoption
        validate_readiness
        validate_tier
        validate_components
        validate_gaps
        validate_risks
        validate_roadmap
        validate_context
        validate_collections
        validate_evidence
        validate_evidence_references
        @errors
      end

      private

      def validate_schema_shape
        unless @result.is_a?(Hash)
          @errors << "top-level result must be a mapping"
          return
        end

        missing = TOP_LEVEL - @result.keys
        extra = @result.keys - TOP_LEVEL
        @errors << "missing top-level fields: #{missing.sort.join(', ')}" unless missing.empty?
        @errors << "unknown top-level fields: #{extra.sort.join(', ')}" unless extra.empty?
        @errors << "schema_version must be 1" unless @result["schema_version"] == 1
        TOP_LEVEL.each { |key| @errors << "#{key} must be present" unless @result.key?(key) }
      end

      def validate_framework
        return unless object(@result["framework"], "framework", required: %w[metadata_schema_version version source_revision])

        integer(@result["framework"]["metadata_schema_version"], "framework.metadata_schema_version")
        string(@result["framework"]["version"], "framework.version")
        string(@result["framework"]["source_revision"], "framework.source_revision")
        object(@result["assessment"], "assessment", required: ["generated_at"])
        string(@result.dig("assessment", "generated_at"), "assessment.generated_at") if @result["assessment"].is_a?(Hash)
      end

      def validate_repository
        return unless object(@result["repository"], "repository", required: %w[root git])

        string(@result["repository"]["root"], "repository.root")
        git = @result["repository"]["git"]
        return unless object(git, "repository.git", required: %w[detected commit branch working_tree])

        boolean(git["detected"], "repository.git.detected")
        %w[commit branch working_tree].each { |field| string(git[field], "repository.git.#{field}") }
        value(git["working_tree"], "repository.git.working_tree", %w[clean dirty unknown])
      end

      def validate_scope
        scope = @result["scope"]
        return unless object(scope, "scope", required: %w[type project_roots shape excluded_paths ignored_paths symlink_boundaries])

        value(scope["type"], "scope.type", ["repository"])
        value(scope["shape"], "scope.shape", %w[single_project multiple_projects unknown])
        %w[project_roots excluded_paths ignored_paths symlink_boundaries].each do |field|
          paths(scope[field], "scope.#{field}")
        end
      end

      def validate_ecosystem
        entries = @result["ecosystem"]
        return unless array(entries, "ecosystem")

        entries.each_with_index do |entry, index|
          location = "ecosystem[#{index}]"
          next unless object(entry, location, required: %w[name role status confidence paths evidence_ids signals])

          string(entry["name"], "#{location}.name")
          value(entry["name"], "#{location}.name", ECOSYSTEMS)
          value(entry["role"], "#{location}.role", ECOSYSTEM_ROLES)
          value(entry["status"], "#{location}.status", ["detected"])
          confidence(entry["confidence"], "#{location}.confidence")
          paths(entry["paths"], "#{location}.paths")
          evidence_ids(entry["evidence_ids"], "#{location}.evidence_ids")
          string_array(entry["signals"], "#{location}.signals")
        end
      end

      def validate_tooling
        tooling = @result["tooling"]
        return unless object(tooling, "tooling", required: %w[package_managers test_frameworks linters formatters type_checkers task_runners command_surface ci hooks workspace containerisation])

        %w[package_managers test_frameworks linters formatters type_checkers task_runners].each do |field|
          validate_tool_list(tooling[field], "tooling.#{field}")
        end

        command_surface = tooling["command_surface"]
        if object(command_surface, "tooling.command_surface", required: %w[status commands])
          value(command_surface["status"], "tooling.command_surface.status", %w[detected not_detected])
          commands(command_surface["commands"], "tooling.command_surface.commands")
        end

        ci = tooling["ci"]
        if object(ci, "tooling.ci", required: %w[provider workflow_paths invocations evidence_ids])
          value(ci["provider"], "tooling.ci.provider", %w[github_actions none_detected])
          paths(ci["workflow_paths"], "tooling.ci.workflow_paths")
          string_array(ci["invocations"], "tooling.ci.invocations")
          evidence_ids(ci["evidence_ids"], "tooling.ci.evidence_ids")
        end

        validate_path_status(tooling["hooks"], "tooling.hooks")
        if object(tooling["workspace"], "tooling.workspace", required: %w[status evidence_ids])
          value(tooling["workspace"]["status"], "tooling.workspace.status", %w[detected not_detected])
          evidence_ids(tooling["workspace"]["evidence_ids"], "tooling.workspace.evidence_ids")
        end
        validate_path_status(tooling["containerisation"], "tooling.containerisation")
      end

      def validate_tool_list(entries, location)
        return unless array(entries, location)

        entries.each_with_index do |entry, index|
          item_location = "#{location}[#{index}]"
          next unless object(entry, item_location, required: %w[name status confidence evidence_ids])

          string(entry["name"], "#{item_location}.name")
          value(entry["status"], "#{item_location}.status", TOOL_STATUSES)
          confidence(entry["confidence"], "#{item_location}.confidence")
          evidence_ids(entry["evidence_ids"], "#{item_location}.evidence_ids")
        end
      end

      def commands(entries, location)
        return unless array(entries, location)

        entries.each_with_index do |entry, index|
          item_location = "#{location}[#{index}]"
          next unless object(entry, item_location, required: %w[name source evidence_ids])

          string(entry["name"], "#{item_location}.name")
          value(entry["source"], "#{item_location}.source", %w[Makefile package.json documentation])
          evidence_ids(entry["evidence_ids"], "#{item_location}.evidence_ids")
        end
      end

      def validate_path_status(value_to_check, location)
        return unless object(value_to_check, location, required: %w[status paths evidence_ids])

        value(value_to_check["status"], "#{location}.status", %w[detected not_detected])
        paths(value_to_check["paths"], "#{location}.paths")
        evidence_ids(value_to_check["evidence_ids"], "#{location}.evidence_ids")
      end

      def validate_validation
        validation = @result["validation"]
        return unless object(validation, "validation", required: %w[capabilities ci_alignment local_commands ci_commands])

        capabilities = validation["capabilities"]
        if object(capabilities, "validation.capabilities", required: CAPABILITIES)
          CAPABILITIES.each { |name| validate_capability(capabilities[name], "validation.capabilities.#{name}", name) }
        end

        alignment = validation["ci_alignment"]
        if object(alignment, "validation.ci_alignment", required: %w[status confidence evidence_ids local_commands ci_commands])
          value(alignment["status"], "validation.ci_alignment.status", VALIDATION_ALIGNMENT_STATUSES)
          confidence(alignment["confidence"], "validation.ci_alignment.confidence")
          evidence_ids(alignment["evidence_ids"], "validation.ci_alignment.evidence_ids")
          string_array(alignment["local_commands"], "validation.ci_alignment.local_commands")
          string_array(alignment["ci_commands"], "validation.ci_alignment.ci_commands")
        end
        string_array(validation["local_commands"], "validation.local_commands")
        string_array(validation["ci_commands"], "validation.ci_commands")
      end

      def validate_capability(capability, location, name)
        if name == "standard_local_verification"
          return unless object(capability, location, required: %w[status commands evidence_ids])

          value(capability["status"], "#{location}.status", VALIDATION_STATUSES)
          string_array(capability["commands"], "#{location}.commands")
          evidence_ids(capability["evidence_ids"], "#{location}.evidence_ids")
        elsif name == "local_hooks"
          validate_path_status(capability, location)
        elsif name == "ci_execution"
          return unless object(capability, location, required: %w[status evidence_ids])

          value(capability["status"], "#{location}.status", VALIDATION_STATUSES)
          evidence_ids(capability["evidence_ids"], "#{location}.evidence_ids")
        else
          return unless object(capability, location, required: %w[status signals evidence_ids])

          value(capability["status"], "#{location}.status", VALIDATION_STATUSES)
          string_array(capability["signals"], "#{location}.signals")
          capability["signals"].each { |signal| value(signal, "#{location}.signals", VALIDATION_STATUSES) } if capability["signals"].is_a?(Array)
          evidence_ids(capability["evidence_ids"], "#{location}.evidence_ids")
        end
      end

      def validate_documentation
        documentation = @result["documentation"]
        return unless object(documentation, "documentation", required: DOCUMENTATION_CATEGORIES)

        DOCUMENTATION_CATEGORIES.each do |category|
          location = "documentation.#{category}"
          next unless object(documentation[category], location, required: %w[status paths discoverability ambiguity evidence_ids])

          value(documentation[category]["status"], "#{location}.status", DOCUMENTATION_STATUSES)
          paths(documentation[category]["paths"], "#{location}.paths")
          value(documentation[category]["discoverability"], "#{location}.discoverability", DISCOVERABILITY)
          boolean(documentation[category]["ambiguity"], "#{location}.ambiguity")
          evidence_ids(documentation[category]["evidence_ids"], "#{location}.evidence_ids")
        end
      end

      def validate_framework_adoption
        adoption = @result["framework_adoption"]
        return unless object(adoption, "framework_adoption", required: %w[metadata detected_components])

        metadata = adoption["metadata"]
        if object(metadata, "framework_adoption.metadata", required: ["status"])
          value(metadata["status"], "framework_adoption.metadata.status", ["unsupported_in_schema_v1"])
        end
        detected = adoption["detected_components"]
        return unless array(detected, "framework_adoption.detected_components")

        names = []
        detected.each_with_index do |item, index|
          location = "framework_adoption.detected_components[#{index}]"
          next unless object(item, location, required: %w[component state paths evidence_ids rationale])

          names << item["component"]
          string(item["component"], "#{location}.component")
          value(item["state"], "#{location}.state", %w[framework_exact framework_like repository_native])
          paths(item["paths"], "#{location}.paths")
          evidence_ids(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["rationale"], "#{location}.rationale")
        end
        unique(names, "detected component IDs")
      end

      def validate_readiness
        readiness = @result["readiness"]
        return unless object(readiness, "readiness", required: Assessor::READINESS_DIMENSIONS)

        Assessor::READINESS_DIMENSIONS.each do |dimension|
          location = "readiness.#{dimension}"
          next unless object(readiness[dimension], location, required: %w[status confidence evidence_ids consequence recommended_action])

          value(readiness[dimension]["status"], "#{location}.status", READINESS_STATUSES)
          confidence(readiness[dimension]["confidence"], "#{location}.confidence")
          evidence_ids(readiness[dimension]["evidence_ids"], "#{location}.evidence_ids")
          string(readiness[dimension]["consequence"], "#{location}.consequence")
          string(readiness[dimension]["recommended_action"], "#{location}.recommended_action")
        end
      end

      def validate_tier
        tier = @result["tier_recommendation"]
        return unless object(tier, "tier_recommendation", required: %w[outcome confidence evidence_ids blocking_gap_ids assumptions alternative_conditions])

        value(tier["outcome"], "tier_recommendation.outcome", %w[tier-1 tier-2 tier-3 manual_review_required])
        confidence(tier["confidence"], "tier_recommendation.confidence")
        evidence_ids(tier["evidence_ids"], "tier_recommendation.evidence_ids")
        string_array(tier["blocking_gap_ids"], "tier_recommendation.blocking_gap_ids")
        string_array(tier["assumptions"], "tier_recommendation.assumptions")
        string_array(tier["alternative_conditions"], "tier_recommendation.alternative_conditions")
      end

      def validate_components
        components = @result["component_recommendations"]
        return unless array(components, "component_recommendations")

        names = []
        components.each_with_index do |item, index|
          location = "component_recommendations[#{index}]"
          next unless object(item, location, required: %w[component state confidence evidence_ids rationale prerequisite_gap_ids])

          names << item["component"]
          string(item["component"], "#{location}.component")
          value(item["state"], "#{location}.state", RECOMMENDATION_STATES)
          confidence(item["confidence"], "#{location}.confidence")
          evidence_ids(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["rationale"], "#{location}.rationale")
          string_array(item["prerequisite_gap_ids"], "#{location}.prerequisite_gap_ids")
        end
        unique(names, "component recommendation IDs")
      end

      def validate_gaps
        gaps = @result["gaps"]
        return unless array(gaps, "gaps")

        ids = []
        gaps.each_with_index do |item, index|
          location = "gaps[#{index}]"
          next unless object(item, location, required: %w[id title readiness_dimension severity confidence evidence_ids why_it_matters prerequisite_gap_ids recommended_outcome])

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "GAP-")
          string(item["title"], "#{location}.title")
          value(item["readiness_dimension"], "#{location}.readiness_dimension", Assessor::READINESS_DIMENSIONS)
          value(item["severity"], "#{location}.severity", SEVERITIES)
          confidence(item["confidence"], "#{location}.confidence")
          evidence_ids(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["why_it_matters"], "#{location}.why_it_matters")
          string_array(item["prerequisite_gap_ids"], "#{location}.prerequisite_gap_ids")
          string(item["recommended_outcome"], "#{location}.recommended_outcome")
        end
        unique(ids, "gap IDs")
      end

      def validate_risks
        risks = @result["risks"]
        return unless array(risks, "risks")

        ids = []
        risks.each_with_index do |item, index|
          location = "risks[#{index}]"
          next unless object(item, location, required: %w[id category severity confidence evidence_ids impact mitigation])

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "RISK-")
          string(item["category"], "#{location}.category")
          value(item["severity"], "#{location}.severity", SEVERITIES)
          confidence(item["confidence"], "#{location}.confidence")
          evidence_ids(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["impact"], "#{location}.impact")
          string(item["mitigation"], "#{location}.mitigation")
        end
        unique(ids, "risk IDs")
      end

      def validate_roadmap
        roadmap = @result["roadmap"]
        return unless array(roadmap, "roadmap")

        ids = []
        roadmap.each_with_index do |item, index|
          location = "roadmap[#{index}]"
          next unless object(item, location, required: %w[id phase title component prerequisite_ids gap_ids rationale])

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "STEP-")
          integer(item["phase"], "#{location}.phase")
          @errors << "#{location}.phase must be 0..3" unless item["phase"].is_a?(Integer) && (0..3).include?(item["phase"])
          string(item["title"], "#{location}.title")
          string(item["component"], "#{location}.component")
          string_array(item["prerequisite_ids"], "#{location}.prerequisite_ids")
          string_array(item["gap_ids"], "#{location}.gap_ids")
          string(item["rationale"], "#{location}.rationale")
        end
        unique(ids, "roadmap IDs")
      end

      def validate_context
        context = @result["assessor_context"]
        unless context.is_a?(Hash)
          @errors << "assessor_context must be a mapping"
          return
        end

        optional = %w[schema_version path evidence_ids conflicts repository sensitive_paths approved_agent_runtimes review_requirements known_setup_constraints notes]
        return unless object(context, "assessor_context", required: ["status"], optional: optional)

        value(context["status"], "assessor_context.status", %w[provided not_provided])
        return unless context["status"] == "provided"

        object(context, "assessor_context", required: %w[status schema_version path evidence_ids conflicts], optional: optional - %w[schema_version path evidence_ids conflicts])
        integer(context["schema_version"], "assessor_context.schema_version")
        @errors << "assessor_context.schema_version must be 1" unless context["schema_version"] == 1
        string(context["path"], "assessor_context.path")
        evidence_ids(context["evidence_ids"], "assessor_context.evidence_ids")
        validate_context_repository(context["repository"])
        %w[sensitive_paths approved_agent_runtimes review_requirements known_setup_constraints notes].each do |field|
          string_array(context[field], "assessor_context.#{field}") if context.key?(field)
        end
        validate_context_conflicts(context["conflicts"])
      end

      def validate_context_repository(repository)
        return if repository.nil?
        return unless object(repository, "assessor_context.repository", required: [], optional: %w[criticality deployment_impact])

        repository.each { |field, value_to_check| string(value_to_check, "assessor_context.repository.#{field}") }
      end

      def validate_context_conflicts(conflicts)
        return unless array(conflicts, "assessor_context.conflicts")

        conflicts.each_with_index do |conflict, index|
          location = "assessor_context.conflicts[#{index}]"
          next unless object(conflict, location, required: %w[field context_value repository_signal evidence_ids])

          string(conflict["field"], "#{location}.field")
          string(conflict["context_value"], "#{location}.context_value")
          string(conflict["repository_signal"], "#{location}.repository_signal")
          evidence_ids(conflict["evidence_ids"], "#{location}.evidence_ids")
        end
      end

      def validate_collections
        string_array(@result["assumptions"], "assumptions")
        string_array(@result["unknowns"], "unknowns")
      end

      def validate_evidence
        evidence = @result["evidence"]
        return unless array(evidence, "evidence")

        ids = []
        evidence.each_with_index do |item, index|
          location = "evidence[#{index}]"
          next unless object(item, location, required: %w[id type method summary], optional: ["path"])

          string(item["id"], "#{location}.id")
          ids << item["id"]
          identifier(item["id"], "#{location}.id", "E")
          value(item["type"], "#{location}.type", EVIDENCE_TYPES)
          string(item["method"], "#{location}.method")
          string(item["summary"], "#{location}.summary")
          if item.key?("path")
            string(item["path"], "#{location}.path")
            relative_path(item["path"], "#{location}.path") unless item["type"] == "assessor_context"
          end
        end
        unique(ids, "evidence IDs")
        ids.each_with_index { |id, index| @errors << "evidence IDs must be E###" unless id == format("E%03d", index + 1) }
      end

      def validate_evidence_references
        evidence_ids = @result["evidence"].is_a?(Array) ? @result["evidence"].filter_map { |item| item["id"] if item.is_a?(Hash) } : []
        referenced = []
        collect_evidence_ids(@result, referenced)
        referenced.uniq.each { |id| @errors << "unknown evidence reference: #{id}" unless evidence_ids.include?(id) }
        gap_ids = @result["gaps"].is_a?(Array) ? @result["gaps"].filter_map { |item| item["id"] if item.is_a?(Hash) } : []
        validate_id_references("gaps", "prerequisite_gap_ids", @result["gaps"], gap_ids)
        validate_id_references("components", "prerequisite_gap_ids", @result["component_recommendations"], gap_ids)
        roadmap_ids = @result["roadmap"].is_a?(Array) ? @result["roadmap"].filter_map { |item| item["id"] if item.is_a?(Hash) } : []
        validate_id_references("roadmap", "prerequisite_ids", @result["roadmap"], roadmap_ids)
        validate_id_references("roadmap", "gap_ids", @result["roadmap"], gap_ids)
        validate_id_references("tier", "blocking_gap_ids", [@result["tier_recommendation"]], gap_ids)
      end

      def collect_evidence_ids(value_to_check, result)
        case value_to_check
        when Hash
          value_to_check.each do |key, item|
            if key == "evidence_ids"
              result.concat(item) if item.is_a?(Array)
            else
              collect_evidence_ids(item, result)
            end
          end
        when Array
          value_to_check.each { |item| collect_evidence_ids(item, result) }
        end
      end

      def validate_id_references(label, field, collection, valid_ids)
        Array(collection).each_with_index do |item, index|
          next unless item.is_a?(Hash)

          Array(item[field]).each do |reference|
            @errors << "#{label}[#{index}].#{field} references unknown ID #{reference}" unless valid_ids.include?(reference)
          end
        end
      end

      def object(value_to_check, location, required:, optional: [])
        unless value_to_check.is_a?(Hash)
          @errors << "#{location} must be a mapping"
          return false
        end

        allowed = required + optional
        missing = required - value_to_check.keys
        extra = value_to_check.keys - allowed
        @errors << "#{location} missing fields: #{missing.join(', ')}" unless missing.empty?
        @errors << "#{location} has unknown fields: #{extra.join(', ')}" unless extra.empty?
        true
      end

      def array(value_to_check, location)
        @errors << "#{location} must be an array" unless value_to_check.is_a?(Array)
        value_to_check.is_a?(Array)
      end

      def paths(value_to_check, location)
        string_array(value_to_check, location)
        value_to_check.each { |path| relative_path(path, location) } if value_to_check.is_a?(Array)
      end

      def string(value_to_check, location)
        @errors << "#{location} must be a string" unless value_to_check.is_a?(String)
      end

      def integer(value_to_check, location)
        @errors << "#{location} must be an integer" unless value_to_check.is_a?(Integer)
      end

      def boolean(value_to_check, location)
        @errors << "#{location} must be a boolean" unless value_to_check == true || value_to_check == false
      end

      def string_array(value_to_check, location)
        unless value_to_check.is_a?(Array) && value_to_check.all? { |item| item.is_a?(String) }
          @errors << "#{location} must be an array of strings"
        end
      end

      def evidence_ids(value_to_check, location)
        string_array(value_to_check, location)
        return unless value_to_check.is_a?(Array)

        value_to_check.each do |id|
          @errors << "#{location} must contain E### IDs" unless id.is_a?(String) && id.match?(/\AE\d{3}\z/)
        end
      end

      def value(value_to_check, location, allowed)
        @errors << "#{location} has unsupported value #{value_to_check.inspect}" unless allowed.include?(value_to_check)
      end

      def confidence(value_to_check, location)
        value(value_to_check, location, CONFIDENCES)
      end

      def unique(values, label)
        duplicates = values.compact.group_by(&:itself).select { |_key, entries| entries.length > 1 }.keys
        @errors << "duplicate #{label}: #{duplicates.join(', ')}" unless duplicates.empty?
      end

      def identifier(value_to_check, location, prefix)
        @errors << "#{location} must match #{prefix}###" unless value_to_check.is_a?(String) && value_to_check.match?(/\A#{Regexp.escape(prefix)}\d{3}\z/)
      end

      def relative_path(value_to_check, location)
        unless value_to_check.is_a?(String) && !value_to_check.empty? && !value_to_check.start_with?("/") && Pathname.new(value_to_check).each_filename.none? { |part| part == ".." }
          @errors << "#{location} must be a safe relative path"
        end
      rescue ArgumentError
        @errors << "#{location} must be a safe relative path"
      end
    end
  end
end
