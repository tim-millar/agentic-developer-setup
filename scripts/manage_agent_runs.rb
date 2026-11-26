#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

class AgentRunsInstaller
  FILES = %w[
    scripts/ads-agent-runs scripts/report_agent_runs.rb lib/agent_run_cli.rb
    lib/agent_run_reporting/corpus.rb lib/agent_run_reporting/markdown.rb
    lib/agent_run_reporting/usage.rb lib/agent_run_reporting/pull_requests.rb
    lib/agent_run_telemetry/validator.rb lib/agent_run_usage/validator.rb
    lib/agent_run_outcomes/validator.rb schemas/agent-run-telemetry-v1.schema.json
    schemas/agent-run-usage-v1.schema.json schemas/agent-run-outcome-v1.schema.json
  ].freeze
  VERSION = "1"

  def initialize(command)
    @command = command
    @home = ENV.fetch("HOME")
    @bin = File.join(@home, ".local/bin")
    data = ENV["XDG_DATA_HOME"].to_s.empty? ? File.join(@home, ".local/share") : ENV.fetch("XDG_DATA_HOME")
    raise "XDG_DATA_HOME must be absolute" unless data.start_with?("/")
    @payload = File.join(data, "agent-development-framework/agent-runs")
    @executable = File.join(@bin, "ads-agent-runs")
    @manifest_name = ".ads-agent-runs-manifest.json"
  end

  def run
    check_runtime
    case @command
    when "status" then status
    when "install" then install
    when "uninstall" then uninstall
    else
      warn "Usage: ruby scripts/manage_agent_runs.rb install|status|uninstall"
      2
    end
  rescue => e
    warn "ads-agent-runs installer: #{e.message}"
    1
  end

  private

  def check_runtime
    version = RUBY_VERSION.split(".").map(&:to_i)
    raise "Ruby 3.3 or later is required (found #{RUBY_VERSION})" if (version <=> [3, 3, 0]).negative?
  end

  def files
    FILES.to_h do |relative|
      source = File.expand_path("../#{relative}", __dir__)
      raise "Missing source file: #{relative}" unless File.file?(source) && !File.symlink?(source)
      [relative, [source, Digest::SHA256.file(source).hexdigest]]
    end
  end

  def status
    state = inspect_installation
    puts state
    0
  end

  def inspect_installation
    return "missing" unless File.exist?(@executable) || File.symlink?(@executable) || File.exist?(@payload) || File.symlink?(@payload)
    return "conflicting (foreign executable or payload)" unless managed?
    manifest = JSON.parse(File.read(File.join(@payload, @manifest_name)))
    actual = inventory(@payload)
    return "modified" unless actual == manifest["files"] && wrapper_digest == manifest["executable_sha256"]
    return "current" if manifest["bundle_digest"] == bundle_digest
    "outdated"
  rescue
    "modified"
  end

  def managed?
    return false unless File.file?(@executable) && File.file?(File.join(@payload, @manifest_name))
    JSON.parse(File.read(File.join(@payload, @manifest_name)))["owner"] == "agent-development-framework/ads-agent-runs"
  rescue
    false
  end

  def bundle_digest
    Digest::SHA256.hexdigest(files.map { |name, (_, hash)| "#{name}\0#{hash}" }.join("\n"))
  end

  def inventory(directory)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: directory).reject { |p| p == "." || p == ".." || p == @manifest_name || File.directory?(File.join(directory, p)) }.sort.to_h do |relative|
      path = File.join(directory, relative)
      raise "managed file is not regular" unless File.file?(path) && !File.symlink?(path)
      [relative, Digest::SHA256.file(path).hexdigest]
    end
  end

  def wrapper
    <<~SH
      #!/bin/sh
      exec #{shell_quote(RbConfig.ruby)} #{shell_quote(File.join(@payload, "scripts/ads-agent-runs"))} "$@"
    SH
  end

  def shell_quote(value)
    "'#{value.gsub("'", %q('"'"'))}'"
  end

  def wrapper_digest
    Digest::SHA256.file(@executable).hexdigest
  end

  def install
    state = inspect_installation
    if state == "current"
      puts "ads-agent-runs is current"
      return path_notice
    end
    if %w[modified].include?(state) || state.start_with?("conflicting")
      raise "refusing to replace #{state} installation"
    end
    source_files = files
    data_parent = File.dirname(@payload)
    FileUtils.mkdir_p(data_parent, mode: 0o700)
    FileUtils.mkdir_p(@bin, mode: 0o755)
    stage = Dir.mktmpdir(".ads-agent-runs-stage-", data_parent)
    backup = "#{@payload}.ads-backup-#{Process.pid}"
    wrapper_tmp = "#{@executable}.ads-new-#{Process.pid}"
    old_wrapper = "#{@executable}.ads-old-#{Process.pid}"
    payload_moved = false
    payload_installed = false
    wrapper_moved = false
    wrapper_installed = false
    begin
      source_files.each do |relative, (source, digest)|
        target = File.join(stage, relative)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        FileUtils.cp(source, target)
        raise "source changed during install" unless Digest::SHA256.file(source).hexdigest == digest
        raise "staged file verification failed" unless Digest::SHA256.file(target).hexdigest == digest
      end
      manifest = {"owner" => "agent-development-framework/ads-agent-runs", "version" => VERSION,
                  "bundle_digest" => bundle_digest, "files" => inventory(stage), "executable_sha256" => Digest::SHA256.hexdigest(wrapper)}
      File.write(File.join(stage, @manifest_name), JSON.pretty_generate(manifest) + "\n", mode: "w", perm: 0o600)
      File.chmod(0o755, File.join(stage, "scripts/ads-agent-runs"))
      File.write(wrapper_tmp, wrapper, mode: "w", perm: 0o755)
      if File.exist?(@payload)
        File.rename(@payload, backup)
        payload_moved = true
      end
      if File.exist?(@executable)
        File.rename(@executable, old_wrapper)
        wrapper_moved = true
      end
      File.rename(stage, @payload)
      payload_installed = true
      File.rename(wrapper_tmp, @executable)
      wrapper_installed = true
      FileUtils.rm_rf(backup) if File.exist?(backup)
      FileUtils.rm_f(old_wrapper)
    rescue
      FileUtils.rm_rf(@payload) if payload_installed && File.exist?(@payload)
      File.rename(backup, @payload) if payload_moved && File.exist?(backup)
      FileUtils.rm_f(@executable) if wrapper_installed && File.exist?(@executable)
      File.rename(old_wrapper, @executable) if wrapper_moved && File.exist?(old_wrapper)
      raise
    ensure
      FileUtils.rm_rf(stage) if File.exist?(stage)
      FileUtils.rm_f(wrapper_tmp)
    end
    puts "Installed #{@executable}"
    path_notice
  end

  def uninstall
    state = inspect_installation
    return puts("ads-agent-runs is not installed") && 0 if state == "missing"
    raise "refusing to remove #{state} installation" unless %w[current outdated].include?(state)
    manifest = JSON.parse(File.read(File.join(@payload, @manifest_name)))
    raise "managed payload inventory does not match its manifest" unless inventory(@payload) == manifest["files"]
    FileUtils.rm_f(@executable)
    manifest.fetch("files").each_key { |relative| FileUtils.rm_f(File.join(@payload, relative)) }
    FileUtils.rm_f(File.join(@payload, @manifest_name))
    directories = FILES.flat_map do |relative|
      parts = relative.split("/")
      (1...parts.length).map { |count| File.join(@payload, *parts.first(count)) }
    end.uniq.sort_by { |path| -path.length }
    directories.each { |path| Dir.rmdir(path) if File.directory?(path) && Dir.empty?(path) }
    Dir.rmdir(@payload) if File.directory?(@payload) && Dir.empty?(@payload)
    puts "Removed ADS-managed ads-agent-runs files"
    0
  end

  def path_notice
    unless ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(@bin)
      warn "Add #{@bin} to PATH to run ads-agent-runs from your terminal."
    end
    0
  end
end

exit AgentRunsInstaller.new(ARGV.fetch(0, "")).run
