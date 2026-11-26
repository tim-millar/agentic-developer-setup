# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class ManageAgentRunsTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/manage_agent_runs.rb", __dir__)

  def setup
    @home = Dir.mktmpdir("ads-agent-runs-home-")
    @data = File.join(@home, "data")
    @bin = File.join(@home, ".local/bin")
    @env = {"HOME" => @home, "XDG_DATA_HOME" => @data, "PATH" => "/usr/bin:/bin"}
  end

  def teardown
    FileUtils.remove_entry_secure(@home)
  end

  def test_install_is_standalone_repeatable_and_refuses_modified_payload
    output, error, status = installer("install")
    assert status.success?, error
    assert_includes output, "Installed"
    executable = File.join(@bin, "ads-agent-runs")
    payload = File.join(@data, "agent-development-framework/agent-runs")
    assert File.executable?(executable)

    output, error, status = Open3.capture3(@env, executable, "--help", chdir: "/tmp")
    assert status.success?, error
    assert_includes output, "Usage: ads-agent-runs"

    output, error, status = installer("status")
    assert status.success?, error
    assert_equal "current", output.strip
    output, error, status = installer("install")
    assert status.success?, error
    assert_includes output, "is current"

    File.write(File.join(payload, "scripts/ads-agent-runs"), "modified")
    output, error, status = installer("status")
    assert status.success?, error
    assert_equal "modified", output.strip
    _, error, status = installer("install")
    refute status.success?
    assert_includes error, "refusing to replace modified installation"
    _, error, status = installer("uninstall")
    refute status.success?
    assert_includes error, "refusing to remove modified installation"
    assert_equal "modified", File.read(File.join(payload, "scripts/ads-agent-runs"))
  end

  def test_foreign_executable_is_left_untouched
    FileUtils.mkdir_p(@bin)
    executable = File.join(@bin, "ads-agent-runs")
    File.write(executable, "foreign executable")
    _, error, status = installer("install")
    refute status.success?
    assert_includes error, "conflicting"
    assert_equal "foreign executable", File.read(executable)
  end

  private

  def installer(command)
    Open3.capture3(@env, RbConfig.ruby, SCRIPT, command)
  end
end
