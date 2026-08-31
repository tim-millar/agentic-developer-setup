# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentDetectorTest < Minitest::Test
  include AssessmentTestSupport

  def test_generic_test_directories_do_not_infer_pytest
    write("tests/README.md", "generic tests\n")
    write("pyproject.toml", "[project]\nname = \"generic-python\"\n")

    result = assess

    refute_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
    assert_equal "implementation_detected", result.dig("validation", "capabilities", "tests", "status")
  end

  def test_node_tests_do_not_infer_pytest
    write("package.json", "{\"scripts\":{\"test\":\"vitest\"}}\n")
    write("tests/example.js", "sentinel\n")

    result = assess

    assert_equal ["vitest"], result.dig("tooling", "test_frameworks").map { |item| item["name"] }
    refute_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
  end

  def test_python_pytest_metadata_is_required_for_pytest_framework_detection
    write("pyproject.toml", "[project]\nname = \"sample\"\n\n[tool.pytest.ini_options]\ntestpaths = [\"tests\"]\n")
    write("tests/test_sample.py", "def test_sample(): pass\n")

    result = assess

    assert_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
  end

  def test_documentation_keeps_every_command_and_deduplicates_by_identity
    write("README.md", "make test\nmake lint\nmake test\nnpm run build\n")
    write("docs/DEVELOPMENT.md", "make test\nyarn check\n")

    result = assess
    names = result.dig("tooling", "command_surface", "commands").map { |item| item["name"] }

    assert_includes names, "make test"
    assert_includes names, "make lint"
    assert_includes names, "npm run build"
    assert_includes names, "yarn check"
    assert_equal names.uniq, names
  end

  def test_ci_alignment_uses_exact_make_target_identity
    write("README.md", "make test\n")
    write("Makefile", "verify:\n\t@echo verify\n")
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: make test-destructive\n")

    result = assess

    assert_equal "partial", result.dig("validation", "ci_alignment", "status")
  end

  def test_ci_alignment_normalizes_equivalent_package_script_syntax
    write("package.json", "{\"scripts\":{\"verify\":\"echo verify\"}}\n")
    write(".github/workflows/ci.yml", "jobs:\n  verify:\n    steps:\n      - run: npm run verify\n")

    result = assess

    assert_equal "ready", result.dig("validation", "ci_alignment", "status")
  end

  def test_package_manager_precedence_and_conflicts_are_explicit
    write("package.json", "{\"name\":\"sample\"}\n")
    write("yarn.lock", "# yarn\n")
    assert_equal ["yarn"], assess.dig("tooling", "package_managers").map { |item| item["name"] }

    write("package.json", "{\"name\":\"sample\",\"packageManager\":\"npm@10\"}\n")
    managers = assess.dig("tooling", "package_managers")
    assert_equal %w[npm yarn], managers.map { |item| item["name"] }
    assert managers.all? { |item| item["status"] == "conflicting" }
    assert managers.all? { |item| item["confidence"] != "high" }

    write("package.json", "{\"name\":\"sample\"}\n")
    FileUtils.rm_f(File.join(@target, "yarn.lock"))
    write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")
    assert_equal ["pnpm"], assess.dig("tooling", "package_managers").map { |item| item["name"] }
    write("package-lock.json", "{}\n")
    conflicting = assess.dig("tooling", "package_managers")
    assert_equal %w[npm pnpm], conflicting.map { |item| item["name"] }
    assert conflicting.all? { |item| item["status"] == "conflicting" }
  end

  def test_github_actions_commands_come_only_from_run_steps
    write("Makefile", "verify:\n\t@echo verify\n")
    write(".github/workflows/ci.yml", <<~YAML)
      name: CI
      on: [push]
      env:
        COMMAND: make env-only
      jobs:
        verify:
          steps:
            - name: make with is not execution
              uses: example/action@v1
              with:
                command: make with-only
            - name: actual
              run: |
                # make commented-out
                make verify
                make lint
          # make job-comment
    YAML

    result = assess
    commands = result.dig("tooling", "ci", "invocations")

    assert_equal ["make lint", "make verify"], commands
    refute_includes commands, "make env-only"
    refute_includes commands, "make with-only"
    refute_includes commands, "make commented-out"
  end

  def test_malformed_github_actions_workflow_degrades_without_execution
    write(".github/workflows/ci.yml", "jobs: [not: valid\n")

    result = assess

    assert_equal [], result.dig("tooling", "ci", "invocations")
    assert_schema(result)
  end
end
