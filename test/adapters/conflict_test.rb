# frozen_string_literal: true

require_relative "support"

class AdapterConflictTest < AdapterTest
  def test_blocked_then_explicit_command_choice_without_mutation
    document = conflict_fixture
    before = Dir.glob(File.join(@target, "**/*"), File::FNM_DOTMATCH)
    blocked = assess(document)
    assert_equal "blocked", blocked.dig("composition", "status")
    assert_includes codes(blocked), "incompatible_command_proposals"
    assert_empty blocked.dig("composition", "commands")
    document["resolutions"] = [decision(blocked, "choose_command", {"contribution_id" => "ruby-test"})]
    ready = assess(document)
    assert_equal "ready", ready.dig("composition", "status")
    assert_equal %w[bundle exec rspec], ready.dig("composition", "commands", 0, "argv")
    assert_equal ["rails-test"], ready.dig("composition", "commands", 0, "overridden_contribution_ids")
    assert_equal "resolved", ready["conflicts"].first["status"]
    assert_equal document["resolutions"], ready["resolved_decisions"]
    assert_equal before, Dir.glob(File.join(@target, "**/*"), File::FNM_DOTMATCH)
  end

  def test_repository_command_replacement_keeps_all_provenance
    document = conflict_fixture
    blocked = assess(document)
    replacement = command("repository-test", argv: ["make", "test"])
    document["resolutions"] = [decision(blocked, "override_command", {"command" => replacement})]
    result = assess(document)
    final = result.dig("composition", "commands", 0)
    assert_equal "ready", result.dig("composition", "status")
    assert_equal %w[make test], final["argv"]
    assert_equal %w[rails-test ruby-test], final["overridden_contribution_ids"].sort
    assert_equal %w[rails ruby], final["provenance"].map { |item| item["adapter_id"] }.sort
    assert_equal blocked["conflicts"].first["id"], final["decision_source"]
  end

  def test_duplicate_semantic_command_ownership_is_not_silently_selected
    register("ruby", contributions: {"commands" => [command, command("ruby-alternative")]})
    result = assess(selected(["ecosystem", "ruby"]))
    assert_includes codes(result), "duplicate_capability_ownership"
    assert_equal "blocked", result.dig("composition", "status")
  end

  def test_conflicting_wrappers_and_explicit_choice
    register("ruby", contributions: {"commands" => [command]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper, wrapper("docker-other", prefix: %w[docker compose exec other])]})
    document = selected(["ecosystem", "ruby"], ["runtime", "docker"])
    blocked = assess(document)
    assert_includes codes(blocked), "command_wrapper_conflict"
    document["resolutions"] = [decision(blocked, "choose_wrapper", {"contribution_id" => "docker-test"}, code: "command_wrapper_conflict")]
    ready = assess(document)
    assert_equal "ready", ready.dig("composition", "status")
    assert_equal %w[docker compose run --rm app bundle exec rspec], ready.dig("composition", "commands", 0, "argv")
  end

  def test_environment_conflict_blocks
    register("ruby", contributions: {"commands" => [command(env: {"MODE" => "test"})]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(env: {"MODE" => "other"})]})
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_includes codes(result), "command_environment_conflict"
    assert_equal "blocked", result.dig("composition", "status")
  end

  def test_nonconflicting_environment_combines
    register("ruby", contributions: {"commands" => [command(env: {"MODE" => "test"})]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(env: {"LANG" => "C"})]})
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_equal({"MODE" => "test", "LANG" => "C"}, result.dig("composition", "commands", 0, "env"))
  end

  def test_invalid_working_directory_mapping
    FileUtils.mkdir_p(File.join(@target, "other"))
    register("ruby", contributions: {"commands" => [command]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(cwd: "other")]})
    assert_includes codes(assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))), "metadata_inconsistency"
  end

  def test_refinement_unknown_command_is_blocked
    register("ruby", contributions: {"commands" => [command]})
    register("rails", "framework", contributions: {"commands" => [refinement(command_id: "missing")]})
    assert_includes codes(assess(selected(["ecosystem", "ruby"], ["framework", "rails"]))), "metadata_inconsistency"
  end

  def test_stale_resolution_rejected
    document = conflict_fixture
    document["resolutions"] = [{"conflict_id" => "sha256:#{"0" * 64}", "kind" => "choose_command", "value" => {"contribution_id" => "ruby-test"}, "rationale" => "Explicit choice"}]
    assert_match(/stale/, assert_raises(A::Error) { assess(document) }.message)
  end

  def test_duplicate_resolutions_rejected
    document = conflict_fixture
    resolution = decision(assess(document), "choose_command", {"contribution_id" => "ruby-test"})
    document["resolutions"] = [resolution, resolution]
    assert_raises(A::Error) { assess(document) }
  end

  def test_resolution_must_choose_applicable_command
    document = conflict_fixture
    document["resolutions"] = [decision(assess(document), "choose_command", {"contribution_id" => "absent"})]
    assert_raises(A::Error) { assess(document) }
  end

  def test_resolution_cannot_change_command_capability
    document = conflict_fixture
    document["resolutions"] = [decision(assess(document), "override_command", {"command" => command("repository", capability: "deployment")})]
    assert_raises(A::Error) { assess(document) }
  end

  ["../escape", "/absolute", "a/../escape", "./alias"].each_with_index do |unsafe, index|
    define_method("test_unsafe_command_override_path_#{index}") do
      document = conflict_fixture
      document["resolutions"] = [decision(assess(document), "override_command", {"command" => command("repository", cwd: unsafe)})]
      assert_raises(A::Error) { assess(document) }
    end
  end

  def test_shell_evaluation_cannot_be_overridden
    document = conflict_fixture
    document["resolutions"] = [decision(assess(document), "override_command", {"command" => command("repository", argv: %w[bash -c dangerous])})]
    assert_match(/shell evaluation/, assert_raises(A::Error) { assess(document) }.message)
  end

  def test_secret_environment_values_rejected
    register("ruby", contributions: {"commands" => [command(env: {"API_TOKEN" => "synthetic-only"})]})
    error = assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
    assert_match(/secret values/, error.message)
    refute_includes error.message, "synthetic-only"
  end

  def test_unsafe_wrapper_cannot_be_selected
    register("ruby", contributions: {"commands" => [command]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper(prefix: %w[sh -c])]})
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], ["runtime", "docker"])) }
  end

  def test_compatibility_missing_framework_dependency
    register("ruby")
    register("rails", "framework")
    register("docker", "runtime", requires: [requirement("framework", "rails")])
    result = assess(selected(["ecosystem", "ruby"], ["runtime", "docker"]))
    assert_includes codes(result), "missing_required_adapter"
    assert_equal "blocked", result.dig("compatibility", "status")
  end

  def test_incompatible_ecosystem_framework
    register("ruby")
    register("python")
    register("rails", "framework", incompatible: [requirement("ecosystem", "python")])
    result = assess(selected(["ecosystem", "python"], ["framework", "rails"]))
    assert_includes codes(result), "incompatible_adapters"
    assert_equal "blocked", result.dig("composition", "status")
  end

  def test_adapter_version_requirement_uses_numeric_versions
    register("ruby", version: "2.9.0")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: ">= 2.10.0")])
    result = assess(selected(["ecosystem", "ruby"], ["framework", "rails"]))
    assert_includes codes(result), "adapter_version_incompatible"
  end

  def test_hard_compatibility_cannot_be_overridden
    register("ruby")
    register("rails", "framework", incompatible: [requirement("ecosystem", "ruby")])
    document = selected(["ecosystem", "ruby"], ["framework", "rails"])
    document["resolutions"] = [decision(assess(document), "choose_command", {"contribution_id" => "any"}, code: "incompatible_adapters")]
    assert_match(/forbidden/, assert_raises(A::Error) { assess(document) }.message)
  end
end
