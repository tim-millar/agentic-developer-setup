# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "tmpdir"
require "yaml"

require "agentic_developer_setup/assessment"

class AssessmentTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "examples", "reference-service")

  def setup
    @temporary_root = Dir.mktmpdir("assessment-test-")
    @target = File.join(@temporary_root, "target")
    FileUtils.mkdir_p(@target)
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_reference_fixture_produces_supported_profile_and_tier_two
    result = assess(FIXTURE)

    assert_equal 1, result["schema_version"]
    assert_equal 2, result.dig("framework", "metadata_schema_version")
    assert_equal "0.1.0", result.dig("framework", "version")
    assert_equal "python", result.dig("ecosystem", 0, "name")
    assert_equal "uv", result.dig("tooling", "package_managers", 0, "name")
    assert_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
    assert_includes result.dig("tooling", "linters").map { |item| item["name"] }, "Ruff"
    assert_includes result.dig("tooling", "type_checkers").map { |item| item["name"] }, "mypy"
    assert_equal "tier-2", result.dig("tier_recommendation", "outcome")
    assert_equal %w[repository_context task_boundary command_surface deterministic_validation ci_alignment sensitive_area_guidance runtime_access review_handoff local_setup_reproducibility], result["readiness"].keys
    assert result["component_recommendations"].any? { |item| item["state"] == "evaluate_later" && item["component"] == "agent_launcher" }
    assert result["framework_adoption"]["detected_components"].any? { |item| item["state"] == "framework_like" }
    assert_schema(result)
  end

  def test_committed_reference_assessment_is_schema_valid_and_report_is_its_projection
    path = File.join(FIXTURE, "assessment", "assessment.yml")
    result = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false)

    assert_schema(result)
    assert_equal AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(result), File.read(File.join(FIXTURE, "assessment", "assessment.md"))
  end

  def test_python_detection_is_metadata_only
    write("README.md", "# Python project\n\nmake verify\n")
    write("pyproject.toml", <<~TOML)
      [project]
      name = "synthetic"
      dependencies = ["pytest", "ruff", "mypy"]
      [tool.pytest.ini_options]
      testpaths = ["tests"]
      [tool.ruff]
      line-length = 100
      [tool.mypy]
      strict = true
    TOML
    write("uv.lock", "version = 1\n")
    FileUtils.mkdir_p(File.join(@target, "tests"))

    result = assess(@target)

    assert_equal ["python"], result["ecosystem"].map { |item| item["name"] }
    assert_equal "uv", result.dig("tooling", "package_managers", 0, "name")
    assert_equal "pytest", result.dig("tooling", "test_frameworks", 0, "name")
    assert_includes result.dig("tooling", "linters").map { |item| item["name"] }, "Ruff"
    assert_includes result.dig("tooling", "type_checkers").map { |item| item["name"] }, "mypy"
  end

  def test_node_and_typescript_detection_includes_package_manager_scripts
    write("package.json", JSON.pretty_generate(
      "name" => "synthetic-node",
      "packageManager" => "pnpm@9.0.0",
      "scripts" => { "test" => "vitest", "lint" => "eslint .", "format" => "prettier --check .", "typecheck" => "tsc --noEmit" },
      "devDependencies" => { "typescript" => "^5", "eslint" => "^9", "prettier" => "^3" }
    ))
    write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")
    write("tsconfig.json", "{}\n")
    write("eslint.config.js", "export default [];\n")
    write("prettier.config.js", "export default {};\n")

    result = assess(@target)

    assert_equal %w[node typescript], result["ecosystem"].map { |item| item["name"] }
    assert_includes result.dig("tooling", "package_managers").map { |item| item["name"] }, "pnpm"
    assert_equal "ESLint", result.dig("tooling", "linters", 0, "name")
    assert_equal "Prettier", result.dig("tooling", "formatters", 0, "name")
    assert_equal "TypeScript compiler", result.dig("tooling", "type_checkers", 0, "name")
  end

  def test_monorepo_roots_are_reported_without_independent_assessments
    write("README.md", "# Workspace\n")
    write("apps/api/pyproject.toml", "[project]\nname = \"api\"\n")
    write("packages/web/package.json", "{\"name\":\"web\"}\n")

    result = assess(@target)

    assert_equal "multiple_projects", result.dig("scope", "shape")
    assert_equal %w[apps/api packages/web], result.dig("scope", "project_roots")
    refute result["scope"]["project_roots"].any? { |path| path.include?("src") }
  end

  def test_unsupported_ecosystem_degrades_to_generic_assessment
    write("README.md", "# Rust project\n")
    write("Cargo.toml", "[package]\nname = \"synthetic\"\n")

    result = assess(@target)

    assert_equal "unsupported", result.dig("ecosystem", 0, "name")
    assert_equal "partial", result.dig("readiness", "repository_context", "status")
    assert result.key?("gaps")
    assert result.key?("risks")
  end

  def test_framework_like_and_repository_native_capabilities_are_distinguished
    write("AGENTS.md", "# Local repository contract\n")
    write("package.json", "{\"scripts\":{\"verify\":\"do-not-run\"}}\n")

    result = assess(@target)
    components = result["framework_adoption"]["detected_components"].to_h { |item| [item["component"], item] }

    assert_equal "framework_like", components.fetch("agent_instructions")["state"]
    assert_equal "repository_native", components.fetch("command_interface")["state"]
    assert_equal "already_satisfied_by_repository_native", result["component_recommendations"].find { |item| item["component"] == "command_interface" }["state"]
  end

  def test_context_is_recorded_as_distinct_evidence_and_conflicts_remain_visible
    write("README.md", "# Production system\n")
    context = File.join(@temporary_root, "context.yml")
    write_absolute(context, <<~YAML)
      schema_version: 1
      repository:
        criticality: low
        deployment_impact: low
      sensitive_paths:
        - config/production
      approved_agent_runtimes:
        - local-only
      review_requirements:
        - human approval
      known_setup_constraints: []
      notes:
        - Synthetic context
    YAML

    result = AgenticDeveloperSetup::Assessment::Assessor.new(@target, clock: fixed_clock).assess(context_path: context)

    assert_equal "provided", result.dig("assessor_context", "status")
    assert_equal ["config/production"], result.dig("assessor_context", "sensitive_paths")
    assert result.dig("assessor_context", "conflicts").any?
    assert_equal "manual_review_required", result.dig("tier_recommendation", "outcome")
    assert result["evidence"].any? { |item| item["type"] == "assessor_context" }
  end

  def test_deterministic_result_and_markdown_projection
    write("README.md", "# Synthetic\n\nmake verify\n")
    write("Makefile", "verify:\n\t@echo not-run\n")
    first = assess(@target)
    second = assess(@target)

    assert_equal YAML.dump(first), YAML.dump(second)
    report = AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(first)
    first["gaps"].each { |gap| assert_includes report, gap["id"] }
    first["risks"].each { |risk| assert_includes report, risk["id"] }
    first["evidence"].each { |item| assert_includes report, item["id"] }
    assert_includes report, "## Executive summary"
    assert_includes report, "## Evidence appendix"
  end

  def test_output_paths_inside_target_are_rejected
    stdout = StringIO.new
    stderr = StringIO.new
    status = AgenticDeveloperSetup::Assessment::CLI.run([@target, "--output", File.join(@target, "assessment.yml")], stdout: stdout, stderr: stderr)

    assert_equal 1, status
    assert_includes stderr.string, "outside the assessed repository"
    refute File.exist?(File.join(@target, "assessment.yml"))
  end

  def test_cli_writes_yaml_and_markdown_only_to_explicit_external_paths
    output = File.join(@temporary_root, "assessment.yml")
    report = File.join(@temporary_root, "assessment.md")
    stderr = StringIO.new

    status = AgenticDeveloperSetup::Assessment::CLI.run([@target, "--output", output, "--report", report], stdout: StringIO.new, stderr: stderr)

    assert_equal 0, status, stderr.string
    result = YAML.safe_load(File.read(output), permitted_classes: [], permitted_symbols: [], aliases: false)
    assert_schema(result)
    assert_equal AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(result), File.read(report)
  end

  def test_no_report_suppresses_report_and_malformed_context_fails
    context = File.join(@temporary_root, "bad-context.yml")
    write_absolute(context, "schema_version: 2\n")
    stderr = StringIO.new
    status = AgenticDeveloperSetup::Assessment::CLI.run([@target, "--context", context, "--no-report"], stdout: StringIO.new, stderr: stderr)

    assert_equal 1, status
    assert_includes stderr.string, "schema_version must be 1"
  end

  def test_exact_framework_content_is_not_inferred_from_filename
    write("AGENTS.md", File.read(File.join(ROOT, "baseline", "AGENTS.md")))

    result = assess(@target)
    component = result["framework_adoption"]["detected_components"].find { |item| item["component"] == "agent_instructions" }

    assert_equal "framework_exact", component["state"]
  end

  def test_tier_algorithm_supports_tier_one_tier_two_and_manual_review
    write("README.md", "# Small repository\n")
    write(".github/ISSUE_TEMPLATE/task.md", "scope\nacceptance criteria\nnon-goals\n")
    assert_equal "tier-1", assess(@target).dig("tier_recommendation", "outcome")

    write("pyproject.toml", "[project]\ndependencies = [\"pytest\"]\n")
    write("Makefile", "verify:\n\t@echo not-run\n")
    FileUtils.mkdir_p(File.join(@target, "tests"))
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: make verify\n")
    assert_equal "tier-2", assess(@target).dig("tier_recommendation", "outcome")

    FileUtils.rm_f(File.join(@target, "README.md"))
    FileUtils.rm_rf(File.join(@target, ".github"))
    assert_equal "tier-2", assess(@target).dig("tier_recommendation", "outcome")
  end

  def test_assessment_does_not_execute_scripts_read_ignored_secrets_or_follow_external_symlinks
    sentinel = File.join(@temporary_root, "executed")
    network_sentinel = File.join(@temporary_root, "network-used")
    write("package.json", JSON.generate("scripts" => {
      "test" => "touch #{sentinel}",
      "network" => "touch #{network_sentinel}"
    }))
    write(".env", "TOP_SECRET=do-not-leak\n")
    write("ignored-sentinel.txt", "IGNORED_SECRET=do-not-leak\n")
    write(".gitignore", ".env\nignored-sentinel.txt\n")
    FileUtils.mkdir_p(File.join(@target, "node_modules"))
    write("node_modules/sentinel.txt", "NODE_MODULES_SECRET=do-not-leak\n")
    external = File.join(@temporary_root, "external")
    write_absolute(File.join(external, "secret.txt"), "EXTERNAL_SECRET=do-not-leak\n")
    FileUtils.mkdir_p(File.join(@target, "docs"))
    File.symlink(external, File.join(@target, "docs", "external"))

    result = assess(@target)
    yaml = YAML.dump(result)
    report = AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(result)

    refute File.exist?(sentinel)
    refute File.exist?(network_sentinel)
    refute_includes yaml, "do-not-leak"
    refute_includes report, "do-not-leak"
    assert_includes result.dig("scope", "excluded_paths"), "node_modules"
    assert_includes result.dig("scope", "symlink_boundaries"), "docs/external"
  end

  def test_dirty_git_state_is_reported_without_being_modified
    init_git(@target)
    write("README.md", "# Dirty\n")
    before = Open3.capture3("git", "-C", @target, "status", "--porcelain", "--untracked-files=all").first

    result = assess(@target)
    after = Open3.capture3("git", "-C", @target, "status", "--porcelain", "--untracked-files=all").first

    assert_equal "dirty", result.dig("repository", "git", "working_tree")
    assert_equal before, after
  end

  def test_schema_rejects_invalid_recommendation_state
    result = assess(@target)
    result["component_recommendations"][0]["state"] = "replace_everything"

    error = assert_raises(AgenticDeveloperSetup::Assessment::SchemaError) { AgenticDeveloperSetup::Assessment::Schema.validate!(result) }
    assert_includes error.message, "unsupported value"
  end

  private

  def assess(target)
    AgenticDeveloperSetup::Assessment::Assessor.new(target, clock: fixed_clock).assess
  end

  def fixed_clock
    -> { Time.utc(2026, 1, 2, 3, 4, 5) }
  end

  def assert_schema(result)
    assert AgenticDeveloperSetup::Assessment::Schema.validate!(result)
  end

  def write(relative_path, content)
    write_absolute(File.join(@target, relative_path), content)
  end

  def write_absolute(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def init_git(path)
    _out, err, status = Open3.capture3("git", "init", path)
    raise err unless status.success?
    Open3.capture3("git", "-C", path, "config", "user.name", "Assessment Test")
    Open3.capture3("git", "-C", path, "config", "user.email", "assessment@example.invalid")
    File.write(File.join(path, "README.md"), "# initial\n")
    Open3.capture3("git", "-C", path, "add", "README.md")
    Open3.capture3("git", "-C", path, "commit", "-m", "initial")
  end
end
