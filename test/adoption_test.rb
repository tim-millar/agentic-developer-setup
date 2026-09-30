# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
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
    metadata = base_metadata.merge("components" => [component])
    File.write(File.join(@target, ".agent-framework/adoption.yml"), YAML.dump(metadata))
  end

  def inspect(framework_source: nil)
    AgenticDeveloperSetup::Adoption::Inspector.new(@target, framework_root: ROOT).inspect(framework_source: framework_source)
  end
end
