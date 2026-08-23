# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "stringio"
require "timeout"
require_relative "support/claude_explore_harness"
require_relative "../agent-runtimes/claude-explore/lib/claude_explore"
require_relative "../agent-runtimes/claude-explore/install"

class ClaudeExploreRuntimeTest < Minitest::Test
  include ClaudeExploreHarness

  def setup
    setup_runtime_fixture
    @policy = ClaudeExplore::Policy.new(File.join(@runtime_root, "policy.yml"))
    @classifier = ClaudeExplore::Classifier.new(@policy)
  end

  def teardown
    teardown_runtime_fixture
  end

  def test_policy_identity_and_native_contract
    assert_equal 1, @policy.data["schema_version"]
    assert_equal "claude-explore", @policy.runtime["id"]
    assert_equal "2.1.224", @policy.minimum_claude_version
    assert_equal 126, @policy.denied_exit_status
    assert_equal true, @policy.native_controls.dig("sandbox", "enabled")
    assert_equal true, @policy.native_controls.dig("sandbox", "fail_if_unavailable")
    assert_equal false, @policy.native_controls.dig("sandbox", "allow_unsandboxed_commands")
  end

  def test_policy_validation_rejects_weakened_native_controls
    weakened = File.join(@temporary_root, "weakened-policy.yml")
    data = policy_data
    data["native_controls"]["sandbox"]["fail_if_unavailable"] = false
    File.write(weakened, YAML.dump(data))
    error = assert_raises(ClaudeExplore::Error) { ClaudeExplore::Policy.new(weakened) }
    assert_includes error.message, "weakens required native control"
  end

  def test_every_fully_blocked_executable_is_policy_driven_and_blocked
    @policy.blocked_executables.each do |name, (category, definition)|
      result = @classifier.classify([name, "apparently-read-only"])
      assert_equal "blocked", result.decision, name
      assert_equal category, result.category, name
      assert_equal definition["rule"], result.rule, name
    end
  end

  def test_every_fully_blocked_guard_refuses_without_invoking_real_binary
    marker = File.join(@temporary_root, "all-blocked-marker")
    previous_path = ENV["CLAUDE_EXPLORE_ORIGINAL_PATH"]
    previous_policy = ENV["CLAUDE_EXPLORE_POLICY"]
    ENV["CLAUDE_EXPLORE_ORIGINAL_PATH"] = @fake_bin
    ENV["CLAUDE_EXPLORE_POLICY"] = @policy.path
    @policy.blocked_executables.each_key do |name|
      write_executable(name, "#!/bin/sh\necho #{name} >> #{marker}\n")
      _stdout, _stderr = capture_io do
        assert_equal 126, ClaudeExplore::Guard.run(name, ["synthetic"]), name
      end
    end
    refute File.exist?(marker)
  ensure
    ENV["CLAUDE_EXPLORE_ORIGINAL_PATH"] = previous_path
    ENV["CLAUDE_EXPLORE_POLICY"] = previous_policy
  end

  def test_git_allowed_local_operations
    %w[status diff log add commit checkout switch].each do |operation|
      result = @classifier.classify(["git", operation, "argument with spaces"])
      assert result.allowed?, operation
      assert_equal "git.local-operation", result.rule
    end
    assert @classifier.classify(%w[git branch feature]).allowed?
    assert @classifier.classify(%w[git -C repo status]).allowed?
    assert @classifier.classify(["git", "-c", "color.ui=false", "status"]).allowed?
  end

  def test_git_remote_and_credential_operations_are_blocked
    %w[push fetch pull clone ls-remote credential credential-cache credential-store send-email imap-send].each do |operation|
      result = @classifier.classify(["git", operation])
      refute result.allowed?, operation
      assert_equal "git.remote-mutation", result.rule
    end
  end

  def test_git_remote_policy
    assert @classifier.classify(%w[git remote]).allowed?
    assert @classifier.classify(%w[git remote -v]).allowed?
    assert @classifier.classify(%w[git remote --verbose]).allowed?
    assert @classifier.classify(%w[git remote get-url origin]).allowed?
    assert @classifier.classify(%w[git remote get-url --all origin]).allowed?
    %w[add remove rename set-head set-branches set-url prune update show].each do |operation|
      refute @classifier.classify(["git", "remote", operation, "origin"]).allowed?, operation
    end
  end

  def test_git_branch_config_tag_submodule_and_unknown_policy
    refute @classifier.classify(%w[git branch -u origin/main]).allowed?
    refute @classifier.classify(%w[git branch --unset-upstream]).allowed?
    assert @classifier.classify(%w[git config --get user.name]).allowed?
    assert @classifier.classify(%w[git config --list]).allowed?
    refute @classifier.classify(%w[git config user.name value]).allowed?
    refute @classifier.classify(%w[git config --unset user.name]).allowed?
    assert @classifier.classify(%w[git tag]).allowed?
    assert @classifier.classify(%w[git tag --list release-*]).allowed?
    assert @classifier.classify(%w[git tag --contains HEAD]).allowed?
    refute @classifier.classify(%w[git tag release]).allowed?
    refute @classifier.classify(%w[git tag -d release]).allowed?
    refute @classifier.classify(%w[git submodule update]).allowed?
    refute @classifier.classify(%w[git submodule foreach echo]).allowed?
    refute @classifier.classify(%w[git maintenance]).allowed?
    refute @classifier.classify(%w[git --unknown status]).allowed?
  end

  def test_psql_local_connections_are_allowed
    [
      ["psql"], ["psql", "-h", "localhost"], ["psql", "-h", "127.0.0.1"],
      ["psql", "--host", "::1"], ["psql", "--host=/var/run/postgresql"],
      ["psql", "postgresql://localhost/db"], ["psql", "postgresql://[::1]/db"],
      ["psql", "-d", "postgres://127.0.0.1/db"]
    ].each { |argv| assert @classifier.classify(argv).allowed?, argv.inspect }
  end

  def test_psql_remote_and_ambiguous_connections_are_blocked_without_leaking_credentials
    cases = [
      ["psql", "-h", "db"], ["psql", "--host=host.docker.internal"],
      ["psql", "-h", "192.0.2.10"], ["psql", "-h", "2001:db8::1"],
      ["psql", "postgresql://secret-user:secret-pass@remote.example/db"],
      ["psql", "host=localhost dbname=test"], ["psql", "service=shared"]
    ]
    cases.each { |argv| refute @classifier.classify(argv).allowed?, argv.inspect }
    result = @classifier.classify(cases[4])
    output = StringIO.new
    ClaudeExplore::Diagnostics.blocked(@policy, result, io: output)
    refute_includes output.string, "secret-user"
    refute_includes output.string, "secret-pass"
    refute_includes output.string, "remote.example"
    assert_includes output.string, "operation=psql remote-connection"
  end

  def test_dry_run_classification_does_not_launch_claude
    FileUtils.rm_f(@fake_log)
    stdout, stderr, status = run_runtime("--claude-explore-check-command", "--", "git", "push", "origin", "main")
    assert_equal 126, status.exitstatus
    assert_empty stderr
    assert_includes stdout, "CLAUDE_EXPLORE_CLASSIFICATION"
    assert_includes stdout, "rule=git.remote-mutation"
    refute File.exist?(@fake_log)

    stdout, _stderr, status = run_runtime("--claude-explore-check-command", "--", "git", "status")
    assert status.success?
    assert_includes stdout, "expected_exit=delegate"
  end

  def test_invalid_runtime_owned_invocations_exit_two
    [["--claude-explore-runtime-info", "extra"], ["--claude-explore-check-command"],
     ["--claude-explore-check-command", "git", "status"], ["--claude-explore-check-command", "--"]].each do |args|
      _stdout, stderr, status = run_runtime(*args)
      assert_equal 2, status.exitstatus, args.inspect
      assert_includes stderr, "invalid runtime-owned invocation"
    end
  end

  def test_runtime_info_is_secret_safe_and_does_not_launch_claude_session
    FileUtils.rm_f(@fake_log)
    stdout, stderr, status = run_runtime("--claude-explore-runtime-info", env: {"GITHUB_TOKEN" => "SYNTHETIC_SECRET"})
    assert status.success?
    assert_empty stderr
    assert_includes stdout, "runtime_id=claude-explore"
    assert_includes stdout, "sandbox_required=true"
    assert_includes stdout, "unsandboxed_retry_allowed=false"
    refute_includes stdout, "SYNTHETIC_SECRET"
    refute File.exist?(@fake_log)
  end

  def test_normal_arguments_no_arguments_help_and_version_are_passed_unchanged
    [[], ["--help"], ["--version"], ["prompt with spaces", "--model", "synthetic"]].each do |args|
      _stdout, stderr, status = run_runtime(*args)
      assert status.success?, stderr
      received = fake_log.fetch("argv")
      assert_equal ["--settings"], received.take(1)
      assert_equal "--append-system-prompt", received[2]
      assert_includes received[3], "intentional runtime authority boundary"
      assert_equal args, received.drop(4)
    end
  end

  def test_generated_settings_require_native_safety_controls_and_credential_denies
    _stdout, stderr, status = run_runtime
    assert status.success?, stderr
    settings = fake_log.fetch("settings")
    assert_equal true, settings.dig("sandbox", "enabled")
    assert_equal true, settings.dig("sandbox", "failIfUnavailable")
    assert_equal false, settings.dig("sandbox", "allowUnsandboxedCommands")
    assert_equal true, settings["disableAllHooks"]
    assert_equal true, settings["disableArtifact"]
    assert_includes settings.dig("permissions", "deny"), "mcp__*"
    @policy.credential_files.each do |path|
      assert_includes settings.dig("sandbox", "filesystem", "denyRead"), path
      assert_includes settings.dig("permissions", "deny"), "Read(#{path})"
      assert_includes settings.dig("permissions", "deny"), "Read(#{path}/**)"
    end
  end

  def test_environment_is_reduced_from_policy_and_safe_values_are_set
    synthetic = @policy.environment.fetch("unset").to_h { |name| [name, "SECRET_#{name}"] }
    synthetic["SAFE_ORDINARY"] = "preserved"
    stdout, stderr, status = run_runtime(env: synthetic)
    assert status.success?, stderr
    child = fake_log.fetch("env")
    @policy.environment.fetch("unset").each { |name| assert_nil child[name], name }
    assert_equal "preserved", child["SAFE_ORDINARY"]
    assert_equal "0", child["GIT_TERMINAL_PROMPT"]
    assert_equal "never", child["GCM_INTERACTIVE"]
    assert_equal "true", child["AWS_EC2_METADATA_DISABLED"]
    assert child["GH_CONFIG_DIR"].start_with?(@temporary_root)
    assert_equal true, fake_log["gh_config_empty"]
    refute File.exist?(child["GIT_ASKPASS"])
    combined = [stdout, stderr, JSON.generate(fake_log)].join("\n")
    synthetic.each_value do |value|
      next if value == "preserved"
      refute_includes combined, value
    end
    fake_log.fetch("guard_sources").each do |source|
      refute_includes source, "eval"
      synthetic.each_value { |value| refute_includes source, value unless value == "preserved" }
    end
  end

  def test_child_exit_status_and_temporary_cleanup_are_preserved
    _stdout, _stderr, status = run_runtime(env: {"FAKE_CLAUDE_EXIT" => "42"})
    assert_equal 42, status.exitstatus
    settings_path = fake_log.fetch("settings_path")
    refute File.exist?(settings_path)
    assert_empty Dir.glob(File.join(@temporary_root, "tmp", "claude-explore-*"))
  end

  def test_session_state_is_private_and_stale_paths_are_not_reused_or_deleted
    stale = File.join(@temporary_root, "tmp", "claude-explore-stale")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "owner"), "unrelated")
    _stdout, stderr, status = run_runtime
    assert status.success?, stderr
    assert_equal 0o700, fake_log["session_mode"]
    assert_equal "unrelated", File.read(File.join(stale, "owner"))
    refute File.exist?(fake_log["settings_path"])
  end

  def test_offline_integration_allows_local_edit_stage_and_commit_but_blocks_push
    repository = File.join(@temporary_root, "repository")
    FileUtils.mkdir_p(repository)
    system("git", "init", "-q", repository) or skip "local Git unavailable"
    system("git", "-C", repository, "config", "user.name", "Synthetic Developer") or skip "local Git config unavailable"
    system("git", "-C", repository, "config", "user.email", "synthetic@example.invalid") or skip "local Git config unavailable"
    edit_path = File.join(repository, "note.txt")

    _stdout, stderr, status = run_runtime(cwd: repository, env: {"FAKE_CLAUDE_EDIT" => edit_path})
    assert status.success?, stderr
    assert_equal "edited by fake Claude\n", File.read(edit_path)

    _stdout, stderr, status = run_runtime(cwd: repository, env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(%w[git add note.txt])})
    assert status.success?, stderr
    _stdout, stderr, status = run_runtime(cwd: repository, env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(["git", "commit", "-m", "local checkpoint"])})
    assert status.success?, stderr
    log_stdout, log_stderr, log_status = Open3.capture3("git", "-C", repository, "log", "-1", "--pretty=%s")
    assert log_status.success?, log_stderr
    assert_equal "local checkpoint", log_stdout.strip

    _stdout, stderr, status = run_runtime(cwd: repository, env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(%w[git push origin main])})
    assert_equal 126, status.exitstatus
    assert_includes stderr, "rule=git.remote-mutation"
  end

  def test_guarded_block_never_invokes_real_binary_and_emits_stable_diagnostic
    marker = File.join(@temporary_root, "blocked-marker")
    write_executable("gh", "#!/bin/sh\necho invoked > #{marker}\n")
    _stdout, stderr, status = run_runtime(env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(%w[gh pr view])})
    assert_equal 126, status.exitstatus
    refute File.exist?(marker)
    assert_match(/\ACLAUDE_EXPLORE_BLOCKED\n/, stderr)
    assert_includes stderr, "runtime=claude-explore"
    assert_includes stderr, "category=github"
    assert_includes stderr, "rule=github.all"
  end

  def test_guarded_git_and_psql_delegate_only_allowed_structured_argv
    marker = File.join(@temporary_root, "delegate.json")
    source = <<~RUBY
      #!#{RbConfig.ruby}
      require "json"
      File.write(#{marker.dump}, JSON.generate(ARGV))
      exit 23
    RUBY
    write_executable("git", source)
    _stdout, _stderr, status = run_runtime(env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(["git", "status", "argument with spaces"])})
    assert_equal 23, status.exitstatus
    assert_equal ["status", "argument with spaces"], JSON.parse(File.read(marker))

    FileUtils.rm_f(marker)
    write_executable("psql", source)
    _stdout, _stderr, status = run_runtime(env: {"FAKE_CLAUDE_COMMAND" => JSON.generate(["psql", "-h", "remote.example"])})
    assert_equal 126, status.exitstatus
    refute File.exist?(marker)
  end

  def test_missing_or_old_claude_and_unsafe_installed_files_fail_before_launch
    FileUtils.rm(@fake_claude)
    _stdout, stderr, status = run_runtime
    assert_equal 1, status.exitstatus
    assert_includes stderr, "repair the installation"

    @fake_claude = write_executable("claude", fake_claude_source)
    write_metadata
    _stdout, stderr, status = run_runtime(env: {"FAKE_CLAUDE_VERSION" => "Claude Code 2.1.223"})
    assert_equal 1, status.exitstatus
    assert_includes stderr, "unsupported"

    File.chmod(0o622, File.join(@runtime_root, "policy.yml"))
    _stdout, stderr, status = run_runtime
    assert_equal 1, status.exitstatus
    assert_includes stderr, "group/world writable"
  end

  def test_symlinked_installed_policy_is_rejected
    policy_path = File.join(@runtime_root, "policy.yml")
    backup = File.join(@runtime_root, "policy-copy.yml")
    FileUtils.mv(policy_path, backup)
    File.symlink(backup, policy_path)
    _stdout, stderr, status = run_runtime
    assert_equal 1, status.exitstatus
    assert_includes stderr, "must not be a symlink"
  end

  def test_sigint_and_sigterm_are_forwarded
    {"INT" => 77, "TERM" => 78}.each do |signal, expected|
      ready = File.join(@temporary_root, "ready-#{signal}")
      env = runtime_env("FAKE_CLAUDE_WAIT" => "1", "FAKE_CLAUDE_READY" => ready)
      stdin, stdout, stderr, thread = Open3.popen3(env, RbConfig.ruby, @launcher)
      Timeout.timeout(5) { sleep 0.01 until File.exist?(ready) }
      Process.kill(signal, thread.pid)
      status = thread.value
      assert_equal expected, status.exitstatus, "#{signal}: #{stdout.read} #{stderr.read}"
      [stdin, stdout, stderr].each(&:close)
    end
  end

  def test_installer_fresh_install_idempotent_upgrade_and_uninstall
    install_home = File.join(@temporary_root, "installer-home")
    env = {"HOME" => install_home, "PATH" => @fake_bin, "XDG_DATA_HOME" => File.join(install_home, "data"),
           "XDG_CONFIG_HOME" => File.join(install_home, "config")}
    output = StringIO.new
    errors = StringIO.new
    installer = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: env, out: output, err: errors)
    assert_equal 0, installer.run("install", claude_bin: @fake_claude), errors.string
    launcher = File.join(install_home, ".local", "bin", "claude-explore")
    assert File.symlink?(launcher)
    assert_equal 0, installer.run("install", claude_bin: @fake_claude), errors.string
    assert_equal 0, installer.run("upgrade"), errors.string
    unrelated = File.join(install_home, ".local", "bin", "unrelated")
    File.write(unrelated, "preserve")
    assert_equal 0, installer.run("uninstall"), errors.string
    refute File.exist?(launcher)
    assert_equal "preserve", File.read(unrelated)
    assert File.exist?(@fake_claude)
    assert_empty errors.string
  end

  def test_installer_path_discovery_versions_and_collision_failures
    install_home = File.join(@temporary_root, "installer-cases")
    env = {"HOME" => install_home, "PATH" => @fake_bin, "XDG_DATA_HOME" => File.join(install_home, "data"),
           "XDG_CONFIG_HOME" => File.join(install_home, "config")}
    out = StringIO.new
    err = StringIO.new
    installer = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: env, out: out, err: err)
    assert_equal 0, installer.run("install")
    assert_includes out.string, "claude_version=2.1.224"

    collision_home = File.join(@temporary_root, "collision-home")
    FileUtils.mkdir_p(File.join(collision_home, ".local", "bin"))
    File.write(File.join(collision_home, ".local", "bin", "claude-explore"), "unrelated")
    collision_env = env.merge("HOME" => collision_home, "XDG_DATA_HOME" => File.join(collision_home, "data"),
                              "XDG_CONFIG_HOME" => File.join(collision_home, "config"))
    collision = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: collision_env,
                                              out: StringIO.new, err: StringIO.new)
    assert_equal 1, collision.run("install", claude_bin: @fake_claude)

    old = write_executable("old-claude", "#!/bin/sh\necho 'Claude Code 2.1.0'\n")
    rejected = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: env,
                                             out: StringIO.new, err: StringIO.new)
    assert_equal 1, rejected.run("upgrade", claude_bin: old)
  end

  def test_installer_rejects_missing_unparseable_recursive_and_symlink_loop_claude
    install_home = File.join(@temporary_root, "installer-reject")
    env = {"HOME" => install_home, "PATH" => File.join(@temporary_root, "empty-bin"),
           "XDG_DATA_HOME" => File.join(install_home, "data"), "XDG_CONFIG_HOME" => File.join(install_home, "config")}
    FileUtils.mkdir_p(env["PATH"])
    installer = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: env,
                                              out: StringIO.new, err: StringIO.new)
    assert_equal 1, installer.run("install")
    unparseable = write_executable("unparseable", "#!/bin/sh\necho unknown\n")
    assert_equal 1, installer.run("install", claude_bin: unparseable)
    source_launcher = File.join(ClaudeExploreHarness::SOURCE_RUNTIME, "bin", "claude-explore")
    assert_equal 1, installer.run("install", claude_bin: source_launcher)
    loop_a = File.join(@temporary_root, "loop-a")
    loop_b = File.join(@temporary_root, "loop-b")
    File.symlink(loop_b, loop_a)
    File.symlink(loop_a, loop_b)
    assert_equal 1, installer.run("install", claude_bin: loop_a)
  end

  def test_failed_upgrade_does_not_switch_the_active_launcher
    install_home = File.join(@temporary_root, "failed-upgrade-home")
    env = {"HOME" => install_home, "PATH" => @fake_bin, "XDG_DATA_HOME" => File.join(install_home, "data"),
           "XDG_CONFIG_HOME" => File.join(install_home, "config")}
    installer = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: env,
                                              out: StringIO.new, err: StringIO.new)
    assert_equal 0, installer.run("install", claude_bin: @fake_claude)
    launcher = File.join(install_home, ".local", "bin", "claude-explore")
    original_target = File.realpath(launcher)

    broken_source = File.join(@temporary_root, "broken-source")
    FileUtils.cp_r(ClaudeExploreHarness::SOURCE_RUNTIME, broken_source)
    File.write(File.join(broken_source, "policy.yml"), "schema_version: 999\n")
    failed = ClaudeExplore::Installer.new(source_root: broken_source, env: env, out: StringIO.new, err: StringIO.new)
    assert_equal 1, failed.run("upgrade")
    assert_equal original_target, File.realpath(launcher)
  end

  def test_installer_rejects_unsafe_directories_and_uninstall_refuses_hostile_symlink
    unsafe_home = File.join(@temporary_root, "unsafe-home")
    unsafe_bin = File.join(unsafe_home, ".local", "bin")
    FileUtils.mkdir_p(unsafe_bin)
    File.chmod(0o777, unsafe_bin)
    unsafe_env = {"HOME" => unsafe_home, "PATH" => @fake_bin,
                  "XDG_DATA_HOME" => File.join(unsafe_home, "data"), "XDG_CONFIG_HOME" => File.join(unsafe_home, "config")}
    unsafe = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: unsafe_env,
                                          out: StringIO.new, err: StringIO.new)
    assert_equal 1, unsafe.run("install", claude_bin: @fake_claude)

    owned_home = File.join(@temporary_root, "owned-home")
    owned_env = {"HOME" => owned_home, "PATH" => @fake_bin,
                 "XDG_DATA_HOME" => File.join(owned_home, "data"), "XDG_CONFIG_HOME" => File.join(owned_home, "config")}
    errors = StringIO.new
    owned = ClaudeExplore::Installer.new(source_root: ClaudeExploreHarness::SOURCE_RUNTIME, env: owned_env,
                                         out: StringIO.new, err: errors)
    assert_equal 0, owned.run("install", claude_bin: @fake_claude)
    data_root = File.join(owned_env["XDG_DATA_HOME"], "agent-development-framework", "claude-explore")
    File.symlink(@fake_claude, File.join(data_root, "hostile-link"))
    assert_equal 1, owned.run("uninstall")
    assert File.exist?(File.join(owned_home, ".local", "bin", "claude-explore"))
    assert_includes errors.string, "unsafe symlink"
  end
end
