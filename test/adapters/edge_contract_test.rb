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

  def test_repeated_composition_is_pure_after_finding_deduplication
    finding = {"id" => "one", "category" => "risk", "severity" => "review_required", "confidence" => "high", "summary" => "Shared risk", "evidence_ids" => [], "related_finding_ids" => [], "equivalence_id" => "shared"}
    register("ruby")
    set = stamped("findings", [finding, finding.merge("id" => "two")])
    composer = A::Composer.new(definitions: registry.supported, scope: @scope, contributions: set)
    assert_equal composer.compose, composer.compose
    assert_equal 2, set["findings"].size
  end

  def test_three_overlapping_owners_have_one_consistent_explicit_resolution
    register("ruby", contributions: {"paths" => [path("one", owner: "one"), path("two", owner: "two"), path("three", owner: "three")]})
    document = selected(["ecosystem", "ruby"])
    blocked = assess(document)
    assert_equal 1, blocked["conflicts"].size
    document["resolutions"] = [decision(blocked, "choose_path_owner", {"owner" => "three"}, code: "path_ownership_conflict")]
    assert_equal "ready", assess(document).dig("composition", "status")
  end

  def test_command_override_cannot_collide_with_unrelated_command_identity
    register("ruby", contributions: {"commands" => [command, command("ruby-lint", capability: "lint")]})
    register("rails", "framework", contributions: {"commands" => [command("rails-test", argv: %w[bin rails test])]})
    document = selected(["ecosystem", "ruby"], ["framework", "rails"])
    blocked = assess(document)
    document["resolutions"] = [decision(blocked, "override_command", {"command" => command("ruby-lint")})]
    assert_match(/collides/, assert_raises(A::Error) { assess(document) }.message)
  end

  def test_shared_input_policy_recognises_camel_case_names_without_substring_false_positives
    %w[apiToken clientSecret privateKey sessionCookie signingKey encryptionKey authenticationCredentials AUTHORIZATION apikey accesskey privatekey signingkey encryptionkey].each do |name|
      assert_raises(A::Error, name) { A::InputValues.validate_name!("ecosystem/ruby.#{name}") }
    end
    %w[tokenization tokenisation tokenizer keymap project_id authentication_mode].each do |name|
      declaration = input("ecosystem/ruby.#{name}", required: false)
      assert_equal "ordinary", A::InputValues.validate_value!(declaration, "ordinary")
    end
  end

  def test_shared_input_policy_rejects_recognisable_credentials_in_composer_and_context
    register("ruby", inputs: [input("ecosystem/ruby.choice", required: false)])
    header = [JSON.generate({"alg" => "HS256", "typ" => "JWT"})].pack("m0").tr("+/", "-_").delete("=")
    payload = [JSON.generate({"sub" => "synthetic", "exp" => 1234567890})].pack("m0").tr("+/", "-_").delete("=")
    custom_payload = [JSON.generate({"role" => "synthetic"})].pack("m0").tr("+/", "-_").delete("=")
    credentials = ["-----BEGIN RSA PRIVATE KEY-----\nsynthetic\n-----END RSA PRIVATE KEY-----",
      "Bearer synthetic_bearer_value_123456", "  Authorization: Bearer synthetic_header_token  ", "ghp_" + "SyntheticValue" * 3,
      "github_pat_" + "SyntheticValue" * 3, "glpat-" + "SyntheticValue" * 3,
      "xox" + "b-" + ["1234567890", "SyntheticValue"].join("-"), "sk-proj-" + "SyntheticValue" * 3,
      "sk_live_" + "SyntheticValue" * 3, "AKIA" + "A" * 16,
      "API_TOKEN=synthetic-sensitive-assignment", "https://user:synthetic-sensitive-password@example.invalid/service",
      "#{header}.#{payload}.#{"S" * 24}", "#{header}.#{custom_payload}.#{"S" * 24}"]
    credentials.each do |credential|
      supplied = {"ecosystem/ruby.choice" => credential}
      error = assert_raises(A::Error) { pure_compose(A::Contributions.empty, inputs: supplied) }
      refute_includes error.full_message, credential
      inventory = AgenticDeveloperSetup::Assessment::Inventory.new(Pathname.new(@target)).discover
      evidence = AgenticDeveloperSetup::Assessment::Evidence.new
      error = assert_raises(A::Error) { A::Context.new(scope: @scope, inventory: inventory, root: @target, evidence: evidence, inputs: supplied) }
      refute_includes error.full_message, credential
    end
  end

  def test_provider_contributed_defaults_and_allowed_values_use_non_secret_policy
    register("ruby")
    credential = "Bearer synthetic_sensitive_provider_value"
    [input("ecosystem/ruby.choice", required: false, default: credential),
      input("ecosystem/ruby.choice", required: false, allowed_values: [credential])].each do |declaration|
      error = assert_raises(A::Error) { pure_compose(stamped("inputs", [declaration.merge("id" => "choice")])) }
      refute_includes error.full_message, credential
    end
  end

  def test_benign_strings_and_value_free_secret_requirements_remain_supported
    register("ruby", inputs: [input("ecosystem/ruby.choice", required: false)])
    %w[ordinary-project-123 apps/api-service npm:test abc.def.ghi https://example.invalid/tokenization].each do |value|
      assert_equal "ready", pure_compose(A::Contributions.empty, inputs: {"ecosystem/ruby.choice" => value}).dig("composition", "status")
    end
    register("docker", "runtime")
    record = {"id" => "credentials-required", "kind" => "secret", "description" => "Requires repository-managed database credentials; no value is supplied."}
    result = pure_compose(stamped("requirements", [record], id: "docker"))
    assert_equal "ready", result.dig("composition", "status")
    refute result.dig("composition", "contributions", "requirements", 0).key?("value")
  end

  def test_provider_invocation_errors_are_sanitised_and_critical_failures_propagate
    register("ruby")
    {"detect" => {detect: 'raise "synthetic-sensitive-detection"'},
     "contribute" => {contribute: 'raise "synthetic-sensitive-contribution"'}}.each do |phase, arguments|
      install_provider("ruby", **arguments)
      error = assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
      assert_includes error.message, "ecosystem/ruby"
      assert_includes error.message, phase
      refute_includes error.full_message, "synthetic-sensitive"
      assert_nil error.cause
    end
    %w[SystemExit Interrupt NoMemoryError].each do |name|
      install_provider("ruby", detect: "raise #{name}")
      assert_raises(Object.const_get(name)) { assess }
      install_provider("ruby", contribute: "raise #{name}")
      assert_raises(Object.const_get(name)) { assess(selected(["ecosystem", "ruby"])) }
    end
  end
end
