# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentInventoryTest < Minitest::Test
  include AssessmentTestSupport

  def test_regular_project_container_child_is_discovered
    write("apps/api/pyproject.toml", "[project]\nname = 'api'\n")

    result = assess

    assert_includes result.dig("scope", "project_roots"), "apps/api"
  end

  def test_external_project_container_symlink_is_reported_without_traversal
    outside = File.join(@temporary_root, "outside-api")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "pyproject.toml"), "[project]\nname = 'outside'\n")
    apps = File.join(@target, "apps")
    FileUtils.mkdir_p(apps)
    File.symlink(outside, File.join(apps, "api"))

    result = assess

    assert_equal ["apps/api"], result.dig("scope", "symlink_boundaries")
    refute_includes result.dig("scope", "project_roots"), "apps/api"
    refute_includes result.dig("evidence").map { |item| item["path"] }, "apps/api/pyproject.toml"
  end
end
