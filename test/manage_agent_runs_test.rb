# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../scripts/manage_agent_runs"

class ManageAgentRunsTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/manage_agent_runs.rb", __dir__)
  FILES = AgentRunsInstaller::FILES
  MANIFEST = AgentRunsInstaller::MANIFEST

  def setup
    @home = Dir.mktmpdir("ads-agent-runs-home-")
    @data = File.join(@home, "data")
    @bin = File.join(@home, ".local/bin")
    @payload = File.join(@data, "agent-development-framework/agent-runs")
    @exe = File.join(@bin, "ads-agent-runs")
    @env = {"HOME" => @home, "XDG_DATA_HOME" => @data, "PATH" => "/usr/bin:/bin"}
  end

  def teardown
    FileUtils.remove_entry_secure(@home) if @home && File.exist?(@home)
  end

  def test_complete_lifecycle_preserves_unrelated_executables_and_telemetry
    unrelated = File.join(@home, ".local/bin/ads-skills")
    telemetry = File.join(@data, "agent-development-framework/telemetry/runs/run-synthetic/task.txt")
    FileUtils.mkdir_p(File.dirname(unrelated))
    File.write(unrelated, "other ADS executable")
    FileUtils.mkdir_p(File.dirname(telemetry))
    File.write(telemetry, "private synthetic task")

    output, error, status = installer("status")
    assert status.success?, error
    assert_equal "missing", output.strip
    refute File.exist?(@exe)
    refute File.exist?(@payload)
    output, error, status = installer("install")
    assert status.success?, error
    assert_includes output, "Installed"
    assert File.executable?(@exe)
    assert_equal "current", installer("status")[0].strip
    output, error, status = installer("install")
    assert status.success?, error
    assert_includes output, "is current"
    output, error, status = Open3.capture3(@env, @exe, "show", "--help", chdir: "/tmp")
    assert status.success?, error
    assert_includes output, "<run_id|unique-prefix|latest>"

    _, error, status = installer("uninstall")
    assert status.success?, error
    assert_equal "other ADS executable", File.read(unrelated)
    assert_equal "private synthetic task", File.read(telemetry)
    refute File.exist?(@exe)
    refute File.exist?(@payload)
    assert installer("uninstall")[2].success?
  end

  def test_legacy_valid_package_is_outdated_and_upgrades_to_current
    assert installer("install")[2].success?
    manifest_path = File.join(@payload, MANIFEST)
    current = JSON.parse(File.read(manifest_path))
    files = current.fetch("files")
    old_bundle = Digest::SHA256.hexdigest(FILES.map { |name| "#{name}\0#{files.fetch(name)}" }.join("\n"))
    legacy = {"owner" => AgentRunsInstaller::OWNER, "version" => "1", "bundle_digest" => old_bundle,
              "files" => files, "executable_sha256" => current.fetch("executable_sha256")}
    File.write(manifest_path, JSON.generate(legacy))
    source = copy_source
    File.open(File.join(source, "lib/agent_run_cli.rb"), "a") { |file| file.write("\n# synthetic source update\n") }

    output, error, status = invoke("status", source_root: source)
    assert status.success?, error
    assert_equal "outdated", output.strip
    output, error, status = invoke("install", source_root: source)
    assert status.success?, error
    assert_includes output, "Installed"
    assert_equal File.binread(File.join(source, "lib/agent_run_cli.rb")), File.binread(File.join(@payload, "lib/agent_run_cli.rb"))
    output, error, status = invoke("status", source_root: source)
    assert status.success?, error
    assert_equal "current", output.strip
    help, error, status = Open3.capture3(@env, @exe, "--help", chdir: "/tmp")
    assert status.success?, error
    assert_includes help, "Usage: ads-agent-runs"
  end

  def test_foreign_executable_and_foreign_payload_are_refused_without_changes
    FileUtils.mkdir_p(@bin)
    File.write(@exe, "foreign executable")
    _, error, status = installer("install")
    refute status.success?
    assert_includes error, "conflicting"
    assert_equal "foreign executable", File.read(@exe)

    FileUtils.rm(@exe)
    FileUtils.mkdir_p(@payload)
    File.write(File.join(@payload, "foreign.txt"), "foreign payload")
    _, _, status = installer("install")
    refute status.success?
    assert_equal "foreign payload", File.read(File.join(@payload, "foreign.txt"))
  end

  def test_symlinked_installation_objects_are_refused_and_targets_preserved
    install
    external = File.join(@home, "external")
    FileUtils.mkdir_p(external)
    sentinel = File.join(external, "sentinel")
    File.write(sentinel, "do not remove")
    FileUtils.rm(@exe)
    File.symlink(sentinel, @exe)
    assert_refused_without_changes(sentinel, "do not remove")

    wrapper = File.binread(@exe)
    before_payload = Digest::SHA256.file(File.join(@payload, "lib/agent_run_cli.rb")).hexdigest
    FileUtils.rm(@exe)
    File.write(@exe, wrapper)
    move_payload = "#{@payload}.real"
    File.rename(@payload, move_payload)
    File.symlink(move_payload, @payload)
    assert_conflict_and_refusal
    assert_equal "do not remove", File.read(sentinel)
    assert_equal before_payload, Digest::SHA256.file(File.join(move_payload, "lib/agent_run_cli.rb")).hexdigest
  end

  def test_symlinked_manifest_subdirectory_file_dangling_and_unexpected_entries_conflict
    install
    outside = File.join(@home, "outside")
    File.write(outside, "external sentinel")
    payload_file = File.join(@payload, "lib/agent_run_cli.rb")
    FileUtils.rm(payload_file)
    File.symlink(outside, payload_file)
    assert_refused_without_changes(outside, "external sentinel")
    FileUtils.rm(payload_file)

    File.symlink(outside, File.join(@payload, "odd-link"))
    assert_conflict_and_refusal
    FileUtils.rm(File.join(@payload, "odd-link"))
    Dir.mkdir(File.join(@payload, "empty-unexpected"))
    assert_conflict_and_refusal
    Dir.rmdir(File.join(@payload, "empty-unexpected"))
    File.write(File.join(@payload, "unexpected.txt"), "sentinel")
    assert_conflict_and_refusal
    FileUtils.rm(File.join(@payload, "unexpected.txt"))

    real_subdirectory = File.join(@payload, "lib/agent_run_reporting.real")
    File.rename(File.join(@payload, "lib/agent_run_reporting"), real_subdirectory)
    File.symlink(real_subdirectory, File.join(@payload, "lib/agent_run_reporting"))
    assert_conflict_and_refusal
    File.unlink(File.join(@payload, "lib/agent_run_reporting"))
    File.rename(real_subdirectory, File.join(@payload, "lib/agent_run_reporting"))

    File.symlink(File.join(@home, "missing-target"), File.join(@payload, "dangling"))
    assert_conflict_and_refusal
  end

  def test_manifest_corruption_and_untrusted_inventory_are_refused
    install
    manifest_path = File.join(@payload, MANIFEST)
    original = File.read(manifest_path)
    cases = [
      original.sub('"manifest_version":2', '"manifest_version":99'),
      original.sub(/"bundle_digest":"[0-9a-f]+"/, '"bundle_digest":"bad"'),
      original.sub(/"bundle_digest":"[0-9a-f]{64}"/, '"bundle_digest":"' + ("0" * 64) + '"'),
      original.sub('"owner":"agent-development-framework/ads-agent-runs"', '"owner":"foreign"'),
      original.sub('"files":{', '"files":{"../outside":"' + ("a" * 64) + '",'),
      original.sub('{"owner":', '{"owner":"foreign","owner":'),
      "malformed manifest sentinel"
    ]
    cases.each_with_index do |content, index|
      refute_equal original, content, "corruption case #{index} must alter the manifest"
      File.write(manifest_path, content)
      assert_conflict_and_refusal
      assert File.file?(manifest_path)
    end
    File.write(manifest_path, original)
    File.symlink(File.join(@home, "missing-manifest"), manifest_path + ".link")
    File.rename(manifest_path, manifest_path + ".saved")
    File.symlink(manifest_path + ".saved", manifest_path)
    assert_conflict_and_refusal
  end

  def test_unsafe_destination_hierarchy_and_special_files_are_refused
    FileUtils.mkdir_p(File.join(@home, ".local"))
    outside = File.join(@home, "outside-bin")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "sentinel"), "keep")
    File.symlink(outside, File.join(@home, ".local/bin"))
    _, error, status = installer("install")
    refute status.success?
    assert_includes error, "unsafe installation"
    assert_equal "keep", File.read(File.join(outside, "sentinel"))
    File.unlink(File.join(@home, ".local/bin"))
    Dir.mkdir(File.join(@home, ".local/bin"), 0o755)

    install
    fifo = File.join(@payload, "unexpected-fifo")
    if system("mkfifo", fifo, out: File::NULL, err: File::NULL)
      assert_conflict_and_refusal
    end
  end

  def test_hardlinked_managed_file_is_not_owned
    install
    path = File.join(@payload, "lib/agent_run_cli.rb")
    external = File.join(@home, "hardlink-copy")
    File.link(path, external)
    assert_conflict_and_refusal
    assert File.file?(path)
    assert_equal File.binread(path), File.binread(external)
  end

  def test_arguments_and_environment_fail_cleanly
    [[], ["bad"], ["install", "extra"]].each do |args|
      _, error, status = Open3.capture3(@env, RbConfig.ruby, SCRIPT, *args)
      assert_equal 2, status.exitstatus
      assert_includes error, "Usage:"
    end
    [{"HOME" => nil}, {"HOME" => "relative"}, {"HOME" => @home, "XDG_DATA_HOME" => "relative"}].each do |env|
      _, error, status = Open3.capture3(@env.merge(env), RbConfig.ruby, SCRIPT, "install")
      refute status.success?
      assert_match(/HOME|XDG_DATA_HOME/, error)
      refute File.exist?(@payload)
    end
  end

  def test_injected_initial_install_and_update_failures_preserve_usable_state
    source = copy_source
    initial_failure = failing_installer(1)
    _, error, status = capture_invoke(initial_failure, "install", source)
    refute status.success?
    assert_includes error, "injected move failure"
    assert_equal "missing", invoke("status")[0].strip
    assert_empty Dir.glob(File.join(@bin, ".ads-agent-runs-*")) if File.directory?(@bin)

    assert invoke("install")[2].success?
    before_payload = Dir.glob(File.join(@payload, "**/*"), File::FNM_DOTMATCH).reject { |p| File.directory?(p) }.sort.to_h { |p| [p.delete_prefix(@payload + "/"), File.binread(p)] }
    before_wrapper = File.binread(@exe)
    unrelated_transaction = File.join(@home, "unrelated-transaction")
    File.write(unrelated_transaction, "unrelated transaction sentinel")
    File.write(File.join(@bin, ".ads-agent-runs-foreign"), "foreign transaction sentinel")
    File.open(File.join(source, "lib/agent_run_cli.rb"), "a") { |f| f.write("\n# update\n") }
    update_failure = failing_installer(4)
    _, error, status = capture_invoke(update_failure, "install", source)
    refute status.success?
    assert_includes error, "injected move failure"
    after_payload = Dir.glob(File.join(@payload, "**/*"), File::FNM_DOTMATCH).reject { |p| File.directory?(p) }.sort.to_h { |p| [p.delete_prefix(@payload + "/"), File.binread(p)] }
    assert_equal before_payload, after_payload
    assert_equal before_wrapper, File.binread(@exe)
    assert_equal "current", invoke("status")[0].strip
    help, error, status = Open3.capture3(@env, @exe, "--help", chdir: "/tmp")
    assert status.success?, error
    assert_includes help, "Usage: ads-agent-runs"
    assert_equal "unrelated transaction sentinel", File.read(unrelated_transaction)
    assert_equal "foreign transaction sentinel", File.read(File.join(@bin, ".ads-agent-runs-foreign"))

    # Failure after the old payload has moved but before the old wrapper moves.
    update_failure = failing_installer(2)
    _, error, status = capture_invoke(update_failure, "install", source)
    refute status.success?
    assert_includes error, "injected move failure"
    assert_equal before_payload, Dir.glob(File.join(@payload, "**/*"), File::FNM_DOTMATCH).reject { |p| File.directory?(p) }.sort.to_h { |p| [p.delete_prefix(@payload + "/"), File.binread(p)] }
    assert_equal before_wrapper, File.binread(@exe)
    assert_equal "current", invoke("status")[0].strip
  end

  private

  def installer(command)
    Open3.capture3(@env, RbConfig.ruby, SCRIPT, command)
  end

  def invoke(command, source_root: File.expand_path("..", __dir__))
    out, err = capture_io { @status = AgentRunsInstaller.run([command], env: @env, source_root: source_root) }
    [out, err, Struct.new(:exitstatus) { def success? = exitstatus.zero? }.new(@status)]
  end

  def install
    output, error, status = installer("install")
    assert status.success?, error
    [output, error, status]
  end

  def assert_refused_without_changes(path, content)
    before = File.read(path)
    assert_conflict_and_refusal
    assert_equal content, File.read(path)
    assert_equal before, File.read(path)
  end

  def assert_conflict_and_refusal
    output, error, status = installer("status")
    assert status.success?, error
    assert_match(/conflicting|modified/, output)
    _, error, status = installer("install")
    refute status.success?
    assert_match(/refusing to replace/, error)
    _, error, status = installer("uninstall")
    refute status.success?
    assert_match(/refusing to remove/, error)
  end

  def copy_source
    root = File.join(@home, "source-copy")
    FILES.each do |relative|
      source = File.expand_path("../#{relative}", __dir__)
      target = File.join(root, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
    end
    root
  end

  def failing_installer(fail_at)
    Class.new(AgentRunsInstaller) do
      define_method(:initialize) do |*args, **kwargs|
        super(*args, **kwargs)
        @move_count = 0
      end
      define_method(:move_path) do |source, destination|
        @move_count += 1
        raise "injected move failure" if @move_count == fail_at
        super(source, destination)
      end
    end
  end

  def capture_invoke(klass, command, source_root)
    out, err = capture_io { @status = klass.run([command], env: @env, source_root: source_root) }
    [out, err, Struct.new(:exitstatus) { def success? = exitstatus.zero? }.new(@status)]
  end

  def wrapper_bytes
    File.binread(@exe)
  end
end
