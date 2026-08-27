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
    assert_includes stdout, "claude_selection=path"
    assert_includes stdout, "If that command is wrapped"
    metadata_before = @harness.read(@harness.metadata)

    _stdout, stderr, status = @harness.install("upgrade", claude: nil)
    assert status.success?, stderr
    assert_equal metadata_before, @harness.read(@harness.metadata)
  end

  def test_explicit_claude_launcher_is_recorded_exactly
    stdout, stderr, status = @harness.install
    assert status.success?, stderr
    assert_includes stdout, "claude_launcher=#{@harness.claude_launcher}"
    assert_includes stdout, "claude_selection=explicit"
    assert_includes @harness.read(@harness.metadata), "claude_launcher_path=#{@harness.claude_launcher}\n"
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

  def test_exported_bash_functions_cannot_shadow_installer_runtime_or_guard_commands
    marker = File.join(@harness.root, "exported-function-ran")
    hostile = "() { /usr/bin/touch '#{marker}'; return 99; }"
    hostile_env = {
      "BASH_FUNC_mkdir%%" => hostile,
      "BASH_FUNC_dirname%%" => hostile,
      "BASH_FUNC_git%%" => hostile
    }

    _stdout, stderr, status = @harness.install(extra_env: hostile_env)
    assert status.success?, stderr
    refute File.exist?(marker)

    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info", extra_env: hostile_env)
    assert status.success?, stderr
    refute File.exist?(marker)

    _stdout, stderr, status = @harness.runtime(extra_env: hostile_env.merge("FAKE_INNER_SCENARIO" => "git-allowed"))
    assert status.success?, stderr
    refute File.exist?(marker), "guard execution must remain authoritative"
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

    native = policy_assignments
    assert_equal native.fetch("CLAUDE_EXPLORE_SANDBOX_ENABLED") == "true", settings.dig("sandbox", "enabled")
    assert_equal native.fetch("CLAUDE_EXPLORE_SANDBOX_FAIL_IF_UNAVAILABLE") == "true", settings.dig("sandbox", "failIfUnavailable")
    assert_equal native.fetch("CLAUDE_EXPLORE_SANDBOX_ALLOW_UNSANDBOXED_COMMANDS") == "true", settings.dig("sandbox", "allowUnsandboxedCommands")
    assert_equal native.fetch("CLAUDE_EXPLORE_DISABLE_ALL_HOOKS") == "true", settings["disableAllHooks"]
    assert_equal native.fetch("CLAUDE_EXPLORE_DISABLE_ARTIFACT") == "true", settings["disableArtifact"]
  end

  def test_generated_settings_json_escapes_permitted_path_characters
    @harness.cleanup
    @harness = ClaudeExploreHarness.new(prefix: "claude-quote-\"-backslash-\\-")
    install!

    _stdout, stderr, status = @harness.runtime
    assert status.success?, stderr
    settings = JSON.parse(@harness.read(@harness.env.fetch("FAKE_SETTINGS_COPY")))
    assert_includes settings.dig("sandbox", "filesystem", "denyWrite"), File.realpath(@harness.data_root)
    assert_includes settings.dig("sandbox", "filesystem", "denyWrite"), @harness.installed_launcher
  end

  def test_settings_and_mcp_write_failures_abort_before_claude_starts
    {
      "SETTINGS_FILE=$SESSION_DIR/settings.json" => "SETTINGS_FILE=$SESSION_DIR",
      "MCP_FILE=$SESSION_DIR/mcp.json" => "MCP_FILE=$SESSION_DIR"
    }.each do |before, after|
      @harness.cleanup
      @harness = ClaudeExploreHarness.new
      install!
      @harness.replace_installed_runtime_text("lib/claude_explore_runtime.sh", before, after)
      FileUtils.rm_f(@harness.env.fetch("FAKE_CLAUDE_LOG"))

      _stdout, stderr, status = @harness.runtime
      assert_equal 1, status.exitstatus, stderr
      assert_includes stderr, "could not create private session state"
      refute File.exist?(@harness.env.fetch("FAKE_CLAUDE_LOG"))
    end
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

    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, stderr, status = @harness.runtime(extra_env: {
      "FAKE_INNER_SCENARIO" => "git-env",
      "GIT_CONFIG_PARAMETERS" => "'alias.status=!marker-command'",
      "GIT_CONFIG_GLOBAL" => "/tmp/unsafe-git-config"
    })
    assert status.success?, stderr
    delegate = @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    assert_includes delegate, "GIT_CONFIG_COUNT=unset"
    assert_includes delegate, "GIT_CONFIG_KEY_0=unset"
    assert_includes delegate, "GIT_CONFIG_VALUE_0=unset"
    refute File.exist?(@harness.env.fetch("FAKE_GIT_INJECTION_MARKER"))
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
    assert_includes @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG")), "psql <-X> <-d> <mydb>"
    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "psql-env", "PGHOST" => "remote.example"})
    assert status.success?, stderr
    assert_includes @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG")), "PGHOST=unset"
    FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "psql-query"})
    assert_equal 126, status.exitstatus
    refute File.exist?(@harness.env.fetch("FAKE_DELEGATE_LOG"))

    [["psql", "-d", "mydb", "-c", "\\connect postgresql://remote.example/db"],
     ["psql", "-d", "mydb", "--command=\\! id"],
     ["psql", "-d", "mydb", "-f", "commands.sql"]].each do |argv|
      assert_classification(argv, 126, "CLAUDE_EXPLORE_BLOCKED")
    end

    File.write(File.join(@harness.home, ".psqlrc"), "\\connect postgresql://remote.example/db\n")
    File.write(File.join(@harness.home, ".pgpass"), "remote.example:5432:*:*:secret\n")
    File.chmod(0o600, File.join(@harness.home, ".pgpass"))
    %w[psql-command psql-stdin].each do |scenario|
      FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
      _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => scenario})
      assert status.success?, stderr
      delegate = @harness.read(@harness.env.fetch("FAKE_DELEGATE_LOG"))
      assert_includes delegate, "psql <-X>"
      assert_match(/PGPASSFILE=.*claude-explore\..*\/pgpass/, delegate)
      refute File.exist?(@harness.env.fetch("FAKE_PSQLRC_MARKER"))
      refute File.exist?(@harness.env.fetch("FAKE_PGPASS_MARKER"))
      refute File.exist?(@harness.env.fetch("FAKE_PSQL_STDIN_MARKER"))
    end

    %w[psql-meta psql-file].each do |scenario|
      FileUtils.rm_f(@harness.env.fetch("FAKE_DELEGATE_LOG"))
      _stdout, _stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => scenario})
      assert_equal 126, status.exitstatus
      refute File.exist?(@harness.env.fetch("FAKE_DELEGATE_LOG"))
    end
  end

  def test_privilege_and_postgresql_companion_guards_are_policy_driven
    install!
    %w[sudo pg_dump pg_restore createdb pg_isready].each do |command|
      assert_includes policy_lines("CLAUDE_EXPLORE_BLOCKED_EXECUTABLES"), command
      assert_classification([command], 126, "CLAUDE_EXPLORE_BLOCKED")
    end
    assert_classification(["sqlite3", ":memory:"], 0, "allowed")
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
    assert_includes stderr, "installed runtime content is missing or unsafe"
  end

  def test_installed_runtime_integrity_rejects_nonexecutable_writable_and_external_content
    [
      ["lib/claude_explore_guard.sh", 0o600, "installed runtime content is missing or unsafe"],
      ["lib/claude_explore_runtime.sh", 0o722, "installed runtime content is missing or unsafe"],
      ["policy.sh", 0o700, "installed runtime content is missing or unsafe"]
    ].each do |relative, mode, diagnostic|
      @harness.cleanup
      @harness = ClaudeExploreHarness.new
      install!
      File.chmod(mode, File.join(@harness.current_runtime, relative))
      FileUtils.rm_f(@harness.env.fetch("FAKE_CLAUDE_LOG"))
      _stdout, stderr, status = @harness.runtime
      refute status.success?
      assert_includes stderr, diagnostic
      refute File.exist?(@harness.env.fetch("FAKE_CLAUDE_LOG"))
    end

    @harness.cleanup
    @harness = ClaudeExploreHarness.new
    install!
    external = File.join(@harness.root, "external-guard")
    @harness.write_executable(external, "#!/bin/sh\nexit 0\n")
    guard = File.join(@harness.current_runtime, "lib/claude_explore_guard.sh")
    FileUtils.rm(guard)
    File.symlink(external, guard)
    _stdout, stderr, status = @harness.runtime
    refute status.success?
    assert_includes stderr, "installed runtime content is missing or unsafe"
  end

  def test_claude_launcher_path_hierarchy_and_relative_xdg_fail_closed
    unsafe_parent = File.join(@harness.root, "unsafe-parent")
    FileUtils.mkdir_p(unsafe_parent)
    File.chmod(0o777, unsafe_parent)
    unsafe_target = File.join(unsafe_parent, "claude-target")
    @harness.write_executable(unsafe_target, "#!/bin/sh\necho 'Claude Code 2.1.224'\n")
    unsafe_launcher = File.join(unsafe_parent, "claude")
    File.symlink(unsafe_target, unsafe_launcher)
    _stdout, stderr, status = @harness.install(claude: unsafe_launcher)
    refute status.success?
    assert_includes stderr, "path hierarchy is unsafe"

    _stdout, stderr, status = @harness.install(claude: "/bin/echo")
    refute status.success?
    refute_includes stderr, "path hierarchy is unsafe"

    _stdout, stderr, status = @harness.install(extra_env: {"XDG_DATA_HOME" => "relative-data"})
    refute status.success?
    assert_includes stderr, "XDG_DATA_HOME must be absolute"

    install!
    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info", extra_env: {"XDG_DATA_HOME" => "relative-data"})
    refute status.success?
    assert_includes stderr, "XDG_DATA_HOME must be absolute"
    _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info", extra_env: {"XDG_CONFIG_HOME" => "relative-config"})
    refute status.success?
    assert_includes stderr, "XDG_CONFIG_HOME must be absolute"
  end

  def test_cross_version_upgrade_and_injected_failure_are_atomic
    install!
    FileUtils.mkdir_p(@harness.sessions_root)
    File.chmod(0o700, @harness.sessions_root)
    preserved_session = File.join(@harness.sessions_root, "claude-explore.active")
    FileUtils.mkdir_p(preserved_session)
    File.chmod(0o700, preserved_session)
    source_v2 = @harness.copy_runtime_source(version: 2)
    _stdout, stderr, status = @harness.install_from(File.join(source_v2, "install.sh"), "upgrade")
    assert status.success?, stderr
    assert_match(%r{/versions/2\z}, File.realpath(File.join(@harness.data_root, "current")))
    assert_match(%r{/versions/2/bin/claude-explore\z}, File.realpath(@harness.installed_launcher))
    assert_includes @harness.read(@harness.metadata), "runtime_version=2"
    assert Dir.exist?(preserved_session), "upgrade must preserve stable sessions state"
    assert_empty activation_transaction_artifacts

    active_before = File.realpath(File.join(@harness.data_root, "current"))
    metadata_before = @harness.read(@harness.metadata)
    source_v3 = @harness.copy_runtime_source(version: 3, fail_metadata_activation: true)
    _stdout, stderr, status = @harness.install_from(File.join(source_v3, "install.sh"), "upgrade")
    refute status.success?
    assert_includes stderr, "injected metadata activation failure"
    assert_equal active_before, File.realpath(File.join(@harness.data_root, "current"))
    assert_equal metadata_before, @harness.read(@harness.metadata)
    assert_match(%r{/versions/2/bin/claude-explore\z}, File.realpath(@harness.installed_launcher))
    assert Dir.exist?(preserved_session), "failed upgrade must preserve stable sessions state"
    assert_empty activation_transaction_artifacts
  end

  def activation_transaction_artifacts
    Dir.glob(File.join(@harness.data_root, ".{previous,current}.*"), File::FNM_DOTMATCH) +
      Dir.glob(File.join(File.dirname(@harness.metadata), ".{previous,install.meta.tmp}.*"), File::FNM_DOTMATCH) +
      Dir.glob(File.join(File.dirname(@harness.installed_launcher), ".{previous,claude-explore}.*"), File::FNM_DOTMATCH)
  end

  def test_reserved_runtime_diagnostic_does_not_echo_secret_argument
    install!
    secret = "--claude-explore-api-key=secret-review-value"
    _stdout, stderr, status = @harness.runtime(secret)
    assert_equal 2, status.exitstatus
    assert_includes stderr, "reserved runtime argument is not accepted"
    refute_includes stderr, secret
    refute_includes stderr, "secret-review-value"
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

  def test_unrelated_path_shadowing_claude_explore_is_preserved_and_reported
    unrelated = File.join(@harness.fake_bin, "claude-explore")
    contents = "#!/bin/sh\necho unrelated-explore\n"
    @harness.write_executable(unrelated, contents)

    stdout, stderr, status = @harness.install
    assert status.success?, stderr
    assert File.symlink?(@harness.installed_launcher)
    assert_equal contents, File.read(unrelated)
    assert_includes stderr, "PATH shadowing"
    assert_includes stderr, "installed public launcher=#{@harness.installed_launcher}"
    assert_includes stderr, "bare claude-explore resolves to=#{unrelated}"
    assert_includes stderr, "will continue to select the earlier PATH entry"
    assert_includes stdout, "launcher=#{@harness.installed_launcher}"
    assert_includes stdout, "Add #{File.dirname(@harness.installed_launcher)} to PATH manually."
  end

  def test_trusted_cleanup_ignores_original_path_and_xdg_runtime_dir
    install!
    hostile_rm = File.join(@harness.fake_bin, "rm")
    @harness.write_executable(hostile_rm, "#!/bin/sh\n: > \"$FAKE_RM_MARKER\"\nexit 91\n")
    repository_runtime = File.join(@harness.root, "repository-controlled-runtime")
    FileUtils.mkdir_p(repository_runtime)
    FileUtils.mkdir_p(@harness.sessions_root)
    File.chmod(0o700, @harness.sessions_root)
    persistent = File.join(@harness.sessions_root, "claude-explore.keep")
    FileUtils.mkdir_p(persistent)
    File.chmod(0o700, persistent)

    _stdout, stderr, status = @harness.runtime(extra_env: {
      "FAKE_CLAUDE_EXIT" => "37",
      "XDG_RUNTIME_DIR" => repository_runtime
    })
    assert_equal 37, status.exitstatus, stderr
    session = @harness.logged_session_dir
    assert session.start_with?("#{@harness.sessions_root}/claude-explore."), session
    refute File.exist?(session)
    refute File.exist?(@harness.env.fetch("FAKE_RM_MARKER"))
    assert Dir.exist?(@harness.sessions_root)
    assert Dir.exist?(persistent)
    assert_empty Dir.children(repository_runtime)
    runtime_source = File.read(File.join(ClaudeExploreHarness::REPOSITORY_ROOT, "agent-runtimes/claude-explore/lib/claude_explore_runtime.sh"))
    refute_includes runtime_source, "XDG_RUNTIME_DIR"
  end

  def test_sessions_root_permissions_and_signal_cleanup_use_trusted_rm
    install!
    hostile_rm = File.join(@harness.fake_bin, "rm")
    @harness.write_executable(hostile_rm, "#!/bin/sh\n: > \"$FAKE_RM_MARKER\"\nexit 91\n")
    @harness.replace_claude_with_signal_runtime
    FileUtils.mkdir_p(@harness.sessions_root)
    File.chmod(0o700, @harness.sessions_root)
    persistent = File.join(@harness.sessions_root, "claude-explore.keep")
    FileUtils.mkdir_p(persistent)
    File.chmod(0o700, persistent)
    repository_runtime = File.join(@harness.root, "repository-controlled-signal-runtime")
    FileUtils.mkdir_p(repository_runtime)
    started = File.join(@harness.root, "started-TERM")
    process_env = @harness.env.merge("FAKE_STARTED" => started, "XDG_RUNTIME_DIR" => repository_runtime)
    _stdin, _stdout, _stderr, wait_thread = Open3.popen3(process_env, @harness.installed_launcher, chdir: ClaudeExploreHarness::REPOSITORY_ROOT)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
    until File.exist?(started)
      flunk "fake Claude did not start" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
      sleep 0.02
    end
    sessions = Dir.glob(File.join(@harness.sessions_root, "claude-explore.*")).reject { |path| path == persistent }
    assert_equal 1, sessions.length
    session = sessions.fetch(0)
    assert_equal 0o700, File.stat(@harness.sessions_root).mode & 0o777
    assert_equal 0o700, File.stat(session).mode & 0o777
    assert_equal 0o700, File.stat(File.join(session, "guard")).mode & 0o777
    assert_equal 0o700, File.stat(File.join(session, "gh")).mode & 0o777
    assert_equal 0o700, File.stat(File.join(session, "askpass")).mode & 0o777
    %w[settings.json mcp.json pgpass].each do |name|
      assert_equal 0o600, File.stat(File.join(session, name)).mode & 0o777
    end
    assert_equal 0o600, File.stat(File.join(session, "guard", "delegates")).mode & 0o777
    assert_empty Dir.children(repository_runtime)
    Process.kill("TERM", wait_thread.pid)
    assert_equal 143, wait_thread.value.exitstatus
    assert Dir.exist?(persistent)
    refute File.exist?(session)
    refute File.exist?(@harness.env.fetch("FAKE_RM_MARKER"))
    assert Dir.exist?(@harness.sessions_root)
    assert_equal [persistent], Dir.glob(File.join(@harness.sessions_root, "claude-explore.*"))
    runtime_source = File.read(File.join(ClaudeExploreHarness::REPOSITORY_ROOT, "agent-runtimes/claude-explore/lib/claude_explore_runtime.sh"))
    assert_includes runtime_source, "kill -INT \"$CHILD_PID\""
    assert_includes runtime_source, "kill -TERM \"$CHILD_PID\""
  end

  def test_unsafe_sessions_parent_fails_before_claude_starts
    install!
    outside = File.join(@harness.root, "outside-sessions")
    FileUtils.mkdir_p(outside)
    File.symlink(outside, @harness.sessions_root)
    FileUtils.rm_f(@harness.env.fetch("FAKE_CLAUDE_LOG"))

    _stdout, stderr, status = @harness.runtime
    assert_equal 1, status.exitstatus
    assert_includes stderr, "could not create private session state"
    refute File.exist?(@harness.env.fetch("FAKE_CLAUDE_LOG"))
    assert_empty Dir.children(outside)
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
    allowed = %w[
      CLAUDE_EXPLORE_BLOCKED_EXECUTABLES CLAUDE_EXPLORE_ENV_UNSET
      CLAUDE_EXPLORE_CREDENTIAL_PATHS CLAUDE_EXPLORE_PG_ENV
    ]
    raise "unsupported policy test variable" unless allowed.include?(variable)

    script = '. "$1"; name=$2; printf \'%s\\n\' "${!name}"'
    stdout, stderr, status = Open3.capture3("/bin/bash", "--noprofile", "--norc", "-p", "-c", script, "test", POLICY, variable)
    assert status.success?, stderr
    stdout.lines(chomp: true).reject(&:empty?)
  end

  def policy_assignments
    names = %w[
      CLAUDE_EXPLORE_SANDBOX_ENABLED
      CLAUDE_EXPLORE_SANDBOX_FAIL_IF_UNAVAILABLE
      CLAUDE_EXPLORE_SANDBOX_ALLOW_UNSANDBOXED_COMMANDS
      CLAUDE_EXPLORE_DISABLE_ALL_HOOKS
      CLAUDE_EXPLORE_DISABLE_ARTIFACT
    ]
    script = '. "$1"; shift; for name in "$@"; do printf \'%s=%s\\n\' "$name" "${!name}"; done'
    stdout, stderr, status = Open3.capture3("/bin/bash", "--noprofile", "--norc", "-p", "-c", script, "test", POLICY, *names)
    assert status.success?, stderr
    stdout.lines(chomp: true).to_h { |line| line.split("=", 2) }
  end
end
