# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentReferenceFixtureTest < Minitest::Test
  include AssessmentTestSupport

  def test_committed_fixture_is_generated_from_the_assessor_with_only_identity_normalisation
    assert_reference_snapshot(isolated_reference_fixture)
  end

  def test_host_global_ignore_does_not_omit_tracked_reference_files
    ignore_file = File.join(@temporary_root, "global-ignore")
    global_config = File.join(@temporary_root, "global-gitconfig")
    File.write(ignore_file, "README.md\n")
    write_git_config(global_config, "core.excludesFile", ignore_file)
    git_env = controlled_git_environment(global_config)

    source_readme = File.binread(File.join(FIXTURE, "README.md"))
    fixture = isolated_reference_fixture(git_env: git_env)

    assert_includes reference_fixture_tracked_paths, "README.md"
    assert_equal "README.md\n", git!(fixture, "check-ignore", "--no-index", "--", "README.md", env: git_env)
    assert_equal reference_fixture_tracked_paths, git!(fixture, "ls-files", "-z", env: git_env).split("\0").reject(&:empty?).sort
    assert_reference_snapshot(fixture)
    assert_equal source_readme, File.binread(File.join(FIXTURE, "README.md"))
    assert_equal global_config, git_env.fetch("GIT_CONFIG_GLOBAL")
    assert_equal "1", git_env.fetch("GIT_CONFIG_NOSYSTEM")
  end

  def test_host_global_hooks_are_eligible_but_not_run_for_the_isolated_fixture_commit
    hooks_directory = File.join(@temporary_root, "host-hooks")
    global_config = File.join(@temporary_root, "global-gitconfig")
    marker = ".hook-ran"
    FileUtils.mkdir_p(hooks_directory)
    hook = File.join(hooks_directory, "pre-commit")
    File.write(hook, "#!/bin/sh\n: > #{marker}\n")
    FileUtils.chmod(0o755, hook)
    write_git_config(global_config, "core.hooksPath", hooks_directory)
    git_env = controlled_git_environment(global_config)

    control = File.join(@temporary_root, "hook-control")
    FileUtils.mkdir_p(control)
    git!(control, "init", env: git_env)
    git!(control, "config", "user.name", "Assessment Test", env: git_env)
    git!(control, "config", "user.email", "assessment@example.invalid", env: git_env)
    File.write(File.join(control, "README.md"), "hook eligibility control\n")
    git!(control, "add", "README.md", env: git_env)
    git!(control, "commit", "-m", "verify host hook eligibility", env: git_env)

    assert File.file?(File.join(control, marker)), "controlled global pre-commit hook was not eligible"
    FileUtils.rm(File.join(control, marker))

    fixture = isolated_reference_fixture(git_env: git_env)
    disabled_hooks = File.join(@temporary_root, "disabled-git-hooks")

    refute File.exist?(File.join(fixture, marker)), "host pre-commit hook ran for the isolated fixture"
    assert_empty Dir.children(disabled_hooks)
    refute_empty git!(fixture, "rev-parse", "--verify", "HEAD^{commit}", env: git_env).strip
    assert_empty git!(fixture, "status", "--porcelain", "--untracked-files=all", env: git_env)
    assert_equal reference_fixture_tracked_paths, git!(fixture, "ls-files", "-z", env: git_env).split("\0").reject(&:empty?).sort
    assert_reference_snapshot(fixture)
  end

  def test_tracked_working_copy_changes_remain_visible_to_the_snapshot_comparison
    fixture = isolated_reference_fixture
    File.write(File.join(fixture, "README.md"), "Changed tracked reference content.\n")
    committed = committed_reference_assessment
    actual = normalize_reference_assessment(assess(fixture))

    refute_equal committed, actual
  end

  def test_local_generated_environment_changes_the_live_assessment_but_not_the_committed_fixture_input
    clean_fixture = isolated_reference_fixture
    generated_fixture = isolated_reference_fixture
    FileUtils.mkdir_p(File.join(generated_fixture, ".venv"))

    clean = normalize_reference_assessment(assess(clean_fixture))
    generated = normalize_reference_assessment(assess(generated_fixture))
    committed = YAML.safe_load_file(File.join(FIXTURE, "assessment", "assessment.yml"), permitted_classes: [],
      permitted_symbols: [],
      aliases: false)

    assert_equal committed, clean
    assert_equal committed.dig("scope", "excluded_paths"), clean.dig("scope", "excluded_paths")
    assert_includes generated.dig("scope", "excluded_paths"), ".venv"
    refute_equal committed, generated
  end

  private

  def controlled_git_environment(global_config)
    {"GIT_CONFIG_GLOBAL" => global_config, "GIT_CONFIG_NOSYSTEM" => "1", "GIT_CONFIG_COUNT" => "0"}
  end

  def committed_reference_assessment
    YAML.safe_load_file(File.join(FIXTURE, "assessment", "assessment.yml"), permitted_classes: [],
      permitted_symbols: [],
      aliases: false)
  end

  def assert_reference_snapshot(fixture)
    actual = normalize_reference_assessment(assess(fixture))

    assert_equal committed_reference_assessment, actual
    assert_schema(actual)
    assert_equal AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(actual),
      File.read(File.join(FIXTURE, "assessment", "assessment.md"))
  end
end
