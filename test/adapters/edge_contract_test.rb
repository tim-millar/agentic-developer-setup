# frozen_string_literal: true

require_relative "support"

class AdapterEdgeContractTest < AdapterTest
  def test_contradictory_version_range_is_invalid_metadata
    register("ruby")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: ">= 2.0, < 1.0")])
    assert_match(/contradictory/, assert_raises(A::Error) { registry }.message)
  end

  def test_separate_requirements_with_disjoint_version_ranges_are_invalid
    register("ruby")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: ">= 2.0"), requirement("ecosystem", "ruby", version: "< 2.0")])
    assert_match(/contradictory/, assert_raises(A::Error) { registry }.message)
  end

  def test_required_range_fully_excluded_by_versioned_incompatibility_is_invalid
    register("ruby")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: "~> 1.0")], incompatible: [requirement("ecosystem", "ruby", version: ">= 1.0, < 2.0")])
    assert_raises(A::Error) { registry }
  end

  def test_partial_version_incompatibility_can_be_valid_metadata
    register("ruby", version: "1.5.0")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: "~> 1.0")], incompatible: [requirement("ecosystem", "ruby", version: "< 1.2")])
    assert_equal "ready", assess(selected(["ecosystem", "ruby"], ["framework", "rails"])).dig("composition", "status")
  end

  def test_fully_qualified_provider_class_can_use_public_framework_helpers
    register("ruby")
    source = <<~RUBY_SOURCE
      class AgenticDeveloperSetup::Adapters::Providers::Synthetic
        def detect(context)
          []
        end
        def contribute(context, inputs:)
          AgenticDeveloperSetup::Adapters::Contributions.empty
        end
      end
    RUBY_SOURCE
    File.write(File.join(@framework, "adapters/ecosystems/ruby/adapter.rb"), source)
    assert_equal "ready", assess(selected(["ecosystem", "ruby"])).dig("composition", "status")
  end

  def test_generic_positive_ecosystem_evidence_conflicts_even_when_adapter_is_planned
    write_target("package.json", '{"name":"static-node-project"}')
    register("node", status: "planned")
    register("ruby")
    result = assess(selected(["ecosystem", "ruby"]))
    assert_includes codes(result), "repository_evidence_conflict"
    assert_equal "blocked", result.dig("composition", "status")
  end

  def test_explicit_without_positive_detection_records_uncertainty_evidence
    register("ruby")
    result = assess(selected(["ecosystem", "ruby"]))
    candidate = result["candidates"].first
    assert_equal "not_detected", candidate["status"]
    assert_equal 1, candidate["ambiguities"].size
    assert result["evidence"].any? { |item| candidate["ambiguities"].include?(item["id"]) && item["method"] == "explicit_selection_without_detection" }
  end

  def test_explicit_inputs_are_preserved_without_defaults
    register("ruby", inputs: [input("ecosystem/ruby.choice")])
    inputs = [{"key" => "ecosystem/ruby.choice", "value" => "explicit-value"}]
    result = assess(selected(["ecosystem", "ruby"], inputs: inputs))
    assert_equal inputs, result.dig("composition", "explicit_inputs")
  end

  def test_excluded_workspace_cannot_bypass_inventory
    write_target("node_modules/Gemfile")
    register("ruby")
    document = selected(["ecosystem", "ruby"], scope: {"type" => "workspace", "path" => "node_modules"})
    assert_match(/excluded/, assert_raises(A::Error) { assess(document) }.message)
  end

  def test_nonplain_provider_values_cannot_be_coerced_to_valid_contract_values
    register("ruby")
    set = stamped("commands", [command(profiles: [:standard])])
    assert_match(/unsupported structured value/, assert_raises(A::Error) { pure_compose(set) }.message)
  end

  def test_provider_output_cannot_forge_provenance
    register("ruby", contributions: {"commands" => [command.merge("provenance" => [])]})
    assert_match(/provenance/, assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }.message)
  end

  def test_invalid_default_type_fails_registry_validation
    register("ruby", inputs: [input("ecosystem/ruby.choice", type: "boolean", default: "yes")])
    assert_raises(A::Error) { registry }
  end

  def test_invalid_resolution_kind_and_empty_rationale_fail_schema
    document = conflict_fixture
    resolution = decision(assess(document), "choose_command", {"contribution_id" => "ruby-test"})
    document["resolutions"] = [resolution.merge("kind" => "ignore_conflict")]
    assert_raises(A::Error) { assess(document) }
    document["resolutions"] = [resolution.merge("rationale" => "")]
    assert_raises(A::Error) { assess(document) }
  end

  def test_manifest_and_selection_contracts_close_nested_objects
    register("ruby")
    mutate_manifest("ruby") { |manifest| manifest["compatibility"]["unknown"] = [] }
    assert_raises(A::Error) { registry }
    mutate_manifest("ruby") { |manifest| manifest["compatibility"].delete("unknown") }
    document = selected(["ecosystem", "ruby"])
    document["scope"]["unknown"] = true
    assert_raises(A::Error) { assess(document) }
  end

  def test_provider_detection_requires_resolvable_static_evidence
    register("ruby")
    path = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    File.write(path, File.read(path).sub("return [] unless MARKER", 'return [IDENTITY.merge("scope" => context.scope, "status" => "detected", "confidence" => "high", "evidence" => [], "ambiguities" => [], "incompatible_evidence" => [])] unless MARKER'))
    assert_match(/requires static evidence/, assert_raises(A::Error) { assess }.message)
  end

  def test_equivalent_findings_keep_related_references_valid
    finding = {"id" => "ruby-risk", "category" => "risk", "severity" => "review_required", "confidence" => "high", "summary" => "Shared risk", "evidence_ids" => [], "related_finding_ids" => [], "equivalence_id" => "shared-risk"}
    related = finding.merge("id" => "related", "summary" => "Different risk", "equivalence_id" => "other-risk", "related_finding_ids" => ["ruby-risk"])
    register("ruby", contributions: {"findings" => [finding]})
    register("rails", "framework", contributions: {"findings" => [finding.merge("id" => "rails-risk"), related]})
    records = assess(selected(["ecosystem", "ruby"], ["framework", "rails"])).dig("composition", "contributions", "findings")
    ids = records.map { |item| item["id"] }
    assert_equal 2, ids.size
    assert_equal ["rails-risk"], records.find { |item| item["id"] == "related" }["related_finding_ids"]
    assert records.all? { |item| (item["related_finding_ids"] - ids).empty? }
  end

  def test_multiple_requirements_based_projects_block_repository_scope
    write_target("apps/one/requirements.txt", "sample==1.0\n")
    write_target("apps/two/requirements.txt", "sample==1.0\n")
    register("python")
    assert_includes codes(assess(selected(["ecosystem", "python"]))), "scope_conflict"
  end

  def test_same_python_project_can_have_pyproject_and_requirements
    write_target("pyproject.toml", "[project]\nname = 'synthetic'\n")
    write_target("requirements.txt", "sample==1.0\n")
    register("python")
    assert_equal "ready", assess(selected(["ecosystem", "python"])).dig("composition", "status")
  end

  def test_recorded_identity_comparison_validates_versions_and_digests
    register("ruby")
    record = registry.supported.first.to_h
    record["provider_digest"] = "invalid"
    assert_raises(A::Error) { registry.compare(record) }
  end

  def test_credential_bearing_arguments_are_rejected_without_disclosure
    register("ruby", contributions: {"commands" => [command(argv: ["tool", "--password", "synthetic-secret"])]})
    error = assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
    refute_includes error.message, "synthetic-secret"
  end

  def test_manifest_version_cannot_have_a_trailing_newline
    register("ruby", version: "1.0.0\n")
    assert_raises(A::Error) { registry }
  end

  def test_composer_does_not_read_files_or_run_processes
    register("ruby")
    definitions = registry.supported
    set = stamped("commands", [command])
    composer = A::Composer.new(definitions: definitions, scope: @scope, contributions: set)
    trace = TracePoint.new(:c_call) do |event|
      filesystem = event.self == File && %i[binread read open write binwrite].include?(event.method_id)
      process = event.method_id == :spawn
      flunk "pure composition attempted filesystem or process access" if filesystem || process
    end
    result = trace.enable(target_thread: Thread.current) { composer.compose }
    assert_equal "ready", result.dig("composition", "status")
  end
end
