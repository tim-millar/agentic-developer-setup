# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"
require "yaml"

module ClaudeExploreHarness
  REPOSITORY_ROOT = File.expand_path("../..", __dir__)
  SOURCE_RUNTIME = File.join(REPOSITORY_ROOT, "agent-runtimes", "claude-explore")

  def setup_runtime_fixture
    @temporary_root = Dir.mktmpdir("claude-explore-test-")
    @home = File.join(@temporary_root, "home")
    @runtime_root = File.join(@temporary_root, "installed", "versions", "1")
    @config_home = File.join(@home, ".config")
    @metadata_path = File.join(@config_home, "agent-development-framework", "claude-explore", "installation.yml")
    @fake_bin = File.join(@temporary_root, "fake-bin")
    @fake_log = File.join(@temporary_root, "fake-claude.json")
    FileUtils.mkdir_p([@home, @runtime_root, File.dirname(@metadata_path), @fake_bin])
    %w[bin lib].each { |directory| FileUtils.mkdir_p(File.join(@runtime_root, directory)) }
    copy_runtime_file("bin/claude-explore", 0o700)
    copy_runtime_file("lib/claude_explore.rb", 0o600)
    copy_runtime_file("policy.yml", 0o600)
    @fake_claude = write_executable("claude", fake_claude_source)
    write_metadata
    @launcher = File.join(@runtime_root, "bin", "claude-explore")
  end

  def teardown_runtime_fixture
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
  end

  def runtime_env(extra = {})
    {
      "HOME" => @home,
      "XDG_CONFIG_HOME" => @config_home,
      "PATH" => [@fake_bin, ENV.fetch("PATH", "")].join(File::PATH_SEPARATOR),
      "TMPDIR" => File.join(@temporary_root, "tmp"),
      "FAKE_CLAUDE_LOG" => @fake_log
    }.merge(extra).tap { |env| FileUtils.mkdir_p(env["TMPDIR"]) }
  end

  def run_runtime(*args, env: {}, cwd: nil)
    options = cwd ? {chdir: cwd} : {}
    Open3.capture3(runtime_env(env), RbConfig.ruby, @launcher, *args, options)
  end

  def write_executable(name, contents, directory: @fake_bin)
    FileUtils.mkdir_p(directory)
    path = File.join(directory, name)
    File.write(path, contents)
    File.chmod(0o700, path)
    File.realpath(path)
  end

  def write_metadata(claude_path: @fake_claude)
    metadata = {
      "runtime_id" => "claude-explore",
      "runtime_version" => 1,
      "policy_version" => 1,
      "runtime_path" => @runtime_root,
      "claude_path" => claude_path,
      "source_framework_revision" => "synthetic"
    }
    File.write(@metadata_path, YAML.dump(metadata))
    File.chmod(0o600, @metadata_path)
  end

  def fake_log
    JSON.parse(File.read(@fake_log))
  end

  def policy_data
    YAML.safe_load(File.read(File.join(@runtime_root, "policy.yml")))
  end

  private

  def copy_runtime_file(relative, mode)
    destination = File.join(@runtime_root, relative)
    FileUtils.cp(File.join(SOURCE_RUNTIME, relative), destination)
    File.chmod(mode, destination)
  end

  def fake_claude_source
    <<~'RUBY'
      #!/usr/bin/env ruby
      require "json"
      require "yaml"
      if ARGV == ["--version"]
        puts ENV.fetch("FAKE_CLAUDE_VERSION", "Claude Code 2.1.224")
        exit 0
      end
      settings_index = ARGV.index("--settings")
      settings_path = settings_index && ARGV[settings_index + 1]
      policy = YAML.safe_load(File.read(ENV.fetch("CLAUDE_EXPLORE_POLICY")))
      selected_names = policy.dig("environment", "unset") + %w[
        SAFE_ORDINARY GIT_TERMINAL_PROMPT GCM_INTERACTIVE GH_CONFIG_DIR
        AWS_EC2_METADATA_DISABLED GIT_ASKPASS PATH CLAUDE_EXPLORE_POLICY
      ]
      selected = selected_names.each_with_object({}) { |name, values| values[name] = ENV[name] }
      log = {
        "argv" => ARGV,
        "env" => selected,
        "settings" => settings_path && JSON.parse(File.read(settings_path)),
        "settings_path" => settings_path,
        "gh_config_empty" => ENV["GH_CONFIG_DIR"] && Dir.empty?(ENV["GH_CONFIG_DIR"]),
        "session_mode" => settings_path && (File.stat(File.dirname(settings_path)).mode & 0777),
        "guard_sources" => Dir.glob(File.join(ENV.fetch("PATH").split(File::PATH_SEPARATOR).first, "*")).sort.map { |path| File.read(path) }
      }
      File.write(ENV.fetch("FAKE_CLAUDE_LOG"), JSON.generate(log))
      File.write(ENV.fetch("FAKE_CLAUDE_EDIT"), "edited by fake Claude\n") if ENV["FAKE_CLAUDE_EDIT"]
      if ENV["FAKE_CLAUDE_COMMAND"]
        command = JSON.parse(ENV.fetch("FAKE_CLAUDE_COMMAND"))
        system(*command)
        exit($?.exitstatus || 1)
      end
      if ENV["FAKE_CLAUDE_WAIT"]
        Signal.trap("INT") { exit 77 }
        Signal.trap("TERM") { exit 78 }
        File.write(ENV.fetch("FAKE_CLAUDE_READY"), "ready")
        sleep
      end
      exit Integer(ENV.fetch("FAKE_CLAUDE_EXIT", "0"))
    RUBY
  end
end
