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
        validate_evidence
        validate_readiness
        validate_tier
        validate_components
        validate_gaps
        validate_risks
        validate_roadmap
        validate_context
        validate_collections
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
        mapping(@result["framework"], "framework")
        return unless @result["framework"].is_a?(Hash)

        integer(@result["framework"]["metadata_schema_version"], "framework.metadata_schema_version")
        string(@result["framework"]["version"], "framework.version")
        string(@result["framework"]["source_revision"], "framework.source_revision")
        mapping(@result["assessment"], "assessment")
        string(@result.dig("assessment", "generated_at"), "assessment.generated_at") if @result["assessment"].is_a?(Hash)
      end

      def validate_repository
        mapping(@result["repository"], "repository")
        return unless @result["repository"].is_a?(Hash)

        string(@result["repository"]["root"], "repository.root")
        git = @result["repository"]["git"]
        mapping(git, "repository.git")
        return unless git.is_a?(Hash)

        boolean(git["detected"], "repository.git.detected")
        %w[commit branch working_tree].each { |field| string(git[field], "repository.git.#{field}") }
        value(git["working_tree"], "repository.git.working_tree", %w[clean dirty unknown])
      end

      def validate_scope
        scope = @result["scope"]
        mapping(scope, "scope")
        return unless scope.is_a?(Hash)

        value(scope["type"], "scope.type", ["repository"])
        string_array(scope["project_roots"], "scope.project_roots")
        %w[project_roots excluded_paths ignored_paths symlink_boundaries].each do |field|
          paths = scope[field]
          string_array(paths, "scope.#{field}") unless paths.nil? && field != "project_roots"
          paths.each { |path| relative_path(path, "scope.#{field}") } if paths.is_a?(Array)
        end
      end

      def validate_framework_adoption
        adoption = @result["framework_adoption"]
        mapping(adoption, "framework_adoption")
        return unless adoption.is_a?(Hash)

        metadata = adoption["metadata"]
        mapping(metadata, "framework_adoption.metadata")
        value(metadata["status"], "framework_adoption.metadata.status", ["unsupported_in_schema_v1"]) if metadata.is_a?(Hash)
        detected = adoption["detected_components"]
        array(detected, "framework_adoption.detected_components")
        return unless detected.is_a?(Array)

        names = []
        detected.each_with_index do |item, index|
          location = "framework_adoption.detected_components[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          names << item["component"]
          string(item["component"], "#{location}.component")
          value(item["state"], "#{location}.state", %w[framework_exact framework_like repository_native])
          string_array(item["paths"], "#{location}.paths")
          item["paths"].each { |path| relative_path(path, "#{location}.paths") } if item["paths"].is_a?(Array)
          string_array(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["rationale"], "#{location}.rationale")
        end
        unique(names, "detected component IDs")
      end

      def validate_evidence
        evidence = @result["evidence"]
        array(evidence, "evidence")
        return unless evidence.is_a?(Array)

        ids = []
        evidence.each_with_index do |item, index|
          location = "evidence[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          string(item["id"], "#{location}.id")
          ids << item["id"]
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

      def validate_readiness
        readiness = @result["readiness"]
        mapping(readiness, "readiness")
        return unless readiness.is_a?(Hash)

        missing = Assessor::READINESS_DIMENSIONS - readiness.keys
        extra = readiness.keys - Assessor::READINESS_DIMENSIONS
        @errors << "readiness missing dimensions: #{missing.join(', ')}" unless missing.empty?
        @errors << "readiness has unknown dimensions: #{extra.join(', ')}" unless extra.empty?
        Assessor::READINESS_DIMENSIONS.each do |dimension|
          item = readiness[dimension]
          mapping(item, "readiness.#{dimension}")
          next unless item.is_a?(Hash)

          value(item["status"], "readiness.#{dimension}.status", READINESS_STATUSES)
          confidence(item["confidence"], "readiness.#{dimension}.confidence")
          string_array(item["evidence_ids"], "readiness.#{dimension}.evidence_ids")
          string(item["consequence"], "readiness.#{dimension}.consequence")
          string(item["recommended_action"], "readiness.#{dimension}.recommended_action")
        end
      end

      def validate_tier
        tier = @result["tier_recommendation"]
        mapping(tier, "tier_recommendation")
        return unless tier.is_a?(Hash)

        value(tier["outcome"], "tier_recommendation.outcome", %w[tier-1 tier-2 tier-3 manual_review_required])
        confidence(tier["confidence"], "tier_recommendation.confidence")
        string_array(tier["evidence_ids"], "tier_recommendation.evidence_ids")
        string_array(tier["blocking_gap_ids"], "tier_recommendation.blocking_gap_ids")
        string_array(tier["assumptions"], "tier_recommendation.assumptions")
        string_array(tier["alternative_conditions"], "tier_recommendation.alternative_conditions")
      end

      def validate_components
        components = @result["component_recommendations"]
        array(components, "component_recommendations")
        return unless components.is_a?(Array)

        names = []
        components.each_with_index do |item, index|
          location = "component_recommendations[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          names << item["component"]
          string(item["component"], "#{location}.component")
          value(item["state"], "#{location}.state", RECOMMENDATION_STATES)
          confidence(item["confidence"], "#{location}.confidence")
          string_array(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["rationale"], "#{location}.rationale")
          string_array(item["prerequisite_gap_ids"], "#{location}.prerequisite_gap_ids")
        end
        unique(names, "component recommendation IDs")
      end

      def validate_gaps
        gaps = @result["gaps"]
        array(gaps, "gaps")
        return unless gaps.is_a?(Array)

        ids = []
        gaps.each_with_index do |item, index|
          location = "gaps[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "GAP")
          string(item["title"], "#{location}.title")
          string(item["readiness_dimension"], "#{location}.readiness_dimension")
          value(item["severity"], "#{location}.severity", SEVERITIES)
          confidence(item["confidence"], "#{location}.confidence")
          string_array(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["why_it_matters"], "#{location}.why_it_matters")
          string_array(item["prerequisite_gap_ids"], "#{location}.prerequisite_gap_ids")
          string(item["recommended_outcome"], "#{location}.recommended_outcome")
        end
        unique(ids, "gap IDs")
      end

      def validate_risks
        risks = @result["risks"]
        array(risks, "risks")
        return unless risks.is_a?(Array)

        ids = []
        risks.each_with_index do |item, index|
          location = "risks[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "RISK")
          string(item["category"], "#{location}.category")
          value(item["severity"], "#{location}.severity", SEVERITIES)
          confidence(item["confidence"], "#{location}.confidence")
          string_array(item["evidence_ids"], "#{location}.evidence_ids")
          string(item["impact"], "#{location}.impact")
          string(item["mitigation"], "#{location}.mitigation")
        end
        unique(ids, "risk IDs")
      end

      def validate_roadmap
        roadmap = @result["roadmap"]
        array(roadmap, "roadmap")
        return unless roadmap.is_a?(Array)

        ids = []
        roadmap.each_with_index do |item, index|
          location = "roadmap[#{index}]"
          mapping(item, location)
          next unless item.is_a?(Hash)

          ids << item["id"]
          identifier(item["id"], "#{location}.id", "STEP")
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
        mapping(context, "assessor_context")
        return unless context.is_a?(Hash)

        value(context["status"], "assessor_context.status", %w[provided not_provided])
        if context["status"] == "provided"
          integer(context["schema_version"], "assessor_context.schema_version")
          @errors << "assessor_context.schema_version must be 1" unless context["schema_version"] == 1
          string(context["path"], "assessor_context.path")
          string_array(context["evidence_ids"], "assessor_context.evidence_ids")
          array(context["conflicts"], "assessor_context.conflicts")
        end
      end

      def validate_collections
        string_array(@result["assumptions"], "assumptions")
        string_array(@result["unknowns"], "unknowns")
        array(@result["ecosystem"], "ecosystem")
        mapping(@result["tooling"], "tooling")
        mapping(@result["validation"], "validation")
        mapping(@result["documentation"], "documentation")
        validate_framework_adoption
      end

      def validate_evidence_references
        evidence_ids = @result["evidence"].is_a?(Array) ? @result["evidence"].filter_map { |item| item["id"] if item.is_a?(Hash) } : []
        referenced = []
        collect_evidence_ids(@result, referenced)
        referenced.uniq.each { |id| @errors << "unknown evidence reference: #{id}" unless evidence_ids.include?(id) }
        validate_id_references("gaps", "prerequisite_gap_ids", @result["gaps"], @result["gaps"].to_a.filter_map { |item| item["id"] if item.is_a?(Hash) })
        validate_id_references("components", "prerequisite_gap_ids", @result["component_recommendations"], @result["gaps"].to_a.filter_map { |item| item["id"] if item.is_a?(Hash) })
        roadmap_ids = @result["roadmap"].to_a.filter_map { |item| item["id"] if item.is_a?(Hash) }
        validate_id_references("roadmap", "prerequisite_ids", @result["roadmap"], roadmap_ids)
        validate_id_references("roadmap", "gap_ids", @result["roadmap"], @result["gaps"].to_a.filter_map { |item| item["id"] if item.is_a?(Hash) })
        validate_id_references("tier", "blocking_gap_ids", [@result["tier_recommendation"]], @result["gaps"].to_a.filter_map { |item| item["id"] if item.is_a?(Hash) })
      end

      def collect_evidence_ids(value, result)
        case value
        when Hash
          value.each do |key, item|
            if key == "evidence_ids"
              result.concat(item.is_a?(Array) ? item : [item])
            else
              collect_evidence_ids(item, result)
            end
          end
        when Array
          value.each { |item| collect_evidence_ids(item, result) }
        end
      end

      def validate_id_references(label, field, collection, valid_ids)
        Array(collection).each_with_index do |item, index|
          Array(item[field]).each do |reference|
            @errors << "#{label}[#{index}].#{field} references unknown ID #{reference}" unless valid_ids.include?(reference)
          end
        end
      end

      def mapping(value, location)
        @errors << "#{location} must be a mapping" unless value.is_a?(Hash)
      end

      def array(value, location)
        @errors << "#{location} must be an array" unless value.is_a?(Array)
      end

      def string(value, location)
        @errors << "#{location} must be a string" unless value.is_a?(String)
      end

      def integer(value, location)
        @errors << "#{location} must be an integer" unless value.is_a?(Integer)
      end

      def boolean(value, location)
        @errors << "#{location} must be a boolean" unless value == true || value == false
      end

      def string_array(value, location)
        unless value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
          @errors << "#{location} must be an array of strings"
        end
      end

      def value(value, location, allowed)
        @errors << "#{location} has unsupported value #{value.inspect}" unless allowed.include?(value)
      end

      def confidence(value, location)
        value(value, location, CONFIDENCES)
      end

      def unique(values, label)
        duplicates = values.compact.group_by(&:itself).select { |_key, entries| entries.length > 1 }.keys
        @errors << "duplicate #{label}: #{duplicates.join(', ')}" unless duplicates.empty?
      end

      def identifier(value, location, prefix)
        @errors << "#{location} must match #{prefix}-###" unless value.is_a?(String) && value.match?(/\A#{prefix}-\d{3}\z/)
      end

      def relative_path(value, location)
        unless value.is_a?(String) && !value.empty? && !value.start_with?("/") && Pathname.new(value).each_filename.none? { |part| part == ".." }
          @errors << "#{location} must be a safe relative path"
        end
      rescue ArgumentError
        @errors << "#{location} must be a safe relative path"
      end
    end
  end
end
