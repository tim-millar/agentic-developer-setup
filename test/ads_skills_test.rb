# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class AdsSkillsTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  SOURCE = File.join(ROOT, "skills/show-me")
  FILES = %w[LICENSE SKILL.md UPSTREAM.md].freeze
  METADATA = ".ads-install.json"
  PINNED_BLOB = "d57a0a0afc2800a4cc7a7765e65a9c6c18e67b4f"
  OWNER = "tim-millar/agentic-developer-setup"

  def setup
    @tmp = File.realpath(Dir.mktmpdir("ads-skills-test-"))
    @home = File.join(@tmp, "home with spaces")
    @cwd = File.join(@tmp, "unrelated")
    @checkout = File.join(@tmp, "checkout")
    @script = File.join(@checkout, "scripts/ads-skills.rb")
    @source = File.join(@checkout, "skills/show-me")
    @claude = File.join(@home, ".claude/skills/show-me")
    @codex = File.join(@home, ".agents/skills/show-me")
    FileUtils.mkdir_p([@home, @cwd, File.dirname(@script), @source])
    FileUtils.cp(File.join(ROOT, "scripts/ads-skills.rb"), @script)
    FILES.each { |name| FileUtils.cp(File.join(SOURCE, name), @source) }
  end

  def teardown
    FileUtils.remove_entry(@tmp)
  end

  def test_pinned_git_blob
    skill = File.binread(File.join(SOURCE, "SKILL.md"))
    assert_equal PINNED_BLOB, Digest::SHA1.hexdigest("blob #{skill.bytesize}\0".b + skill)
  end

  def test_combined_install_from_unrelated_cwd_is_standalone_and_checkout_independent
    guard = prelude(<<~RUBY)
      require "socket"
      [Socket, TCPSocket, UDPSocket].each do |klass|
        def klass.new(*)
          raise "unexpected network access"
        end
      end
      def Socket.tcp(*)
        raise "unexpected network access"
      end
    RUBY

    output = succeed("install", "show-me", preload: guard)
    {claude: @claude, codex: @codex}.each do |agent, target|
      assert_includes output, "#{agent} #{target}: installed"
      assert_installed(target)
    end
    assert_empty Dir.children(@cwd)
    refute_workspaces

    before = snapshot(@home)
    output = succeed("install", "show-me", "--agent", "both", preload: guard)
    assert_includes output, "claude #{@claude}: current"
    assert_includes output, "codex #{@codex}: current"
    assert_equal before, snapshot(@home)

    output = succeed("status", "show-me", preload: guard)
    assert_includes output, "claude #{@claude}: current"
    assert_includes output, "codex #{@codex}: current"
    assert_equal before, snapshot(@home)
    File.rename(@checkout, File.join(@tmp, "moved"))
    assert_equal before, snapshot(@home)
    [@claude, @codex].each do |target|
      assert_installed(target, source: SOURCE)
    end
  end

  def test_claude_only_leaves_codex_untouched
    succeed("install", "show-me", "--agent", "claude")
    assert_installed(@claude)
    refute_path_exists File.join(@home, ".agents")
    succeed("uninstall", "show-me", "--agent", "claude")
    refute_path_exists @claude
    refute_path_exists File.join(@home, ".agents")
  end

  def test_codex_only_leaves_claude_untouched
    FileUtils.mkdir_p(@claude)
    File.write(File.join(@claude, "keep"), "foreign skill")
    before = snapshot(@claude)
    succeed("install", "show-me", "--agent", "codex")
    assert_installed(@codex)
    assert_equal before, snapshot(@claude)
    succeed("uninstall", "show-me", "--agent", "codex")
    assert_equal before, snapshot(@claude)
  end

  def test_explicit_update_from_changed_canonical_bundle
    succeed("install", "show-me")
    previous = snapshot(@home)
    change_source
    output = reject("status", "show-me")
    assert_includes output, "claude #{@claude}: outdated"
    assert_includes output, "codex #{@codex}: outdated"
    assert_equal previous, snapshot(@home)

    output = succeed("install", "show-me")
    assert_includes output, "claude #{@claude}: updated"
    assert_includes output, "codex #{@codex}: updated"
    [@claude, @codex].each { |target| assert_installed(target) }
    succeed("status", "show-me")
    refute_workspaces
  end

  def test_locally_modified_managed_copy_is_preserved
    install_claude
    File.write(File.join(@claude, "SKILL.md"), "local changes")
    change_source
    assert_blocked("modified")
  end

  def test_unmanaged_copy_with_identical_bytes_is_preserved
    FileUtils.mkdir_p(@claude)
    FILES.each { |name| FileUtils.cp(File.join(@source, name), @claude) }
    assert_blocked("conflict")
  end

  def test_foreign_manager_and_invalid_manifests_are_conflicts
    install_claude
    marker = File.join(@claude, METADATA)
    original = File.binread(marker)
    record = JSON.parse(original)
    corruptions = [
      record.merge("managed_by" => "another/tool"),
      record.merge("schema_version" => 2),
      record.merge("schema_version" => 1.0),
      record.merge("skill" => "another-skill"),
      record.merge("extra" => true),
      record.merge("files" => record["files"].merge("SKILL.md" => "not a digest")),
      record.merge("files" => record["files"].except("SKILL.md")),
      record.merge("files" => record["files"].merge("extra" => record["files"]["SKILL.md"])),
      [],
      nil
    ].map { |value| JSON.generate(value) }
    corruptions.concat([
      "{",
      original.sub('"schema_version": 1', '"schema_version": 9, "schema_version": 1'),
      original.b.sub("sha256:", "\xFF".b),
      original.sub(/sha256:[0-9a-f]{64}/, '\udc00')
    ])
    corruptions.each do |contents|
      File.binwrite(marker, contents)
      assert_blocked("conflict")
    end
  end

  def test_valid_digest_of_wrong_bytes_is_modified
    install_claude
    marker = File.join(@claude, METADATA)
    record = JSON.parse(File.read(marker))
    record["files"]["LICENSE"] = "sha256:#{"0" * 64}"
    File.write(marker, JSON.generate(record))
    assert_blocked("modified")
  end

  def test_missing_managed_file_and_extra_entries_are_modified
    install_claude
    path = File.join(@claude, "LICENSE")
    File.unlink(path)
    assert_blocked("modified")

    FileUtils.cp(File.join(@source, "LICENSE"), path)
    extra = File.join(@claude, ".extra")
    File.write(extra, "keep")
    assert_blocked("modified")

    File.unlink(extra)
    Dir.mkdir(extra)
    File.write(File.join(extra, "nested"), "keep")
    assert_blocked("modified")
  end

  def test_managed_file_and_metadata_symlinks_are_preserved
    install_claude
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    {"SKILL.md" => "modified", METADATA => "conflict"}.each do |name, state|
      path = File.join(@claude, name)
      other = File.join(outside, name)
      File.rename(path, other)
      File.symlink(other, path)
      before = snapshot(outside)
      assert_blocked(state)
      assert_equal before, snapshot(outside)
      File.unlink(path)
      File.rename(other, path)
    end
  end

  def test_file_and_both_kinds_of_target_symlinks_are_conflicts
    FileUtils.mkdir_p(File.dirname(@claude))
    File.write(@claude, "keep")
    assert_blocked("conflict")
    File.unlink(@claude)

    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "keep"), "safe")
    before = snapshot(outside)
    [outside, File.join(@tmp, "absent")].each do |point|
      File.symlink(point, @claude)
      assert_blocked("conflict")
      assert_equal before, snapshot(outside)
      File.unlink(@claude)
    end
  end

  def test_unsafe_parent_components_block_combined_operations
    outside = File.join(@tmp, "outside")
    Dir.mkdir(outside)
    File.write(File.join(outside, "keep"), "safe")
    before = snapshot(outside)
    agent_dir = File.join(@home, ".agents")
    File.symlink(outside, agent_dir)
    assert_second_agent_conflict
    File.unlink(agent_dir)

    Dir.mkdir(agent_dir)
    skills_dir = File.join(agent_dir, "skills")
    File.symlink(File.join(@tmp, "absent"), skills_dir)
    assert_second_agent_conflict
    File.unlink(skills_dir)

    File.write(skills_dir, "keep")
    assert_second_agent_conflict
    assert_equal before, snapshot(outside)
  end

  def test_mixed_status_reports_every_target_and_leaves_home_unchanged
    before = snapshot(@home)
    output = reject("status", "show-me")
    assert_includes output, "claude #{@claude}: missing"
    assert_includes output, "codex #{@codex}: missing"
    assert_equal before, snapshot(@home)

    install_claude
    before = snapshot(@home)
    output = reject("status", "show-me", "--agent", "both")
    assert_includes output, "claude #{@claude}: current"
    assert_includes output, "codex #{@codex}: missing"
    assert_equal before, snapshot(@home)
    succeed("status", "show-me", "--agent", "claude")
  end

  def test_second_agent_conflict_blocks_update_and_uninstall_of_first
    install_claude
    FileUtils.mkdir_p(@codex)
    File.write(File.join(@codex, "keep"), "foreign skill")
    change_source
    before = snapshot(@home)
    %w[install uninstall].each do |operation|
      output = reject(operation, "show-me")
      assert_includes output, "codex #{@codex}: conflict"
      assert_includes output, "blocked for all selected agents"
      assert_equal before, snapshot(@home)
    end
  end

  def test_uninstall_preserves_siblings_and_parent_permissions_and_can_repeat
    succeed("install", "show-me")
    sibling = File.join(File.dirname(@claude), "other-skill")
    Dir.mkdir(sibling, 0o750)
    File.write(File.join(sibling, "SKILL.md"), "unrelated")
    parents = [File.dirname(@claude), File.dirname(@codex)]
    File.chmod(0o750, parents.first)
    modes = parents.map { |path| File.stat(path).mode }
    sibling_before = snapshot(sibling)

    output = succeed("uninstall", "show-me")
    assert_includes output, "claude #{@claude}: removed"
    assert_includes output, "codex #{@codex}: removed"
    [@claude, @codex].each { |path| refute_path_exists path }
    assert_equal sibling_before, snapshot(sibling)
    assert_equal modes, parents.map { |path| File.stat(path).mode }

    before = snapshot(@home)
    output = succeed("uninstall", "show-me")
    assert_includes output, "claude #{@claude}: missing"
    assert_includes output, "codex #{@codex}: missing"
    assert_equal before, snapshot(@home)
    refute_workspaces
  end

  def test_invalid_source_is_rejected_and_does_not_prevent_owned_uninstall
    install_claude
    File.unlink(File.join(@source, "LICENSE"))
    File.symlink(File.join(SOURCE, "LICENSE"), File.join(@source, "LICENSE"))
    before = snapshot(@home)
    assert_includes reject("install", "show-me"), "cannot read canonical show-me bundle"
    output = reject("status", "show-me")
    assert_includes output, "claude #{@claude}: status unavailable"
    assert_includes output, "codex #{@codex}: status unavailable"
    assert_equal before, snapshot(@home)
    succeed("uninstall", "show-me")
    refute_path_exists @claude
  end

  def test_staging_write_failure_publishes_neither_target
    fault = file_fault(<<~RUBY)
      def open(path, *args, &block)
        if path.include?("/.agents/skills/.ads-show-me-") && path.end_with?("/new/UPSTREAM.md")
          raise Errno::ENOSPC, "injected staging failure"
        end
        super
      end
    RUBY

    output = reject("install", "show-me", preload: fault)
    assert_includes output, "injected staging failure"
    assert_includes output, "claude #{@claude}: missing"
    assert_includes output, "codex #{@codex}: missing"
    assert_empty Dir.children(@home)
  end

  def test_failed_first_replacement_recovers_original
    install_claude
    original = snapshot(@claude)
    change_source
    fault = rename_fault(agent: ".claude")

    output = reject("install", "show-me", "--agent", "claude", preload: fault)
    assert_includes output, "injected replacement failure"
    assert_includes output, "claude #{@claude}: outdated"
    assert_equal original, snapshot(@claude)
    refute_workspaces
  end

  def test_second_replacement_failure_restores_both_originals
    succeed("install", "show-me")
    originals = [snapshot(@claude), snapshot(@codex)]
    change_source

    output = reject("install", "show-me", preload: rename_fault(agent: ".agents"))
    assert_includes output, "injected replacement failure"
    assert_includes output, "claude #{@claude}: outdated"
    assert_includes output, "codex #{@codex}: outdated"
    assert_equal originals, [snapshot(@claude), snapshot(@codex)]
    refute_workspaces
  end

  def test_second_uninstall_failure_restores_first_target
    succeed("install", "show-me")
    originals = [snapshot(@claude), snapshot(@codex)]
    fault = file_fault(<<~RUBY)
      def rename(from, to)
        if from.end_with?("/.agents/skills/show-me") && to.end_with?("/previous")
          raise Errno::EACCES, "injected uninstall failure"
        end
        super
      end
    RUBY

    output = reject("uninstall", "show-me", preload: fault)
    assert_includes output, "injected uninstall failure"
    assert_equal originals, [snapshot(@claude), snapshot(@codex)]
    refute_workspaces
  end

  def test_failed_restoration_reports_and_retains_original_snapshot
    install_claude
    original = snapshot(@claude)
    change_source
    fault = rename_fault(agent: ".claude", fail_restore: true)
    output = reject("install", "show-me", "--agent", "claude", preload: fault)

    assert_includes output, "restoration failed for #{@claude}"
    assert_includes output, "workspace retained for recovery"
    refute_path_exists @claude
    workspace, = Dir.glob(File.join(File.dirname(@claude), ".ads-show-me-*"))
    assert_path_exists workspace
    assert_includes output, workspace
    assert_equal original, snapshot(File.join(workspace, "previous"))
    assert_installed(File.join(workspace, "new"))
  end

  def test_cleanup_failure_reports_applied_updates_and_retains_backup
    succeed("install", "show-me")
    original = snapshot(@codex)
    change_source
    fault = file_fault(<<~RUBY)
      def unlink(path)
        if path.include?("/.agents/skills/.ads-show-me-") && path.include?("/previous/")
          raise Errno::EACCES, "injected cleanup failure"
        end
        super
      end
    RUBY

    output = reject("install", "show-me", preload: fault)
    assert_includes output, "injected cleanup failure"
    assert_includes output, "install applied, but workspace cleanup failed"
    succeed("status", "show-me")
    [@claude, @codex].each { |target| assert_installed(target) }
    workspace, = Dir.glob(File.join(File.dirname(@codex), ".ads-show-me-*"))
    assert_includes output, workspace
    assert_equal original, snapshot(File.join(workspace, "previous"))
    assert_empty Dir.glob(File.join(File.dirname(@claude), ".ads-show-me-*"))
  end

  def test_invalid_home_and_arguments_leave_disposable_directories_unchanged
    home_link = File.join(@tmp, "home-link")
    home_file = File.join(@tmp, "home-file")
    File.symlink(@home, home_link)
    File.write(home_file, "keep")
    before = snapshot(@tmp)

    [nil, "", "relative/home", "/", File.join(@tmp, "missing"), home_link, home_file, "#{home_link}/.."].each do |home|
      assert_includes reject("install", "show-me", home: home), "HOME"
      assert_equal before, snapshot(@tmp)
    end
    [
      [], ["install"], %w[update show-me], %w[install other], %w[install show-me --force],
      %w[install show-me --agent], %w[install show-me --agent nobody],
      %w[install show-me --agent both --force], %w[install show-me --help]
    ].each do |args|
      assert_includes reject(*args), "Invalid arguments"
      assert_equal before, snapshot(@tmp)
    end
    assert_includes succeed("--help", home: nil), "Usage:"
    assert_equal before, snapshot(@tmp)
  end

  private

  def invoke(*args, home: @home, preload: nil)
    command = [RbConfig.ruby, "--disable-gems"]
    command.concat(["-r", preload]) if preload
    Open3.capture3({"HOME" => home, "PATH" => File.join(@tmp, "no-executables")},
      *command, @script, *args, chdir: @cwd, unsetenv_others: true)
  end

  def succeed(*args, **options)
    stdout, stderr, status = invoke(*args, **options)
    assert status.success?, "#{args.inspect} failed\n#{stdout}#{stderr}"
    assert_empty stderr
    stdout
  end

  def reject(*args, **options)
    stdout, stderr, status = invoke(*args, **options)
    assert status.exited?, "#{args.inspect} exited abnormally"
    refute status.success?, "#{args.inspect} succeeded\n#{stdout}#{stderr}"
    stdout + stderr
  end

  def install_claude
    succeed("install", "show-me", "--agent", "claude")
  end

  def change_source
    File.open(File.join(@source, "SKILL.md"), "ab") { |file| file.write("\nnew canonical content\n") }
  end

  def assert_installed(path, source: @source)
    assert File.lstat(path).directory?
    assert_equal [METADATA, *FILES], Dir.children(path).sort
    record = JSON.parse(File.binread(File.join(path, METADATA)))
    assert File.lstat(File.join(path, METADATA)).file?
    hashes = FILES.to_h do |name|
      file = File.join(path, name)
      assert File.lstat(file).file?
      bytes = File.binread(file)
      assert_equal File.binread(File.join(source, name)), bytes
      [name, "sha256:#{Digest::SHA256.hexdigest(bytes)}"]
    end
    assert_equal({"schema_version" => 1, "managed_by" => OWNER, "skill" => "show-me", "files" => hashes}, record)
  end

  def assert_blocked(state)
    before = snapshot(@home)
    %w[status install uninstall].each do |operation|
      output = reject(operation, "show-me", "--agent", "claude")
      assert_includes output, "claude #{@claude}: #{state}"
      assert_equal before, snapshot(@home)
    end
  end

  def assert_second_agent_conflict
    before = snapshot(@home)
    %w[status install uninstall].each do |operation|
      output = reject(operation, "show-me")
      assert_includes output, "claude #{@claude}: missing"
      assert_includes output, "codex #{@codex}: conflict"
      assert_equal before, snapshot(@home)
    end
    refute_path_exists File.join(@home, ".claude")
  end

  def snapshot(path)
    stat = File.lstat(path)
    content = if stat.directory?
      Dir.children(path).sort.to_h { |name| [name, snapshot(File.join(path, name))] }
    elsif stat.symlink?
      File.readlink(path)
    else
      File.binread(path)
    end
    [stat.mode, stat.ino, stat.mtime, content]
  end

  def refute_workspaces
    assert_empty Dir.glob(File.join(@home, "{.claude,.agents}", "skills", ".ads-show-me-*"))
  end

  def prelude(code)
    path = File.join(@tmp, "preload.rb")
    File.write(path, code)
    path
  end

  def file_fault(code)
    prelude("File.singleton_class.prepend(Module.new do\n#{code}end)\n")
  end

  def rename_fault(agent:, fail_restore: false)
    file_fault(<<~RUBY)
      def rename(from, to)
        if (from.end_with?("/new") || (#{fail_restore} && from.end_with?("/previous"))) &&
            to.end_with?(#{"/#{agent}/skills/show-me".inspect})
          raise Errno::EACCES, "injected replacement failure"
        end
        super
      end
    RUBY
  end
end
