# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

class AdoptionCLITest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE_REVISION = "cc9e7943d6d0758cb34d53e257ff44cc72347281"
  CONFIG_DIGEST = "sha256:e71bea835ed1158881306294d96968f125b0b0c5eff66cd94df559336bd0b210"

  def setup
    @temporary_root = Dir.mktmpdir("adoption-cli-test-")
    @target = File.join(@temporary_root, "target")
    FileUtils.mkdir_p(File.join(@target, ".github/ISSUE_TEMPLATE"))
    FileUtils.cp(
      File.join(ROOT, "baseline/.github/ISSUE_TEMPLATE/config.yml"),
      File.join(@target, ".github/ISSUE_TEMPLATE/config.yml")
    )
    FileUtils.mkdir_p(File.join(@target, ".agent-framework"))
    File.write(File.join(@target, ".agent-framework/adoption.yml"), YAML.dump(metadata))
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_missing_repo_is_rejected
    _stdout, stderr, status = Open3.capture3("make", "adoption-inspect", chdir: ROOT)

    refute status.success?
    assert_includes stderr, "REPO is required"
  end

  def test_make_wrapper_emits_structured_inspection_without_candidate
    stdout, stderr, status = run_make

    assert status.success?, stderr
    result = YAML.safe_load(stdout, aliases: false)
    assert_equal "valid", result.dig("metadata", "status")
    assert_equal "not_checked", result.dig("components", 0, "update_state")
    assert_equal "not_checked", result.dig("candidate", "status")
  end

  def test_make_wrapper_forwards_framework_source
    candidate = File.join(@temporary_root, "candidate")
    FileUtils.mkdir_p(File.join(candidate, "baseline/.github/ISSUE_TEMPLATE"))
    FileUtils.cp(File.join(ROOT, "framework.yml"), File.join(candidate, "framework.yml"))
    FileUtils.cp(
      File.join(ROOT, "baseline/.github/ISSUE_TEMPLATE/config.yml"),
      File.join(candidate, "baseline/.github/ISSUE_TEMPLATE/config.yml")
    )

    stdout, stderr, status = run_make("FRAMEWORK_SOURCE=#{candidate}")

    assert status.success?, stderr
    result = YAML.safe_load(stdout, aliases: false)
    assert_equal "available", result.dig("candidate", "status")
    assert_equal "unchanged", result.dig("components", 0, "update_state")
  end

  private

  def run_make(*variables)
    Open3.capture3("make", "adoption-inspect", "REPO=#{@target}", *variables, chdir: ROOT)
  end

  def metadata
    {
      "schema_version" => 1,
      "framework" => {
        "source" => "https://github.com/tim-millar/agentic-developer-setup",
        "version" => "0.1.0",
        "revision" => SOURCE_REVISION,
        "adopted_at" => "2026-09-30",
        "updated_at" => "2026-09-30"
      },
      "scope" => {"type" => "repository", "path" => "."},
      "components" => [
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
      ]
    }
  end
end
