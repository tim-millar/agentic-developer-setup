#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "find"
require "optparse"
require "open3"
require "pathname"
require "tmpdir"
require "yaml"
require_relative "lib/claude_explore"

module ClaudeExplore
  class Installer
    FILES = %w[bin/claude-explore lib/claude_explore.rb policy.yml].freeze

    def initialize(source_root:, env: ENV, out: $stdout, err: $stderr)
      @source_root = File.realpath(source_root)
      @env = env
      @out = out
      @err = err
      home = env.fetch("HOME")
      @data_root = File.join(env["XDG_DATA_HOME"] || File.join(home, ".local", "share"),
                             "agent-development-framework", RUNTIME_ID)
      @config_root = File.join(env["XDG_CONFIG_HOME"] || File.join(home, ".config"),
                               "agent-development-framework", RUNTIME_ID)
      @launcher = File.join(home, ".local", "bin", RUNTIME_ID)
      @metadata_path = File.join(@config_root, "installation.yml")
    end

    def run(command, claude_bin: nil)
      case command
      when "install" then install(claude_bin: claude_bin)
      when "upgrade" then upgrade(claude_bin: claude_bin)
      when "uninstall" then uninstall
      else raise Error, "expected install, upgrade, or uninstall"
      end
      0
    rescue Error, SystemCallError => e
      @err.puts "claude-explore installer: #{e.message}"
      1
    end

    def install(claude_bin: nil)
      policy = Policy.new(File.join(@source_root, "policy.yml"))
      existing = load_metadata(optional: true)
      if existing && existing["runtime_version"] != RUNTIME_VERSION
        raise Error, "a different runtime version is installed; use upgrade"
      end
      claude, version = resolve_claude(claude_bin, policy)
      validate_destinations!(existing)
      activate(policy, claude, existing: existing)
      @out.puts "installed runtime=#{RUNTIME_ID} version=#{RUNTIME_VERSION} policy=#{policy.policy_version}"
      @out.puts "launcher=#{@launcher}"
      @out.puts "runtime_data=#{version_root}"
      @out.puts "configuration=#{@metadata_path}"
      report_path
      @out.puts "claude_version=#{version}"
    end

    def upgrade(claude_bin: nil)
      existing = load_metadata(optional: false)
      policy = Policy.new(File.join(@source_root, "policy.yml"))
      selected = claude_bin || existing.fetch("claude_path")
      claude, version = resolve_claude(selected, policy)
      validate_destinations!(existing)
      @out.puts "old_runtime_version=#{existing.fetch('runtime_version')}"
      @out.puts "new_runtime_version=#{RUNTIME_VERSION}"
      @out.puts "old_policy_version=#{existing.fetch('policy_version')}"
      @out.puts "new_policy_version=#{policy.policy_version}"
      activate(policy, claude, existing: existing)
      @out.puts "upgrade activated launcher=#{@launcher} claude_version=#{version}"
    end

    def uninstall
      metadata = load_metadata(optional: false)
      validate_destinations!(metadata)
      expected_runtime = File.realpath(metadata.fetch("runtime_path"))
      raise Error, "installed runtime path is not framework-owned" unless expected_runtime.start_with?(File.realpath(@data_root) + File::SEPARATOR)
      prove_owned_tree!(@data_root)
      prove_launcher!(metadata)
      File.unlink(@launcher)
      FileUtils.remove_entry_secure(@data_root)
      File.unlink(@metadata_path)
      remove_empty_directory(@config_root)
      @out.puts "uninstalled runtime=#{RUNTIME_ID}"
      @out.puts "preserved real_claude=#{metadata.fetch('claude_path')}"
    end

    private

    def activate(policy, claude, existing:)
      FileUtils.mkdir_p(File.dirname(@launcher), mode: 0o700)
      FileUtils.mkdir_p(File.dirname(version_root), mode: 0o700)
      FileUtils.mkdir_p(@config_root, mode: 0o700)
      validate_safe_directory!(File.dirname(@launcher))
      validate_safe_directory!(File.dirname(version_root))
      validate_safe_directory!(@config_root)

      staging = Dir.mktmpdir(".claude-explore-install-", File.dirname(version_root))
      begin
        FILES.each do |relative|
          source = File.join(@source_root, relative)
          raise Error, "source runtime file is missing: #{relative}" unless File.file?(source) && !File.symlink?(source)
          destination = File.join(staging, relative)
          FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
          FileUtils.cp(source, destination)
          File.chmod(relative.start_with?("bin/") ? 0o700 : 0o600, destination)
        end
        Policy.new(File.join(staging, "policy.yml"))

        if File.exist?(version_root)
          prove_owned_tree!(version_root)
          FILES.each do |relative|
            destination = File.join(version_root, relative)
            FileUtils.mkdir_p(File.dirname(destination), mode: 0o700)
            FileUtils.cp(File.join(staging, relative), destination)
            File.chmod(relative.start_with?("bin/") ? 0o700 : 0o600, destination)
          end
        else
          File.rename(staging, version_root)
          staging = nil
        end

        metadata = {
          "runtime_id" => RUNTIME_ID,
          "runtime_version" => RUNTIME_VERSION,
          "policy_version" => policy.policy_version,
          "runtime_path" => version_root,
          "claude_path" => claude,
          "source_framework_revision" => source_revision
        }
        atomic_write(@metadata_path, YAML.dump(metadata), 0o600)
        atomic_symlink(File.join(version_root, "bin", RUNTIME_ID), @launcher, existing: existing)
        Runtime.new(runtime_root: version_root, metadata_path: @metadata_path)
      ensure
        FileUtils.remove_entry_secure(staging) if staging && File.directory?(staging)
      end
    end

    def resolve_claude(explicit, policy)
      if explicit
        raise Error, "--claude-bin must be an absolute path" unless Pathname.new(explicit).absolute?
        claude = Executable.canonical(explicit, reject: rejected_launchers)
      else
        claude = Executable.resolve("claude", path: @env.fetch("PATH", ""), reject: rejected_launchers)
      end
      raise Error, "a safe real Claude executable could not be found" unless claude
      version = Executable.version(claude)
      Executable.require_version!(version, policy.minimum_claude_version)
      [claude, version]
    end

    def rejected_launchers
      [File.join(@source_root, "bin", RUNTIME_ID), @launcher]
    end

    def validate_destinations!(metadata)
      [@data_root, @config_root].each do |path|
        next unless File.exist?(path) || File.symlink?(path)
        raise Error, "unsafe symlink in installation path: #{path}" if File.symlink?(path)
        validate_safe_directory!(path)
      end
      return unless File.exist?(@launcher) || File.symlink?(@launcher)
      raise Error, "launcher collision is not owned by this runtime" unless metadata
      prove_launcher!(metadata)
    end

    def prove_launcher!(metadata)
      raise Error, "owned launcher is not a symlink" unless File.symlink?(@launcher)
      raise Error, "launcher is not owned by the current user" unless File.lstat(@launcher).uid == Process.uid
      target = File.realpath(@launcher)
      expected = File.join(File.realpath(metadata.fetch("runtime_path")), "bin", RUNTIME_ID)
      raise Error, "launcher ownership cannot be proven" unless target == expected
    rescue Errno::ENOENT, Errno::ELOOP
      raise Error, "launcher ownership cannot be proven"
    end

    def prove_owned_tree!(root)
      root_real = File.realpath(root)
      Find.find(root) do |path|
        stat = File.lstat(path)
        raise Error, "installation contains an unsafe symlink: #{path}" if stat.symlink?
        raise Error, "installation contains a file owned by another user: #{path}" unless stat.uid == Process.uid
        raise Error, "installation contains group/world-writable material: #{path}" unless (stat.mode & 0o022).zero?
        resolved = File.realpath(path)
        raise Error, "installation path escapes its root: #{path}" unless resolved == root_real || resolved.start_with?(root_real + File::SEPARATOR)
      end
    end

    def validate_safe_directory!(path)
      stat = File.stat(path)
      raise Error, "installation directory is not owned by the current user: #{path}" unless stat.uid == Process.uid
      raise Error, "installation directory is group/world writable: #{path}" unless (stat.mode & 0o022).zero?
    end

    def load_metadata(optional:)
      return nil if optional && !File.exist?(@metadata_path)
      raise Error, "runtime is not installed" unless File.file?(@metadata_path) && !File.symlink?(@metadata_path)
      stat = File.stat(@metadata_path)
      raise Error, "installation metadata is not owned by the current user" unless stat.uid == Process.uid
      raise Error, "installation metadata is group/world writable" unless (stat.mode & 0o022).zero?
      metadata = ClaudeExplore.load_yaml(@metadata_path)
      raise Error, "installation metadata has the wrong runtime identity" unless metadata.is_a?(Hash) && metadata["runtime_id"] == RUNTIME_ID
      metadata
    rescue Psych::Exception => e
      raise Error, "installation metadata is invalid: #{e.message.lines.first.strip}"
    end

    def atomic_write(path, contents, mode)
      temporary = "#{path}.tmp-#{Process.pid}"
      File.write(temporary, contents, mode: "w", perm: mode)
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if temporary && File.exist?(temporary)
    end

    def atomic_symlink(target, path, existing:)
      if File.exist?(path) || File.symlink?(path)
        prove_launcher!(existing)
      end
      temporary = "#{path}.tmp-#{Process.pid}"
      File.symlink(target, temporary)
      File.rename(temporary, path)
    ensure
      File.unlink(temporary) if temporary && File.symlink?(temporary)
    end

    def source_revision
      stdout, _stderr, status = Open3.capture3("git", "-C", File.expand_path("../..", @source_root), "rev-parse", "HEAD")
      status.success? ? stdout.strip : nil
    rescue Errno::ENOENT
      nil
    end

    def report_path
      entries = @env.fetch("PATH", "").split(File::PATH_SEPARATOR).map { |entry| File.expand_path(entry) }
      @out.puts "path_action=add #{File.dirname(@launcher)} to PATH" unless entries.include?(File.dirname(@launcher))
    end

    def remove_empty_directory(path)
      Dir.rmdir(path) if Dir.exist?(path) && Dir.empty?(path)
    rescue Errno::ENOTEMPTY
      nil
    end

    def version_root
      File.join(@data_root, "versions", RUNTIME_VERSION.to_s)
    end
  end
end

if $PROGRAM_NAME == __FILE__
  unless Gem::Version.new(RUBY_VERSION) >= Gem::Version.new("3.3")
    warn "claude-explore installer requires Ruby >= 3.3"
    exit 1
  end

  options = {}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby install.rb <install|upgrade|uninstall> [--claude-bin ABSOLUTE_PATH]"
    opts.on("--claude-bin PATH") { |value| options[:claude_bin] = value }
  end

  begin
    parser.parse!(ARGV)
    command = ARGV.shift
    raise OptionParser::InvalidArgument, "unexpected arguments: #{ARGV.join(' ')}" unless ARGV.empty?
    raise OptionParser::MissingArgument, "command" unless command
  rescue OptionParser::ParseError => e
    warn "claude-explore installer: #{e.message}"
    exit 2
  end

  exit ClaudeExplore::Installer.new(source_root: __dir__).run(command, **options)
end
