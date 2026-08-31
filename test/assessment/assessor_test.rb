# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentAssessorTest < Minitest::Test
  include AssessmentTestSupport

  def test_sensitive_path_without_specific_guidance_is_missing_and_blocks_tier
    write("AGENTS.md", "# Repository instructions\nUse normal review.\n")
    context = context_file(sensitive_paths: ["config/production"])

    result = assess(@target, context_path: context)

    assert_equal "missing", result.dig("readiness", "sensitive_area_guidance", "status")
    assert_equal "manual_review_required", result.dig("tier_recommendation", "outcome")
    assert result["gaps"].any? { |gap| gap["readiness_dimension"] == "sensitive_area_guidance" && gap["severity"] == "blocking" }
  end

  def test_sensitive_path_with_explicit_handling_guidance_is_supportable
    write("AGENTS.md", "# Repository instructions\nSensitive paths contain credentials. Do not edit restricted files without human review; access boundaries apply.\n")
    context = context_file(sensitive_paths: ["config/production"])

    result = assess(@target, context_path: context)

    assert_equal "ready", result.dig("readiness", "sensitive_area_guidance", "status")
  end

  def test_security_guidance_is_assessed_without_supplied_sensitive_paths
    write("SECURITY.md", "Sensitive areas and credentials are restricted; review access and handling before changes.\n")

    result = assess

    assert_equal "ready", result.dig("readiness", "sensitive_area_guidance", "status")
  end

  def test_issue_template_native_equivalence_is_component_specific
    write(".github/ISSUE_TEMPLATE/defect.md", "# Bug report\nSteps to reproduce\n")

    components = assess["framework_adoption"]["detected_components"].to_h { |item| [item["component"], item] }

    assert_equal "repository_native", components.fetch("bug_report_issue_template")["state"]
    refute components.key?("agent_ready_issue_template")
    refute components.key?("discovery_or_shaping_issue_template")
    refute components.key?("issue_template_config")
  end

  def test_each_other_issue_template_component_requires_its_own_evidence
    write(".github/ISSUE_TEMPLATE/implementation.md", "# Implementation\nAcceptance criteria and non-goals\n")
    write(".github/ISSUE_TEMPLATE/questions.md", "# Discovery\nProblem statement and open questions\n")
    write(".github/ISSUE_TEMPLATE/chooser.yml", "blank_issues_enabled: true\n")

    components = assess["framework_adoption"]["detected_components"].to_h { |item| [item["component"], item] }

    assert_equal "repository_native", components.fetch("agent_ready_issue_template")["state"]
    assert_equal "repository_native", components.fetch("discovery_or_shaping_issue_template")["state"]
    assert_equal "repository_native", components.fetch("issue_template_config")["state"]
    refute components.key?("bug_report_issue_template")
  end

  def test_gitignore_does_not_satisfy_commit_metadata
    write(".gitignore", ".env\n")

    result = assess

    refute result["framework_adoption"]["detected_components"].any? { |item| item["component"] == "commit_metadata" }
    assert_equal "defer", result["component_recommendations"].find { |item| item["component"] == "commit_metadata" }["state"]
  end

  def test_bare_package_manifest_does_not_satisfy_command_interface
    write("package.json", "{\"name\":\"bare\"}\n")

    result = assess

    refute result["framework_adoption"]["detected_components"].any? { |item| item["component"] == "command_interface" }
    refute result["component_recommendations"].any? { |item| item["component"] == "command_interface" && item["state"] == "already_satisfied_by_repository_native" }
  end

  def test_package_script_can_satisfy_command_interface
    write("package.json", "{\"scripts\":{\"verify\":\"echo verify\"}}\n")

    result = assess
    component = result["framework_adoption"]["detected_components"].find { |item| item["component"] == "command_interface" }

    assert_equal "repository_native", component["state"]
    assert_equal ["package.json"], component["paths"]
  end

  def test_testing_strategy_never_fabricates_a_tests_path
    write("test/example_test.py", "sentinel\n")
    write("pyproject.toml", "[project]\nname = \"sample\"\n")

    result = assess

    refute result["framework_adoption"]["detected_components"].any? { |item| item["component"] == "testing_strategy" }
    result["component_recommendations"].each do |recommendation|
      recommendation["evidence_ids"].each { |evidence_id| assert result["evidence"].any? { |item| item["id"] == evidence_id } }
    end
  end

  def test_testing_documentation_is_the_native_testing_strategy_evidence
    write("docs/testing-guide.md", "Testing guidance\n")

    result = assess
    component = result["framework_adoption"]["detected_components"].find { |item| item["component"] == "testing_strategy" }

    assert_equal "repository_native", component["state"]
    assert_equal ["docs/testing-guide.md"], component["paths"]
  end

  def test_task_boundary_requires_all_four_concerns
    write(".github/ISSUE_TEMPLATE/task.md", "Scope only\n")

    assert_equal "partial", assess.dig("readiness", "task_boundary", "status")
  end

  def test_task_boundary_can_be_complete_across_workflow_documents
    write(".github/ISSUE_TEMPLATE/task.md", "Scope and acceptance criteria.\nNon-goals.\n")
    write(".github/PULL_REQUEST_TEMPLATE.md", "Implementation boundaries and constraints.\n")

    assert_equal "ready", assess.dig("readiness", "task_boundary", "status")
  end

  def test_tier_three_requires_architecture_domain_testing_and_commit_evidence
    write("README.md", "# Service\n")
    write("docs/ARCHITECTURE.md", "Architecture boundaries.\n")
    write("docs/DOMAIN.md", "Domain context.\n")
    write("docs/TESTING.md", "Testing strategy.\n")
    write("docs/COMMITS.md", "Commit conventions.\n")
    write("pyproject.toml", "[project]\ndependencies = [\"pytest\"]\n")
    write("Makefile", "verify:\n\t@echo verify\n")
    write(".github/ISSUE_TEMPLATE/task.md", "Scope. Acceptance criteria. Non-goals. Implementation boundaries.\n")
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: make verify\n")

    assert_equal "tier-3", assess.dig("tier_recommendation", "outcome")
  end

  def test_tier_two_does_not_require_tier_three_specialisation_evidence
    write("README.md", "# Service\n")
    write("docs/ARCHITECTURE.md", "Architecture boundaries.\n")
    write("pyproject.toml", "[project]\ndependencies = [\"pytest\"]\n")
    write("Makefile", "verify:\n\t@echo verify\n")
    write(".github/ISSUE_TEMPLATE/task.md", "Scope. Acceptance criteria. Non-goals. Implementation boundaries.\n")
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: make verify\n")

    assert_equal "tier-2", assess.dig("tier_recommendation", "outcome")
  end

  def test_context_conflict_is_attributed_to_low_criticality
    write("README.md", "This is a critical production service.\n")
    result = assess(@target, context_path: context_file(criticality: "low"))

    assert_equal [["repository.criticality", "low"]], context_conflict_fields(result)
  end

  def test_context_conflict_is_attributed_to_low_deployment_impact
    write("README.md", "This is a critical production service.\n")
    result = assess(@target, context_path: context_file(criticality: "high", deployment_impact: "low"))

    assert_equal [["repository.deployment_impact", "low"]], context_conflict_fields(result)
  end

  def test_context_conflict_is_attributed_to_low_criticality_when_impact_is_high
    write("README.md", "This is a critical production service.\n")
    result = assess(@target, context_path: context_file(criticality: "low", deployment_impact: "high"))

    assert_equal [["repository.criticality", "low"]], context_conflict_fields(result)
  end

  def test_both_low_context_fields_produce_two_explicit_conflicts
    write("README.md", "This is a critical production service.\n")
    result = assess(@target, context_path: context_file(criticality: "low", deployment_impact: "none"))

    assert_equal [["repository.criticality", "low"], ["repository.deployment_impact", "none"]], context_conflict_fields(result)
  end

  def test_both_high_context_fields_do_not_conflict_with_high_impact_evidence
    write("README.md", "This is a critical production service.\n")
    result = assess(@target, context_path: context_file(criticality: "high", deployment_impact: "high"))

    assert_empty result["assessor_context"]["conflicts"]
  end

  def test_low_context_field_does_not_conflict_without_high_impact_evidence
    write("README.md", "A small local example service.\n")
    result = assess(@target, context_path: context_file(criticality: "low"))

    assert_empty result["assessor_context"]["conflicts"]
  end

  def test_ci_secret_risk_contains_resolved_public_evidence_ids
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: echo ${{ secrets.DEPLOY_TOKEN }}\n")

    result = assess
    risk = result["risks"].find { |item| item["category"] == "ci_requires_unavailable_secrets" }

    refute_nil risk
    assert risk["evidence_ids"].all? { |id| id.match?(/\AE\d{3}\z/) }
    assert_schema(result)
  end

  def test_roadmap_uses_component_phase_mapping_and_non_boilerplate_actions
    write("README.md", "# Service\n")
    write("pyproject.toml", "[project]\nname = 'sample'\ndependencies = ['pytest']\n")
    write("Makefile", "verify:\n\t@echo verify\n")
    write(".github/ISSUE_TEMPLATE/task.md", "Scope. Acceptance criteria. Non-goals. Implementation boundaries.\n")

    result = assess
    roadmap = result["roadmap"]

    assert_equal 1, roadmap.find { |item| item["component"] == "agent_instructions" }["phase"]
    assert_equal 1, roadmap.find { |item| item["component"] == "command_interface" }["phase"]
    assert_equal 2, roadmap.find { |item| item["component"] == "bug_report_issue_template" }["phase"]
    refute roadmap.any? { |item| item["title"].start_with?("Review and") }
  end

  def test_blocking_gaps_are_phase_zero
    result = assess
    blocking_gap_ids = result["gaps"].select { |gap| gap["severity"] == "blocking" }.map { |gap| gap["id"] }

    refute_empty blocking_gap_ids
    blocking_gap_ids.each do |gap_id|
      assert result["roadmap"].any? { |item| item["phase"] == 0 && item["gap_ids"].include?(gap_id) }
    end
  end

  def test_native_components_are_not_given_separate_component_boilerplate
    write("docs/testing-guide.md", "Testing guidance.\n")

    result = assess
    native = result["framework_adoption"]["detected_components"].find { |item| item["component"] == "testing_strategy" }

    assert_equal "repository_native", native["state"]
    refute result["roadmap"].any? { |item| item["title"].match?(/testing strategy/i) && item["gap_ids"].empty? }
  end

  private

  def context_file(sensitive_paths: [], criticality: nil, deployment_impact: nil)
    path = File.join(@temporary_root, "context.yml")
    repository = {}
    repository["criticality"] = criticality if criticality
    repository["deployment_impact"] = deployment_impact if deployment_impact
    write_absolute(path, YAML.dump(
      "schema_version" => 1,
      "repository" => repository,
      "sensitive_paths" => sensitive_paths,
      "approved_agent_runtimes" => [],
      "review_requirements" => [],
      "known_setup_constraints" => [],
      "notes" => []
    ))
    path
  end

  def context_conflict_fields(result)
    result.fetch("assessor_context").fetch("conflicts").map { |item| [item["field"], item["context_value"]] }
  end
end
