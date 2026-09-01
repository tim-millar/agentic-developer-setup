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

  def test_tracked_excluded_manifests_do_not_enter_inventory
    init_git
    write("package.json", "{\"name\":\"root\"}\n")
    write("vendor/package.json", "{\"name\":\"vendor\"}\n")
    write("node_modules/pkg/package.json", "{\"name\":\"dependency\"}\n")
    write("dist/pyproject.toml", "[project]\nname = 'generated'\n")
    write("build/requirements.txt", "pytest\n")
    Open3.capture3("git", "-C", @target, "add", "package.json", "vendor", "node_modules", "dist", "build")
    Open3.capture3("git", "-C", @target, "commit", "-m", "add excluded manifests")

    result = assess
    paths = result["evidence"].filter_map { |item| item["path"] }

    assert_equal ["node"], result["ecosystem"].map { |item| item["name"] }
    assert_includes paths, "package.json"
    refute paths.any? { |path| path.match?(%r{\A(?:vendor|node_modules|dist|build)/}) }
    assert_includes result.dig("scope", "excluded_paths"), "vendor"
    assert_includes result.dig("scope", "excluded_paths"), "node_modules"
    assert_includes result.dig("scope", "excluded_paths"), "dist"
    assert_includes result.dig("scope", "excluded_paths"), "build"
  end

  def test_documentation_sample_manifests_do_not_enter_project_inventory
    init_git
    write("docs/examples/package.json", "{\"name\":\"sample\"}\n")
    write("docs/snippets/pyproject.toml", "[project]\nname = \"sample\"\n")
    write("docs/examples/requirements.txt", "pytest\n")
    write("docs/DEVELOPMENT.md", "Development guidance.\n")
    Open3.capture3("git", "-C", @target, "add", "docs")
    Open3.capture3("git", "-C", @target, "commit", "-m", "add documentation samples")

    result = assess

    refute_includes result.dig("scope", "project_roots"), "docs/examples"
    refute_includes result.dig("ecosystem").map { |item| item["name"] }, "node"
    refute_includes result.dig("ecosystem").map { |item| item["name"] }, "python"
    assert_includes result.dig("documentation", "development_guide", "paths"), "docs/DEVELOPMENT.md"
    refute result["evidence"].any? { |item| item["path"].to_s.match?(%r{\Adocs/(?:examples|snippets)/(?:package\.json|pyproject\.toml|requirements\.txt)\z}) }
  end

  def test_project_container_manifest_remains_discoverable
    write("apps/api/package.json", "{\"name\":\"api\"}\n")

    result = assess

    assert_includes result.dig("scope", "project_roots"), "apps/api"
    assert_includes result.dig("ecosystem").map { |item| item["name"] }, "node"
  end
end
