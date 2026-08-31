# frozen_string_literal: true

require "digest"
require "pathname"
require "time"

module AgenticDeveloperSetup
  module Assessment
    class Assessor
      READINESS_DIMENSIONS = %w[
        repository_context
        task_boundary
        command_surface
        deterministic_validation
        ci_alignment
        sensitive_area_guidance
        runtime_access
        review_handoff
        local_setup_reproducibility
      ].freeze
      RECOMMENDATION_STATES = %w[
        adopt_now
        specialise_now
        adopt_after_prerequisite
        evaluate_later
        defer
        not_applicable
        already_satisfied_by_repository_native
      ].freeze
      ROADMAP_COMPONENT_PLAN = {
        "agent_instructions" => { "phase" => 1, "title" => "Establish repository agent instructions and boundaries" },
        "development_guide" => { "phase" => 1, "title" => "Document reproducible local development" },
        "testing_strategy" => { "phase" => 1, "title" => "Document deterministic testing and validation strategy" },
        "architecture_scaffold" => { "phase" => 1, "title" => "Document architecture boundaries for adoption" },
        "domain_context" => { "phase" => 1, "title" => "Document domain context for adoption" },
        "command_interface" => { "phase" => 1, "title" => "Establish a stable repository command interface" },
        "agent_ready_issue_template" => { "phase" => 2, "title" => "Establish the agent-ready task workflow" },
        "bug_report_issue_template" => { "phase" => 2, "title" => "Establish the defect-report workflow" },
        "discovery_or_shaping_issue_template" => { "phase" => 2, "title" => "Establish the discovery and shaping workflow" },
        "issue_template_config" => { "phase" => 2, "title" => "Configure the issue-template chooser" },
        "pull_request_template" => { "phase" => 2, "title" => "Establish the human review handoff" },
        "ci_workflow" => { "phase" => 2, "title" => "Align the CI validation workflow" },
        "git_hooks" => { "phase" => 2, "title" => "Evaluate repository hooks for justified validation" },
        "agent_launcher" => { "phase" => 2, "title" => "Evaluate an agent launcher and access boundary" },
        "github_access_helper" => { "phase" => 2, "title" => "Evaluate scoped GitHub access" },
        "claude_agent_entrypoint" => { "phase" => 2, "title" => "Evaluate the agent compatibility entrypoint" },
        "commit_metadata" => { "phase" => 3, "title" => "Operationalise commit authorship and metadata conventions" }
      }.freeze
      SUBSTANTIVE_VALIDATION_CAPABILITIES = %w[
        tests linting static_type_checking build_compile standard_local_verification
      ].freeze
      SENSITIVE_TERMS = /\b(?:sensitive|secret|credential|security[- ]critical|restricted)\b/i
      SENSITIVE_POLICY = /(?:\bmust(?:\s+not)?\b|\bdo not\b|\bnever\b|\brestricted\b|\bprohibited\b|\bonly\b|\brequires?\s+(?:human\s+)?(?:review|approval|handling|access)\b|\breview\s+required\b|\baccess\s+limited\b|\bhandling\s+requirements?\b|\bpermitted\s+operations\b|\bnot\s+permitted\b)/i
      SENSITIVE_DENIAL = /(?:\b(?:no|not)\s+(?:secrets?|credentials?|sensitive|review|approval)\b|\b(?:contains?|has|requires?|needs?)\s+no\s+(?:secrets?|credentials?|review|approval)\b|\b(?:no|without)\s+(?:review|approval)\s+(?:required|needed)\b)/i

      def initialize(target, framework_root: default_framework_root, clock: -> { Time.now.utc })
        expanded = Pathname.new(target.to_s).expand_path
        raise InvocationError, "target repository does not exist: #{target}" unless expanded.directory?

        @root = expanded.realpath
        @framework_root = Pathname.new(framework_root).expand_path.realpath
        @clock = clock
        @catalogue = Catalogue.new(@framework_root.to_s)
        @evidence = Evidence.new
        @git = GitInspector.new(@root)
        @inventory = Inventory.new(@root, git: @git).discover
      rescue Errno::EACCES => e
        raise InvocationError, "target repository is unreadable: #{e.message}"
      rescue Errno::ENOENT => e
        raise InvocationError, "assessment input does not exist: #{e.message}"
      end

      def assess(context_path: nil)
        context = Context.load(context_path, @evidence)
        @evidence.add(type: "framework_metadata", path: "framework.yml", method: "framework_catalogue", summary: "Current framework catalogue and metadata detected")
        git_info = @git.info
        git_evidence(git_info)
        analysis = Detector.new(@inventory, @catalogue, @evidence).analyze
        context_conflicts = detect_context_conflicts(context)
        readiness = readiness(analysis, context, context_conflicts)
        gap_specs = gap_specs(analysis, readiness, context, context_conflicts)
        gaps, gap_ids = materialize_gaps(gap_specs)
        risks = materialize_risks(risk_specs(analysis, context, context_conflicts))
        framework_states = framework_states(analysis)
        tier = tier_recommendation(analysis, readiness, gaps, context, context_conflicts)
        component_recommendations = component_recommendations(framework_states, analysis, gap_ids, tier)
        roadmap = roadmap(component_recommendations, gaps, gap_ids)
        result = {
          "schema_version" => 1,
          "framework" => {
            "metadata_schema_version" => @catalogue.metadata_schema_version,
            "version" => @catalogue.framework_version,
            "source_revision" => @catalogue.source_revision
          },
          "assessment" => { "generated_at" => @clock.call.utc.iso8601 },
          "repository" => {
            "root" => @root.to_s,
            "git" => git_info
          },
          "scope" => analysis[:scope],
          "ecosystem" => analysis[:ecosystem],
          "tooling" => analysis[:tooling],
          "validation" => analysis[:validation],
          "documentation" => analysis[:documentation],
          "framework_adoption" => {
            "metadata" => { "status" => "unsupported_in_schema_v1" },
            "detected_components" => framework_states
          },
          "readiness" => readiness,
          "tier_recommendation" => tier,
          "component_recommendations" => component_recommendations,
          "gaps" => gaps,
          "risks" => risks,
          "roadmap" => roadmap,
          "assessor_context" => context_output(context, context_conflicts),
          "assumptions" => assumptions(analysis, context),
          "unknowns" => unknowns(analysis, context),
            "evidence" => []
          }
        @evidence.resolve_references!(result)
        result["evidence"] = @evidence.materialize
        Schema.validate!(result)
        result
      rescue SchemaError
        raise
      rescue StandardError => e
        raise e if e.is_a?(InvocationError)

        raise InternalError, "assessment failed: #{e.message}"
      end

      attr_reader :root

      private

      def default_framework_root
        Pathname.new(__dir__).join("../../..").to_s
      end

      def git_evidence(info)
        keys = [@evidence.add(type: "git", method: "git_repository_detection", summary: "Git repository detection completed")]
        if info["detected"]
          keys << @evidence.add(type: "git", method: "git_commit", summary: "Current Git commit detected")
          keys << @evidence.add(type: "git", method: "git_branch", summary: "Current Git branch detected")
          keys << @evidence.add(type: "git", method: "git_working_tree", summary: "Git working-tree state detected")
        end
        keys
      end

      def context_output(context, conflicts)
        return { "status" => "not_provided" } unless context.provided?

        context.values.merge(
          "status" => "provided",
          "path" => context.path,
          "evidence_ids" => @evidence.references(context.evidence_keys),
          "conflicts" => conflicts
        )
      end

      def detect_context_conflicts(context)
        return [] unless context.provided?

        conflicts = []
        low_fields = %w[criticality deployment_impact].filter_map do |field|
          value = context.values.dig("repository", field)
          [field, value] if %w[low minimal none].include?(value.to_s.downcase)
        end
        return [] if low_fields.empty?

        @inventory.files.keys.sort.each do |path|
          next unless path.match?(/\A(?:README|CONTRIBUTING|AGENTS|CLAUDE|docs\/).*/i)

          content = @inventory.read(path).to_s
          next unless content.match?(/\b(?:production|critical|safety[- ]critical|high[- ]impact)\b/i)

          key = @evidence.add(type: "file", path: path, method: "context_conflicting_repository_signal", summary: "Repository documentation describes a potentially high-impact context")
          low_fields.each do |field, value|
            conflicts << {
              "field" => "repository.#{field}",
              "context_value" => value,
              "repository_signal" => "high-impact language in recognised documentation",
              "evidence_ids" => @evidence.references([key])
            }
          end
        end
        conflicts.sort_by { |item| [item["field"], item["context_value"], item["repository_signal"], item["evidence_ids"]] }
          .uniq { |item| [item["field"], item["context_value"], item["repository_signal"], item["evidence_ids"]] }
      end

      def readiness(analysis, context, conflicts)
        docs = analysis[:documentation]
        validation = analysis[:validation]
        tooling = analysis[:tooling]
        project_roots = analysis[:scope]["project_roots"]
        task_paths = docs["issue_templates"]["paths"] + docs["pull_request_template"]["paths"]
        task_evidence = docs["issue_templates"]["evidence_ids"] + docs["pull_request_template"]["evidence_ids"]
        architecture_evidence = docs["architecture"]["evidence_ids"] + docs["development_guide"]["evidence_ids"]
        context_evidence = context.provided? ? @evidence.references(context.evidence_keys) : []
        guidance = sensitive_guidance(docs)
        {
          "repository_context" => readiness_entry(
            if project_roots.any? && docs["root_readme"]["status"] == "present" && architecture_evidence.any?
              "ready"
            elsif project_roots.any? || docs["root_readme"]["status"] == "present"
              "partial"
            else
              "missing"
            end,
            project_roots.any? && docs["root_readme"]["status"] == "present" ? "high" : "medium",
            docs["root_readme"]["evidence_ids"] + architecture_evidence,
            "Agents need discoverable repository purpose, roots, and development context.",
            "Document repository purpose, project roots, and material boundaries."
          ),
          "task_boundary" => readiness_entry(
            if task_paths.any? && task_templates_show_boundaries(task_paths).values.all?
              "ready"
            elsif task_paths.any? || docs["development_guide"]["status"] == "present"
              "partial"
            else
              "missing"
            end,
            task_evidence.any? ? "high" : "low",
            task_evidence,
            "Explicit scope, acceptance criteria, and non-goals make agent work reviewable.",
            "Document task scope, acceptance criteria, non-goals, and implementation boundaries."
          ),
          "command_surface" => readiness_entry(
            if tooling["command_surface"]["commands"].any? { |command| command["source"] != "documentation" }
              "ready"
            elsif tooling["command_surface"]["commands"].any?
              "partial"
            else
              "missing"
            end,
            tooling["command_surface"]["commands"].any? ? "high" : "low",
            tooling["command_surface"]["commands"].flat_map { |command| command["evidence_ids"] },
            "A stable command surface bounds how humans and agents discover local work.",
            "Define a stable local command for development and deterministic validation."
          ),
          "deterministic_validation" => validation_readiness(validation),
          "ci_alignment" => ci_readiness(validation),
          "sensitive_area_guidance" => sensitive_readiness(guidance, context, context_evidence),
          "runtime_access" => runtime_readiness(analysis, context, context_evidence),
          "review_handoff" => review_readiness(docs),
          "local_setup_reproducibility" => setup_readiness(analysis, docs)
        }.tap do |items|
          if conflicts.any?
            items["repository_context"]["status"] = "blocked"
            items["repository_context"]["confidence"] = "low"
            items["repository_context"]["consequence"] = "Conflicting context and repository evidence require human review before adoption."
          end
        end
      end

      def readiness_entry(status, confidence, evidence_ids, consequence, action)
        {
          "status" => status,
          "confidence" => confidence,
          "evidence_ids" => @evidence.references(evidence_ids),
          "consequence" => consequence,
          "recommended_action" => action
        }
      end

      def validation_readiness(validation)
        capabilities = validation["capabilities"]
        substantive = substantive_validation_capabilities(capabilities)
        status = case substantive.length
                  when 0 then "missing"
                  when 1 then "partial"
                  else "ready"
                  end
        keys = capabilities.values.flat_map { |item| item["evidence_ids"] }
        readiness_entry(status, validation_confidence(capabilities), keys, "Static validation evidence helps constrain agent changes without executing project tools.", "Document and align deterministic tests and validation checks.")
      end

      def substantive_validation_capabilities(capabilities)
        SUBSTANTIVE_VALIDATION_CAPABILITIES.select do |name|
          capability = capabilities[name]
          next false unless capability

          if name == "standard_local_verification"
            capability["status"] == "documented_command_detected" && capability["commands"].any?
          else
            %w[implementation_detected configuration_detected].include?(capability["status"])
          end
        end
      end

      def validation_confidence(capabilities)
        keys = capabilities.values.flat_map { |item| item["evidence_ids"] }
        keys.length >= 2 ? "high" : "medium"
      end

      def ci_readiness(validation)
        alignment = validation["ci_alignment"]
        readiness_entry(alignment["status"], alignment["confidence"], alignment["evidence_ids"], "CI should provide merge-time evidence conceptually aligned with local validation.", "Align CI invocations with the documented local validation surface.")
      end

      def sensitive_guidance(docs)
        docs["security"]["evidence_ids"] + docs["agent_instructions"]["evidence_ids"]
      end

      def sensitive_readiness(guidance, context, context_evidence)
        if context.values.fetch("sensitive_paths", []).any?
          supported = guidance_mentions_sensitive?
          status = supported ? "ready" : "missing"
          return readiness_entry(status, supported ? "high" : "medium", guidance + context_evidence, "Sensitive paths need explicit handling boundaries before agent access is expanded.", "Document sensitive areas, permitted operations, and review requirements.")
        end
        return readiness_entry("ready", "medium", guidance, "Recognised repository guidance provides evidence of sensitive-area boundaries.", "Keep sensitive-area guidance current.") if guidance.any? && guidance_mentions_sensitive?

        readiness_entry("unknown", "low", guidance, "Static inspection cannot establish whether undocumented restricted areas exist.", "Ask repository owners to identify sensitive or high-risk areas.")
      end

      def guidance_mentions_sensitive?
        @inventory.files.keys.any? do |path|
          next false unless path.match?(/\A(?:SECURITY|AGENTS|CLAUDE|docs\/).*/i)

          content = @inventory.read(path).to_s
          content.split(/(?<=[.!?])\s+|\R/).any? do |sentence|
            sentence.match?(SENSITIVE_TERMS) && sentence.match?(SENSITIVE_POLICY) && !sentence.match?(SENSITIVE_DENIAL)
          end
        end
      end

      def runtime_readiness(analysis, context, context_evidence)
        launcher = analysis[:facts][:framework_paths].any? { |path| path == "scripts/run_codex.sh" || path == "CLAUDE.md" }
        if context.values.fetch("approved_agent_runtimes", []).any?
          return readiness_entry("ready", "high", context_evidence, "Assessor context states which agent runtimes are approved.", "Verify runtime policy against the repository's access boundaries.")
        end
        return readiness_entry("partial", "medium", [], "A runtime-related artefact is visible, but its access expectations require review.", "Review runtime and repository-access expectations explicitly.") if launcher

        readiness_entry("not_applicable", "high", [], "No agent runtime requirement is established by static repository evidence.", "Evaluate runtime controls only if the adoption scope requires them.")
      end

      def review_readiness(docs)
        evidence = docs["pull_request_template"]["evidence_ids"] + docs["issue_templates"]["evidence_ids"]
        status = if docs["pull_request_template"]["status"] == "present" && docs["issue_templates"]["status"] == "present"
                   "ready"
                 elsif evidence.any? || docs["root_readme"]["status"] == "present"
                   "partial"
                 else
                   "missing"
                 end
        readiness_entry(status, evidence.any? ? "high" : "medium", evidence, "Human review needs a visible place for scope and validation evidence.", "Provide a review handoff that records scope, validation, risks, and follow-up work.")
      end

      def setup_readiness(analysis, docs)
        manifest = analysis[:facts][:framework_paths].any? { |path| path.match?(/\A(?:pyproject\.toml|package\.json|requirements[^\/]*\.txt)\z/i) }
        lock = analysis[:facts][:framework_paths].any? { |path| path.match?(/\A(?:uv\.lock|package-lock\.json|yarn\.lock|pnpm-lock\.yaml)\z/i) }
        setup_docs = docs["root_readme"]["status"] == "present" || docs["development_guide"]["status"] == "present"
        status = if manifest && lock && setup_docs
                   "ready"
                 elsif manifest || setup_docs
                   "partial"
                 else
                   "unknown"
                 end
        keys = docs["root_readme"]["evidence_ids"] + docs["development_guide"]["evidence_ids"]
        readiness_entry(status, manifest && lock ? "high" : "medium", keys, "Agents need reproducible prerequisites without relying on undocumented local state.", "Document prerequisites, setup commands, and lockfile/runtime expectations.")
      end

      def task_templates_show_boundaries(paths)
        contents = paths.map { |path| @inventory.read(path).to_s }.join("\n")
        {
          "scope" => contents.match?(/\b(?:scope|in scope|out of scope)\b/i),
          "acceptance" => contents.match?(/\b(?:acceptance criteria|acceptance|success criteria|definition of done)\b/i),
          "non_goals" => contents.match?(/\b(?:non[- ]goals?|out of scope|explicit non-goals?)\b/i),
          "implementation_boundary" => contents.match?(/\b(?:implementation boundaries?|implementation constraints?|architecture boundaries?|repository boundaries?|constraints?)\b/i)
        }
      end

      def gap_specs(analysis, readiness, context, conflicts)
        specs = []
        add_gap(specs, "repository_context", "Repository context is not sufficiently discoverable", "blocking", readiness["repository_context"], "Agents may infer project boundaries incorrectly.", "Document purpose, project roots, architecture, and material boundaries.") if %w[missing blocked].include?(readiness["repository_context"]["status"])
        add_gap(specs, "task_boundary", "Task conventions do not expose complete boundaries", "high", readiness["task_boundary"], "Agent tasks may lack explicit scope, acceptance criteria, or non-goals.", "Document those task fields in the repository's native workflow.") if %w[missing partial].include?(readiness["task_boundary"]["status"])
        add_gap(specs, "command_surface", "No stable local command surface was detected", "blocking", readiness["command_surface"], "Reviewers cannot reliably identify the commands that should support development and validation.", "Expose a stable native command surface before adopting executable agent workflows.") if readiness["command_surface"]["status"] == "missing"
        add_gap(specs, "deterministic_validation", "Deterministic validation evidence is incomplete", "high", readiness["deterministic_validation"], "Agent changes will have weak static evidence for safe review.", "Document or add deterministic tests and validation checks appropriate to the repository.") if %w[missing partial].include?(readiness["deterministic_validation"]["status"])
        add_gap(specs, "ci_alignment", "Local and CI validation do not have clear conceptual alignment", "high", readiness["ci_alignment"], "Merge-time evidence may not cover the same validation surface as local work.", "Align CI invocations with stable local validation commands.") if readiness["ci_alignment"]["status"] == "partial"
        sensitive_gap = context.values.fetch("sensitive_paths", []).any? && readiness["sensitive_area_guidance"]["status"] == "missing"
        add_gap(specs, "sensitive_area_guidance", "Sensitive-area guidance is not discoverable", "blocking", readiness["sensitive_area_guidance"], "Agent access boundaries cannot be reviewed for identified sensitive paths.", "Document sensitive paths and the human review required for them.") if sensitive_gap || conflicts.any?
        add_gap(specs, "local_setup_reproducibility", "Local setup prerequisites are not fully reproducible from static evidence", "medium", readiness["local_setup_reproducibility"], "Agent sessions may depend on undocumented runtime or dependency state.", "Document setup prerequisites and commit the relevant dependency identity.") if readiness["local_setup_reproducibility"]["status"] == "partial"
        if analysis[:scope]["project_roots"].length > 1
          add_gap(specs, "repository_context", "Multiple candidate project roots require scoped adoption review", "high", readiness["repository_context"], "Repository-level adoption may not apply uniformly across project roots.", "Identify shared surfaces and defer workspace-specific decisions to separate review.")
        end
        if @inventory.symlink_boundaries.any?
          key = @evidence.add(type: "directory", path: @inventory.symlink_boundaries.first, method: "symlink_boundary_excluded", summary: "Symlink outside the target root was excluded from inspection")
          item = readiness["repository_context"].merge("evidence_ids" => (readiness["repository_context"]["evidence_ids"] + @evidence.ids_for([key])).uniq)
          add_gap(specs, "repository_context", "A symlink escapes the assessed repository root", "high", item, "Static inspection did not follow the external path and cannot establish its contents.", "Review or remove the boundary before adopting repository-wide controls.")
        end
        specs
      end

      def add_gap(specs, dimension, title, severity, readiness_item, why, outcome)
        key = "#{dimension}:#{title}"
        specs << {
          "key" => key,
          "title" => title,
          "readiness_dimension" => dimension,
          "severity" => severity,
          "confidence" => readiness_item["confidence"],
          "evidence_ids" => readiness_item["evidence_ids"],
          "why_it_matters" => why,
          "recommended_outcome" => outcome,
          "prerequisite_keys" => []
        }
      end

      def materialize_gaps(specs)
        ordered = specs.uniq { |item| item["key"] }.sort_by { |item| [item["readiness_dimension"], item["title"]] }
        ids = ordered.each_with_index.to_h { |item, index| [item["key"], format("GAP-%03d", index + 1)] }
        gaps = ordered.map do |item|
          {
            "id" => ids.fetch(item["key"]),
            "title" => item["title"],
            "readiness_dimension" => item["readiness_dimension"],
            "severity" => item["severity"],
            "confidence" => item["confidence"],
            "evidence_ids" => item["evidence_ids"],
            "why_it_matters" => item["why_it_matters"],
            "prerequisite_gap_ids" => item["prerequisite_keys"].filter_map { |key| ids[key] },
            "recommended_outcome" => item["recommended_outcome"]
          }
        end
        [gaps, ids]
      end

      def risk_specs(analysis, context, conflicts)
        specs = []
        if analysis[:scope]["project_roots"].length > 1
          specs << risk("heterogeneous_monorepo", "heterogeneous monorepo", "high", "Multiple candidate project roots may have different adoption constraints.", "Review shared repository surfaces and scope later adoption decisions.", analysis[:documentation]["root_readme"]["evidence_ids"])
        end
        if analysis[:documentation]["architecture"]["status"] == "not_detected"
          specs << risk("undocumented_architecture", "undocumented architecture", "medium", "Static inspection cannot establish architecture boundaries.", "Require repository-owner architecture review before architecture-specific specialisation.", [])
        end
        if analysis[:validation]["ci_alignment"]["status"] == "partial"
          specs << risk("weak_deterministic_validation", "weak deterministic validation", "high", "CI and local validation signals appear divergent.", "Resolve the command mapping and require human review of the validation contract.", analysis[:validation]["ci_alignment"]["evidence_ids"])
        end
        if context.values.dig("repository", "deployment_impact")&.match?(/high|critical/i)
          keys = @evidence.ids_for(context.evidence_keys)
          specs << risk("high_impact_deployment_path", "high-impact deployment path", "high", "Assessor context identifies deployment impact that warrants restricted agent scope.", "Keep deployment changes explicitly human-reviewed and outside automatic assessment conclusions.", keys)
        end
        if context.values.fetch("sensitive_paths", []).any?
          specs << risk("sensitive_security_critical_area", "sensitive or security-critical areas", "high", "Assessor context identifies paths requiring special handling.", "Record path-level access and review rules before expanding runtime authority.", @evidence.ids_for(context.evidence_keys))
        end
        if context.values.fetch("review_requirements", []).any?
          specs << risk("unresolved_ownership_review", "unresolved ownership or review responsibilities", "medium", "Assessor context adds review requirements that static repository evidence cannot verify.", "Resolve the requirements with repository owners and retain them in the adoption decision.", @evidence.ids_for(context.evidence_keys))
        end
        if @inventory.excluded_paths.any? { |path| path.split("/").any? { |part| %w[vendor node_modules dist build target coverage].include?(part.downcase) } }
          key = @evidence.add(type: "directory", path: @inventory.excluded_paths.first, method: "excluded_generated_or_dependency_area", summary: "Generated, dependency, or build area excluded from inspection")
          specs << risk("generated_or_vendored_code", "generated or vendored code", "medium", "Excluded areas may contain code whose ownership and validation differ from repository source.", "Confirm generated and vendored boundaries before adopting broad component coverage.", @evidence.ids_for([key]))
        end
        @inventory.files.keys.grep(%r{\A\.github/workflows/}).each do |path|
          next unless @inventory.read(path).to_s.match?(/secrets\./i)

          key = @evidence.add(type: "ci_invocation", path: path, method: "ci_secret_reference", summary: "CI workflow references repository secrets")
          specs << risk("ci_requires_unavailable_secrets", "CI requires unavailable secrets", "medium", "Static CI inspection shows secret references that an offline assessment cannot resolve.", "Review CI prerequisites and do not infer that validation can run locally from this evidence.", [key])
        end
        conflicts.each do |conflict|
          specs << risk("conflicting_assessor_context", "conflicting assessor context", "high", "Assessor context conflicts with recognised repository documentation.", "Resolve the context conflict with repository owners before selecting an adoption tier.", conflict["evidence_ids"])
        end
        specs
      end

      def risk(category, title, severity, impact, mitigation, evidence_ids)
        { "category" => category, "title" => title, "severity" => severity, "confidence" => evidence_ids.any? ? "high" : "low", "evidence_ids" => evidence_ids, "impact" => impact, "mitigation" => mitigation }
      end

      def materialize_risks(specs)
        specs.sort_by { |item| [item["category"], item["title"]] }.each_with_index.map do |item, index|
          {
            "id" => format("RISK-%03d", index + 1),
            "category" => item["category"],
            "severity" => item["severity"],
            "confidence" => item["confidence"],
            "evidence_ids" => item["evidence_ids"],
            "impact" => item["impact"],
            "mitigation" => item["mitigation"]
          }
        end
      end

      def framework_states(analysis)
        @catalogue.components.filter_map do |component|
          target = component["target_path"]
          state = nil
          keys = []
          source = @catalogue.source_root.join(component["source_path"])
          target_bytes = @inventory.read(target) if @inventory.files.key?(target)
          if target_bytes
            if source.file? && Digest::SHA256.hexdigest(target_bytes) == Digest::SHA256.file(source.to_s).hexdigest
              state = "framework_exact"
              keys << @evidence.add(type: "file", path: target, method: "framework_exact_content_match", summary: "Current framework artefact content matches #{component["name"]}")
            else
              state = "framework_like"
              keys << @evidence.add(type: "file", path: target, method: "framework_like_path", summary: "Recognised framework-style artefact path detected for #{component["name"]}")
            end
          else
            native_paths = native_paths_for(component["name"], analysis)
            next if native_paths.empty?

            state = "repository_native"
            keys.concat(native_paths.map { |path| @evidence.add(type: "file", path: path, method: "repository_native_equivalent", summary: "Repository-native mechanism satisfies #{component["name"]} capability") })
          end
          {
            "component" => component["name"],
            "state" => state,
            "paths" => state == "repository_native" ? native_paths_for(component["name"], analysis) : [target],
            "evidence_ids" => @evidence.ids_for(keys),
            "rationale" => state_rationale(state)
          }
        end.sort_by { |item| item["component"] }
      end

      def native_paths_for(name, analysis)
        docs = analysis[:documentation]
        case name
        when "command_interface" then analysis[:facts][:package_scripts].any? && !@inventory.exists?("Makefile") ? ["package.json"] : []
        when "development_guide" then docs["development_guide"]["paths"]
        when "testing_strategy" then docs["testing"]["paths"]
        when "architecture_scaffold" then docs["architecture"]["paths"]
        when "domain_context" then docs["domain"]["paths"]
        when "commit_metadata" then []
        when "pull_request_template" then docs["pull_request_template"]["paths"]
        when "ci_workflow" then analysis[:tooling]["ci"]["workflow_paths"]
        when "git_hooks" then analysis[:tooling]["hooks"]["paths"]
        when "agent_ready_issue_template", "bug_report_issue_template", "discovery_or_shaping_issue_template", "issue_template_config"
          analysis[:facts][:issue_template_components].fetch(name, [])
        else []
        end
      end

      def state_rationale(state)
        {
          "framework_exact" => "Exact current-framework correspondence was established by content identity.",
          "framework_like" => "A recognised framework-style artefact exists, but current-framework provenance was not established.",
          "repository_native" => "A repository-native mechanism provides the capability without claiming framework provenance."
        }.fetch(state)
      end

      def tier_recommendation(analysis, readiness, gaps, context, conflicts)
        blocking = gaps.select { |gap| gap["severity"] == "blocking" }.map { |gap| gap["id"] }
        manual = conflicts.any? || readiness["repository_context"]["status"] == "blocked" || readiness["sensitive_area_guidance"]["status"] == "missing" || %w[missing unknown].include?(readiness["repository_context"]["status"])
        tier1 = !manual && %w[ready partial].include?(readiness["repository_context"]["status"]) && %w[ready partial].include?(readiness["task_boundary"]["status"])
        tier2 = tier1 && readiness["command_surface"]["status"] == "ready" && readiness["deterministic_validation"]["status"] == "ready" && readiness["ci_alignment"]["status"] != "partial" && readiness["ci_alignment"]["status"] != "blocked"
        tier3_components = tier_components("tier-3")
        tier3 = tier2 && tier3_components.all? { |name| tier_component_supported?(name, analysis) }
        outcome = if manual || !tier1
                    "manual_review_required"
                  elsif tier3
                    "tier-3"
                  elsif tier2
                    "tier-2"
                  else
                    "tier-1"
                  end
        confidence = if outcome == "manual_review_required"
                       "low"
                     elsif outcome == "tier-3"
                       "high"
                     elsif outcome == "tier-2"
                       "high"
                     else
                       "medium"
                     end
        {
          "outcome" => outcome,
          "confidence" => confidence,
          "evidence_ids" => readiness.values.flat_map { |item| item["evidence_ids"] }.uniq.sort_by { |id| id.delete_prefix("E").to_i },
          "blocking_gap_ids" => blocking,
          "assumptions" => ["The supplied target path is treated as the repository-level adoption scope."],
          "alternative_conditions" => alternative_conditions(readiness, outcome)
        }
      end

      def alternative_conditions(readiness, outcome)
        return ["Resolve the repository-context and safety findings before selecting a tier."] if outcome == "manual_review_required"

        conditions = []
        conditions << "Tier 2 becomes supportable when a stable command surface and deterministic validation are documented." unless readiness["command_surface"]["status"] == "ready" && readiness["deterministic_validation"]["status"] == "ready"
        conditions << "Tier 3 requires discoverable architecture, domain, testing, and repository conventions that can be specialised without invention." unless outcome == "tier-3"
        conditions
      end

      def tier_components(tier_id)
        tier = @catalogue.tiers.find { |item| item["id"] == tier_id }
        return [] unless tier

        tier.fetch("includes", []).filter_map do |target_path|
          @catalogue.components.find { |component| component["target_path"] == target_path }&.fetch("name")
        end
      end

      def tier_component_supported?(name, analysis)
        framework_states(analysis).any? do |item|
          item["component"] == name && %w[framework_exact framework_like repository_native].include?(item["state"])
        end
      end

      def component_recommendations(states, analysis, gap_ids, tier)
        by_name = states.to_h { |item| [item["component"], item] }
        @catalogue.components.map do |component|
          name = component["name"]
          detected = by_name[name]
          state, rationale, prereqs = if detected
                                       component_state_for_detected(detected)
                                     else
                                       component_state_for_missing(component, analysis, gap_ids, tier)
                                     end
          {
            "component" => name,
            "state" => state,
            "confidence" => detected ? (detected["state"] == "framework_exact" || detected["state"] == "repository_native" ? "high" : "medium") : "low",
            "evidence_ids" => detected ? detected["evidence_ids"] : [],
            "rationale" => rationale,
            "prerequisite_gap_ids" => prereqs
          }
        end.sort_by { |item| item["component"] }
      end

      def component_state_for_detected(detected)
        case detected["state"]
        when "framework_exact" then ["adopt_now", "Current framework content is present; retain it and review its applicability.", []]
        when "framework_like" then ["specialise_now", "A framework-like artefact is present; confirm provenance and specialise it to repository evidence.", []]
        when "repository_native" then ["already_satisfied_by_repository_native", "The repository-native mechanism satisfies this capability; preserve it unless review identifies a substantive gap.", []]
        end
      end

      def component_state_for_missing(component, analysis, gap_ids, tier)
        name = component["name"]
        if name == "github_access_helper" && analysis[:facts][:ecosystems].empty?
          return ["not_applicable", "No supported project or GitHub-access requirement was established by static evidence.", []]
        end
        if %w[agent_launcher claude_agent_entrypoint github_access_helper git_hooks].include?(name)
          return ["evaluate_later", "This optional runtime or hook component should be evaluated only if its access and workflow value is established.", []]
        end
        if name == "ci_workflow" && analysis[:tooling]["ci"]["workflow_paths"].empty?
          return ["evaluate_later", "No CI workflow is present; absence is not treated as a defect without repository-owner policy.", []]
        end
        if %w[agent_prompt commit_metadata].include?(name)
          return ["defer", "The current repository does not establish a need for this source-repository session artefact.", []]
        end
        prereqs = []
        if name == "command_interface" || %w[testing_strategy development_guide].include?(name) || %w[command_surface deterministic_validation local_setup_reproducibility].include?(component["category"])
          prereqs.concat(gap_ids.values_at("command_surface:No stable local command surface was detected", "deterministic_validation:Deterministic validation evidence is incomplete").compact)
        end
        state = prereqs.any? ? "adopt_after_prerequisite" : "adopt_now"
        [state, "The capability is not currently detected; adopt it incrementally using repository evidence and native conventions.", prereqs]
      end

      def roadmap(recommendations, gaps, gap_ids)
        items = []
        gaps.each do |gap|
          component = component_for_dimension(gap["readiness_dimension"])
          phase = gap["severity"] == "blocking" ? 0 : 1
          items << {
            "key" => "gap:#{gap["id"]}",
            "phase" => phase,
            "title" => gap["recommended_outcome"],
            "component" => component,
            "prerequisite_ids" => gap["prerequisite_gap_ids"],
            "gap_ids" => [gap["id"]],
            "rationale" => gap["why_it_matters"]
          }
        end
        recommendations.select { |item| %w[adopt_now specialise_now adopt_after_prerequisite].include?(item["state"]) }.each do |item|
          next if items.any? { |roadmap_item| roadmap_item["component"] == item["component"] }

          plan = ROADMAP_COMPONENT_PLAN[item["component"]]
          next unless plan

          items << {
            "key" => "component:#{item["component"]}",
            "phase" => plan["phase"],
            "title" => plan["title"],
            "component" => item["component"],
            "prerequisite_ids" => item["prerequisite_gap_ids"],
            "gap_ids" => item["prerequisite_gap_ids"],
            "rationale" => item["rationale"]
          }
        end
        ordered = items.sort_by { |item| [item["phase"], item["title"], item["component"]] }
        step_ids = ordered.each_with_index.to_h { |item, index| [item["key"], format("STEP-%03d", index + 1)] }
        gap_to_steps = ordered.each_with_object({}) do |item, result|
          item["gap_ids"].each { |gap_id| result[gap_id] ||= step_ids[item["key"]] }
        end
        ordered.each_with_index.map do |item, index|
          {
            "id" => format("STEP-%03d", index + 1),
            "phase" => item["phase"],
            "title" => item["title"],
            "component" => item["component"],
            "prerequisite_ids" => item["prerequisite_ids"].filter_map { |gap_id| gap_to_steps[gap_id] }.uniq.sort,
            "gap_ids" => item["gap_ids"].uniq.sort,
            "rationale" => item["rationale"]
          }
        end
      end

      def component_for_dimension(dimension)
        {
          "repository_context" => "agent_instructions",
          "task_boundary" => "agent_ready_issue_template",
          "command_surface" => "command_interface",
          "deterministic_validation" => "testing_strategy",
          "ci_alignment" => "ci_workflow",
          "sensitive_area_guidance" => "agent_instructions",
          "runtime_access" => "agent_launcher",
          "review_handoff" => "pull_request_template",
          "local_setup_reproducibility" => "development_guide"
        }.fetch(dimension, "agent_instructions")
      end

      def assumptions(analysis, context)
        values = ["Static inspection is limited to recognised repository metadata and documentation; arbitrary source code is not analysed.", "Existing repository-native mechanisms are treated as capability evidence, not as framework provenance."]
        values << "Assessor context supplements repository evidence and is not treated as a replacement for it." if context.provided?
        values
      end

      def unknowns(analysis, context)
        values = ["Static evidence cannot prove that a documented command succeeds or that an unobserved area does not exist.", "Repository semantics, ownership, security posture, and operational suitability require human review.", "The assessment does not recursively assess each project root in a multi-project repository."]
        values << "No assessor context was supplied for facts that are not discoverable from repository files." unless context.provided?
        values
      end
    end
  end
end
