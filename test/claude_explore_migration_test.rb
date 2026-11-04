# frozen_string_literal: true

require "digest"
require "json"
require "minitest/autorun"
require_relative "support/claude_explore_harness"

class ClaudeExploreMigrationTest < Minitest::Test
  def setup
    @harness = ClaudeExploreHarness.new
  end

  def teardown
    @harness.cleanup
  end

  def test_inherited_staging_variables_never_authorize_unowned_cleanup
    stage = File.join(@harness.root, "unrelated-stage")
    FileUtils.mkdir_p(stage)
    File.write(File.join(stage, "keep"), "preserve directory contents\n")
    inherited = {"STAGE" => stage}
    %w[STAGED_CURRENT STAGED_LAUNCHER STAGED_METADATA].each do |name|
      path = File.join(@harness.root, name.downcase)
      File.write(path, "preserve unrelated file\n")
      inherited[name] = path
    end
    FileUtils.mkdir_p(File.dirname(@harness.installed_launcher))
    File.write(@harness.installed_launcher, "unowned collision\n")
    before = snapshot(*inherited.values)
    _stdout, _stderr, status = @harness.install(extra_env: inherited)
    refute status.success?
    assert_equal before, snapshot(*inherited.values)
  end

  def test_fresh_install_has_only_the_qualified_ads_entrypoint_and_coexists_with_paf
    paf_before = simulate_paf
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
    assert File.symlink?(@harness.installed_launcher)
    refute File.exist?(legacy_launcher)
    refute File.symlink?(legacy_launcher)
    refute File.exist?(File.join(@harness.home, ".local/bin/claude"))
    assert File.executable?(File.join(@harness.current_runtime, "bin/ads-claude-explore"))
    refute File.exist?(File.join(@harness.current_runtime, "bin/claude-explore"))

    [true, false].each do |ads_first|
      ads_bin = File.dirname(@harness.installed_launcher)
      paf_bin = File.join(@harness.root, "paf/bin")
      directories = ads_first ? [ads_bin, paf_bin] : [paf_bin, ads_bin]
      stdout, stderr, status = @harness.run(
        ["/bin/sh", "-c", "command -v ads-claude-explore; command -v paf-claude-explore"],
        extra_env: {"PATH" => "#{directories.join(":")}:/usr/bin:/bin"}
      )
      assert status.success?, stderr
      resolved = stdout.lines(chomp: true)
      assert_equal File.realpath(@harness.installed_launcher), File.realpath(resolved.fetch(0))
      assert_equal File.realpath(File.join(paf_bin, "paf-claude-explore")), File.realpath(resolved.fetch(1))
    end
    assert_equal paf_before, paf_snapshot
    _stdout, stderr, status = @harness.install("uninstall")
    assert status.success?, stderr
    assert_equal paf_before, paf_snapshot
  end

  def test_fresh_install_preserves_an_unrelated_generic_symlink_without_following_it
    target = File.join(@harness.root, "unrelated-runtime")
    @harness.write_executable(target, "#!/bin/sh\necho unrelated\n")
    FileUtils.mkdir_p(File.dirname(legacy_launcher))
    File.symlink(target, legacy_launcher)
    before = snapshot(target, legacy_launcher)
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
    assert_equal before, snapshot(target, legacy_launcher)
  end

  def test_legacy_upgrade_and_reinstall_preserve_vendor_sessions_evidence_and_paf
    %w[install upgrade].each do |operation|
      reset_harness
      paf_before = simulate_paf
      legacy_install!
      preserved = add_persistent_evidence
      metadata_before = File.binread(@harness.metadata)
      replacement_vendor = @harness.replace_claude
      # A different ambient Claude must not replace the recorded stable launcher.
      alternate_bin = File.join(@harness.root, "alternate-bin")
      @harness.write_executable(File.join(alternate_bin, "claude"), "#!/bin/sh\nexit 99\n")
      stdout, stderr, status = @harness.install(
        operation, claude: nil,
        extra_env: {"PATH" => "#{alternate_bin}:#{@harness.env.fetch("PATH")}"}
      )
      assert status.success?, stderr
      assert_includes stdout, "claude_selection=recorded"
      assert_equal metadata_before, File.binread(@harness.metadata)
      assert_equal preserved, persistent_snapshot
      refute File.symlink?(legacy_launcher)
      assert_equal paf_before, paf_snapshot
      info, stderr, status = @harness.runtime("--claude-explore-runtime-info")
      assert status.success?, stderr
      assert_includes info, "runtime_id=claude-explore"
      assert_includes info, "public_launcher_path=#{@harness.installed_launcher}"
      assert_includes info, "resolved_current_claude_path=#{File.realpath(replacement_vendor)}"
      %w[install upgrade].each do |repeat|
        _stdout, stderr, status = @harness.install(repeat, claude: nil)
        assert status.success?, stderr
        refute File.symlink?(legacy_launcher)
        assert_equal preserved, persistent_snapshot
        assert_equal paf_before, paf_snapshot
      end
      _stdout, stderr, status = @harness.install("uninstall")
      assert status.success?, stderr
      assert_equal paf_before, paf_snapshot
    end
  end

  def test_old_core_layout_without_later_evidence_helpers_can_migrate
    legacy_install!
    active = @harness.current_runtime
    %w[agent_run_telemetry.sh agent_run_usage.sh agent_run_usage_collector.rb agent_run_outcomes.sh].each do |name|
      FileUtils.rm(File.join(active, "lib", name))
    end
    old = File.join(@harness.data_root, "versions/1")
    FileUtils.mv(active, old)
    FileUtils.rm(File.join(@harness.data_root, "current"))
    File.symlink(old, File.join(@harness.data_root, "current"))
    policy = File.join(old, "policy.sh")
    File.write(policy, File.read(policy).sub("CLAUDE_EXPLORE_RUNTIME_VERSION=3", "CLAUDE_EXPLORE_RUNTIME_VERSION=1"))
    File.write(@harness.metadata, File.read(@harness.metadata).sub("runtime_version=3", "runtime_version=1"))
    _stdout, stderr, status = @harness.install("upgrade", claude: nil)
    assert status.success?, stderr
    assert Dir.exist?(old), "other valid historical versions are retained"
    refute File.symlink?(legacy_launcher)
  end

  def test_uninstall_accepts_verified_legacy_qualified_and_consistent_mixed_states
    %i[legacy qualified mixed].each do |state|
      reset_harness
      paf_before = simulate_paf
      (state == :qualified) ? install! : legacy_install!
      add_qualified_link_to_legacy if state == :mixed
      add_persistent_evidence
      vendor_before = snapshot(@harness.claude_target, @harness.claude_launcher)
      unrelated = File.join(@harness.env.fetch("XDG_DATA_HOME"), "unrelated.txt")
      File.write(unrelated, "keep\n")
      _stdout, stderr, status = @harness.install("uninstall")
      assert status.success?, "#{state}: #{stderr}"
      refute File.symlink?(legacy_launcher)
      refute File.symlink?(@harness.installed_launcher)
      refute Dir.exist?(@harness.data_root)
      refute File.exist?(@harness.metadata)
      assert_equal vendor_before, snapshot(@harness.claude_target, @harness.claude_launcher)
      assert_equal "keep\n", File.read(unrelated)
      assert_equal paf_before, paf_snapshot
    end
  end

  def test_consistent_mixed_install_migrates_without_a_dangling_legacy_link
    legacy_install!
    add_qualified_link_to_legacy
    _stdout, stderr, status = @harness.install("upgrade", claude: nil)
    assert status.success?, stderr
    refute File.symlink?(legacy_launcher)
    assert @harness.runtime("--claude-explore-runtime-info").fetch(2).success?
  end

  def test_ambiguous_launchers_metadata_and_unsafe_layouts_leave_all_state_untouched
    mutations = {
      unknown_qualified_file: -> { File.write(@harness.installed_launcher, "personal\n") },
      unknown_qualified_symlink: -> { File.symlink(@harness.claude_target, @harness.installed_launcher) },
      broken_qualified_symlink: -> { File.symlink("/nonexistent/ads-runtime", @harness.installed_launcher) },
      unknown_legacy_symlink: -> {
        FileUtils.rm(legacy_launcher)
        File.symlink(@harness.claude_target, legacy_launcher)
      },
      legacy_direct_version_link: -> {
        FileUtils.rm(legacy_launcher)
        File.symlink(File.join(@harness.current_runtime, "bin/claude-explore"), legacy_launcher)
      },
      inconsistent_qualified_target: -> {
        File.symlink("#{@harness.data_root}/current/bin/claude-explore", @harness.installed_launcher)
      },
      malformed_metadata: -> { File.open(@harness.metadata, "a") { |file| file.puts("unknown=value") } },
      wrong_runtime_id: -> { rewrite_metadata("runtime_id=claude-explore", "runtime_id=other-runtime") },
      wrong_version: -> { rewrite_metadata("runtime_version=3", "runtime_version=2") },
      wrong_recorded_vendor: -> { rewrite_metadata(@harness.claude_launcher, legacy_launcher) },
      unsafe_metadata: -> { File.chmod(0o622, @harness.metadata) },
      unsafe_version: -> { File.chmod(0o722, @harness.current_runtime) },
      unsafe_ancestor: -> { File.chmod(0o777, File.dirname(@harness.data_root)) },
      external_runtime_file: -> {
        path = File.join(@harness.current_runtime, "bin/claude-explore")
        FileUtils.rm(path)
        File.symlink(@harness.claude_target, path)
      },
      unsafe_sessions: -> {
        FileUtils.mkdir_p(@harness.sessions_root)
        File.chmod(0o777, @harness.sessions_root)
      }
    }
    mutations.each do |name, mutate|
      reset_harness
      legacy_install!
      mutate.call
      before = installation_snapshot
      %w[install upgrade uninstall].each do |operation|
        _stdout, stderr, status = @harness.install(operation, claude: nil)
        refute status.success?, "#{name} must reject #{operation}: #{stderr}"
        assert_equal before, installation_snapshot, "#{name}: #{operation} mutated untrusted state"
      end
    end
  end

  def test_qualified_install_rejects_an_unknown_generic_link_before_uninstall
    install!
    File.symlink(@harness.claude_target, legacy_launcher)
    before = installation_snapshot
    _stdout, stderr, status = @harness.install("uninstall")
    refute status.success?
    assert_includes stderr, "not framework-owned"
    assert_equal before, installation_snapshot
  end

  def test_orphaned_metadata_or_launcher_never_proves_ownership
    %i[missing_metadata missing_current missing_public_links].each do |state|
      reset_harness
      legacy_install!
      case state
      when :missing_metadata then FileUtils.rm(@harness.metadata)
      when :missing_current then FileUtils.rm(File.join(@harness.data_root, "current"))
      when :missing_public_links then FileUtils.rm(legacy_launcher)
      end
      before = installation_snapshot
      %w[upgrade uninstall].each do |operation|
        _stdout, _stderr, status = @harness.install(operation, claude: nil)
        refute status.success?, "#{state}: #{operation}"
        assert_equal before, installation_snapshot
      end
    end
  end

  def test_each_migration_failure_restores_the_previous_working_legacy_install
    injections = {
      preflight: ["  preflight_destination", '  die "injected preflight failure"'],
      staging: ['  cp "$SOURCE_ROOT/policy.sh" "$STAGE/policy.sh"', "  false"],
      version: ['  mv "$STAGE" "$ACTIVATION_VERSION_DIR"', "  false"],
      current: ['  mv "$STAGED_CURRENT" "$CURRENT_LINK"', "  false"],
      launcher: ['  mv "$STAGED_LAUNCHER" "$STABLE_LAUNCHER"', "  false"],
      metadata: ['  mv "$STAGED_METADATA" "$METADATA_FILE"', "  false"],
      retirement: ['    mv "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false"],
      final_verification: ['  [ -L "$STABLE_LAUNCHER" ] &&', "  false &&"]
    }
    injections.each do |stage, (before_text, after_text)|
      reset_harness
      paf_before = simulate_paf
      legacy_install!
      add_persistent_evidence
      before = installation_snapshot
      source = @harness.copy_runtime_source
      inject(source, before_text, after_text)
      stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
      refute status.success?, "#{stage}: #{stderr}"
      refute_includes stdout, "3 upgrade"
      refute_includes stderr, "rollback incomplete"
      assert_equal before, installation_snapshot, "#{stage} failed to restore the old installation"
      assert_equal paf_before, paf_snapshot
      _stdout, stderr, status = @harness.run([legacy_launcher, "--claude-explore-runtime-info"])
      assert status.success?, "#{stage}: restored legacy launcher must work: #{stderr}"
      assert_empty transaction_artifacts
    end
  end

  def test_cross_version_retirement_failure_restores_current_metadata_and_legacy_link
    legacy_install!
    before = installation_snapshot
    source = @harness.copy_runtime_source(version: 4)
    inject(source, '    mv "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false")
    _stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    assert_includes stderr, "previous installation restored"
    assert_equal before, installation_snapshot
    refute Dir.exist?(File.join(@harness.data_root, "versions/4"))
  end

  def test_incomplete_rollback_reports_the_exact_path_and_retains_recovery_backup
    legacy_install!
    source = @harness.copy_runtime_source
    inject(source, '    mv "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false")
    inject(source, 'mv "$BACKUP_CURRENT" "$CURRENT_LINK"', "false")
    stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    refute_includes stdout, "3 upgrade"
    assert_includes stderr, "rollback incomplete"
    assert_includes stderr, "path=#{@harness.data_root}/current"
    backups = Dir[File.join(@harness.data_root, ".previous.current.*")]
    assert_equal 1, backups.length
    assert File.symlink?(backups.fetch(0))
    assert_includes stderr, "backup=#{backups.fetch(0)}"
    assert File.symlink?(legacy_launcher)
    assert File.exist?(@harness.metadata)
    refute File.symlink?(@harness.installed_launcher)
  end

  def test_uninstall_failure_keeps_runtime_for_any_remaining_ads_launcher
    legacy_install!
    add_qualified_link_to_legacy
    source = @harness.copy_runtime_source
    inject(source, '    rm "$STABLE_LAUNCHER"', "    false")
    _stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "uninstall")
    refute status.success?
    assert_includes stderr, "runtime state retained"
    assert File.exist?(@harness.installed_launcher)
    assert Dir.exist?(@harness.data_root)
    assert File.exist?(@harness.metadata)
  end

  def test_vendor_resolution_rejects_all_managed_names_before_version_execution
    %w[ads-claude-explore claude-explore paf-claude-explore].each do |name|
      reset_harness
      managed = File.join(@harness.root, name)
      marker = File.join(@harness.root, "wrapper-was-executed")
      @harness.write_executable(managed, "#!/bin/sh\ntouch '#{marker}'\necho 'Claude Code 2.1.224'\n")
      [managed, @harness.claude_launcher].each do |selected|
        if selected == @harness.claude_launcher
          FileUtils.rm(selected)
          File.symlink(managed, selected)
        end
        _stdout, stderr, status = @harness.install(claude: selected)
        refute status.success?
        assert_includes stderr, "managed wrapper"
        refute File.exist?(marker)
      end
    end
  end

  def test_vendor_updater_cannot_turn_a_recorded_launcher_into_a_managed_wrapper
    %w[ads-claude-explore claude-explore paf-claude-explore].each do |name|
      reset_harness
      install!
      managed = File.join(@harness.root, name)
      @harness.write_executable(managed, "#!/bin/sh\nexit 99\n")
      FileUtils.rm(@harness.claude_launcher)
      File.symlink(managed, @harness.claude_launcher)
      _stdout, stderr, status = @harness.runtime("--claude-explore-runtime-info")
      refute status.success?
      assert_includes stderr, "managed wrapper"
    end
  end

  def test_qualified_and_legacy_nested_agent_names_are_blocked_without_delegation
    install!
    %w[ads-claude-explore claude-explore paf-claude-explore].each do |name|
      _stdout, stderr, status = @harness.runtime("--claude-explore-check-command", "--", name)
      assert_equal 126, status.exitstatus, stderr
      assert_includes stderr, "fully-blocked-executable"
      _stdout, stderr, status = @harness.runtime(extra_env: {"FAKE_INNER_SCENARIO" => "blocked", "FAKE_COMMAND" => name})
      assert_equal 126, status.exitstatus, stderr
    end
  end

  private

  def reset_harness
    @harness.cleanup
    @harness = ClaudeExploreHarness.new
    @paf_paths = nil
    @persistent_paths = nil
  end

  def install!
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
  end

  def legacy_launcher
    File.join(@harness.home, ".local/bin/claude-explore")
  end

  # Synthetic legacy metadata/layout: no reliance on Git history or real installs.
  # The core launcher still works before and after fault-injected rollback.
  def legacy_install!
    install!
    active = @harness.current_runtime
    Dir[File.join(active, "{bin,lib}", "*")].each do |path|
      next unless File.file?(path)
      next unless File.basename(path).include?("claude")

      File.write(path, File.read(path).gsub("ads-claude-explore", "claude-explore"))
    end
    File.rename(File.join(active, "bin/ads-claude-explore"), File.join(active, "bin/claude-explore"))
    FileUtils.rm(@harness.installed_launcher)
    File.symlink("#{@harness.data_root}/current/bin/claude-explore", legacy_launcher)
    _stdout, stderr, status = @harness.run([legacy_launcher, "--claude-explore-runtime-info"])
    assert status.success?, stderr
  end

  def add_qualified_link_to_legacy
    source = File.join(@harness.current_runtime, "bin/claude-explore")
    FileUtils.cp(source, File.join(@harness.current_runtime, "bin/ads-claude-explore"))
    File.symlink("#{@harness.data_root}/current/bin/ads-claude-explore", @harness.installed_launcher)
  end

  def add_persistent_evidence
    session = File.join(@harness.sessions_root, "claude-explore.active")
    history = File.join(@harness.env.fetch("AGENT_TELEMETRY_DIR"), "historical-run")
    FileUtils.mkdir_p([session, history])
    File.chmod(0o700, @harness.sessions_root)
    File.chmod(0o700, session)
    File.write(File.join(session, "control"), "active session\n")
    %w[run.json usage.json outcome.json].each { |name| File.write(File.join(history, name), "{\"historical\":\"#{name}\"}\n") }
    @persistent_paths = [session, history]
    persistent_snapshot
  end

  def persistent_snapshot
    snapshot(*@persistent_paths)
  end

  def simulate_paf
    root = File.join(@harness.root, "paf")
    launcher = File.join(root, "bin/paf-claude-explore")
    @harness.write_executable(launcher, "#!/bin/sh\necho simulated-paf\n")
    FileUtils.mkdir_p(File.dirname(@harness.installed_launcher))
    public_launcher = File.join(@harness.home, ".local/bin/paf-claude-explore")
    File.symlink(launcher, public_launcher)
    state = File.join(root, "state")
    FileUtils.mkdir_p(state)
    File.write(File.join(state, "install.meta"), "framework=paf\n")
    @paf_paths = [root, public_launcher]
    paf_snapshot
  end

  def paf_snapshot
    snapshot(*@paf_paths)
  end

  def rewrite_metadata(before, after)
    File.write(@harness.metadata, File.read(@harness.metadata).sub(before, after))
  end

  def inject(source, before, after)
    path = File.join(source, "lib/claude_explore_installer.sh")
    contents = File.read(path)
    assert_includes contents, before
    File.write(path, contents.sub(before, after))
  end

  def installation_snapshot
    snapshot(
      @harness.data_root, File.dirname(@harness.metadata),
      File.dirname(@harness.installed_launcher)
    )
  end

  def snapshot(*roots)
    roots.flat_map do |root|
      [root, *Dir.glob(File.join(root, "**/*"), File::FNM_DOTMATCH)].uniq
    end.sort.filter_map do |path|
      next if %w[. ..].include?(File.basename(path))
      next unless File.exist?(path) || File.symlink?(path)

      stat = File.lstat(path)
      content = if stat.symlink?
        File.readlink(path)
      elsif stat.file?
        File.binread(path)
      end
      [path, stat.ftype, stat.mode & 0o7777, content]
    end
  end

  def transaction_artifacts
    [
      *Dir[File.join(@harness.data_root, ".{previous,current,stage}.*")],
      *Dir[File.join(File.dirname(@harness.metadata), ".{previous,install.meta.tmp}.*")],
      *Dir[File.join(File.dirname(@harness.installed_launcher), ".{previous,ads-claude-explore}.*")]
    ]
  end
end
