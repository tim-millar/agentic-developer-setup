# frozen_string_literal: true

require_relative "support"

class AdapterCompositionTest < AdapterTest
  def test_base_refinement_wrapper_end_to_end
    write_target("Gemfile", "source 'https://example.invalid'\n")
    write_target("Dockerfile", "FROM scratch\n")
    register("ruby", marker: "Gemfile", contributions: {"commands" => [command]})
    register("rails", "framework", marker: "Gemfile", requires: [requirement("ecosystem", "ruby", version: ">= 1.0.0")], contributions: {"commands" => [refinement]})
    register("docker", "runtime", marker: "Dockerfile", contributions: {"command_wrappers" => [wrapper]})
    document = selected(["ecosystem", "ruby"], ["framework", "rails"], ["runtime", "docker"])
    result = assess(document)
    assert_equal "ready", result.dig("composition", "status")
    assert_equal "ready", result.dig("compatibility", "status")
    final = result.dig("composition", "commands").first
    assert_equal %w[docker compose run --rm app bundle exec rspec], final["argv"]
    assert_equal %w[extended standard], final["profiles"]
    assert_equal ["migration review"], final["preconditions"]
    assert_equal %w[automated_test integration_test], final["classification"]
    assert_equal %w[docker rails ruby], final["provenance"].map { |item| item["adapter_id"] }.sort
    assert_equal 3, result["candidates"].size
    assert_equal "satisfied", result.dig("compatibility", "checks", 0, "outcome")
    assert_equal result, YAML.safe_load(YAML.dump(result))
    assert_equal result, assess(document)
  end

  {"sinatra" => "ruby", "phoenix" => "elixir", "hydrogen" => "node", "fastapi" => "python"}.each do |framework, ecosystem|
    define_method("test_synthetic_#{ecosystem}_#{framework}_composition") do
      register(ecosystem, contributions: {"commands" => [command("#{ecosystem}-test")]})
      register(framework, "framework", requires: [requirement("ecosystem", ecosystem)], contributions: {})
      pairs = [["ecosystem", ecosystem], ["framework", framework]]
      if %w[sinatra fastapi].include?(framework)
        register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(command_id: "#{ecosystem}-test")]})
        pairs << ["runtime", "docker"]
      else
        register("non-containerised", "runtime")
        pairs << ["runtime", "non-containerised"]
      end
      assert_equal "ready", assess(selected(*pairs)).dig("composition", "status")
    end
  end

  def test_ecosystem_runtime_without_framework
    register("ruby", contributions: {"commands" => [command]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper]})
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal "docker", result.dig("composition", "commands", 0, "argv", 0)
  end

  def test_specialised_framework_command_keeps_generic_command
    register("ruby", contributions: {"commands" => [command]})
    register("rails", "framework", contributions: {"commands" => [command("rails-migrate", capability: "migration", argv: %w[bin rails db:migrate])]})
    result = assess(selected(["ecosystem", "ruby"], ["framework", "rails"]))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal %w[migration test], result.dig("composition", "commands").map { |item| item["capability"] }.sort
  end

  def test_argument_boundaries_preserved
    args = ["tool", "two words", "$(never-execute)", "semi;colon", "quote'and\"double"]
    register("ruby", contributions: {"commands" => [command(argv: args)]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(prefix: ["runner", "service with spaces"], suffix_argv: ["trailing argument"])]})
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_equal ["runner", "service with spaces", *args, "trailing argument"], result.dig("composition", "commands", 0, "argv")
  end

  def test_optional_app_shape_adds_profiles_risk_and_documentation
    register("ruby", contributions: {"commands" => [command]})
    register("monolith", "app-shape", contributions: {
      "validation_profiles" => [{"id" => "monolith-profile", "profile" => "extended", "command_ids" => ["ruby-test"], "emphasis" => "Integration boundaries"}],
      "requirements" => [{"id" => "monolith-risk", "kind" => "risk", "description" => "Review changes across boundaries"}],
      "documentation_requirements" => [{"id" => "monolith-doc", "description" => "Document module boundaries"}]
    })
    result = assess(selected(["ecosystem", "ruby"], ["app-shape", "monolith"]))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal %w[extended standard], result.dig("composition", "commands", 0, "profiles")
    assert_equal 1, result.dig("composition", "contributions", "requirements").size
  end

  %w[commands command_wrappers services paths inputs].each do |domain|
    define_method("test_app_shape_cannot_supply_#{domain}") do
      record = case domain
      when "commands" then command
      when "command_wrappers" then wrapper
      when "services" then {"id" => "database", "kind" => "binding", "service_id" => "database", "implementation" => "db"}
      when "paths" then path("protected")
      when "inputs" then {"id" => "input"}.merge(input("app-shape/monolith.choice"))
      end
      register("ruby")
      register("monolith", "app-shape", contributions: {domain => [record]})
      assert_match(/unsupported_contribution/, assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], ["app-shape", "monolith"])) }.message)
    end
  end

  def test_runtime_cannot_redefine_base_semantics
    register("ruby")
    register("docker", "runtime", contributions: {"commands" => [command]})
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], ["runtime", "docker"])) }
  end

  def test_runtime_can_add_preconditions_only
    register("ruby", contributions: {"commands" => [command]})
    record = refinement("runtime-precondition").merge("profiles" => [], "classification" => [])
    register("docker", "runtime", contributions: {"commands" => [record]})
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_equal %w[bundle exec rspec], result.dig("composition", "commands", 0, "argv")
    assert_equal ["migration review"], result.dig("composition", "commands", 0, "preconditions")
  end

  def test_paths_combine_conservatively
    register("ruby", contributions: {"paths" => [path("ruby-db", classifications: %w[protected sensitive])]})
    register("rails", "framework", contributions: {"paths" => [path("rails-db", classifications: %w[generated migration_or_schema]), path("rails-child", "db/schema.rb", classifications: ["framework_managed"])]})
    result = assess(selected(["ecosystem", "ruby"], ["framework", "rails"]))
    records = result.dig("composition", "contributions", "paths")
    child = records.find { |item| item["id"] == "rails-child" }
    assert_equal %w[framework_managed generated migration_or_schema protected sensitive], child["classifications"]
    assert_equal "ready", result.dig("composition", "status")
  end

  def test_path_ownership_conflict_and_explicit_resolution
    register("ruby", contributions: {"paths" => [path("ruby-db", owner: "ecosystem", classifications: ["protected"])]})
    register("rails", "framework", contributions: {"paths" => [path("rails-db", owner: "framework", classifications: ["generated"])]})
    document = selected(["ecosystem", "ruby"], ["framework", "rails"])
    blocked = assess(document)
    assert_equal "blocked", blocked.dig("composition", "status")
    resolution = decision(blocked, "choose_path_owner", {"owner" => "framework"}, code: "path_ownership_conflict")
    document["resolutions"] = [resolution]
    ready = assess(document)
    assert_equal "ready", ready.dig("composition", "status")
    assert ready.dig("composition", "contributions", "paths").all? { |item| item["classifications"].include?("protected") }
    assert_equal "resolved", ready["conflicts"].first["status"]
    document["resolutions"][0]["value"]["owner"] = "undeclared"
    assert_raises(A::Error) { assess(document) }
  end

  def test_services_logical_requirement_and_runtime_binding
    register("ruby", contributions: {"services" => [{"id" => "db-required", "kind" => "requirement", "service_id" => "database", "required_for" => ["standard"]}]})
    blocked = assess(selected(["ecosystem", "ruby"]))
    assert_includes codes(blocked), "unresolved_required_input"
    register("docker", "runtime", contributions: {"services" => [{"id" => "db-binding", "kind" => "binding", "service_id" => "database", "implementation" => "db"}]})
    assert_equal "ready", assess(selected(["ecosystem", "ruby"], ["runtime", "docker"])).dig("composition", "status")
  end

  def test_service_binding_conflict
    register("ruby")
    bindings = %w[one two].map { |name| {"id" => name, "kind" => "binding", "service_id" => "database", "implementation" => name} }
    register("docker", "runtime", contributions: {"services" => bindings})
    assert_includes codes(assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))), "service_binding_conflict"
  end

  def test_input_defaults_cannot_satisfy_required_values
    register("ruby", inputs: [input("ecosystem/ruby.choice", default: "suggestion")])
    document = selected(["ecosystem", "ruby"])
    assert_includes codes(assess(document)), "unresolved_required_input"
    document["inputs"] = [{"key" => "ecosystem/ruby.choice", "value" => "explicit"}]
    assert_equal "ready", assess(document).dig("composition", "status")
  end

  {"string" => "value", "boolean" => false, "integer" => 3, "relative_path" => "safe/path"}.each do |type, value|
    define_method("test_typed_#{type}_input") do
      register("ruby", inputs: [input("ecosystem/ruby.choice", type: type)])
      document = selected(["ecosystem", "ruby"], inputs: [{"key" => "ecosystem/ruby.choice", "value" => value}])
      assert_equal "ready", assess(document).dig("composition", "status")
      document["inputs"][0]["value"] = (type == "string") ? true : "../escape"
      assert_raises(A::Error) { assess(document) }
    end
  end

  def test_input_definition_conflict
    register("ruby", inputs: [input("ecosystem/ruby.choice")], contributions: {"inputs" => [{"id" => "input-choice"}.merge(input("ecosystem/ruby.choice", type: "boolean"))]})
    assert_includes codes(assess(selected(["ecosystem", "ruby"]))), "input_definition_conflict"
  end

  def test_component_recommendations_validate_catalogue_ids
    register("ruby", contributions: {"component_recommendations" => [{"id" => "component", "component_id" => "agent_instructions", "rationale" => "Document tools"}]})
    assert_equal "ready", assess(selected(["ecosystem", "ruby"])).dig("composition", "status")
    mutate_manifest("ruby") { |manifest| manifest["contribution_domains"].delete("component_recommendations") }
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
  end

  def test_unknown_component_rejected
    register("ruby", contributions: {"component_recommendations" => [{"id" => "component", "component_id" => "invented", "rationale" => "Unknown"}]})
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
  end

  def test_findings_are_additive_and_equivalent_findings_keep_provenance
    finding = {"id" => "ruby-risk", "category" => "risk", "severity" => "review_required", "confidence" => "high", "summary" => "Review migrations", "evidence_ids" => [], "related_finding_ids" => [], "equivalence_id" => "migration-review"}
    register("ruby", contributions: {"findings" => [finding]})
    register("rails", "framework", contributions: {"findings" => [finding.merge("id" => "rails-risk"), finding.merge("id" => "rails-other", "summary" => "Review schema ownership")]})
    result = assess(selected(["ecosystem", "ruby"], ["framework", "rails"]))
    findings = result.dig("composition", "contributions", "findings")
    assert_equal 3, findings.size # Same equivalence ID with different meaning must never flatten risks.
  end

  def test_identical_equivalent_findings_deduplicate
    finding = {"id" => "ruby-risk", "category" => "risk", "severity" => "review_required", "confidence" => "high", "summary" => "Review migrations", "evidence_ids" => [], "related_finding_ids" => [], "equivalence_id" => "migration-review"}
    register("ruby", contributions: {"findings" => [finding]})
    register("rails", "framework", contributions: {"findings" => [finding.merge("id" => "rails-risk")]})
    records = assess(selected(["ecosystem", "ruby"], ["framework", "rails"])).dig("composition", "contributions", "findings")
    assert_equal 1, records.size
    assert_equal 2, records.first["provenance"].size
  end

  def test_resolved_connected_path_group_has_one_effective_owner_and_keeps_claims_and_safety
    paths = [path("parent", "db", owner: "ruby", classifications: %w[protected sensitive]),
      path("child", "db/schema.rb", owner: "rails", classifications: ["migration_or_schema"]),
      path("descendant", "db/migrate", owner: "runtime", classifications: ["framework_managed"]),
      path("unrelated", "docs", owner: "repository", classifications: ["generated"])]
    register("ruby")
    set = stamped("paths", paths)
    blocked = pure_compose(set)
    assert_equal "blocked", blocked.dig("composition", "status")
    assert_equal 1, blocked["conflicts"].size
    resolution = decision(blocked, "choose_path_owner", {"owner" => "rails"}, code: "path_ownership_conflict")
    ready = pure_compose(set, resolutions: [resolution])
    assert_equal "ready", ready.dig("composition", "status")
    records = ready.dig("composition", "contributions", "paths")
    affected = records.reject { |item| item["id"] == "unrelated" }
    assert_equal ["rails"], affected.map { |item| item["owner"] }.uniq
    assert_equal %w[rails ruby runtime], affected.map { |item| item["original_owner"] }.sort
    affected.each do |item|
      assert_equal resolution["conflict_id"], item["ownership_resolution_id"]
      assert_equal "ruby", item["provenance"][0]["adapter_id"]
      assert_includes item["classifications"], "protected"
      assert_includes item["classifications"], "sensitive"
    end
    assert_includes affected.find { |item| item["id"] == "child" }["classifications"], "migration_or_schema"
    assert_equal blocked.dig("composition", "contributions", "paths").find { |item| item["id"] == "unrelated" }, records.find { |item| item["id"] == "unrelated" }
    assert_equal resolution, ready["conflicts"][0]["resolution"]
    refute_equal blocked.dig("composition", "composition_digest"), ready.dig("composition", "composition_digest")
    set["paths"].reverse!
    assert_equal ready, pure_compose(set, resolutions: [resolution])
    resolution["value"]["owner"] = "absent"
    assert_raises(A::Error) { pure_compose(set, resolutions: [resolution]) }
  end

  def test_provider_input_declarations_must_own_their_exact_namespace
    register("ruby")
    valid = {"id" => "choice"}.merge(input("ecosystem/ruby.choice", required: false))
    assert_equal "ready", pure_compose(stamped("inputs", [valid])).dig("composition", "status")
    %w[runtime/docker.service ecosystem/python.choice framework/ruby.choice].each do |forged|
      set = stamped("inputs", [valid.merge("key" => forged)])
      error = assert_raises(A::Error) { pure_compose(set) }
      assert_match(/originating adapter namespace/, error.message)
    end
  end

  def test_manifest_and_provider_input_declarations_coexist_without_overriding
    declaration = input("ecosystem/ruby.choice", required: false)
    register("ruby", inputs: [declaration], contributions: {"inputs" => [declaration.merge("id" => "choice")]})
    result = assess(selected(["ecosystem", "ruby"]))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal "ecosystem/ruby.choice", result.dig("composition", "contributions", "inputs", 0, "key")
  end

  def test_assessment_rejects_a_provider_forging_an_input_owner
    register("ruby", contributions: {"inputs" => [input("runtime/docker.service", required: false).merge("id" => "forged")]})
    error = assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
    assert_match(/originating adapter namespace/, error.message)
  end

  def test_path_owner_decision_becomes_stale_when_ownership_conflict_is_gone
    register("ruby")
    set = stamped("paths", [path("one", owner: "one"), path("two", owner: "two")])
    blocked = pure_compose(set)
    resolution = decision(blocked, "choose_path_owner", {"owner" => "one"}, code: "path_ownership_conflict")
    set["paths"][1]["owner"] = "one"
    assert_match(/stale/, assert_raises(A::Error) { pure_compose(set, resolutions: [resolution]) }.message)
  end
end
