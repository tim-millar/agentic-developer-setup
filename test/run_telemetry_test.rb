# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require "open3"
require "timeout"
require_relative "../lib/agent_run_telemetry/validator"
require_relative "support/claude_explore_harness"
require_relative "support/launcher_harness"

module RunTelemetryAssertions
  def assert_valid_telemetry(record)
    validator = AgentRunTelemetry::Validator.new(record)
    assert validator.validate, validator.errors.join("\n")
  end

  def assert_unavailable(observation)
    assert_equal "unavailable", observation.fetch("evidence_kind")
    assert_nil observation.fetch("value")
  end

  def wait_for(path)
    Timeout.timeout(8) do
      sleep 0.02 until File.exist?(path)
    end
  end
end

class CodexRunTelemetryTest < Minitest::Test
  include RunTelemetryAssertions

  def setup
    @harness = LauncherHarness.new(telemetry: true)
  end

  def teardown
    @harness&.close
  end

  def test_success_resume_schema_identity_configuration_permissions_and_immutability
    first = @harness.run("--profile", "telemetry-profile", "--model", "gpt-test", "-c", 'model_reasoning_effort="high"')
    assert first.status.success?, first.stderr
    directory = @harness.telemetry_run_directories.fetch(0)
    path = File.join(directory, "run.json")
    original = File.binread(path)
    record = JSON.parse(original)
    assert_valid_telemetry(record)
    assert_equal "completed", record.fetch("state")
    assert_equal "codex-cli", record.dig("runtime", "client", "id")
    assert_equal({"evidence_kind" => "runtime_observed", "value" => "codex-cli 1.2.3"}, record.dig("runtime", "client", "version"))
    assert_equal "agent-development-framework/codex", record.dig("runtime", "harness", "id")
    assert_equal 1, record.dig("runtime", "harness", "version")
    expected_revision = "sha256:#{Digest::SHA256.file(@harness.launcher).hexdigest}"
    assert_equal expected_revision, record.dig("runtime", "harness", "revision")
    assert_equal "gpt-test", record.dig("configuration", "model", "requested", "value")
    assert_equal "high", record.dig("configuration", "reasoning_effort", "requested", "value")
    assert_unavailable record.dig("configuration", "model", "initial_effective")
    assert_unavailable record.dig("configuration", "reasoning_effort", "initial_effective")
    assert_equal "unknown", record.dig("configuration", "configuration_stability")
    assert_equal({"source" => "unavailable", "identifier" => nil, "content_sha256" => nil, "snapshot" => nil}, record.fetch("task"))
    assert_equal({"kind" => "github", "value" => "#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}"}, record.dig("repository", "identity"))
    assert_equal "main", record.dig("repository", "start", "branch")
    assert_equal record.dig("repository", "start", "head_sha"), record.dig("repository", "finish", "head_sha")
    %w[start finish].each do |phase|
      assert_equal false, record.dig("repository", phase, "dirty")
      assert_equal [0, 0, 0], record.dig("repository", phase).values_at("staged_count", "unstaged_count", "untracked_count")
    end
    assert_equal 0o700, File.stat(File.dirname(directory)).mode & 0o777
    assert_equal 0o700, File.stat(directory).mode & 0o777
    assert_equal 0o600, File.stat(path).mode & 0o777
    refute File.exist?(File.join(File.dirname(directory), "runs.json"))
    refute File.exist?(File.join(File.dirname(directory), "runs.jsonl"))
    assert_equal ["run.json"], Dir.children(directory)

    resumed = @harness.run("--resume", "session-123")
    assert resumed.status.success?, resumed.stderr
    records = @harness.telemetry_records
    assert_equal 2, records.length
    resumed_record = records.find { |item| item.dig("runtime", "session", "value") == "session-123" }
    refute_nil resumed_record
    refute_equal record.fetch("run_id"), resumed_record.fetch("run_id")
    assert_equal({"evidence_kind" => "launcher_requested", "value" => "session-123"}, resumed_record.dig("runtime", "session"))
    assert_equal original, File.binread(path), "a terminal base record must not be rewritten by later runs"
  end

  def test_help_runtime_information_and_invalid_arguments_create_no_runs
    assert @harness.run("--help").status.success?
    assert @harness.run("--", "--version").status.success?
    invalid = @harness.run("--issue")
    assert_equal 2, invalid.status.exitstatus
    assert_empty @harness.telemetry_run_directories
  end

  def test_preflight_launch_runtime_and_launcher_failure_states
    @harness.remove_origin
    preflight = @harness.run
    refute preflight.status.success?
    assert_equal "preflight_failed", @harness.telemetry_records.fetch(0).fetch("state")

    replace_harness
    runtime = @harness.run(env: {"FAKE_CODEX_EXIT" => "9"})
    assert_equal 9, runtime.status.exitstatus
    assert_equal "runtime_failed", @harness.telemetry_records.fetch(0).fetch("state")
    assert_equal 9, @harness.telemetry_records.fetch(0).dig("termination", "child_exit_code")

    replace_harness
    launch = @harness.run(env: {"FAKE_CODEX_EXIT" => "127"})
    assert_equal 127, launch.status.exitstatus
    assert_equal "runtime_failed", @harness.telemetry_records.fetch(0).fetch("state")

    replace_harness
    launcher = @harness.run_app(env: {"FAKE_FAIL_READY_CHMOD" => "1"})
    refute launcher.status.success?
    assert_equal "launcher_failed", @harness.telemetry_records.fetch(0).fetch("state")
  end

  def test_signal_interruption_is_terminal_and_preserves_exit_status
    stdin, stdout, stderr, wait_thread = @harness.spawn(env: {"FAKE_CODEX_WAIT" => "1"})
    wait_for(@harness.started_marker)
    Process.kill("TERM", wait_thread.pid)
    status = wait_thread.value
    stdin.close
    stdout.read
    diagnostic = stderr.read
    assert_equal 143, status.exitstatus, diagnostic
    record = @harness.telemetry_records.fetch(0)
    assert_valid_telemetry(record)
    assert_equal "interrupted", record.fetch("state")
    assert_equal "TERM", record.dig("termination", "signal")
    refute_nil record.dig("timing", "child_finished_at")
    assert_equal 143, record.dig("termination", "child_exit_code")
  ensure
    [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
  end

  def test_issue_and_local_task_context_are_snapshotted_exactly
    extra = "Local task line one.\nLocal task line two."
    @harness.write_repository_file("docs/EXTRA_PROMPT.txt", extra)
    @harness.commit_all("Add task prompt")
    result = @harness.run_app("--issue", "7", "--extra-prompt-file", "docs/EXTRA_PROMPT.txt")
    assert result.status.success?, result.stderr
    record = @harness.telemetry_records.fetch(0)
    task = record.fetch("task")
    snapshot = File.binread(File.join(@harness.telemetry_run_directories.fetch(0), task.fetch("snapshot"))).force_encoding(Encoding::UTF_8)
    assert_equal "composite", task.fetch("source")
    assert_equal "#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}#7", task.fetch("identifier")
    assert_includes snapshot, JSON.parse(File.binread(@harness.issue_json)).fetch("body")
    assert_includes snapshot, extra
    refute_includes snapshot, @harness.default_prompt
    assert_equal "sha256:#{Digest::SHA256.hexdigest(snapshot)}", task.fetch("content_sha256")
    assert_equal 0o600, File.stat(File.join(@harness.telemetry_run_directories.fetch(0), "task.txt")).mode & 0o777
    @harness.write_repository_file("docs/EXTRA_PROMPT.txt", "mutated after launch")
    assert_equal snapshot, File.binread(File.join(@harness.telemetry_run_directories.fetch(0), "task.txt")).force_encoding(Encoding::UTF_8)
    serialized = @harness.telemetry_run_directories.flat_map { |run| Dir[File.join(run, "*")].map { |path| File.binread(path) } }.join
    [LauncherHarness::INSTALLATION_TOKEN, LauncherHarness::RENEWED_INSTALLATION_TOKEN, LauncherHarness::PRIVATE_KEY_CONTENT].each do |secret|
      refute_includes serialized, secret
    end
  end

  def test_git_evidence_is_nul_safe_and_captures_counts_detached_head_and_head_changes
    @harness.write_repository_file("tracked-staged.txt", "base\n")
    @harness.write_repository_file("tracked-unstaged.txt", "base\n")
    @harness.commit_all("Add Git state fixtures")
    @harness.write_repository_file("tracked-staged.txt", "staged\n")
    @harness.repository_git("add", "tracked-staged.txt")
    @harness.write_repository_file("tracked-unstaged.txt", "unstaged\n")
    @harness.write_repository_file("unusual\nname.txt", "untracked\n")
    result = @harness.run("--allow-dirty")
    assert result.status.success?, result.stderr
    state = @harness.telemetry_records.fetch(0).dig("repository", "start")
    assert_equal true, state.fetch("dirty")
    assert_equal 1, state.fetch("staged_count")
    assert_equal 1, state.fetch("unstaged_count")
    assert_equal 1, state.fetch("untracked_count")

    replace_harness
    @harness.repository_git("checkout", "--detach", "HEAD")
    result = @harness.run(env: {"FAKE_CODEX_GIT_ACTION" => "commit"})
    assert result.status.success?, result.stderr
    record = @harness.telemetry_records.fetch(0)
    assert_equal true, record.dig("repository", "start", "detached")
    assert_nil record.dig("repository", "start", "branch")
    refute_equal record.dig("repository", "start", "head_sha"), record.dig("repository", "finish", "head_sha")
  end

  def test_version_and_git_observation_failures_are_fail_open
    @harness.fail_codex_version
    result = @harness.run(env: {"FAKE_GIT_STATUS_FAILURE" => "1"})
    assert result.status.success?, result.stderr
    assert_includes result.stderr, "AGENT_TELEMETRY_WARNING:"
    record = @harness.telemetry_records.fetch(0)
    assert_unavailable record.dig("runtime", "client", "version")
    assert_nil record.dig("repository", "start")
    assert_nil record.dig("repository", "finish")
  end

  def test_version_observation_uses_a_minimal_environment
    sensitive_names = %w[
      GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH
      GH_TOKEN GITHUB_TOKEN GITHUB_PAT INSTALL_TOKEN AGENT_GITHUB_TOKEN_HELPER
      GIT_ASKPASS SSH_AUTH_SOCK AGENT_TELEMETRY AGENT_TELEMETRY_DIR JWT TOKEN_JSON
    ]
    environment = sensitive_names.to_h { |name| [name, "synthetic-#{name.downcase}"] }
    environment["AGENT_TELEMETRY"] = "1"
    environment["AGENT_TELEMETRY_DIR"] = File.join(@harness.root, "sanitized-probe-telemetry")

    result = @harness.run(env: environment)

    assert result.status.success?, result.stderr
    observed = JSON.parse(File.binread(@harness.codex_version_env_log))
    sensitive_names.each { |name| refute observed.key?(name), "expected #{name} to be absent from Codex --version" }
    assert_equal @harness.home, observed.fetch("HOME")
    assert observed.key?("PATH")
  end

  def test_forwarded_configuration_trims_simple_toml_scalar_whitespace
    invocations = [
      ["-c", 'model="o3"'],
      ["-c", 'model = "o3"'],
      ["-c", "model = 'o3'"],
      ["-c", 'model_reasoning_effort = "high"']
    ]
    invocations.each do |arguments|
      result = @harness.run(*arguments)
      assert result.status.success?, result.stderr
    end

    records = @harness.telemetry_records
    assert_equal %w[o3 o3 o3], records.filter_map { |record| record.dig("configuration", "model", "requested", "value") }.sort
    assert_equal ["high"], records.filter_map { |record| record.dig("configuration", "reasoning_effort", "requested", "value") }
  end

  def test_storage_failure_relative_override_and_opt_out_are_fail_open
    storage_file = File.join(@harness.root, "not-a-directory")
    File.write(storage_file, "collision")
    failed = @harness.run(env: {"AGENT_TELEMETRY_DIR" => File.join(storage_file, "runs")})
    assert failed.status.success?, failed.stderr
    assert_includes failed.stderr, "AGENT_TELEMETRY_WARNING:"

    relative = @harness.run(env: {"AGENT_TELEMETRY_DIR" => "relative/runs"})
    assert relative.status.success?, relative.stderr
    assert_includes relative.stderr, "AGENT_TELEMETRY_WARNING: AGENT_TELEMETRY_DIR must be absolute"
    refute Dir.exist?(File.join(@harness.repository, "relative"))

    relative_xdg = @harness.run(env: {"AGENT_TELEMETRY_DIR" => nil, "XDG_DATA_HOME" => "relative-data"})
    assert relative_xdg.status.success?, relative_xdg.stderr
    assert_includes relative_xdg.stderr, "AGENT_TELEMETRY_WARNING: XDG_DATA_HOME must be absolute"

    xdg_data = File.join(@harness.root, "explicit-data")
    defaulted = @harness.run(env: {"AGENT_TELEMETRY_DIR" => nil, "XDG_DATA_HOME" => xdg_data})
    assert defaulted.status.success?, defaulted.stderr
    assert_equal 1, Dir[File.join(xdg_data, "agent-development-framework", "telemetry", "runs", "run-*")].length

    empty_xdg = @harness.run(env: {"AGENT_TELEMETRY_DIR" => "", "XDG_DATA_HOME" => ""})
    assert empty_xdg.status.success?, empty_xdg.stderr
    refute_includes empty_xdg.stderr, "AGENT_TELEMETRY_WARNING:"
    fallback_root = File.join(@harness.home, ".local", "share", "agent-development-framework", "telemetry", "runs")
    assert_equal 1, Dir[File.join(fallback_root, "run-*")].length

    disabled = @harness.run(env: {"AGENT_TELEMETRY" => "0"})
    assert disabled.status.success?, disabled.stderr
    refute_includes disabled.stderr, "AGENT_TELEMETRY_WARNING:"
    assert_empty @harness.telemetry_run_directories
  end

  def test_in_repository_storage_is_rejected_without_changing_workload_or_git_state
    telemetry_root = File.join(@harness.repository, ".agent-telemetry", "runs")
    success = @harness.run(env: {"AGENT_TELEMETRY_DIR" => telemetry_root})
    failure = @harness.run(env: {"AGENT_TELEMETRY_DIR" => telemetry_root, "FAKE_CODEX_EXIT" => "9"})

    assert success.status.success?, success.stderr
    assert_equal 9, failure.status.exitstatus
    assert_includes success.stderr, "AGENT_TELEMETRY_WARNING: telemetry run root must be outside the repository"
    assert_includes failure.stderr, "AGENT_TELEMETRY_WARNING: telemetry run root must be outside the repository"
    refute File.exist?(File.join(@harness.repository, ".agent-telemetry"))
    assert_empty @harness.repository_git("status", "--porcelain")
  end

  def test_finalisation_failure_does_not_replace_success_or_the_started_record
    stdin, stdout, stderr, wait_thread = @harness.spawn(env: {"FAKE_CODEX_WAIT" => "1"})
    wait_for(@harness.started_marker)
    directory = @harness.telemetry_run_directories.fetch(0)
    File.chmod(0o500, directory)
    @harness.release_codex
    status = wait_thread.value
    stdin.close
    stdout.read
    diagnostic = stderr.read
    assert status.success?, diagnostic
    assert_includes diagnostic, "AGENT_TELEMETRY_WARNING:"
    assert_equal "started", JSON.parse(File.binread(File.join(directory, "run.json"))).fetch("state")
  ensure
    File.chmod(0o700, directory) if directory && File.exist?(directory)
    [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
  end

  def test_concurrent_runs_use_independent_directories_and_do_not_serialize_secrets
    secret_values = %w[synthetic-gh-secret synthetic-github-secret synthetic-auth-header synthetic-unrelated-secret]
    environments = 4.times.map do |index|
      {
        "GH_TOKEN" => secret_values[0],
        "GITHUB_TOKEN" => secret_values[1],
        "AUTHORIZATION_HEADER" => secret_values[2],
        "UNRELATED_SECRET" => secret_values[3],
        "FAKE_CODEX_EXIT" => index.zero? ? "3" : "0"
      }
    end
    results = environments.map { |environment| Thread.new { @harness.run(env: environment) } }.map(&:value)
    assert_equal [3, 0, 0, 0].sort, results.map { |result| result.status.exitstatus }.sort
    directories = @harness.telemetry_run_directories
    assert_equal 4, directories.length
    assert_equal 4, @harness.telemetry_records.map { |record| record.fetch("run_id") }.uniq.length
    serialized = directories.flat_map { |directory| Dir[File.join(directory, "*")].map { |path| File.binread(path) } }.join
    secret_values.each { |secret| refute_includes serialized, secret }
    directories.each { |directory| refute Dir.exist?(File.join(directory, ".lock")) }
  end

  private

  def replace_harness
    @harness.close
    @harness = LauncherHarness.new(telemetry: true)
  end
end

class ClaudeExploreRunTelemetryTest < Minitest::Test
  include RunTelemetryAssertions

  def setup
    @harness = ClaudeExploreHarness.new(telemetry: true)
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
  end

  def teardown
    @harness&.cleanup
  end

  def test_fresh_and_resume_runs_emit_common_schema_without_task_or_effective_guesses
    _stdout, stderr, status = @harness.runtime("--model=sonnet", "--effort", "high")
    assert status.success?, stderr
    _stdout, stderr, status = @harness.runtime("--resume", "session-456")
    assert status.success?, stderr
    records = @harness.telemetry_records
    assert_equal 2, records.length
    records.each { |record| assert_valid_telemetry(record) }
    fresh = records.find { |record| record.dig("configuration", "model", "requested", "value") == "sonnet" }
    resumed = records.find { |record| record.dig("runtime", "session", "value") == "session-456" }
    refute_nil fresh
    refute_nil resumed
    refute_equal fresh.fetch("run_id"), resumed.fetch("run_id")
    assert_equal "claude-code", fresh.dig("runtime", "client", "id")
    assert_equal "2.1.224", fresh.dig("runtime", "client", "version", "value")
    assert_equal "agent-development-framework/claude-explore", fresh.dig("runtime", "harness", "id")
    assert_equal "sonnet", fresh.dig("configuration", "model", "requested", "value")
    assert_equal "high", fresh.dig("configuration", "reasoning_effort", "requested", "value")
    assert_unavailable fresh.dig("configuration", "model", "initial_effective")
    assert_unavailable fresh.dig("configuration", "reasoning_effort", "initial_effective")
    assert_equal "unknown", fresh.dig("configuration", "configuration_stability")
    assert_equal({"source" => "unavailable", "identifier" => nil, "content_sha256" => nil, "snapshot" => nil}, fresh.fetch("task"))
    assert_equal "session-456", resumed.dig("runtime", "session", "value")
    settings = JSON.parse(@harness.read(@harness.env.fetch("FAKE_SETTINGS_COPY")))
    assert_equal true, settings.fetch("disableAllHooks")
    telemetry_directories = @harness.telemetry_run_directories.map { |path| File.realpath(path) }
    assert (telemetry_directories & settings.dig("sandbox", "filesystem", "denyWrite")).any?
    child_env = @harness.read(@harness.env.fetch("FAKE_ENV_LOG"))
    refute_includes child_env, "AGENT_TELEMETRY_DIR="
    version_env = @harness.read(@harness.claude_version_env_log)
    refute_includes version_env, "AGENT_TELEMETRY="
    refute_includes version_env, "AGENT_TELEMETRY_DIR="
  end

  def test_help_information_classification_and_invalid_invocations_create_no_runs
    assert @harness.runtime("--help").fetch(2).success?
    assert @harness.runtime("--version").fetch(2).success?
    assert @harness.runtime("--claude-explore-runtime-info").fetch(2).success?
    assert @harness.runtime("--claude-explore-check-command", "--", "git", "status").fetch(2).success?
    refute @harness.runtime("--unknown-option").fetch(2).success?
    assert_empty @harness.telemetry_run_directories
  end

  def test_preflight_launch_and_runtime_failures_are_distinct
    File.open(@harness.metadata, "a") { |file| file.puts("unexpected=value") }
    _stdout, _stderr, status = @harness.runtime
    refute status.success?
    assert_equal "preflight_failed", @harness.telemetry_records.fetch(0).fetch("state")

    replace_harness
    _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_CLAUDE_EXIT" => "12"})
    assert_equal 12, status.exitstatus
    assert_equal "runtime_failed", @harness.telemetry_records.fetch(0).fetch("state")

    replace_harness
    _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_CLAUDE_EXIT" => "127"})
    assert_equal 127, status.exitstatus
    assert_equal "runtime_failed", @harness.telemetry_records.fetch(0).fetch("state")
  end

  def test_positional_initial_prompt_is_snapshotted_as_local_task_evidence
    task_text = "fix the failing authentication test"
    _stdout, stderr, status = @harness.runtime(task_text)
    assert status.success?, stderr
    record = @harness.telemetry_records.fetch(0)
    task = record.fetch("task")
    snapshot = File.binread(File.join(@harness.telemetry_run_directories.fetch(0), task.fetch("snapshot")))

    assert_equal "local_prompt", task.fetch("source")
    assert_nil task.fetch("identifier")
    assert_equal task_text, snapshot
    assert_equal "sha256:#{Digest::SHA256.hexdigest(snapshot)}", task.fetch("content_sha256")
    refute_includes snapshot, "Claude Explore"
  end

  def test_abnormal_inspection_exit_cleans_private_session_without_creating_telemetry
    @harness.replace_installed_runtime_text(
      "lib/claude_explore_runtime.sh",
      "  make_session || { cleanup_session; runtime_error \"could not create private session state\"; return 1; }\n",
      "  make_session || { cleanup_session; runtime_error \"could not create private session state\"; return 1; }\n  [ \"$inspection\" -eq 0 ] || return 77\n"
    )
    _stdout, stderr, status = @harness.runtime("--help")

    assert_equal 77, status.exitstatus, stderr
    assert_empty @harness.telemetry_run_directories
    assert_empty Dir[File.join(@harness.sessions_root, "claude-explore.*")]
  end

  def test_unavailable_client_version_is_preserved_in_preflight_evidence
    _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_VERSION_EXIT" => "1"})
    refute status.success?
    record = @harness.telemetry_records.fetch(0)
    assert_equal "preflight_failed", record.fetch("state")
    assert_unavailable record.dig("runtime", "client", "version")
  end

  def test_signal_is_recorded_as_interrupted
    @harness.replace_claude_with_signal_runtime
    started = File.join(@harness.root, "telemetry-signal-started")
    process_env = @harness.env.merge("FAKE_STARTED" => started)
    stdin, stdout, stderr, wait_thread = Open3.popen3(process_env, @harness.installed_launcher, chdir: ClaudeExploreHarness::REPOSITORY_ROOT)
    wait_for(started)
    Process.kill("TERM", wait_thread.pid)
    status = wait_thread.value
    stdin.close
    stdout.read
    diagnostic = stderr.read
    assert_equal 143, status.exitstatus, diagnostic
    record = @harness.telemetry_records.fetch(0)
    assert_equal "interrupted", record.fetch("state")
    assert_equal "TERM", record.dig("termination", "signal")
  ensure
    [stdin, stdout, stderr].compact.each { |io| io.close unless io.closed? }
  end

  def test_git_evidence_uses_path_digest_and_observes_child_change
    repository = File.join(@harness.root, "local-repository")
    FileUtils.mkdir_p(repository)
    git(repository, "init", "-q", "-b", "main")
    git(repository, "config", "user.name", "Telemetry Fixture")
    git(repository, "config", "user.email", "telemetry@example.test")
    File.write(File.join(repository, "README.md"), "fixture\n")
    git(repository, "add", "README.md")
    git(repository, "commit", "-q", "-m", "Initial")
    _stdout, stderr, status = @harness.runtime(chdir: repository, extra_env: {"FAKE_CLAUDE_GIT_ACTION" => "untracked"})
    assert status.success?, stderr
    record = @harness.telemetry_records.fetch(0)
    assert_equal "path_digest", record.dig("repository", "identity", "kind")
    refute_includes record.dig("repository", "identity", "value"), repository
    assert_equal record.dig("repository", "start", "head_sha"), record.dig("repository", "finish", "head_sha")
    assert_equal false, record.dig("repository", "start", "dirty")
    assert_equal true, record.dig("repository", "finish", "dirty")
    assert_equal 1, record.dig("repository", "finish", "untracked_count")
  end

  def test_relative_storage_and_opt_out_preserve_runtime_behaviour
    _stdout, stderr, status = @harness.runtime(extra_env: {"AGENT_TELEMETRY_DIR" => "relative"})
    assert status.success?, stderr
    assert_includes stderr, "AGENT_TELEMETRY_WARNING: AGENT_TELEMETRY_DIR must be absolute"
    assert_empty @harness.telemetry_run_directories

    _stdout, stderr, status = @harness.runtime(extra_env: {"AGENT_TELEMETRY" => "0"})
    assert status.success?, stderr
    refute_includes stderr, "AGENT_TELEMETRY_WARNING:"
    assert_empty @harness.telemetry_run_directories
  end

  private

  def replace_harness
    @harness.cleanup
    @harness = ClaudeExploreHarness.new(telemetry: true)
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
  end

  def git(repository, *arguments)
    _stdout, stderr, status = Open3.capture3("git", *arguments, chdir: repository)
    assert status.success?, stderr
  end
end

class RunTelemetrySchemaTest < Minitest::Test
  def test_schema_is_json_and_runtime_helpers_remain_semantically_identical
    schema = JSON.parse(File.binread(File.expand_path("../schemas/agent-run-telemetry-v1.schema.json", __dir__)))
    assert_equal 1, schema.dig("properties", "schema_version", "const")
    assert_equal false, schema.fetch("additionalProperties")
    baseline = File.binread(File.expand_path("../baseline/scripts/agent_run_telemetry.sh", __dir__))
    claude = File.binread(File.expand_path("../agent-runtimes/claude-explore/lib/agent_run_telemetry.sh", __dir__))
    assert_equal baseline.rstrip, claude.rstrip
    runtime_observation = schema.dig("$defs", "runtime_observation")
    configuration_observation = schema.dig("$defs", "configuration_observation")
    assert_equal %w[evidence_kind value], runtime_observation.fetch("required")
    assert_equal %w[evidence_kind value], runtime_observation.fetch("properties").keys
    assert_equal false, runtime_observation.fetch("additionalProperties")
    assert_equal %w[evidence_kind value source], configuration_observation.fetch("required")
    assert_equal %w[evidence_kind value source], configuration_observation.fetch("properties").keys
    assert_equal false, configuration_observation.fetch("additionalProperties")
    assert_equal "#/$defs/runtime_observation", schema.dig("$defs", "runtime", "properties", "client", "properties", "version", "$ref")
    assert_equal "#/$defs/runtime_observation", schema.dig("$defs", "runtime", "properties", "session", "$ref")
    assert_equal "#/$defs/configuration_observation", schema.dig("$defs", "configuration_pair", "properties", "requested", "$ref")
  end

  def test_validator_rejects_malformed_or_later_semantics_and_ignores_extensions
    record = {
      "schema_version" => 2,
      "unexpected" => true,
      "extensions" => {"future/runtime" => {"anything" => true}}
    }
    validator = AgentRunTelemetry::Validator.new(record)
    refute validator.validate
    assert validator.errors.any? { |error| error.include?("schema_version") }
    assert validator.errors.any? { |error| error.include?("unexpected") }
    refute validator.errors.any? { |error| error.include?("future/runtime") }
  end

  def test_validator_matches_runtime_and_configuration_observation_shapes
    record = valid_started_record
    record.dig("runtime", "client", "version")["source"] = nil
    refute_valid(record, "runtime.client.version.source")

    record = valid_started_record
    record.dig("runtime", "session")["source"] = nil
    refute_valid(record, "runtime.session.source")

    record = valid_started_record
    record.dig("configuration", "model", "requested").delete("source")
    refute_valid(record, "configuration.model.requested.source")

    validator = AgentRunTelemetry::Validator.new(valid_started_record)
    assert validator.validate, validator.errors.join("\n")
  end

  def test_launch_intent_without_child_start_is_launch_failed
    result, record = run_helper_scenario(<<~BASH)
      agent_telemetry_mark_preflight_complete
      agent_telemetry_mark_launch_intent
      agent_telemetry_finalize_pending 23 "" ""
      exit 23
    BASH

    assert_equal 23, result.exitstatus
    assert_equal "launch_failed", record.fetch("state")
    assert_nil record.dig("timing", "child_started_at")
    assert_nil record.dig("timing", "child_finished_at")
    validator = AgentRunTelemetry::Validator.new(record)
    assert validator.validate, validator.errors.join("\n")
  end

  def test_git_scratch_is_allocated_outside_repository_and_run_directory
    Dir.mktmpdir("telemetry-scratch-scenario-") do |root|
      repository = File.join(root, "repository")
      run_directory = File.join(root, "telemetry", "run-example")
      script = File.join(root, "scratch.sh")
      FileUtils.mkdir_p([repository, run_directory])
      helper = File.expand_path("../baseline/scripts/agent_run_telemetry.sh", __dir__)
      File.write(script, <<~BASH)
        #!/usr/bin/env bash
        source #{helper.dump}
        AGENT_TELEMETRY_RUN_DIR=#{run_directory.dump}
        scratch=$(agent_telemetry_git_scratch #{repository.dump}) || exit 1
        printf '%s' "$scratch"
        /bin/rm -f -- "$scratch"
      BASH
      File.chmod(0o700, script)
      scratch, stderr, status = Open3.capture3("/bin/bash", script)

      assert status.success?, stderr
      refute scratch.start_with?("#{File.realpath(repository)}/")
      refute scratch.start_with?("#{File.realpath(run_directory)}/")
    end
  end

  def test_backwards_calendar_clock_is_clamped_without_replacing_workload_status
    result, record, stderr = run_helper_scenario(<<~BASH, include_stderr: true)
      agent_telemetry_epoch() {
        printf '100'
      }
      AGENT_TELEMETRY_STARTED_EPOCH=200
      agent_telemetry_mark_preflight_complete
      agent_telemetry_mark_launch_intent
      agent_telemetry_mark_child_started
      agent_telemetry_mark_child_finished 7
      agent_telemetry_finalize_pending 7 "" ""
      exit 7
    BASH

    assert_equal 7, result.exitstatus
    assert_equal 0, record.dig("timing", "calendar_elapsed_ms")
    assert_includes stderr, "AGENT_TELEMETRY_WARNING: calendar clock moved backwards"
    validator = AgentRunTelemetry::Validator.new(record)
    assert validator.validate, validator.errors.join("\n")
  end

  private

  def valid_started_record
    {
      "schema_version" => 1,
      "run_id" => "run-20260913T120000Z-0123456789abcdef0123456789abcdef",
      "state" => "started",
      "runtime" => {
        "client" => {"id" => "codex-cli", "version" => {"evidence_kind" => "unavailable", "value" => nil}},
        "harness" => {"id" => "agent-development-framework/codex", "version" => 1, "revision" => "sha256:#{"0" * 64}"},
        "session" => {"evidence_kind" => "unavailable", "value" => nil}
      },
      "configuration" => {
        "model" => {
          "requested" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil},
          "initial_effective" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil}
        },
        "reasoning_effort" => {
          "requested" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil},
          "initial_effective" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil}
        },
        "configuration_stability" => "unknown"
      },
      "repository" => {"identity" => {"kind" => "path_digest", "value" => "sha256:#{"1" * 64}"}, "start" => nil, "finish" => nil},
      "task" => {"source" => "unavailable", "identifier" => nil, "content_sha256" => nil, "snapshot" => nil},
      "timing" => {"run_started_at" => "2026-09-13T12:00:00.000Z", "child_started_at" => nil, "child_finished_at" => nil, "run_finished_at" => nil, "calendar_elapsed_ms" => nil},
      "termination" => {"child_exit_code" => nil, "signal" => nil, "reason" => nil},
      "extensions" => {}
    }
  end

  def refute_valid(record, expected_error)
    validator = AgentRunTelemetry::Validator.new(record)
    refute validator.validate
    assert validator.errors.any? { |error| error.include?(expected_error) }, validator.errors.join("\n")
  end

  def run_helper_scenario(body, include_stderr: false)
    Dir.mktmpdir("telemetry-helper-scenario-") do |root|
      repository = File.join(root, "repository")
      telemetry = File.join(root, "telemetry")
      script = File.join(root, "scenario.sh")
      FileUtils.mkdir_p(repository)
      helper = File.expand_path("../baseline/scripts/agent_run_telemetry.sh", __dir__)
      File.write(script, <<~BASH)
        #!/usr/bin/env bash
        source #{helper.dump}
        AGENT_TELEMETRY=1
        AGENT_TELEMETRY_DIR=#{telemetry.dump}
        agent_telemetry_start codex-cli agent-development-framework/codex 1 #{helper.dump} #{repository.dump}
        #{body}
      BASH
      File.chmod(0o700, script)
      _stdout, stderr, status = Open3.capture3("/bin/bash", script)
      directory = Dir[File.join(telemetry, "run-*")].fetch(0)
      record = JSON.parse(File.binread(File.join(directory, "run.json")))
      return [status, record, stderr] if include_stderr

      [status, record]
    end
  end
end
