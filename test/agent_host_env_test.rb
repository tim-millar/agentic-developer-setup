# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"

class AgentHostEnvTest < Minitest::Test
  REPOSITORY_ROOT = File.expand_path("..", __dir__)
  HOOK = File.join(REPOSITORY_ROOT, "scripts", "agent_host_env.sh")
  BASH = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |directory| File.join(directory, "bash") }.find do |path|
    File.executable?(path)
  end || "/bin/bash"
  Result = Struct.new(:stdout, :stderr, :status)

  def setup
    @temporary_root = Dir.mktmpdir("agent-host-env-test-")
    @repository = File.join(@temporary_root, "repository")
    @ruby_bin = File.join(@repository, "synthetic-bin")
    @observed_path = File.join(@temporary_root, "observed-path")
    FileUtils.mkdir_p(@ruby_bin)
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def test_exact_match_succeeds_silently_and_preserves_path
    result, path = run_hook("ruby-3.3.12", actual_version: "3.3.12")

    assert_success(result)
    assert_empty result.stdout
    assert_empty result.stderr
    assert_path_was_preserved(path)
  end

  def test_requirement_is_derived_from_ruby_version_file
    result, path = run_hook("ruby-9.8.7", actual_version: "9.8.7")

    assert_success(result)
    assert_empty result.stdout
    assert_empty result.stderr
    assert_path_was_preserved(path)
  end

  def test_patch_mismatch_fails_with_actionable_diagnostic_and_preserves_path
    result, path = run_hook("ruby-3.3.12", actual_version: "3.3.11")

    assert_failure(result)
    assert_empty result.stdout
    assert_includes result.stderr, ".ruby-version requires Ruby 3.3.12"
    assert_includes result.stderr, "as Ruby 3.3.11"
    assert_includes result.stderr, "Prepare the host shell before launching Codex."
    assert_path_was_preserved(path)
  end

  def test_major_and_minor_mismatch_fails_with_actionable_diagnostic
    result, path = run_hook("ruby-3.3.12", actual_version: "2.6.10")

    assert_failure(result)
    assert_empty result.stdout
    assert_includes result.stderr, ".ruby-version requires Ruby 3.3.12"
    assert_includes result.stderr, "as Ruby 2.6.10"
    assert_includes result.stderr, "Prepare the host shell before launching Codex."
    assert_path_was_preserved(path)
  end

  def test_missing_ruby_fails_with_required_version_and_preparation_guidance
    result, path = run_hook("ruby-3.3.12", ruby_present: false)

    assert_failure(result)
    assert_empty result.stdout
    assert_includes result.stderr, ".ruby-version requires Ruby 3.3.12"
    assert_includes result.stderr, "no ruby executable is available through the selected host PATH"
    assert_includes result.stderr, "Prepare the host shell before launching Codex."
  end

  def test_failed_version_probe_fails_safely
    result, path = run_hook("ruby-3.3.12", probe_status: 17)

    assert_failure(result)
    assert_empty result.stdout
    assert_includes result.stderr, "could not determine the Ruby version"
    assert_includes result.stderr, "required Ruby 3.3.12"
    assert_path_was_preserved(path)
  end

  def test_missing_ruby_version_file_fails_before_ruby_probe
    path = path_for(ruby_present: true)
    result = run_hook_without_version_file(path)

    assert_failure(result)
    assert_empty result.stdout
    assert_includes result.stderr, ".ruby-version"
    assert_includes result.stderr, "missing or unreadable"
  end

  def test_malformed_ruby_version_files_fail
    ["3.3.12", "ruby-3.3", "ruby-3.3.12 extra"].each do |declaration|
      result, path = run_hook(declaration, ruby_present: false)

      assert_failure(result, declaration)
      assert_empty result.stdout
      assert_includes result.stderr, ".ruby-version", declaration
      assert_includes result.stderr, "ruby-X.Y.Z", declaration
    end
  end

  private

  def run_hook(declaration, actual_version: "3.3.12", probe_status: 0, ruby_present: true)
    File.write(File.join(@repository, ".ruby-version"), declaration)
    path = path_for(ruby_present: ruby_present)
    write_synthetic_ruby(actual_version, probe_status) if ruby_present
    [run_hook_process(path), path]
  end

  def run_hook_without_version_file(path)
    run_hook_process(path)
  end

  def run_hook_process(path)
    stdout, stderr, status = Open3.capture3(
      {
        "PATH" => path,
        "EXPECTED_PATH" => path,
        "PATH_OBSERVED" => @observed_path
      },
      BASH,
      HOOK,
      chdir: @repository,
      stdin_data: "",
      unsetenv_others: true
    )
    Result.new(stdout, stderr, status)
  end

  def path_for(ruby_present: true)
    entries = ruby_present ? [@ruby_bin] : []
    entries << "/synthetic/host-path"
    entries.join(File::PATH_SEPARATOR)
  end

  def write_synthetic_ruby(version, probe_status)
    File.write(File.join(@ruby_bin, "ruby"), <<~SH)
      #!/bin/sh
      printf '%s' "${PATH-}" > "$PATH_OBSERVED"
      if [ "${PATH-}" != "${EXPECTED_PATH-}" ]; then
        exit 18
      fi
      if [ "${1-}" != "-e" ] || [ "${2-}" != "print RUBY_VERSION" ]; then
        exit 19
      fi
      printf '%s' '#{version}'
      exit #{probe_status}
    SH
    FileUtils.chmod(0o755, File.join(@ruby_bin, "ruby"))
  end

  def assert_success(result, context = nil)
    assert result[2].success?, failure_message(result, context)
  end

  def assert_failure(result, context = nil)
    refute result[2].success?, failure_message(result, context)
  end

  def assert_path_was_preserved(path)
    if File.exist?(@observed_path)
      assert_equal path, File.read(@observed_path)
    else
      assert_empty path
    end
  end

  def failure_message(result, context)
    label = context ? " for #{context.inspect}" : ""
    "unexpected hook result#{label}: status=#{result[2].exitstatus.inspect}, stdout=#{result[0].inspect}, stderr=#{result[1].inspect}"
  end
end
