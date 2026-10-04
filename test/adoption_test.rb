# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

require "agentic_developer_setup/adoption"

class AdoptionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE_REVISION = "cc9e7943d6d0758cb34d53e257ff44cc72347281"
  CONFIG_DIGEST = "sha256:e71bea835ed1158881306294d96968f125b0b0c5eff66cd94df559336bd0b210"

  def setup
    @temporary_root = Dir.mktmpdir("adoption-test-")
    @target = File.join(@temporary_root, "target")
    FileUtils.mkdir_p(File.join(@target, ".github/ISSUE_TEMPLATE"))
    FileUtils.mkdir_p(File.join(@target, ".agent-framework"))
    FileUtils.cp(File.join(ROOT, "baseline/.github/ISSUE_TEMPLATE/config.yml"), File.join(@target, ".github/ISSUE_TEMPLATE/config.yml"))
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_inherited_target_is_in_sync_and_candidate_is_not_checked_by_default
    write_metadata(inherited_component)

    result = inspect

    assert_equal "valid", result.dig("metadata", "status")
    assert_equal "in_sync", result.dig("components", 0, "local_state")
    assert_equal "not_checked", result.dig("components", 0, "update_state")
    assert_equal 0, result.dig("summary", "error_count")
  end

  def test_specialised_content_is_not_treated_as_drift
    File.write(File.join(@target, "AGENTS.md"), "local contract\n")
    write_metadata(
      "id" => "agent_instructions",
      "status" => "active",
      "ownership" => "specialised",
      "update_policy" => "manual_merge",
      "source_path" => "baseline/AGENTS.md",
      "target_path" => "AGENTS.md",
      "adopted_revision" => SOURCE_REVISION,
      "adopted_source_digest" => "sha256:5048f022ba7b394ef963f42be91272cd6c516d7e4997404cd87e547b04699f17",
      "local_ownership" => ["local operating contract"]
    )

    result = inspect

    assert_equal "specialised_as_expected", result.dig("components", 0, "local_state")
    refute result["diagnostics"].any? { |item| item["code"] == "inherited_digest_mismatch" }
  end

  def test_metadata_parent_symlink_is_rejected_without_reading_external_content
    external = File.join(@temporary_root, "external")
    FileUtils.mkdir_p(external)
    File.write(File.join(external, "adoption.yml"), YAML.dump(base_metadata.merge("framework" => {"version" => "must not be read"})))
    FileUtils.rm_rf(File.join(@target, ".agent-framework"))
    File.symlink(external, File.join(@target, ".agent-framework"))

    result = inspect

    assert_equal "invalid", result.dig("metadata", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "unsafe_metadata_path"
    assert_nil result.dig("framework", "version")
  end

  def test_metadata_file_symlink_is_rejected
    external = File.join(@temporary_root, "external-adoption.yml")
    File.write(external, YAML.dump(base_metadata.merge("components" => [])))
    File.symlink(external, File.join(@target, ".agent-framework/adoption.yml"))

    result = inspect

    assert_equal "invalid", result.dig("metadata", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "unsafe_metadata_path"
  end

  def test_missing_metadata_file_remains_distinguishable_from_unsafe_metadata
    result = inspect

    assert_equal "missing", result.dig("metadata", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "metadata_missing"
  end

  def test_repository_owned_command_is_not_executed
    write_metadata(
      "id" => "ci_workflow",
      "status" => "active",
      "ownership" => "repository_owned",
      "update_policy" => "repository_managed",
      "equivalent" => {"commands" => ["make verify"]},
      "rationale" => "Native CI is authoritative."
    )

    result = inspect

    assert_equal "repository_equivalent", result.dig("components", 0, "local_state")
    assert_equal 1, result.dig("summary", "review_required_count")
    assert_equal 0, result.dig("summary", "error_count")
  end

  def test_candidate_change_is_available_without_git_ancestry
    write_metadata(inherited_component)
    candidate = File.join(@temporary_root, "candidate")
    FileUtils.mkdir_p(File.join(candidate, "baseline/.github/ISSUE_TEMPLATE"))
    FileUtils.cp(File.join(ROOT, "framework.yml"), File.join(candidate, "framework.yml"))
    File.write(File.join(candidate, "baseline/.github/ISSUE_TEMPLATE/config.yml"), "changed candidate\n")

    result = inspect(framework_source: candidate)

    assert_equal "available", result.dig("candidate", "status")
    assert_equal "candidate_available", result.dig("components", 0, "update_state")
    assert_equal 1, result.dig("summary", "review_required_count")
  end

  def test_valid_git_checkout_candidate_is_available_and_unchanged
    write_metadata(inherited_component)

    result = inspect(framework_source: ROOT)

    assert_equal "available", result.dig("candidate", "status")
    assert_equal "unchanged", result.dig("components", 0, "update_state")
  end

  def test_candidate_path_movement_with_identical_source_bytes_remains_unchanged
    write_metadata(inherited_component)
    candidate = candidate_source
    catalogue = YAML.safe_load_file(File.join(candidate, "framework.yml"), aliases: false)
    entry = catalogue["baseline"].values_at("required", "recommended").flatten.find { |item| item["name"] == "issue_template_config" }
    moved_source = "baseline/moved/config.yml"
    original_source = File.join(candidate, entry["source_path"])
    FileUtils.mkdir_p(File.dirname(original_source))
    FileUtils.cp(File.join(ROOT, entry["source_path"]), original_source)
    FileUtils.mkdir_p(File.join(candidate, "baseline/moved"))
    FileUtils.cp(original_source, File.join(candidate, moved_source))
    entry["source_path"] = moved_source
    entry["target_path"] = ".github/moved/config.yml"
    File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

    result = inspect(framework_source: candidate)

    assert_equal "available", result.dig("candidate", "status")
    assert_equal "unchanged", result.dig("components", 0, "update_state")
  end

  def test_validator_revision_lookup_ignores_ambient_git_repository_selection
    framework = git_framework_source
    decoy = git_repository("decoy", "decoy")
    framework_revision = git_revision(framework)
    component = inherited_component.merge(
      "adopted_revision" => framework_revision,
      "adopted_source_digest" => "sha256:0000000000000000000000000000000000000000000000000000000000000000"
    )
    write_metadata(component)

    with_hostile_git_environment(decoy) do
      validator = AgenticDeveloperSetup::Adoption::Validator.new(root: @target, framework_root: framework)

      assert_equal framework_revision, validator.send(:catalogue_revision)
      assert_includes validator.validate(base_metadata.merge("components" => [component])).map(&:code), "source_digest_mismatch"
    end
  end

  def test_candidate_revision_lookup_ignores_ambient_git_repository_selection
    candidate = candidate_source
    Open3.capture3("git", "-C", candidate, "init", "--quiet")
    Open3.capture3("git", "-C", candidate, "config", "user.name", "Adoption Test")
    Open3.capture3("git", "-C", candidate, "config", "user.email", "adoption@example.invalid")
    Open3.capture3("git", "-C", candidate, "add", "framework.yml")
    Open3.capture3("git", "-C", candidate, "commit", "--quiet", "-m", "candidate")
    candidate_revision = git_revision(candidate)
    decoy = git_repository("decoy", "different")

    with_hostile_git_environment(decoy) do
      result = inspect(framework_source: candidate)

      assert_equal "available", result.dig("candidate", "status")
      assert_equal candidate_revision, result.dig("candidate", "revision")
    end
  end

  def test_invalid_candidate_catalogue_is_not_available
    write_metadata(inherited_component)
    candidate = candidate_source
    catalogue = YAML.safe_load_file(File.join(candidate, "framework.yml"), aliases: false)
    catalogue["baseline"]["recommended"] << catalogue["baseline"]["required"].first.merge("source_path" => "baseline/other")
    File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

    result = inspect(framework_source: candidate)

    assert_equal "invalid", result.dig("candidate", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "candidate_catalogue_invalid"
  end

  def test_candidate_catalogue_rejects_invalid_id_and_unsafe_source_path
    write_metadata(inherited_component)
    candidate = candidate_source
    catalogue = YAML.safe_load_file(File.join(candidate, "framework.yml"), aliases: false)
    catalogue["baseline"]["required"].first["name"] = "Invalid-ID"
    catalogue["baseline"]["required"].first["source_path"] = "../outside"
    File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

    result = inspect(framework_source: candidate)

    assert_equal "invalid", result.dig("candidate", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "candidate_catalogue_invalid"
  end

  def test_candidate_catalogue_rejects_malformed_component_entry
    write_metadata(inherited_component)
    candidate = candidate_source
    catalogue = YAML.safe_load_file(File.join(candidate, "framework.yml"), aliases: false)
    catalogue["baseline"]["required"][0] = "not a component mapping"
    File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

    result = inspect(framework_source: candidate)

    assert_equal "invalid", result.dig("candidate", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "candidate_catalogue_invalid"
  end

  def test_malformed_candidate_catalogue_container_shapes_are_bounded
    cases = [
      ["top-level sequence", ["not", "a", "mapping"]],
      ["baseline scalar", {"schema_version" => 2, "baseline" => "broken"}],
      ["baseline sequence", {"schema_version" => 2, "baseline" => []}],
      ["missing baseline collections", {"schema_version" => 2, "baseline" => {}}],
      ["missing recommended", {"schema_version" => 2, "baseline" => {"required" => []}}],
      ["wrong required type", {"schema_version" => 2, "baseline" => {"required" => {}, "recommended" => []}}],
      ["wrong recommended type", {"schema_version" => 2, "baseline" => {"required" => [], "recommended" => {}}}],
      ["malformed framework identity", {"schema_version" => 2, "framework" => "broken", "baseline" => {"required" => [], "recommended" => []}}]
    ]

    cases.each do |label, catalogue|
      candidate = candidate_source
      File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

      result = inspect(framework_source: candidate)

      assert_equal "invalid", result.dig("candidate", "status"), label
      assert_includes result["diagnostics"].map { |item| item["code"] }, "candidate_catalogue_invalid", label
    end
  end

  def test_candidate_catalogue_requires_complete_baseline_entry_shape
    cases = [
      ["missing category", ->(entry) { entry.delete("category") }],
      ["missing target path", ->(entry) { entry.delete("target_path") }],
      ["missing description", ->(entry) { entry.delete("description") }],
      ["category has wrong type", ->(entry) { entry["category"] = ["invalid"] }],
      ["target path has wrong type", ->(entry) { entry["target_path"] = 123 }],
      ["description has wrong type", ->(entry) { entry["description"] = false }],
      ["unknown field", ->(entry) { entry["extra"] = "unexpected" }],
      ["empty description", ->(entry) { entry["description"] = "" }]
    ]

    cases.each do |label, mutation|
      write_metadata(inherited_component)
      candidate = candidate_source
      catalogue = YAML.safe_load_file(File.join(candidate, "framework.yml"), aliases: false)
      mutation.call(catalogue["baseline"]["required"].first)
      File.write(File.join(candidate, "framework.yml"), YAML.dump(catalogue))

      result = inspect(framework_source: candidate)

      assert_equal "invalid", result.dig("candidate", "status"), label
      assert_includes result["diagnostics"].map { |item| item["code"] }, "candidate_catalogue_invalid", label
    end
  end

  def test_mixed_type_unknown_keys_are_bounded_at_top_level
    metadata = base_metadata.merge("components" => [], "unexpected" => "foo", 123 => "bar")
    File.write(File.join(@target, ".agent-framework/adoption.yml"), YAML.dump(metadata))

    result = inspect

    assert_equal "invalid", result.dig("metadata", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "schema_violation"
  end

  def test_mixed_type_unknown_keys_are_bounded_in_nested_component
    write_components(inherited_component.merge("unexpected" => "foo", 42 => "bad"))

    result = inspect

    assert_equal "invalid", result.dig("metadata", "status")
    assert_includes result["diagnostics"].map { |item| item["code"] }, "schema_violation"
  end

  def test_duplicate_managed_targets_are_order_independent
    first = specialised_component("agent_instructions", "AGENTS.md")
    second = specialised_component("review_policy", "AGENTS.md")
    File.write(File.join(@target, "AGENTS.md"), "local\n")

    [[first, second], [second, first]].each do |components|
      write_components(*components)
      result = inspect
      assert_includes result["diagnostics"].map { |item| item["code"] }, "duplicate_target_ownership"
    end
  end

  def test_repository_owned_equivalent_does_not_claim_managed_target
    managed = specialised_component("agent_instructions", "AGENTS.md")
    native = {
      "id" => "ci_workflow", "status" => "active", "ownership" => "repository_owned",
      "update_policy" => "repository_managed", "equivalent" => {"paths" => ["AGENTS.md"]},
      "rationale" => "Native capability is authoritative."
    }
    File.write(File.join(@target, "AGENTS.md"), "local\n")

    [[managed, native], [native, managed]].each do |components|
      write_components(*components)
      result = inspect
      refute_includes result["diagnostics"].map { |item| item["code"] }, "duplicate_target_ownership"
    end
  end

  def test_schema_validation_is_used_for_structural_errors
    write_metadata(inherited_component.merge("unexpected" => true))

    result = inspect

    assert_includes result["diagnostics"].map { |item| item["code"] }, "schema_violation"
  end

  def test_missing_metadata_is_bounded
    FileUtils.rm_rf(File.join(@target, ".agent-framework"))

    result = inspect

    assert_equal "missing", result.dig("metadata", "status")
    assert_equal 1, result.dig("summary", "error_count")
    assert_empty result["components"]
  end

  def test_unknown_fields_and_unsafe_paths_are_diagnostics
    metadata = base_metadata.merge("unexpected" => true)
    metadata["components"] = [inherited_component.merge("target_path" => "../outside", "extra" => true)]
    File.write(File.join(@target, ".agent-framework/adoption.yml"), YAML.dump(metadata))

    result = inspect

    codes = result["diagnostics"].map { |item| item["code"] }
    assert_includes codes, "unknown_field"
    assert_includes codes, "unsafe_target_path"
  end

  private

  def base_metadata
    {
      "schema_version" => 1,
      "framework" => {
        "source" => AgenticDeveloperSetup::Adoption::SOURCE,
        "version" => "0.1.0",
        "revision" => SOURCE_REVISION,
        "adopted_at" => "2026-09-30",
        "updated_at" => "2026-09-30"
      },
      "scope" => {"type" => "repository", "path" => "."}
    }
  end

  def inherited_component
    {
      "id" => "issue_template_config",
      "status" => "active",
      "ownership" => "inherited",
      "update_policy" => "review_required",
      "source_path" => "baseline/.github/ISSUE_TEMPLATE/config.yml",
      "target_path" => ".github/ISSUE_TEMPLATE/config.yml",
      "adopted_revision" => SOURCE_REVISION,
      "adopted_source_digest" => CONFIG_DIGEST
    }
  end

  def write_metadata(component)
    write_components(component)
  end

  def write_components(*components)
    metadata = base_metadata.merge("components" => components)
    File.write(File.join(@target, ".agent-framework/adoption.yml"), YAML.dump(metadata))
  end

  def candidate_source
    candidate = File.join(@temporary_root, "candidate")
    FileUtils.mkdir_p(candidate)
    FileUtils.cp(File.join(ROOT, "framework.yml"), File.join(candidate, "framework.yml"))
    candidate
  end

  def git_framework_source
    framework = File.join(@temporary_root, "framework")
    FileUtils.mkdir_p(File.join(framework, "baseline/.github/ISSUE_TEMPLATE"))
    FileUtils.mkdir_p(File.join(framework, "schemas"))
    FileUtils.cp(File.join(ROOT, "framework.yml"), File.join(framework, "framework.yml"))
    FileUtils.cp(File.join(ROOT, "schemas/framework-adoption-v1.schema.json"), File.join(framework, "schemas/framework-adoption-v1.schema.json"))
    FileUtils.cp(File.join(ROOT, "baseline/.github/ISSUE_TEMPLATE/config.yml"), File.join(framework, "baseline/.github/ISSUE_TEMPLATE/config.yml"))
    git_repository(framework, "framework")
  end

  def git_repository(name, content)
    repository = name.start_with?(File::SEPARATOR) ? name : File.join(@temporary_root, name)
    FileUtils.mkdir_p(repository)
    File.write(File.join(repository, "README.md"), content)
    Open3.capture3("git", "-C", repository, "init", "--quiet")
    Open3.capture3("git", "-C", repository, "config", "user.name", "Adoption Test")
    Open3.capture3("git", "-C", repository, "config", "user.email", "adoption@example.invalid")
    Open3.capture3("git", "-C", repository, "add", "README.md")
    Open3.capture3("git", "-C", repository, "commit", "--quiet", "-m", "repository")
    repository
  end

  def git_revision(repository)
    Open3.capture3("git", "-C", repository, "rev-parse", "--verify", "HEAD^{commit}").first.strip
  end

  def with_hostile_git_environment(decoy)
    names = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR]
    original = names.to_h { |name| [name, ENV[name]] }
    names.each { |name| ENV[name] = File.join(decoy, (name == "GIT_WORK_TREE") ? "" : ".git") }
    ENV["GIT_INDEX_FILE"] = File.join(decoy, ".git", "index")
    yield
  ensure
    original&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
  end

  def specialised_component(id, target_path)
    {
      "id" => id,
      "status" => "active",
      "ownership" => "specialised",
      "update_policy" => "manual_merge",
      "source_path" => "baseline/AGENTS.md",
      "target_path" => target_path,
      "adopted_revision" => "0" * 40,
      "adopted_source_digest" => "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "local_ownership" => ["repository-specific content"]
    }
  end

  def inspect(framework_source: nil)
    AgenticDeveloperSetup::Adoption::Inspector.new(@target, framework_root: ROOT).inspect(framework_source: framework_source)
  end
end
