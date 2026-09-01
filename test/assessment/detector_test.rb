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
    assert_equal "high", result.dig("ecosystem").find { |item| item["name"] == "python" }["confidence"]
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
    assert_equal "high", result.dig("tooling", "test_frameworks").find { |item| item["name"] == "pytest" }["confidence"]
  end

  def test_single_direct_python_configuration_has_high_ecosystem_and_tool_confidence
    write("pyproject.toml", "[project]\nname = \"sample\"\n\n[tool.pytest.ini_options]\ntestpaths = [\"tests\"]\n")

    result = assess

    assert_equal "high", result["ecosystem"].find { |item| item["name"] == "python" }["confidence"]
    assert_equal "high", result.dig("tooling", "test_frameworks").find { |item| item["name"] == "pytest" }["confidence"]
    assert_equal "high", result.dig("readiness", "deterministic_validation", "confidence")
  end

  def test_typescript_compiler_script_has_package_script_evidence
    write("package.json", "{\"scripts\":{\"typecheck\":\"tsc --noEmit\"}}\n")

    compiler = assess.dig("tooling", "type_checkers").find { |item| item["name"] == "TypeScript compiler" }

    refute_nil compiler
    refute_empty compiler["evidence_ids"]
  end

  def test_tsconfig_alone_detects_typescript_compiler_with_high_confidence
    write("package.json", "{\"name\":\"sample\"}\n")
    write("tsconfig.json", "{}\n")

    result = assess
    compiler = result.dig("tooling", "type_checkers").find { |item| item["name"] == "TypeScript compiler" }

    assert_equal "high", compiler["confidence"]
    assert_equal ["tsconfig.json"], compiler["evidence_ids"].map { |id| result["evidence"].find { |item| item["id"] == id }["path"] }
  end

  def test_typescript_dependency_alone_detects_compiler_with_high_confidence
    write("package.json", "{\"devDependencies\":{\"typescript\":\"^5.0.0\"}}\n")

    compiler = assess.dig("tooling", "type_checkers").find { |item| item["name"] == "TypeScript compiler" }

    assert_equal "high", compiler["confidence"]
    refute_empty compiler["evidence_ids"]
  end

  def test_typescript_configuration_alone_is_not_an_implemented_validation_check
    write("package.json", "{\"name\":\"sample\"}\n")
    write("tsconfig.json", "{}\n")

    result = assess

    assert_equal "configuration_detected", result.dig("validation", "capabilities", "static_type_checking", "status")
    assert_equal "missing", result.dig("readiness", "deterministic_validation", "status")
  end

  def test_no_typescript_evidence_does_not_detect_compiler
    write("package.json", "{\"name\":\"sample\"}\n")

    refute assess.dig("tooling", "type_checkers").any? { |item| item["name"] == "TypeScript compiler" }
  end

  def test_typescript_compiler_configuration_and_dependency_have_high_confidence
    write("package.json", "{\"devDependencies\":{\"typescript\":\"^5.0.0\"}}\n")
    write("tsconfig.json", "{}\n")

    compiler = assess.dig("tooling", "type_checkers").find { |item| item["name"] == "TypeScript compiler" }

    assert_equal "high", compiler["confidence"]
  end

  def test_dependency_only_validation_tools_are_discovered_but_not_invokable
    write("package.json", "{\"devDependencies\":{\"eslint\":\"^9\",\"typescript\":\"^5\"}}\n")

    result = assess

    assert_equal "detected", result.dig("tooling", "linters").find { |item| item["name"] == "ESLint" }["status"]
    assert_equal "detected", result.dig("tooling", "type_checkers").find { |item| item["name"] == "TypeScript compiler" }["status"]
    refute_equal "implementation_detected", result.dig("validation", "capabilities", "linting", "status")
    refute_equal "implementation_detected", result.dig("validation", "capabilities", "static_type_checking", "status")
  end

  def test_eslint_configuration_without_local_invocation_is_not_substantive
    write(".eslintrc.json", "{}\n")

    result = assess

    assert_equal "detected", result.dig("tooling", "linters").find { |item| item["name"] == "ESLint" }["status"]
    assert_equal "configuration_detected", result.dig("validation", "capabilities", "linting", "status")
    assert_equal "missing", result.dig("readiness", "deterministic_validation", "status")
  end

  def test_mypy_configuration_requires_a_local_invocation_for_substantive_validation
    write("pyproject.toml", "[project]\nname = \"sample\"\n\n[tool.mypy]\nstrict = true\n")

    result = assess

    assert_equal "configuration_detected", result.dig("validation", "capabilities", "static_type_checking", "status")
    refute_equal "ready", result.dig("readiness", "deterministic_validation", "status")
  end

  def test_mypy_make_invocation_is_substantive_validation
    write("pyproject.toml", "[project]\nname = \"sample\"\n\n[tool.mypy]\nstrict = true\n")
    write("tests/example_test.py", "sentinel\n")
    write("Makefile", "typecheck:\n\t@mypy src\n")

    result = assess

    assert_equal "implementation_detected", result.dig("validation", "capabilities", "static_type_checking", "status")
    assert_equal "ready", result.dig("readiness", "deterministic_validation", "status")
  end

  def test_package_json_only_has_high_node_confidence_and_medium_npm_fallback
    write("package.json", "{\"name\":\"sample\"}\n")

    result = assess

    assert_equal "high", result.dig("ecosystem").find { |item| item["name"] == "node" }["confidence"]
    npm = result.dig("tooling", "package_managers").find { |item| item["name"] == "npm" }
    assert_equal "medium", npm["confidence"]
  end

  def test_direct_python_and_node_tool_evidence_has_high_confidence
    write("pyproject.toml", "[project]\nname = 'sample'\ndependencies = ['pytest']\n\n[tool.ruff]\nline-length = 100\n\n[tool.mypy]\nstrict = true\n")
    write("package.json", "{\"devDependencies\":{\"eslint\":\"^9\",\"prettier\":\"^3\"}}\n")
    write(".eslintrc.json", "{}\n")

    result = assess
    detected = result.dig("tooling", "test_frameworks") + result.dig("tooling", "linters") + result.dig("tooling", "formatters") + result.dig("tooling", "type_checkers")

    %w[pytest Ruff mypy ESLint Prettier].each do |name|
      assert_equal "high", detected.find { |item| item["name"] == name }["confidence"]
    end
  end

  def test_explicit_package_manager_and_lockfile_have_high_confidence
    write("package.json", "{\"packageManager\":\"pnpm@9\"}\n")
    write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

    result = assess

    manager = result.dig("tooling", "package_managers").find { |item| item["name"] == "pnpm" }
    assert_equal "detected", manager["status"]
    assert_equal "high", manager["confidence"]
  end

  def test_package_manager_lockfile_only_has_high_confidence
    write("package.json", "{\"name\":\"sample\"}\n")
    write("yarn.lock", "# yarn\n")

    manager = assess.dig("tooling", "package_managers").find { |item| item["name"] == "yarn" }

    assert_equal "high", manager["confidence"]
  end

  def test_package_lockfile_identifies_npm_with_high_confidence
    write("package.json", "{\"name\":\"sample\"}\n")
    write("package-lock.json", "{}\n")

    manager = assess.dig("tooling", "package_managers").find { |item| item["name"] == "npm" }

    assert_equal "high", manager["confidence"]
  end

  def test_conflicting_package_manager_evidence_is_low_confidence
    write("package.json", "{\"packageManager\":\"yarn@4\"}\n")
    write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

    managers = assess.dig("tooling", "package_managers")

    assert managers.all? { |manager| manager["status"] == "conflicting" }
    assert managers.all? { |manager| manager["confidence"] == "low" }
  end

  def test_unsupported_explicit_package_manager_does_not_fall_back_to_npm
    write("package.json", "{\"name\":\"sample\",\"packageManager\":\"bun@1.2.3\"}\n")

    managers = assess.dig("tooling", "package_managers")

    assert_equal ["bun"], managers.map { |manager| manager["name"] }
    assert_equal "unknown", managers.first["status"]
    refute_includes managers.map { |manager| manager["name"] }, "npm"
  end

  def test_unsupported_package_manager_and_lockfile_remain_conflicting
    write("package.json", "{\"packageManager\":\"bun@1\"}\n")
    write("pnpm-lock.yaml", "lockfileVersion: '9.0'\n")

    managers = assess.dig("tooling", "package_managers").to_h { |item| [item["name"], item] }

    assert_equal %w[bun pnpm], managers.keys.sort
    assert_equal "conflicting", managers.fetch("bun")["status"]
    assert_equal "conflicting", managers.fetch("pnpm")["status"]
    assert managers.values.all? { |manager| manager["confidence"] == "low" }
  end

  def test_supported_explicit_package_manager_declarations_are_high_confidence
    {
      "npm" => "npm@10",
      "yarn" => "yarn@4",
      "pnpm" => "pnpm@9"
    }.each do |manager_name, declaration|
      write("package.json", "{\"packageManager\":\"#{declaration}\"}\n")

      manager = assess.dig("tooling", "package_managers").find { |item| item["name"] == manager_name }

      assert_equal "detected", manager["status"]
      assert_equal "high", manager["confidence"]
    end
  end

  def test_node_manager_conflict_does_not_lower_uv_confidence
    write("package.json", "{\"name\":\"sample\"}\n")
    write("package-lock.json", "{}\n")
    write("yarn.lock", "# yarn\n")
    write("uv.lock", "version = 1\n")

    managers = assess.dig("tooling", "package_managers").to_h { |item| [item["name"], item] }

    assert_equal "low", managers.fetch("npm")["confidence"]
    assert_equal "low", managers.fetch("yarn")["confidence"]
    assert_equal "high", managers.fetch("uv")["confidence"]
  end

  def test_setup_documentation_does_not_count_as_validation_documentation
    write("README.md", "make setup\nmake dev\n")

    assert_equal "not_detected", assess.dig("validation", "capabilities", "validation_documentation", "status")
  end

  def test_documented_validation_commands_are_retained_as_validation_evidence
    write("README.md", "make setup\nmake test\nmake lint\n")

    result = assess
    validation = result.dig("validation", "capabilities", "validation_documentation")

    assert_equal "documented_command_detected", validation["status"]
    refute_empty validation["evidence_ids"]
    validation_summaries = validation["evidence_ids"].map { |id| result["evidence"].find { |item| item["id"] == id }["summary"] }
    refute validation_summaries.any? { |summary| summary.include?("make setup") }
    assert_equal ["make lint", "make setup", "make test"], result.dig("tooling", "command_surface", "commands").select { |item| item["source"] == "documentation" }.map { |item| item["name"] }
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

  def test_validation_readiness_confidence_uses_evidence_quality_not_count
    write("tests/example_test.py", "sentinel\n")
    write("README.md", "make lint\n")
    write("docs/DEVELOPMENT.md", "make setup\n")

    result = assess

    assert_equal "medium", result.dig("readiness", "deterministic_validation", "confidence")
  end

  def test_pyproject_prose_and_comments_do_not_detect_python_tools
    write("pyproject.toml", <<~TOML)
      [project]
      name = "sample"
      description = "this project does not use pytest, ruff, or mypy"
      # ruff and mypy are intentionally mentioned only in a comment
      notes = "mypy is not configured here"
    TOML

    result = assess

    assert_empty result.dig("tooling", "test_frameworks")
    assert_empty result.dig("tooling", "linters")
    assert_empty result.dig("tooling", "formatters")
    assert_empty result.dig("tooling", "type_checkers")
  end

  def test_pyproject_dependency_and_configuration_structures_detect_tools
    write("pyproject.toml", <<~TOML)
      [project]
      name = "sample"
      dependencies = ["pytest>=8"]

      [tool.ruff]
      line-length = 100

      [tool.mypy]
      strict = true
    TOML

    result = assess

    assert_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
    assert_includes result.dig("tooling", "linters").map { |item| item["name"] }, "Ruff"
    assert_includes result.dig("tooling", "type_checkers").map { |item| item["name"] }, "mypy"
  end

  def test_requirements_parser_ignores_comments_and_options
    write("requirements.txt", <<~REQUIREMENTS)
      # this project does not use pytest
      --extra-index-url https://example.invalid/simple/pytest
      pytest==8.0
      ruff>=0.12 # linting
    REQUIREMENTS

    result = assess

    assert_includes result.dig("tooling", "test_frameworks").map { |item| item["name"] }, "pytest"
    assert_includes result.dig("tooling", "linters").map { |item| item["name"] }, "Ruff"
  end

  def test_requirements_comments_and_options_alone_do_not_detect_tools
    write("requirements.txt", "# pytest and ruff are not used\n--index-url https://example.invalid/ruff\n")

    result = assess

    assert_empty result.dig("tooling", "test_frameworks")
    assert_empty result.dig("tooling", "linters")
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

  def test_ci_alignment_ignores_setup_only_overlap
    write("README.md", "make setup\n")
    write(".github/workflows/ci.yml", "jobs:\n  setup:\n    steps:\n      - run: make setup\n")

    assert_equal "partial", assess.dig("validation", "ci_alignment", "status")
  end

  def test_ci_alignment_is_partial_when_ci_covers_only_one_local_validation_command
    write("Makefile", "test:\n\t@echo test\nlint:\n\t@echo lint\n")
    write(".github/workflows/ci.yml", "jobs:\n  lint:\n    steps:\n      - run: make lint\n")

    assert_equal "partial", assess.dig("validation", "ci_alignment", "status")
  end

  def test_ci_alignment_is_ready_when_all_local_validation_commands_are_invoked
    write("Makefile", "test:\n\t@echo test\nlint:\n\t@echo lint\n")
    write(".github/workflows/ci.yml", <<~YAML)
      jobs:
        validation:
          steps:
            - run: make test
            - run: make lint
    YAML

    assert_equal "ready", assess.dig("validation", "ci_alignment", "status")
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

  def test_github_actions_recognizes_uv_run_validation_commands
    write(".github/workflows/ci.yml", <<~YAML)
      jobs:
        verify:
          steps:
            - run: uv run pytest
    YAML

    result = assess

    assert_equal ["uv run pytest"], result.dig("tooling", "ci", "invocations")
  end

  def test_malformed_github_actions_workflow_degrades_without_execution
    write(".github/workflows/ci.yml", "jobs: [not: valid\n")

    result = assess

    assert_equal [], result.dig("tooling", "ci", "invocations")
    assert_schema(result)
  end
end
