# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

class FrameworkValidationTest < Minitest::Test
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  VALIDATOR = File.join(REPOSITORY_ROOT, "scripts", "validate_framework.rb")

  def setup
    @temporary_root = Dir.mktmpdir("framework-validation-test-")
    @fixture_root = File.join(@temporary_root, "repository")
    build_fixture
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_actual_checked_out_repository_passes_validation
    stdout, stderr, status = run_validator(REPOSITORY_ROOT)

    assert status.success?, failure_message("live repository", stdout, stderr, status)
    assert_includes stdout, "Framework validation passed."
    assert_empty stderr
  end

  def test_valid_isolated_repository_passes_validation_from_another_directory
    assert_passes("valid isolated repository")
  end

  def test_root_harness_satisfies_minimum_structure
    %w[AGENTS.md docs/AGENT_PROMPT.txt scripts/run_codex.sh .github/PULL_REQUEST_TEMPLATE.md].each do |path|
      assert File.file?(File.join(@fixture_root, path)), "expected fixture root harness file #{path}"
    end
    assert_passes("root harness structure")
  end

  def test_target_paths_are_not_checked_for_existence
    refute File.exist?(File.join(@fixture_root, "bin/codex"))
    refute File.exist?(File.join(@fixture_root, "target/issues/implementation.md"))
    assert_passes("nonexistent target paths")
  end

  def test_planned_adapter_directory_may_be_absent
    refute File.exist?(File.join(@fixture_root, "adapters/ecosystems/node"))
    assert_passes("planned adapter without implementation")
  end

  def test_runtime_and_issue_template_may_repeat_baseline_source_paths
    assert_passes("intentional baseline cross-reference repetition")
  end

  def test_multiple_independent_errors_are_reported_together
    mutate do |metadata|
      metadata["framework"]["name"] = ""
      metadata["conventions"]["issue_workflow"]["implementation_ready_issues_are_primary"] = "true"
    end

    _stdout, stderr, status = run_validator
    refute status.success?
    assert_includes stderr, "framework.name: expected a non-empty string"
    assert_includes stderr, "implementation_ready_issues_are_primary: expected a boolean"
  end

  def test_root_target_like_launcher_does_not_replace_missing_baseline_source
    FileUtils.rm(File.join(@fixture_root, "baseline/scripts/run_codex.sh"))

    assert_fails("baseline/scripts/run_codex.sh", "file does not exist")
  end

  def test_root_prompt_does_not_replace_missing_runtime_baseline_prompt
    FileUtils.rm(File.join(@fixture_root, "baseline/docs/AGENT_PROMPT.txt"))

    assert_fails("agent_runtimes.supported[codex].artefacts[1].source_path", "baseline/docs/AGENT_PROMPT.txt")
  end

  def test_root_launcher_does_not_replace_missing_runtime_baseline_launcher
    FileUtils.rm(File.join(@fixture_root, "baseline/scripts/run_codex.sh"))

    assert_fails("agent_runtimes.supported[codex].artefacts[0].source_path", "baseline/scripts/run_codex.sh")
  end

  def test_missing_required_top_level_section_fails
    mutate { |metadata| metadata.delete("prompts") }

    assert_fails("framework.yml.prompts: missing required field")
  end

  def test_unknown_top_level_key_fails
    mutate { |metadata| metadata["surprise"] = true }

    assert_fails("framework.yml.surprise: unknown field")
  end

  def test_unsupported_schema_version_fails
    mutate { |metadata| metadata["schema_version"] = 1 }

    assert_fails("unsupported schema version", "expected: 2")
  end

  def test_missing_required_nested_field_fails
    mutate { |metadata| metadata["prompts"].first.delete("purpose") }

    assert_fails("prompts[bootstrap].purpose: missing required field")
  end

  def test_unknown_nested_field_fails
    mutate { |metadata| metadata["usage_modes"].first["extra"] = "value" }

    assert_fails("usage_modes[bootstrap].extra: unknown field")
  end

  def test_mapping_where_sequence_required_fails
    mutate { |metadata| metadata["usage_modes"] = {} }

    assert_fails("usage_modes: expected a sequence, got: mapping")
  end

  def test_sequence_where_mapping_required_fails
    mutate { |metadata| metadata["framework"] = [] }

    assert_fails("framework: expected a mapping, got: sequence")
  end

  def test_scalar_document_where_top_level_mapping_required_fails_cleanly
    File.write(File.join(@fixture_root, "framework.yml"), "false\n")

    assert_fails("framework.yml: expected a mapping, got: boolean")
  end

  def test_string_where_boolean_required_fails
    mutate do |metadata|
      metadata["conventions"]["command_surface"]["makefile_is_primary_interface"] = "true"
    end

    assert_fails("makefile_is_primary_interface: expected a boolean, got: string")
  end

  def test_numeric_string_where_integer_required_fails
    mutate { |metadata| metadata["schema_version"] = "1" }

    assert_fails("schema_version: expected an integer, got: string")
  end

  def test_empty_required_identity_fails
    mutate { |metadata| metadata["usage_modes"].first["id"] = "" }

    assert_fails("usage_modes[0].id: expected a non-empty string")
  end

  def test_empty_required_path_fails
    mutate { |metadata| metadata["prompts"].first["path"] = "" }

    assert_fails("prompts[bootstrap].path: expected a non-empty string")
  end

  def test_unsupported_supported_runtime_status_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["status"] = "planned" }

    assert_fails("unsupported runtime status", "expected: supported")
  end

  def test_unsupported_planned_runtime_status_fails
    mutate { |metadata| metadata["agent_runtimes"]["planned"].first["status"] = "supported" }

    assert_fails("unsupported runtime status", "expected: planned")
  end

  def test_empty_planned_runtime_collection_is_valid
    mutate { |metadata| metadata["agent_runtimes"]["planned"] = [] }

    assert_passes("empty planned runtime collection")
  end

  def test_invalid_runtime_version_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["runtime_version"] = 0 }

    assert_fails("runtime_version: expected a positive integer")
  end

  def test_invalid_runtime_distribution_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["distribution"] = "system" }

    assert_fails("distribution: unsupported value")
  end

  def test_invalid_runtime_artefact_role_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["artefacts"].first["role"] = "binary" }

    assert_fails("role: unsupported value")
  end

  def test_duplicate_runtime_artefact_role_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["artefacts"][1]["role"] = "launcher" }

    assert_fails("duplicate artefact role: launcher")
  end

  def test_repository_runtime_requires_target_path
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["artefacts"].first.delete("target_path") }

    assert_fails("artefacts[0].target_path: missing required field")
  end

  def test_global_user_runtime_rejects_target_path
    add_claude_runtime
    mutate { |metadata| metadata["agent_runtimes"]["supported"].last["artefacts"].first["target_path"] = "bin/claude-explore" }

    assert_fails("target_path: unknown field")
  end

  def test_missing_runtime_source_artefact_fails
    add_claude_runtime(source_path: "agent-runtimes/claude-explore/missing")

    assert_fails("file does not exist: agent-runtimes/claude-explore/missing")
  end

  def test_invalid_runtime_platform_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["supported_platforms"] << "windows" }

    assert_fails("unsupported value: \"windows\"")
  end

  def test_duplicate_runtime_capability_fails
    mutate do |metadata|
      capability = metadata["agent_runtimes"]["supported"].first["capabilities"].first
      metadata["agent_runtimes"]["supported"].first["capabilities"] << capability
    end

    assert_fails("duplicate value: repository work")
  end

  def test_invalid_runtime_configuration_type_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["configuration"] = {"type" => "other"} }

    assert_fails("unsupported configuration type")
  end

  def test_valid_claude_runtime_configuration_passes
    add_claude_runtime

    assert_passes("valid Claude runtime configuration")
  end

  def test_invalid_claude_runtime_configuration_fails
    add_claude_runtime
    mutate { |metadata| metadata["agent_runtimes"]["supported"].last["configuration"]["minimum_client_version"] = "2.0.0" }

    assert_fails("unsupported minimum client version", "expected: 2.1.224")
  end

  def test_unsupported_adapter_status_fails
    mutate { |metadata| metadata["adapters"]["available"].first["status"] = "experimental" }

    assert_fails("unsupported adapter status")
  end

  def test_unsupported_runtime_access_mode_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["configuration"]["access_modes"] << "ssh" }

    assert_fails("unsupported value: \"ssh\"", "expected one of: disabled, app")
  end

  def test_unsupported_origin_scheme_fails
    mutate do |metadata|
      metadata["agent_runtimes"]["supported"].first["configuration"]["repository_identity"]["origin_remote_scheme"] = "ssh"
    end

    assert_fails("unsupported origin scheme", "expected: https")
  end

  def test_duplicate_usage_mode_id_fails
    mutate { |metadata| metadata["usage_modes"] << deep_copy(metadata["usage_modes"].first) }

    assert_fails("duplicate value: bootstrap")
  end

  def test_duplicate_prompt_id_fails
    mutate { |metadata| metadata["prompts"] << deep_copy(metadata["prompts"].first) }

    assert_fails("duplicate value: bootstrap")
  end

  def test_duplicate_baseline_name_across_collections_fails
    mutate do |metadata|
      duplicate = deep_copy(metadata["baseline"]["required"].first)
      duplicate["target_path"] = "bin/other-codex"
      metadata["baseline"]["recommended"] << duplicate
    end

    assert_fails("duplicate value: launcher")
  end

  def test_duplicate_baseline_target_across_collections_fails
    write_file("baseline/scripts/other.sh")
    mutate do |metadata|
      duplicate = deep_copy(metadata["baseline"]["required"].first)
      duplicate["name"] = "other_launcher"
      duplicate["source_path"] = "baseline/scripts/other.sh"
      metadata["baseline"]["recommended"] << duplicate
    end

    assert_fails("duplicate value: bin/codex")
  end

  def test_duplicate_runtime_id_across_supported_and_planned_fails
    mutate { |metadata| metadata["agent_runtimes"]["planned"].first["id"] = "codex" }

    assert_fails("duplicate value: codex")
  end

  def test_duplicate_adoption_tier_id_fails
    mutate { |metadata| metadata["adoption_tiers"] << deep_copy(metadata["adoption_tiers"].first) }

    assert_fails("duplicate value: tier-1")
  end

  def test_duplicate_adapter_taxonomy_type_fails
    mutate { |metadata| metadata["adapters"]["taxonomy"] << deep_copy(metadata["adapters"]["taxonomy"].first) }

    assert_fails("duplicate value: ecosystem")
  end

  def test_duplicate_adapter_identity_fails
    mutate { |metadata| metadata["adapters"]["available"] << deep_copy(metadata["adapters"]["available"].first) }

    assert_fails("duplicate adapter identity: ecosystem/node")
  end

  def test_duplicate_issue_template_id_fails
    mutate do |metadata|
      duplicate = deep_copy(metadata["issue_templates"]["primary"])
      metadata["issue_templates"]["additional"] << duplicate
    end

    assert_fails("duplicate value: implementation")
  end

  def test_duplicate_access_mode_fails
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["configuration"]["access_modes"] << "app" }

    assert_fails("duplicate value: app")
  end

  def test_duplicate_adoption_include_fails
    mutate { |metadata| metadata["adoption_tiers"].first["includes"] << "bin/codex" }

    assert_fails("duplicate value: bin/codex")
  end

  def test_missing_prompt_file_fails
    FileUtils.rm(File.join(@fixture_root, "prompts/bootstrap.md"))

    assert_fails("prompts[bootstrap].path", "file does not exist: prompts/bootstrap.md")
  end

  def test_missing_baseline_source_file_fails
    FileUtils.rm(File.join(@fixture_root, "baseline/issues/implementation.md"))

    assert_fails("baseline.required[issue_template].source_path", "file does not exist")
  end

  def test_missing_supported_runtime_launcher_fails
    FileUtils.rm(File.join(@fixture_root, "baseline/scripts/run_codex.sh"))

    assert_fails("agent_runtimes.supported[codex].artefacts[0].source_path", "file does not exist")
  end

  def test_missing_issue_template_source_fails
    FileUtils.rm(File.join(@fixture_root, "baseline/issues/implementation.md"))

    assert_fails("issue_templates.primary.source_path", "file does not exist")
  end

  def test_missing_supported_adapter_directory_fails
    mutate { |metadata| metadata["adapters"]["available"].first["status"] = "supported" }

    assert_fails("adapters.available[node].path", "directory does not exist")
  end

  def test_absolute_source_path_fails
    mutate { |metadata| metadata["prompts"].first["path"] = "/tmp/prompt.md" }

    assert_fails("expected a relative path, got: /tmp/prompt.md")
  end

  def test_absolute_target_path_fails
    mutate { |metadata| metadata["baseline"]["required"].first["target_path"] = "/tmp/codex" }

    assert_fails("expected a relative path, got: /tmp/codex")
  end

  def test_source_path_traversal_fails
    mutate { |metadata| metadata["prompts"].first["path"] = "prompts/../README.md" }

    assert_fails("path must not contain '.' or '..' segments")
  end

  def test_target_path_traversal_fails
    mutate { |metadata| metadata["baseline"]["required"].first["target_path"] = "bin/../codex" }

    assert_fails("path must not contain '.' or '..' segments")
  end

  def test_source_symlink_cannot_escape_repository
    outside = File.join(@temporary_root, "outside.md")
    File.write(outside, "outside")
    File.symlink(outside, File.join(@fixture_root, "prompts/escape.md"))
    mutate { |metadata| metadata["prompts"].first["path"] = "prompts/escape.md" }

    assert_fails("path resolves outside repository: prompts/escape.md")
  end

  def test_source_symlink_loop_reports_resolution_error_instead_of_nonexistence
    File.symlink("loop-b.md", File.join(@fixture_root, "prompts/loop-a.md"))
    File.symlink("loop-a.md", File.join(@fixture_root, "prompts/loop-b.md"))
    mutate { |metadata| metadata["prompts"].first["path"] = "prompts/loop-a.md" }

    stdout, stderr, status = run_validator
    refute status.success?, failure_message("source symlink loop", stdout, stderr, status)
    assert_empty stdout
    assert_includes stderr, "could not resolve file: prompts/loop-a.md (Errno::ELOOP)"
    refute_includes stderr, "file does not exist: prompts/loop-a.md"
    refute_includes stderr, "validate_framework.rb:"
  end

  def test_source_path_with_nul_byte_fails_without_filesystem_exception
    mutate { |metadata| metadata["prompts"].first["path"] = "prompts/\0bootstrap.md" }

    stdout, stderr, status = run_validator
    refute status.success?, failure_message("NUL-containing source path", stdout, stderr, status)
    assert_empty stdout
    assert_includes stderr, "prompts[bootstrap].path: path must not contain NUL bytes"
    refute_includes stderr, "\0"
    refute_includes stderr, "validate_framework.rb:"
  end

  def test_target_path_with_nul_byte_fails_without_filesystem_exception
    mutate do |metadata|
      metadata["conventions"]["commit_metadata"]["documented_in"] = "docs/\0COMMITS.md"
    end

    stdout, stderr, status = run_validator
    refute status.success?, failure_message("NUL-containing target path", stdout, stderr, status)
    assert_empty stdout
    assert_includes stderr, "conventions.commit_metadata.documented_in: path must not contain NUL bytes"
    refute_includes stderr, "\0"
    refute_includes stderr, "validate_framework.rb:"
  end

  def test_file_where_supported_adapter_directory_expected_fails
    write_file("adapters/ecosystems/node")
    mutate { |metadata| metadata["adapters"]["available"].first["status"] = "supported" }

    assert_fails("expected a directory: adapters/ecosystems/node")
  end

  def test_directory_where_source_file_expected_fails
    FileUtils.rm(File.join(@fixture_root, "prompts/bootstrap.md"))
    FileUtils.mkdir_p(File.join(@fixture_root, "prompts/bootstrap.md"))

    assert_fails("expected a regular file: prompts/bootstrap.md")
  end

  def test_missing_root_agents_file_fails
    FileUtils.rm(File.join(@fixture_root, "AGENTS.md"))

    assert_fails("repository structure: AGENTS.md", "file does not exist")
  end

  def test_missing_root_prompt_file_fails
    FileUtils.rm(File.join(@fixture_root, "docs/AGENT_PROMPT.txt"))

    assert_fails("repository structure: docs/AGENT_PROMPT.txt", "file does not exist")
  end

  def test_missing_root_launcher_file_fails
    FileUtils.rm(File.join(@fixture_root, "scripts/run_codex.sh"))

    assert_fails("repository structure: scripts/run_codex.sh", "file does not exist")
  end

  def test_missing_root_pull_request_template_fails
    FileUtils.rm(File.join(@fixture_root, ".github/PULL_REQUEST_TEMPLATE.md"))

    assert_fails("repository structure: .github/PULL_REQUEST_TEMPLATE.md", "file does not exist")
  end

  def test_windows_and_empty_path_segments_fail
    mutate do |metadata|
      metadata["prompts"].first["path"] = "C:\\prompts\\bootstrap.md"
      metadata["baseline"]["required"].first["target_path"] = "bin//codex"
    end

    assert_fails("expected a relative path", "path must use forward slashes", "path must not contain empty segments")
  end

  def test_runtime_launcher_pair_must_match_baseline
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["artefacts"][0]["target_path"] = "bin/other" }

    assert_fails("artefacts[0]: source_path/target_path pair does not match a baseline artefact")
  end

  def test_runtime_launcher_baseline_category_must_match
    mutate { |metadata| metadata["baseline"]["required"].first["category"] = "command-surface" }

    assert_fails("artefacts[0].category", "expected: agent-launcher")
  end

  def test_runtime_prompt_pair_must_match_baseline
    mutate { |metadata| metadata["agent_runtimes"]["supported"].first["artefacts"][1]["target_path"] = "docs/OTHER.txt" }

    assert_fails("artefacts[1]: source_path/target_path pair does not match a baseline artefact")
  end

  def test_issue_template_pair_must_match_baseline
    mutate { |metadata| metadata["issue_templates"]["primary"]["target_path"] = "target/issues/other.md" }

    assert_fails("issue_templates.primary: source_path/target_path pair does not match")
  end

  def test_issue_template_baseline_category_must_match
    mutate { |metadata| metadata["baseline"]["required"][2]["category"] = "issue-template-config" }

    assert_fails("issue_templates.primary.category", "expected: issue-template")
  end

  def test_adoption_tier_unknown_target_fails
    mutate { |metadata| metadata["adoption_tiers"].first["includes"] = ["scripts/missing.sh"] }

    assert_fails("unknown baseline target path: scripts/missing.sh")
  end

  def test_available_adapter_unknown_taxonomy_fails
    mutate { |metadata| metadata["adapters"]["available"].first["type"] = "language" }

    assert_fails("unknown adapter taxonomy type: language")
  end

  def test_adapter_path_must_match_taxonomy_pattern
    mutate { |metadata| metadata["adapters"]["available"].first["path"] = "adapters/ecosystems/javascript" }

    assert_fails("path does not match taxonomy pattern", "expected: adapters/ecosystems/node")
  end

  def test_supported_adapter_requires_implementation_directory
    mutate { |metadata| metadata["adapters"]["available"].first["status"] = "supported" }

    assert_fails("directory does not exist: adapters/ecosystems/node")
  end

  def test_invalid_taxonomy_path_pattern_fails
    mutate { |metadata| metadata["adapters"]["taxonomy"].first["path_pattern"] = "adapters/../<name>/<name>/" }

    assert_fails("expected exactly one literal <name> placeholder", "must not end with a slash", "must not contain '.' or '..' segments")
  end

  def test_diagnostics_are_stably_ordered
    mutate do |metadata|
      metadata["framework"]["name"] = ""
      metadata["framework"]["description"] = ""
    end

    _stdout, first_stderr, first_status = run_validator
    _stdout, second_stderr, second_status = run_validator
    refute first_status.success?
    refute second_status.success?
    assert_equal first_stderr, second_stderr
    assert_equal first_stderr.lines.sort, first_stderr.lines
  end

  private

  def build_fixture
    %w[docs scripts .github baseline/scripts baseline/docs baseline/issues prompts adapters/ecosystems].each do |directory|
      FileUtils.mkdir_p(File.join(@fixture_root, directory))
    end
    %w[
      AGENTS.md README.md docs/AGENT_PROMPT.txt scripts/run_codex.sh
      .github/PULL_REQUEST_TEMPLATE.md
      baseline/scripts/run_codex.sh baseline/docs/AGENT_PROMPT.txt
      baseline/issues/implementation.md prompts/bootstrap.md
    ].each { |path| write_file(path) }
    FileUtils.cp(VALIDATOR, File.join(@fixture_root, "scripts/validate_framework.rb"))
    write_metadata(valid_metadata)
  end

  def valid_metadata
    {
      "schema_version" => 2,
      "framework" => {
        "name" => "fixture-framework",
        "framework_version" => "1.0.0",
        "description" => "Fixture framework metadata.",
        "intended_for" => ["test repositories"],
        "primary_goals" => ["deterministic validation"]
      },
      "usage_modes" => [
        {"id" => "bootstrap", "name" => "Bootstrap", "description" => "Create a repository."}
      ],
      "prompts" => [
        {"id" => "bootstrap", "path" => "prompts/bootstrap.md", "purpose" => "Bootstrap a repository."}
      ],
      "path_conventions" => {
        "baseline" => {"source_path" => "Framework source path.", "target_path" => "Adopted target path."},
        "agent_runtimes" => {"source_path" => "Runtime source.", "target_path" => "Optional runtime target."},
        "adapters" => {"path" => "Adapter implementation path."},
        "prompts" => {"path" => "Reusable prompt path."}
      },
      "baseline" => {
        "description" => "Fixture baseline.",
        "path_semantics" => {"source_path" => "Framework source.", "target_path" => "Adopted target."},
        "required" => [
          baseline_entry("launcher", "agent-launcher", "baseline/scripts/run_codex.sh", "bin/codex"),
          baseline_entry("runtime_prompt", "agent-session-brief", "baseline/docs/AGENT_PROMPT.txt", "target/docs/AGENT_PROMPT.txt"),
          baseline_entry("issue_template", "issue-template", "baseline/issues/implementation.md", "target/issues/implementation.md")
        ],
        "recommended" => []
      },
      "agent_runtimes" => {
        "philosophy" => "Runtime-specific launchers.",
        "supported" => [
          {
            "id" => "codex",
            "display_name" => "Codex",
            "status" => "supported",
            "runtime_version" => 1,
            "distribution" => "repository",
            "description" => "Supported fixture runtime.",
            "artefacts" => [
              {"role" => "launcher", "source_path" => "baseline/scripts/run_codex.sh", "target_path" => "bin/codex"},
              {"role" => "prompt", "source_path" => "baseline/docs/AGENT_PROMPT.txt", "target_path" => "target/docs/AGENT_PROMPT.txt"}
            ],
            "supported_platforms" => ["macos", "linux"],
            "required_executables" => [],
            "capabilities" => ["repository work"],
            "limitations" => ["fixture limitation"],
            "configuration" => {
              "type" => "codex",
              "access_modes" => ["disabled", "app"],
              "repository_identity" => {
                "origin_remote_required" => true,
                "origin_remote_scheme" => "https",
                "expected_owner_env" => "EXPECTED_OWNER",
                "expected_owner_default" => "example",
                "expected_repo_env" => "EXPECTED_REPO",
                "expected_repo_default" => "repository"
              }
            }
          }
        ],
        "planned" => [
          {"id" => "future-agent", "display_name" => "Future Agent", "status" => "planned", "description" => "Planned fixture runtime."}
        ]
      },
      "adoption_tiers" => [
        {"id" => "tier-1", "name" => "starter", "description" => "Starter tier.", "includes" => ["bin/codex"]}
      ],
      "adapters" => {
        "taxonomy" => [
          {"type" => "ecosystem", "description" => "Language ecosystem.", "path_pattern" => "adapters/ecosystems/<name>"}
        ],
        "available" => [
          {"name" => "node", "type" => "ecosystem", "path" => "adapters/ecosystems/node", "status" => "planned"}
        ]
      },
      "issue_templates" => {
        "primary" => {
          "id" => "implementation",
          "source_path" => "baseline/issues/implementation.md",
          "target_path" => "target/issues/implementation.md",
          "purpose" => "Implementation work."
        },
        "additional" => []
      },
      "conventions" => {
        "issue_workflow" => {
          "implementation_ready_issues_are_primary" => true,
          "discovery_work_should_be_explicit" => true,
          "issue_execution_readiness_is_part_of_scope_control" => true
        },
        "command_surface" => {
          "makefile_is_primary_interface" => true,
          "local_and_ci_commands_share_conceptual_surface" => true,
          "ci_specific_overlays_supported" => true
        },
        "hooks" => {"standard_runner" => "hooks", "hook_targets" => ["make hook"]},
        "ci" => {"semantically_grouped_jobs_preferred" => true, "typical_targets" => ["make check"]},
        "commit_metadata" => {
          "documented_in" => "docs/COMMITS.md",
          "default_authorship_model" => "developer-author",
          "agent_metadata_recorded_in_trailers" => true
        }
      }
    }
  end

  def baseline_entry(name, category, source_path, target_path)
    {
      "name" => name,
      "category" => category,
      "source_path" => source_path,
      "target_path" => target_path,
      "description" => "Fixture baseline artefact."
    }
  end

  def add_claude_runtime(source_path: "agent-runtimes/claude-explore/bin/claude-explore")
    write_file("agent-runtimes/claude-explore/bin/claude-explore") if source_path.end_with?("bin/claude-explore")
    mutate do |metadata|
      metadata["agent_runtimes"]["supported"] << {
        "id" => "claude-explore",
        "display_name" => "Claude Code Explore",
        "status" => "supported",
        "runtime_version" => 1,
        "distribution" => "global-user",
        "description" => "Reduced-authority exploration runtime.",
        "artefacts" => [{"role" => "launcher", "source_path" => source_path}],
        "supported_platforms" => ["macos", "linux"],
        "required_executables" => [{"name" => "ruby", "minimum_version" => "3.3"}],
        "capabilities" => ["local exploration"],
        "limitations" => ["not a hostile-code sandbox"],
        "configuration" => {
          "type" => "claude-explore",
          "policy_schema_version" => 1,
          "minimum_client_version" => "2.1.224"
        }
      }
    end
  end

  def mutate
    metadata = YAML.safe_load(File.read(File.join(@fixture_root, "framework.yml")))
    yield metadata
    write_metadata(metadata)
  end

  def deep_copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def write_metadata(metadata)
    File.write(File.join(@fixture_root, "framework.yml"), YAML.dump(metadata))
  end

  def write_file(path, contents = "fixture\n")
    absolute_path = File.join(@fixture_root, path)
    FileUtils.mkdir_p(File.dirname(absolute_path))
    File.write(absolute_path, contents)
  end

  def run_validator(root = @fixture_root)
    script = File.join(root, "scripts/validate_framework.rb")
    Open3.capture3(RbConfig.ruby, script, chdir: Dir.tmpdir)
  end

  def assert_passes(scenario)
    stdout, stderr, status = run_validator
    assert status.success?, failure_message(scenario, stdout, stderr, status)
    assert_includes stdout, "Framework validation passed."
    assert_empty stderr
  end

  def assert_fails(*diagnostics)
    stdout, stderr, status = run_validator
    refute status.success?, failure_message("invalid fixture", stdout, stderr, status)
    assert_empty stdout
    diagnostics.each do |diagnostic|
      assert_includes stderr, diagnostic, failure_message("missing diagnostic #{diagnostic.inspect}", stdout, stderr, status)
    end
    refute_includes stderr, "validate_framework.rb:"
  end

  def failure_message(scenario, stdout, stderr, status)
    <<~MESSAGE
      #{scenario} produced an unexpected validator result.
      Expected status: #{scenario == 'invalid fixture' ? 'non-zero' : 'zero'}
      Actual status: #{status.exitstatus}
      stdout:
      #{stdout}
      stderr:
      #{stderr}
    MESSAGE
  end
end
