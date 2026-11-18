# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

require "agentic_developer_setup/assessment"
require_relative "assessment/reference_fixture_support"

module AssessmentTestSupport
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "examples", "reference-service")

  def setup
    super
    @temporary_root = Dir.mktmpdir("assessment-amendment-")
    @target = File.join(@temporary_root, "target")
    FileUtils.mkdir_p(@target)
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
    super
  end

  def assess(target = @target, context_path: nil)
    AgenticDeveloperSetup::Assessment::Assessor.new(target, clock: fixed_clock).assess(context_path: context_path)
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

  def init_git(path = @target)
    _out, err, status = Open3.capture3("git", "init", path)
    raise err unless status.success?

    Open3.capture3("git", "-C", path, "config", "user.name", "Assessment Test")
    Open3.capture3("git", "-C", path, "config", "user.email", "assessment@example.invalid")
    File.write(File.join(path, "README.md"), "# initial\n")
    Open3.capture3("git", "-C", path, "add", "README.md")
    Open3.capture3("git", "-C", path, "commit", "-m", "initial")
  end

  def isolated_reference_fixture(git_env: {})
    @isolated_reference_fixture_count = (@isolated_reference_fixture_count || 0) + 1
    name = "reference-service-#{@isolated_reference_fixture_count}"
    root = File.join(@temporary_root, name)
    FileUtils.mkdir_p(root)

    relative_paths = reference_fixture_tracked_paths

    relative_paths.each do |relative_path|
      source = File.join(FIXTURE, relative_path)
      destination = File.join(root, relative_path)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.copy_entry(source, destination, true, false, true)
    end

    git!(root, "init", "--separate-git-dir", File.join(@temporary_root, "#{name}.git"), env: git_env)
    git!(root, "config", "user.name", "Assessment Test", env: git_env)
    git!(root, "config", "user.email", "assessment@example.invalid", env: git_env)
    git!(root, "add", "-f", "--", *relative_paths, env: git_env)

    assert_reference_fixture_paths(root, relative_paths, env: git_env)
    disabled_hooks = File.join(@temporary_root, "disabled-git-hooks")
    FileUtils.mkdir_p(disabled_hooks)
    git!(root, "-c", "core.hooksPath=#{disabled_hooks}", "-c", "commit.gpgsign=false", "commit", "-m", "fixture", env: git_env)
    assert_reference_fixture_paths(root, relative_paths, env: git_env)

    status = git!(root, "status", "--porcelain", "--untracked-files=all", env: git_env)
    raise "isolated reference fixture is not clean after commit: #{status}" unless status.empty?

    root
  end

  def reference_fixture_tracked_paths
    tracked_paths, error, status = Open3.capture3(
      "git", "ls-files", "-z", "--", "examples/reference-service", chdir: ROOT
    )
    raise "could not list tracked reference fixture files: #{error}" unless status.success?

    tracked_paths.split("\0").reject(&:empty?).map do |path|
      path.delete_prefix("examples/reference-service/")
    end.sort
  end

  def assert_reference_fixture_paths(root, expected_paths, env: {})
    actual_paths = git!(root, "ls-files", "-z", env: env).split("\0").reject(&:empty?).sort
    return if actual_paths == expected_paths

    missing = expected_paths - actual_paths
    unexpected = actual_paths - expected_paths
    raise "isolated reference fixture tracked paths differ (missing: #{missing.inspect}; unexpected: #{unexpected.inspect})"
  end

  def git!(directory, *arguments, env: {})
    stdout, stderr, status = Open3.capture3(env, "git", "-C", directory, *arguments)
    return stdout if status.success?

    details = [stdout, stderr].reject(&:empty?).join("\n")
    raise "git #{arguments.join(" ")} failed in #{directory} (exit #{status.exitstatus}): #{details}"
  end

  def write_git_config(config_path, key, value)
    _stdout, stderr, status = Open3.capture3("git", "config", "--file", config_path, key, value)
    return if status.success?

    raise "could not write temporary Git config #{key}: #{stderr}"
  end

  def self.normalize_reference_assessment(result)
    ReferenceAssessmentSupport.normalize(result)
  end

  def normalize_reference_assessment(result)
    AssessmentTestSupport.normalize_reference_assessment(result)
  end
end
