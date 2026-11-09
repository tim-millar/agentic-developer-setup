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

  def test_prepared_fixture_matches_real_installation_and_is_isolated
    _stdout, stderr, status = @harness.install
    assert status.success?, stderr
    roots = [@harness.env.fetch("XDG_DATA_HOME"), @harness.env.fetch("XDG_CONFIG_HOME"), File.join(@harness.home, ".local")]
    signature = -> { snapshot(*roots).map { |path, kind, mode, content| [path, kind, mode, (kind == "file") ? Digest::SHA256.hexdigest(content) : content] } }
    actual_installation = signature.call
    roots.each { |root| FileUtils.remove_entry_secure(root) }
    @harness.prepare_installed_fixture
    assert_equal actual_installation, signature.call

    other = ClaudeExploreHarness.new
    other.prepare_installed_fixture
    other_before = snapshot(other.root)
    File.write(File.join(@harness.current_runtime, "policy.sh"), "changed fixture")
    @harness.cleanup
    assert_equal other_before, snapshot(other.root)
    _stdout, stderr, status = other.runtime("--claude-explore-runtime-info")
    assert status.success?, stderr
  ensure
    other&.cleanup
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
    paf_before = simulate_paf
    preserved = nil
    history_before = nil
    history = File.join(@harness.env.fetch("AGENT_TELEMETRY_DIR"), "historical-run")
    target = File.join(@harness.root, "unrelated-runtime")
    @harness.write_executable(target, "#!/bin/sh\necho unrelated\n")
    FileUtils.mkdir_p(File.dirname(legacy_launcher))
    File.symlink(target, legacy_launcher)
    before = snapshot(target, legacy_launcher)
    %w[install install upgrade uninstall].each do |operation|
      _stdout, stderr, status = @harness.install(operation, claude: nil)
      assert status.success?, "#{operation}: #{stderr}"
      assert_equal before, snapshot(target, legacy_launcher)
      assert_equal paf_before, paf_snapshot
      if operation == "uninstall"
        refute File.symlink?(@harness.installed_launcher)
        refute Dir.exist?(@harness.data_root)
        assert_equal history_before, snapshot(history)
      else
        preserved ||= add_persistent_evidence
        history_before ||= snapshot(history)
        assert_equal preserved, persistent_snapshot
        assert File.symlink?(@harness.installed_launcher)
        assert @harness.runtime("--claude-explore-runtime-info").fetch(2).success?
        assert_empty transaction_artifacts
      end
    end
  end

  def test_fresh_generic_links_to_ads_state_are_rejected_before_target_population
    %w[root descendant].each do |target_kind|
      reset_harness
      FileUtils.mkdir_p(@harness.data_root)
      target = (target_kind == "root") ? @harness.data_root : File.join(@harness.data_root, "unrelated-command")
      sentinel = File.join(@harness.data_root, "keep")
      File.write(sentinel, "unrelated content\n")
      @harness.write_executable(target, "#!/bin/sh\necho keep\n") if target_kind == "descendant"
      FileUtils.mkdir_p(File.dirname(legacy_launcher))
      File.symlink(target, legacy_launcher)
      before = installation_snapshot
      %w[install upgrade].each do |operation|
        _stdout, stderr, status = @harness.install(operation)
        refute status.success?
        assert_includes stderr, "ownership is ambiguous"
        assert_equal before, installation_snapshot
        assert_equal "unrelated content\n", File.read(sentinel)
      end
    end
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
      (state == :qualified) ? prepare_runtime! : legacy_install!
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

  def test_qualified_install_rejects_an_ambiguous_ads_related_generic_link_before_uninstall
    prepare_runtime!
    File.symlink(@harness.data_root, legacy_launcher)
    before = installation_snapshot
    %w[install upgrade uninstall].each do |operation|
      _stdout, stderr, status = @harness.install(operation)
      refute status.success?
      assert_includes stderr, "ownership is ambiguous"
      assert_equal before, installation_snapshot
    end
  end

  def test_qualified_install_rejects_unresolved_or_unsafe_external_generic_targets
    %i[broken directory writable unsafe_ancestor].each do |kind|
      reset_harness
      prepare_runtime!
      target = File.join(@harness.root, "external-command")
      if kind == :directory
        FileUtils.mkdir_p(target)
      elsif kind != :broken
        @harness.write_executable(target, "#!/bin/sh\nexit 0\n")
        File.chmod(0o722, target) if kind == :writable
        if kind == :unsafe_ancestor
          unsafe = File.join(@harness.root, "unsafe")
          FileUtils.mkdir_p(unsafe)
          File.chmod(0o777, unsafe)
          FileUtils.mv(target, File.join(unsafe, "external-command"))
          target = File.join(unsafe, "external-command")
        end
      end
      File.symlink(target, legacy_launcher)
      before = installation_snapshot
      target_before = snapshot(target)
      %w[install upgrade uninstall].each do |operation|
        _stdout, stderr, status = @harness.install(operation)
        refute status.success?, "#{kind}: #{operation}"
        assert_includes stderr, "ownership is ambiguous"
        assert_equal before, installation_snapshot
        assert_equal target_before, snapshot(target)
      end
    end
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
      version: ['  move_to_empty "$STAGE" "$ACTIVATION_VERSION_DIR"', "  false"],
      current: ['  move_to_empty "$STAGED_CURRENT" "$CURRENT_LINK"', "  false"],
      launcher: ['  move_to_empty "$STAGED_LAUNCHER" "$STABLE_LAUNCHER"', "  false"],
      metadata: ['  move_to_empty "$STAGED_METADATA" "$METADATA_FILE"', "  false"],
      retirement: ['    move_to_empty "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false"],
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
    inject(source, '    move_to_empty "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false")
    _stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    assert_includes stderr, "previous installation restored"
    assert_equal before, installation_snapshot
    refute Dir.exist?(File.join(@harness.data_root, "versions/4"))
  end

  def test_incomplete_rollback_reports_the_exact_path_and_retains_recovery_backup
    legacy_install!
    source = @harness.copy_runtime_source
    inject(source, '    move_to_empty "$LEGACY_LAUNCHER" "$BACKUP_LEGACY"', "    false")
    inject(source, '  restore_component "$CURRENT_LINK" "$BACKUP_CURRENT" "$STAGED_CURRENT_ID" "$ORIGINAL_CURRENT_ID"', '  rollback_problem "$CURRENT_LINK" "$BACKUP_CURRENT"')
    stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    refute_includes stdout, "3 upgrade"
    assert_includes stderr, "rollback incomplete"
    assert_includes stderr, "path=#{@harness.data_root}/current"
    backups = Dir[File.join(@harness.data_root, ".transaction.*/previous.current")]
    assert_equal 1, backups.length
    assert File.symlink?(backups.fetch(0))
    backup_path = File.join(File.realpath(File.dirname(backups.fetch(0))), File.basename(backups.fetch(0)))
    assert_includes stderr, "backup=#{backup_path}"
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

  def test_failed_qualified_upgrade_preserves_unrelated_generic_launcher
    paf_before = simulate_paf
    prepare_runtime!
    target = File.join(@harness.root, "unrelated-generic")
    @harness.write_executable(target, "#!/bin/sh\nexit 0\n")
    File.symlink(target, legacy_launcher)
    preserved = add_persistent_evidence
    before = installation_snapshot
    generic_before = snapshot(target, legacy_launcher)
    source = @harness.copy_runtime_source
    inject(source, '  move_to_empty "$STAGED_METADATA" "$METADATA_FILE"', "  false")
    stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    refute_includes stdout, "3 upgrade"
    assert_includes stderr, "previous installation restored"
    refute_includes stderr, "rollback incomplete"
    assert_equal before, installation_snapshot
    assert_equal generic_before, snapshot(target, legacy_launcher)
    assert_equal preserved, persistent_snapshot
    assert_equal paf_before, paf_snapshot
    assert @harness.runtime("--claude-explore-runtime-info").fetch(2).success?
    assert_empty transaction_artifacts
  end

  def test_stale_transaction_names_are_never_adopted_or_cleaned_by_maintenance
    legacy_install!
    external = File.join(@harness.root, "unrelated-sentinel")
    File.write(external, "unrelated bytes\n")
    stale_directory = File.join(@harness.data_root, ".previous.version.stale")
    FileUtils.mkdir_p(stale_directory)
    File.write(File.join(stale_directory, "keep"), "keep stale backup\n")
    stale_link = File.join(File.dirname(@harness.metadata), ".install.meta.tmp.stale")
    File.symlink(external, stale_link)
    stale_launcher = File.join(File.dirname(@harness.installed_launcher), ".previous.ads-claude-explore.stale")
    File.symlink(external, stale_launcher)
    stale_transaction = File.join(@harness.data_root, ".transaction.stale")
    FileUtils.mkdir_p(stale_transaction)
    File.write(File.join(stale_transaction, "keep"), "unknown transaction\n")
    paths = [external, stale_directory, stale_link, stale_launcher, stale_transaction]
    before = snapshot(*paths)
    original_artifacts = transaction_artifacts
    %w[upgrade install upgrade].each do |operation|
      _stdout, stderr, status = @harness.install(operation, claude: nil)
      assert status.success?, stderr
      assert_equal before, snapshot(*paths)
      assert_equal original_artifacts, transaction_artifacts
      assert @harness.runtime("--claude-explore-runtime-info").fetch(2).success?
    end
  end

  def test_all_transaction_slot_collisions_preserve_live_state_and_unrelated_sentinels
    {
      "BACKUP_VERSION" => :directory,
      "BACKUP_CURRENT" => :symlink,
      "BACKUP_LAUNCHER" => :directory,
      "BACKUP_METADATA" => :symlink,
      "BACKUP_LEGACY" => :directory,
      "STAGED_METADATA" => :symlink,
      "STAGED_CURRENT" => :directory,
      "STAGED_LAUNCHER" => :symlink,
      "STAGE" => :directory
    }.each do |slot, kind|
      reset_harness
      assert_preserved_collision(slot, kind, "  check_transaction_slots")
    end
  end

  def test_late_staging_collisions_cannot_follow_links_or_delete_unknown_objects
    {
      "STAGED_METADATA" => "stage_metadata() {",
      "STAGED_CURRENT" => "activate_transaction() {",
      "STAGED_LAUNCHER" => "activate_transaction() {"
    }.each do |slot, hook|
      reset_harness
      assert_preserved_collision(slot, :symlink, hook, after_hook: true)
    end
  end

  def test_late_backup_collision_rolls_back_activated_version_without_nesting
    assert_preserved_collision("BACKUP_CURRENT", :directory, '  if [ -n "$ORIGINAL_CURRENT_ID" ]; then')
    assert @harness.run([legacy_launcher, "--claude-explore-runtime-info"]).fetch(2).success?
  end

  def test_failed_allocation_does_not_grant_cleanup_authority_over_existing_directories
    legacy_install!
    unrelated = File.join(@harness.root, "unowned-transaction")
    FileUtils.mkdir_p(unrelated)
    File.write(File.join(unrelated, "keep"), "preserve unowned directory\n")
    before = installation_snapshot
    unrelated_before = snapshot(unrelated)
    source = @harness.copy_runtime_source
    inject(source,
      '  TX_VERSION=$(new_transaction_dir "$VERSIONS_ROOT_REAL") || die "cannot allocate version transaction"',
      '  TX_VERSION=$TEST_UNOWNED_TRANSACTION; die "injected allocation failure"')
    _stdout, stderr, status = @harness.install_from(
      File.join(source, "install.sh"), "upgrade", claude: nil,
      extra_env: {"TEST_UNOWNED_TRANSACTION" => unrelated}
    )
    refute status.success?
    assert_includes stderr, "injected allocation failure"
    assert_equal before, installation_snapshot
    assert_equal unrelated_before, snapshot(unrelated)
  end

  def test_replaced_transaction_boundary_cannot_authorize_cleanup_through_a_symlink
    legacy_install!
    preserved = add_persistent_evidence
    before = stable_installation_snapshot
    displaced = File.join(@harness.root, "displaced-transaction")
    log = File.join(@harness.root, "transaction-boundary.log")
    source = @harness.copy_runtime_source
    inject(source, "stage_runtime() {", <<~SH)
      stage_runtime() {
        mv "$TX_CONFIG" "$TEST_DISPLACED_TRANSACTION"
        ln -s "$TEST_DISPLACED_TRANSACTION" "$TX_CONFIG"
        printf '%s\\n' "$TX_CONFIG" > "$TEST_TRANSACTION_LOG"
        die "injected boundary replacement"
    SH
    _stdout, stderr, status = @harness.install_from(
      File.join(source, "install.sh"), "upgrade", claude: nil,
      extra_env: {"TEST_DISPLACED_TRANSACTION" => displaced, "TEST_TRANSACTION_LOG" => log}
    )
    refute status.success?
    assert_includes stderr, "transaction directory ownership changed"
    assert_equal before, stable_installation_snapshot
    assert_equal preserved, persistent_snapshot
    boundary = File.read(log).strip
    assert File.symlink?(boundary)
    assert_equal displaced, File.readlink(boundary)
    assert_includes File.read(File.join(displaced, "install.meta")), "runtime_id=claude-explore\n"
    assert_equal ["install.meta"], Dir.children(displaced)
  end

  def test_each_occupied_restoration_destination_preserves_sentinel_and_recovery_backup
    {
      "ACTIVATION_VERSION_DIR" => "BACKUP_VERSION",
      "CURRENT_LINK" => "BACKUP_CURRENT",
      "METADATA_FILE" => "BACKUP_METADATA",
      "STABLE_LAUNCHER" => "BACKUP_LAUNCHER",
      "LEGACY_LAUNCHER" => "BACKUP_LEGACY"
    }.each do |destination, backup|
      reset_harness
      paf_before = simulate_paf
      legacy_install!
      add_qualified_link_to_legacy
      preserved = add_persistent_evidence
      live_path = component_path(destination)
      original = relative_snapshot(live_path)
      before = stable_installation_snapshot
      source = @harness.copy_runtime_source
      log = File.join(@harness.root, "recovery.log")
      displaced = File.join(@harness.root, "displaced-activation")
      inject(source, '  [ -L "$STABLE_LAUNCHER" ] &&', <<~SH)
        if [ -e "$#{destination}" ] || [ -L "$#{destination}" ]; then
          mv "$#{destination}" "$TEST_DISPLACED_ACTIVATION" || exit 99
        fi
        mkdir "$#{destination}" || exit 99
        printf 'unrelated replacement\\n' > "$#{destination}/sentinel"
        printf '%s\\n' "$#{backup}" > "$TEST_RECOVERY_LOG"
        false &&
      SH
      stdout, stderr, status = @harness.install_from(
        File.join(source, "install.sh"), "upgrade", claude: nil,
        extra_env: {"TEST_DISPLACED_ACTIVATION" => displaced, "TEST_RECOVERY_LOG" => log}
      )
      refute status.success?, destination
      refute_includes stdout, "3 upgrade"
      refute_includes stderr, "previous installation restored"
      assert_includes stderr, "rollback incomplete"
      assert_includes stderr, "path=#{live_path}"
      recovery = File.read(log).strip
      assert_includes stderr, "backup=#{recovery}"
      assert_equal original, relative_snapshot(recovery), destination
      assert_equal ["sentinel"], Dir.children(live_path), "rollback must not nest into an occupied #{destination}"
      assert_equal "unrelated replacement\n", File.read(File.join(live_path, "sentinel"))
      assert_equal preserved, persistent_snapshot
      assert_equal paf_before, paf_snapshot
      outside_component = ->(records) { records.reject { |path, *_| path == live_path || path.start_with?("#{live_path}/") } }
      assert_equal outside_component.call(before), outside_component.call(stable_installation_snapshot)
    end
  end

  def test_early_staging_failure_cleans_only_current_allocations
    legacy_install!
    preserved = add_persistent_evidence
    stale = File.join(@harness.data_root, ".transaction.unknown")
    FileUtils.mkdir_p(stale)
    File.write(File.join(stale, "keep"), "unknown transaction\n")
    before = installation_snapshot
    artifacts_before = transaction_artifacts
    source = @harness.copy_runtime_source
    inject(source, '  cp "$SOURCE_ROOT/policy.sh" "$STAGE/policy.sh"', "  false")
    _stdout, stderr, status = @harness.install_from(File.join(source, "install.sh"), "upgrade", claude: nil)
    refute status.success?
    assert_includes stderr, "cannot stage policy"
    assert_equal before, installation_snapshot
    assert_equal artifacts_before, transaction_artifacts
    assert_equal preserved, persistent_snapshot
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
      prepare_runtime!
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
    prepare_runtime!
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

  def prepare_runtime!
    @harness.prepare_installed_fixture
    assert File.symlink?(@harness.installed_launcher)
  end

  def legacy_launcher
    File.join(@harness.home, ".local/bin/claude-explore")
  end

  # Synthetic legacy metadata/layout: no reliance on Git history or real installs.
  # The core launcher still works before and after fault-injected rollback.
  def legacy_install!
    prepare_runtime!
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

  def component_path(name)
    case name
    when "ACTIVATION_VERSION_DIR" then File.join(@harness.data_root, "versions/3")
    when "CURRENT_LINK" then File.join(@harness.data_root, "current")
    when "METADATA_FILE" then @harness.metadata
    when "STABLE_LAUNCHER" then @harness.installed_launcher
    when "LEGACY_LAUNCHER" then legacy_launcher
    end
  end

  def relative_snapshot(root)
    snapshot(root).map { |path, *attributes| [path.delete_prefix(root), *attributes] }
  end

  def stable_installation_snapshot
    installation_snapshot.reject do |path, *_|
      path.split(File::SEPARATOR).any? { |part| part.start_with?(".transaction.") }
    end
  end

  def assert_preserved_collision(slot, kind, hook, after_hook: false)
    paf_before = simulate_paf
    legacy_install!
    preserved = add_persistent_evidence
    before = stable_installation_snapshot
    unrelated = File.join(@harness.root, "unrelated-sentinel")
    File.write(unrelated, "unrelated sentinel bytes\n")
    unrelated_before = snapshot(unrelated)
    log = File.join(@harness.root, "collision.log")
    source = @harness.copy_runtime_source
    create = if kind == :directory
      "  mkdir \"$#{slot}\" && printf 'unknown child\\n' > \"$#{slot}/sentinel\"\n"
    else
      "  ln -s \"$TEST_UNRELATED_SENTINEL\" \"$#{slot}\"\n"
    end
    collision_code = create + "  printf '%s\\n' \"$#{slot}\" > \"$TEST_COLLISION_LOG\"\n"
    replacement = after_hook ? "#{hook}\n#{collision_code}" : "#{collision_code}#{hook}"
    inject(source, hook, replacement)
    stdout, stderr, status = @harness.install_from(
      File.join(source, "install.sh"), "upgrade", claude: nil,
      extra_env: {"TEST_UNRELATED_SENTINEL" => unrelated, "TEST_COLLISION_LOG" => log}
    )
    refute status.success?, "#{slot}: #{stderr}"
    refute_includes stdout, "3 upgrade"
    assert_includes stderr, "occupied"
    assert_equal before, stable_installation_snapshot, slot
    assert_equal unrelated_before, snapshot(unrelated), slot
    assert_equal preserved, persistent_snapshot
    assert_equal paf_before, paf_snapshot
    collision = File.read(log).strip
    assert collision.start_with?("#{File.realpath(@harness.root)}/")
    assert File.basename(File.dirname(collision)).start_with?(".transaction.")
    if kind == :directory
      assert_equal ["sentinel"], Dir.children(collision), "#{slot} must not receive a nested live object"
      assert_equal "unknown child\n", File.read(File.join(collision, "sentinel"))
    else
      assert File.symlink?(collision)
      assert_equal unrelated, File.readlink(collision)
    end
    assert_includes stderr, collision
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
      *Dir[File.join(@harness.data_root, ".{transaction,previous,current,stage}.*")],
      *Dir[File.join(@harness.data_root, "versions/.transaction.*")],
      *Dir[File.join(File.dirname(@harness.metadata), ".{transaction,previous,install.meta.tmp}.*")],
      *Dir[File.join(File.dirname(@harness.installed_launcher), ".{transaction,previous,ads-claude-explore}.*")]
    ]
  end
end
