# frozen_string_literal: true

require "json"
require "minitest/autorun"
require "open3"
require_relative "support/claude_explore_harness"

class ClaudeExploreRuntimeTest < Minitest::Test
  POLICY = File.join(ClaudeExploreHarness::REPOSITORY_ROOT, "agent-runtimes/claude-explore/policy.sh")

  def setup
    @harness = ClaudeExploreHarness.new
  end

  def teardown
    @harness.cleanup
  end

  def test_install_runtime_info_idempotence_and_uninstall
    stdout, stderr, status = @harness.install
    assert status.success?, stderr
    assert_includes stdout, "claude-explore 1 install"
    assert File.symlink?(@harness.installed_launcher)
    assert_equal 0o600, File.stat(@harness.metadata).mode & 0o777
    assert_equal 0o700, File.stat(@harness.current_runtime).mode & 0o777

    _stdout, stderr, status = @harness.install
    assert status.success?, stderr

    stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info")
    assert status.success?, stderr
    assert_includes stdout, "runtime_id=claude-explore"
    assert_includes stdout, "claude_version=2.1.224"
    assert_includes stdout, "sandbox_required=true"
    assert_includes stdout, "unsandboxed_retry_allowed=false"

    real_claude = @harness.claude_target
    _stdout, stderr, status = @harness.install("uninstall")
    assert status.success?, stderr
    refute File.exist?(@harness.installed_launcher)
    assert File.exist?(real_claude)
  end

  def test_stable_claude_launcher_is_reresolved_after_updater_change
    install!
    replacement = @harness.replace_claude(version: "2.1.225")

    stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info")
    assert status.success?, stderr
    assert_includes stdout, "recorded_claude_launcher_path=#{@harness.claude_launcher}"
    assert_includes stdout, "resolved_current_claude_path=#{File.realpath(replacement)}"
    assert_includes stdout, "claude_version=2.1.225"
  end

  def test_path_discovery_and_upgrade_reuse_the_recorded_launcher
    stdout, stderr, status = @harness.install(claude: nil)
    assert status.success?, stderr
    assert_includes stdout, "claude_launcher=#{@harness.claude_launcher}"
    metadata_before = @harness.read(@harness.metadata)

    _stdout, stderr, status = @harness.install("upgrade", claude: nil)
    assert status.success?, stderr
    assert_equal metadata_before, @harness.read(@harness.metadata)
  end

  def test_missing_old_unparseable_recursive_and_broken_launchers_fail_closed
    _stdout, stderr, status = @harness.install(extra_env: {"FAKE_CLAUDE_VERSION" => "2.1.223"})
    refute status.success?
    assert_includes stderr, "below required"

    _stdout, stderr, status = @harness.install(extra_env: {"FAKE_CLAUDE_VERSION" => "not-a-version"})
    refute status.success?
    assert_includes stderr, "could not parse"

    loop_a = File.join(@harness.root, "loop-a")
    loop_b = File.join(@harness.root, "loop-b")
    File.symlink(loop_b, loop_a); File.symlink(loop_a, loop_b)
    _stdout, stderr, status = @harness.install(claude: loop_a)
    refute status.success?
    assert_match(/does not exist|cannot be resolved/, stderr)

    FileUtils.rm(@harness.claude_launcher)
    _stdout, stderr, status = @harness.install
    refute status.success?
    assert_includes stderr, "does not exist"
  end

  def test_group_writable_claude_target_is_rejected
    File.chmod(0o722, @harness.claude_target)
    _stdout, stderr, status = @harness.install
    refute status.success?
    assert_includes stderr, "group/world writable"
  end

  def test_language_runtime_shims_and_hostile_bash_env_cannot_control_runtime
    marker = File.join(@harness.root, "bash-env-ran")
    hostile = File.join(@harness.root, "hostile.sh")
    File.write(hostile, ": > '#{marker}'\n")
    %w[ruby python python3 node npm].each do |name|
      @harness.write_executable(File.join(@harness.fake_bin, name), "#!/bin/sh\nexit 99\n")
    end
    _stdout, stderr, status = @harness.install(extra_env: {"BASH_ENV" => hostile})
    assert status.success?, stderr
    refute File.exist?(marker)

    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info", extra_env: {"BASH_ENV" => hostile})
    assert status.success?, stderr
    refute File.exist?(marker)

    _stdout, _stderr, status = @harness.runtime(extra_env: {"BASH_ENV" => hostile, "FAKE_INNER_SCENARIO" => "git-allowed"})
    assert status.success?
    refute File.exist?(marker), "generated guard must not load BASH_ENV"
  end

  def test_environment_native_settings_mcp_browser_and_guidance_are_forced
    install!
    extra = {
      "GITHUB_TOKEN" => "secret-github",
      "AWS_ACCESS_KEY_ID" => "secret-aws",
      "PGHOST" => "remote.example",
      "SAFE_PROJECT_VALUE" => "preserved"
    }
    _stdout, stderr, status = @harness.runtime("--model", "sonnet", "inspect locally", extra_env: extra)
    assert status.success?, stderr
    child_env = @harness.read(@harness.env.fetch("FAKE_ENV_LOG"))
    refute_includes child_env, "secret-github"
    refute_includes child_env, "secret-aws"
    refute_includes child_env, "PGHOST="
    assert_includes child_env, "SAFE_PROJECT_VALUE=preserved"
    assert_includes child_env, "CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1"
    assert_includes child_env, "CLAUDE_CODE_DISABLE_ARTIFACT=1"
    assert_includes child_env, "GIT_TERMINAL_PROMPT=0"
    assert_match(/^PATH=.*\/guard:#{Regexp.escape(@harness.fake_bin)}:/, child_env.lines.find { |line| line.start_with?("PATH=") })

    settings = JSON.parse(@harness.read(@harness.env.fetch("FAKE_SETTINGS_COPY")))
    assert_equal true, settings.dig("sandbox", "enabled")
    assert_equal true, settings.dig("sandbox", "failIfUnavailable")
    assert_equal false, settings.dig("sandbox", "allowUnsandboxedCommands")
    assert_equal false, settings.dig("sandbox", "filesystem", "disabled")
    refute settings.dig("sandbox").key?("excludedCommands")
    assert_equal true, settings["disableAllHooks"]
    assert_equal true, settings["disableArtifact"]
    assert_includes settings.dig("permissions", "deny"), "mcp__*"
    assert_includes settings.dig("permissions", "deny"), "Artifact"
    assert settings.dig("sandbox", "credentials", "files").any? { |entry| entry == {"path" => "~/.ssh", "mode" => "deny"} }
    assert_includes settings.dig("permissions", "deny"), "Read(~/.git-credentials)"
    deny_write = settings.dig("sandbox", "filesystem", "denyWrite")
    assert_includes deny_write, File.realpath(@harness.data_root)
    assert_includes deny_write, File.dirname(@harness.metadata)
    assert_includes deny_write, @harness.installed_launcher
    assert deny_write.any? { |path| path.include?("claude-explore.") }, "session control directory must be write-denied"
    assert_equal({"mcpServers" => {}}, JSON.parse(@harness.read(@harness.env.fetch("FAKE_MCP_COPY"))))
    assert_includes settings.dig("permissions", "deny"), "Edit(//#{@harness.installed_launcher.delete_prefix('/')})"

    argv = @harness.read(@harness.env.fetch("FAKE_CLAUDE_LOG"))
    assert_includes argv, "--strict-mcp-config\n"
    assert_includes argv, "--mcp-config\n"
    assert_includes argv, "--no-chrome\n"
    assert_includes argv, "CLAUDE_EXPLORE_BLOCKED results are intentional"
  end

  def test_allowed_and_blocked_claude_startup_arguments
    install!
    allowed = [
      [], ["--help"], ["--version"], ["-v"], ["--model", "sonnet"], ["--effort=high"],
      ["--fallback-model", "sonnet"], ["--autocompact", "500k"], ["-n", "explore"],
      ["-c"], ["-r", "session"], ["--fork-session"], ["--session-id", "abc"],
      ["--verbose"], ["--debug"], ["--debug=mcp"], ["--ax-screen-reader"], ["--disable-slash-commands"],
      ["--permission-mode", "plan"], ["--permission-mode=dontAsk"], ["initial prompt"]
    ]
    allowed.each do |arguments|
      _stdout, stderr, status = @harness.runtime(*arguments)
      assert status.success?, "expected allowed #{arguments.inspect}: #{stderr}"
    end

    blocked = %w[
      --dangerously-skip-permissions --allow-dangerously-skip-permissions --settings --mcp-config
      --plugin-dir --chrome --cloud --remote --environment --remote-control --add-dir --worktree
      --bg --background --exec --print -p --bare --system-prompt --allowedTools --tools --init
      --maintenance --debug-file --unknown-future-option
    ]
    blocked.each do |flag|
      FileUtils.rm_f(@harness.env.fetch("FAKE_CLAUDE_LOG"))
      _stdout, stderr, status = @harness.runtime(flag, "value")
      assert_equal 126, status.exitstatus, "expected blocked #{flag}: #{stderr}"
      assert_includes stderr, "CLAUDE_EXPLORE_BLOCKED"
      refute File.exist?(@harness.env.fetch("FAKE_CLAUDE_LOG")), "real Claude started for #{flag}"
    end

    %w[update gateway auth agents daemon doctor mcp plugin project remote-control self-hosted-runner setup-token ultrareview].each do |subcommand|
      _stdout, stderr, status = @harness.runtime(subcommand)
      assert_equal 126, status.exitstatus, "expected blocked #{subcommand}: #{stderr}"
    end
    _stdout, stderr, status = @harness.runtime("--permission-mode=bypassPermissions")
    assert_equal 126, status.exitstatus
    assert_includes stderr, "CLAUDE_EXPLORE_BLOCKED"

    secret_prompt = "do-not-print-this-prompt-or-token"
    _stdout, stderr, status = @harness.runtime("--cloud", secret_prompt)
    assert_equal 126, status.exitstatus
    refute_includes stderr, secret_prompt

    _stdout, stderr, status = @harness.runtime("--claude-explore-check-command", "git", "status")
    assert_equal 2, status.exitstatus
    assert_includes stderr, "requires --"
  end

  def test_every_policy_blocked_executable_has_a_non_delegating_guard
    install!
    policy_lines("CLAUDE_EXPLORE_BLOCKED_EXECUTABLES").each do |command|
      FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
      _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "blocked", "FAKE_COMMAND" => command})
      assert_equal 126, status.exitstatus, "#{command}: #{stderr}"
      assert_includes stderr, "CLAUDE_EXPLORE_BLOCKED"
      refute File.exist?(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    end
  end

  def test_git_policy_classification_and_delegation
    install!
    allowed = [["git", "status"], ["git", "-C", "/tmp", "log"], ["git", "branch", "topic"], ["git", "remote", "-v"], ["git", "remote", "get-url", "origin"], ["git", "config", "--get", "user.name"], ["git", "tag", "--list"], ["git", "tag", "--contains", "HEAD"]]
    blocked = [["git", "push"], ["git", "fetch"], ["git", "-c", "credential.helper=x", "status"], ["git", "branch", "-u", "origin/main"], ["git", "remote", "add", "x", "url"], ["git", "config", "user.name", "x"], ["git", "config", "--get", "--unset", "user.name"], ["git", "tag", "v1"], ["git", "tag", "--contains", "-d", "v1"], ["git", "submodule", "status"], ["git", "future-command"]]
    allowed.each { |argv| assert_classification(argv, 0, "allowed") }
    blocked.each { |argv| assert_classification(argv, 126, "CLAUDE_EXPLORE_BLOCKED") }

    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "git-allowed"})
    assert status.success?, stderr
    assert_includes @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG")), "git <status>"
    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "git-push"})
    assert_equal 126, status.exitstatus
    refute File.exist?(@harness.env.fetch("FAKE_DELEGATE_LOG"))
  end

  def test_postgresql_policy_regressions_and_final_environment_scrub
    install!
    allowed = [
      ["psql"], ["psql", "mydb"], ["psql", "-d", "mydb"], ["psql", "-dmydb"], ["psql", "--dbname=mydb"],
      ["psql", "-h", "localhost"], ["psql", "-h127.0.0.1"], ["psql", "-h", "::1"],
      ["psql", "-h", "/tmp/postgres"], ["psql", "postgresql://localhost/db"],
      ["psql", "postgresql://127.0.0.1/db"], ["psql", "postgresql://[::1]/db"]
    ]
    blocked = [
      ["psql", "-h", "db.example"], ["psql", "-h", "postgres"], ["psql", "service=prod"],
      ["psql", "host=localhost dbname=x"], ["psql", "postgresql://localhost,remote/db"],
      ["psql", "postgresql://localhost/db?host=remote.example"], ["psql", "postgresql://localhost/db#fragment"]
    ]
    allowed.each { |argv| assert_classification(argv, 0, "allowed") }
    blocked.each { |argv| assert_classification(argv, 126, "CLAUDE_EXPLORE_BLOCKED") }

    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "psql-db"})
    assert status.success?, stderr
    assert_includes @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG")), "psql <-d> <mydb>"
    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "psql-env", "PGHOST" => "remote.example"})
    assert status.success?, stderr
    assert_includes @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG")), "PGHOST=unset"
    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "psql-query"})
    assert_equal 126, status.exitstatus
    refute File.exist?(@harness.env.fetch("FAKE_DELEGATE_LOG"))
  end

  def test_policy_override_environment_has_no_authority
    install!
    weaker = File.join(@harness.root, "weaker-policy.sh")
    File.write(weaker, "CLAUDE_EXPLORE_BLOCKED_EXECUTABLES=''\n")
    _stdout, stderr, status = @harness.runtime("--claude-explore-check-command", "--", "gh", extra_env: {"CLAUDE_EXPLORE_POLICY" => weaker})
    assert_equal 126, status.exitstatus
    assert_includes stderr, "CLAUDE_EXPLORE_BLOCKED"
  end

  def test_failed_upgrade_recursion_and_destination_collisions_preserve_active_runtime
    install!
    active_before = File.realpath(@harness.current_runtime)
    metadata_before = @harness.read(@harness.metadata)

    _stdout, stderr, status = @harness.install("upgrade", extra_env: {"FAKE_CLAUDE_VERSION" => "2.1.223"})
    refute status.success?
    assert_includes stderr, "below required"
    assert_equal active_before, File.realpath(@harness.current_runtime)
    assert_equal metadata_before, @harness.read(@harness.metadata)

    recursive = File.join(@harness.root, "recursive-claude")
    File.symlink(@harness.installed_launcher, recursive)
    _stdout, stderr, status = @harness.install("upgrade", claude: recursive)
    refute status.success?
    assert_includes stderr, "recurses into claude-explore"
    assert_equal active_before, File.realpath(@harness.current_runtime)
  end

  def test_strict_metadata_and_installed_file_modes_fail_closed
    install!
    File.open(@harness.metadata, "a") { |file| file.puts("unexpected=value") }
    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info")
    refute status.success?
    assert_includes stderr, "unknown installation metadata field"

    _stdout, stderr, status = @harness.install("upgrade")
    refute status.success?
    assert_includes stderr, "unknown existing installation metadata field"

    lines = @harness.read(@harness.metadata).lines.reject { |line| line.start_with?("unexpected=") }
    File.write(@harness.metadata, lines.join)
    File.chmod(0o622, File.join(@harness.current_runtime, "policy.sh"))
    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info")
    refute status.success?
    assert_includes stderr, "installed runtime file is missing or unsafe"
  end

  def test_non_framework_launcher_collision_is_not_overwritten
    collision = @harness.installed_launcher
    FileUtils.mkdir_p(File.dirname(collision))
    File.write(collision, "developer-owned\n")
    File.chmod(0o600, collision)

    _stdout, stderr, status = @harness.install
    refute status.success?
    assert_includes stderr, "not framework-owned"
    assert_equal "developer-owned\n", File.read(collision)
  end

  def test_child_exit_status_and_session_cleanup
    install!
    before = Dir.glob(File.join(@harness.env.fetch("XDG_RUNTIME_DIR"), "claude-explore.*"))
    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_CLAUDE_EXIT" => "37"})
    assert_equal 37, status.exitstatus, stderr
    after = Dir.glob(File.join(@harness.env.fetch("XDG_RUNTIME_DIR"), "claude-explore.*"))
    assert_equal before, after
  end

  def test_signal_handlers_and_sigterm_cleanup
    install!
    @harness.replace_claude_with_signal_runtime
    persistent = File.join(@harness.env.fetch("XDG_RUNTIME_DIR"), "claude-explore.keep")
    FileUtils.mkdir_p(persistent)
    started = File.join(@harness.root, "started-TERM")
    process_env = @harness.env.merge("FAKE_STARTED" => started)
    _stdin, _stdout, _stderr, wait_thread = Open3.popen3(process_env, @harness.installed_launcher, chdir: ClaudeExploreHarness::REPOSITORY_ROOT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(started)
      flunk "fake Claude did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    Process.kill("TERM", wait_thread.pid)
    assert_equal 143, wait_thread.value.exitstatus
    assert Dir.exist?(persistent)
    assert_equal [persistent], Dir.glob(File.join(@harness.env.fetch("XDG_RUNTIME_DIR"), "claude-explore.*"))
    runtime_source = File.read(File.join(ClaudeExploreHarness::REPOSITORY_ROOT, "agent-runtimes/claude-explore/lib/claude_explore_runtime.sh"))
    assert_includes runtime_source, "kill -INT \"$CHILD_PID\""
    assert_includes runtime_source, "kill -TERM \"$CHILD_PID\""
  end

  private

  def install!
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
  end

  def assert_classification(argv, expected_status, expected_output)
    stdout, stderr, status = @harness.runtime("--claude-explore-check-command", "--", *argv)
    assert_equal expected_status, status.exitstatus, "#{argv.inspect}: #{stdout} #{stderr}"
    assert_includes "#{stdout}#{stderr}", expected_output
  end

  def policy_lines(variable)
    raise "unsupported policy test variable" unless variable == "CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"

    script = '. "$1"; printf \'%s\\n\' "$CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"'
    stdout, stderr, status = Open3.capture3("/bin/bash", "--noprofile", "--norc", "-c", script, "test", POLICY)
    assert status.success?, stderr
    stdout.lines(chomp: true).reject(&:empty?)
  end
end
