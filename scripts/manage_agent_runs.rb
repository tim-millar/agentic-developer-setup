#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "rbconfig"
require "tmpdir"

class AgentRunsInstaller
  OWNER = "agent-development-framework/ads-agent-runs"
  MANIFEST = ".ads-agent-runs-manifest.json"
  FILES = %w[
    scripts/ads-agent-runs scripts/report_agent_runs.rb lib/agent_run_cli.rb
    lib/agent_run_reporting/corpus.rb lib/agent_run_reporting/markdown.rb
    lib/agent_run_reporting/usage.rb lib/agent_run_reporting/pull_requests.rb
    lib/agent_run_telemetry/validator.rb lib/agent_run_usage/validator.rb
    lib/agent_run_outcomes/validator.rb schemas/agent-run-telemetry-v1.schema.json
    schemas/agent-run-usage-v1.schema.json schemas/agent-run-outcome-v1.schema.json
  ].freeze
  DIRECTORIES = FILES.flat_map { |f|
    parts = f.split("/")
    (1...parts.length).map { |n| parts.first(n).join("/") }
  }.uniq.sort.freeze
  def self.run(argv, env: ENV, source_root: File.expand_path("..", __dir__))
    unless argv.length == 1 && %w[install status uninstall].include?(argv.first)
      warn "Usage: ruby scripts/manage_agent_runs.rb install|status|uninstall"
      return 2
    end
    new(argv.first, env: env, source_root: source_root).run
  end

  def initialize(command, env: ENV, source_root: File.expand_path("..", __dir__))
    @command, @env, @source_root = command, env, source_root
    @uid = Process.uid
  end

  def run
    check_runtime
    resolve_paths
    case @command
    when "status" then status
    when "install" then install
    when "uninstall" then uninstall
    end
  rescue => e
    warn "ads-agent-runs installer: #{safe_message(e.message)}"
    1
  end

  private

  def check_runtime
    raise "Ruby 3.3 or later is required (found #{RUBY_VERSION})" if (GemVersion(RUBY_VERSION) <=> [3, 3, 0]).negative?
  end

  def GemVersion(value)
    value.split(".").map(&:to_i)
  end

  def resolve_paths
    home = @env["HOME"]
    raise "HOME must be an absolute existing directory" unless home&.start_with?("/")
    @home = canonical_existing(home)
    home_stat = File.lstat(@home)
    raise "HOME must be owned by the current user and not group/world-writable" unless home_stat.directory? && home_stat.uid == @uid && (home_stat.mode & 0o022).zero?

    data = @env["XDG_DATA_HOME"].to_s.empty? ? File.join(@home, ".local/share") : @env["XDG_DATA_HOME"]
    raise "XDG_DATA_HOME must be an absolute path" unless data.start_with?("/")
    @data_root = canonical_existing(data)
    @bin = File.join(@home, ".local/bin")
    @payload = File.join(@data_root, "agent-development-framework/agent-runs")
    @executable = File.join(@bin, "ads-agent-runs")
    @data_parent = File.dirname(@payload)
    validate_install_hierarchy(@bin)
    validate_install_hierarchy(@data_parent)
  rescue Errno::ENOENT, Errno::EACCES
    raise "HOME and XDG_DATA_HOME must resolve through readable directories"
  end

  def canonical_existing(path)
    expanded = File.expand_path(path)
    existing = expanded
    existing = File.dirname(existing) until File.exist?(existing)
    resolved = File.realpath(existing)
    suffix = expanded.delete_prefix(existing).sub(%r{\A/}, "")
    suffix.empty? ? resolved : File.join(resolved, suffix)
  end

  def validate_install_hierarchy(path)
    current = File::SEPARATOR
    path.delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |part|
      current = File.join(current, part)
      begin
        st = File.lstat(current)
      rescue Errno::ENOENT
        next
      end
      trusted_parent = st.uid == 0 && (st.mode & 0o022).zero?
      sticky_parent = st.uid == 0 && (st.mode & 0o1000) != 0 && st.directory?
      trusted_user = st.uid == @uid && (st.mode & 0o022).zero?
      safe = st.directory? && !st.symlink? && (trusted_parent || sticky_parent || trusted_user)
      raise UnsafeInstall, "unsafe installation hierarchy at #{current}" unless safe
    end
  end

  def source_package
    snapshot = {}
    FILES.each do |relative|
      path = File.join(@source_root, relative)
      st = File.lstat(path)
      raise "unsafe source package file: #{relative}" unless st.file? && !st.symlink? && st.nlink == 1
      bytes = File.binread(path)
      raise "source changed while reading: #{relative}" unless Digest::SHA256.hexdigest(bytes) == Digest::SHA256.file(path).hexdigest
      snapshot[relative] = bytes
    rescue SystemCallError
      raise "cannot read source package file: #{relative}"
    end
    snapshot
  end

  def bundle_digest(files)
    canonical = files.keys.sort.map { |name| "#{name}\0#{Digest::SHA256.hexdigest(files.fetch(name))}" }.join("\n")
    Digest::SHA256.hexdigest(canonical)
  end

  def status
    state = inspect_installation
    puts state
    0
  end

  def inspect_installation
    validate_install_hierarchy(@bin)
    validate_install_hierarchy(@data_parent)
    exe_state = lstat_or_nil(@executable)
    payload_state = lstat_or_nil(@payload)
    return "missing" unless exe_state || payload_state
    return "conflicting (unsafe executable or payload object)" unless safe_object?(exe_state, :file) && safe_object?(payload_state, :directory)

    manifest_path = File.join(@payload, MANIFEST)
    manifest_stat = lstat_or_nil(manifest_path)
    return "conflicting (missing or unsafe ownership manifest)" unless safe_object?(manifest_stat, :file)
    manifest = parse_manifest(File.binread(manifest_path))
    actual_files, actual_dirs = scan_payload(@payload)
    expected_dirs = manifest.fetch(:directories)
    return "conflicting (payload inventory mismatch)" unless actual_dirs.sort == expected_dirs.sort && actual_files.keys.sort == manifest.fetch(:files).keys.sort
    return "modified" unless actual_files == manifest.fetch(:files)
    return "modified" unless Digest::SHA256.file(@executable).hexdigest == manifest.fetch(:executable_sha256)
    source = source_package
    return "current" if manifest.fetch(:bundle_digest) == bundle_digest(source)
    "outdated"
  rescue UnsafeInstall => e
    "conflicting (#{e.message})"
  rescue JSON::ParserError, KeyError, TypeError, SystemCallError, ArgumentError
    "conflicting (invalid or unsupported ownership metadata)"
  end

  class UnsafeInstall < StandardError; end

  def safe_object?(stat, kind)
    return false unless stat && !stat.symlink? && stat.uid == @uid && (stat.mode & 0o022).zero?
    return stat.file? && stat.nlink == 1 if kind == :file
    stat.directory?
  end

  def parse_manifest(bytes)
    text = bytes.dup.force_encoding(Encoding::UTF_8)
    raise JSON::ParserError, "manifest is not valid UTF-8" unless text.valid_encoding?
    reject_duplicate_keys!(text)
    m = JSON.parse(text)
    raise JSON::ParserError, "manifest must be an object" unless m.is_a?(Hash)
    raise JSON::ParserError, "wrong owner" unless m["owner"] == OWNER
    version = m["manifest_version"]
    if version == 2
      required = %w[owner manifest_version bundle_digest files directories executable_sha256]
      raise JSON::ParserError, "unexpected manifest fields" unless m.keys.sort == required.sort
      dirs = m["directories"]
      raise JSON::ParserError, "invalid directory inventory" unless dirs.is_a?(Array) && dirs.all? { |d| d.is_a?(String) } && dirs.uniq == dirs && dirs.sort == DIRECTORIES
    elsif version.nil? && m["version"] == "1"
      # Exact legacy schema emitted by the first #71 installer. Its directory
      # inventory is derived from the fixed package paths and checked on disk.
      required = %w[owner version bundle_digest files executable_sha256]
      raise JSON::ParserError, "unsupported legacy manifest fields" unless m.keys.sort == required.sort
      dirs = DIRECTORIES
    else
      raise JSON::ParserError, "unsupported manifest version"
    end
    files = m["files"]
    raise JSON::ParserError, "invalid file inventory" unless files.is_a?(Hash) && files.keys.sort == FILES.sort
    files.each { |path, digest|
      validate_relative_path!(path)
      validate_digest!(digest)
    }
    validate_digest!(m["bundle_digest"])
    validate_digest!(m["executable_sha256"])
    calculated = if version == 2
      Digest::SHA256.hexdigest(files.keys.sort.map { |n| "#{n}\0#{files[n]}" }.join("\n"))
    else
      Digest::SHA256.hexdigest(FILES.map { |n| "#{n}\0#{files[n]}" }.join("\n"))
    end
    raise JSON::ParserError, "inconsistent bundle digest" unless calculated == m["bundle_digest"]
    {files: files, directories: dirs, bundle_digest: m["bundle_digest"], executable_sha256: m["executable_sha256"]}
  end

  def reject_duplicate_keys!(text)
    objects = []
    index = 0
    while index < text.length
      char = text[index]
      if char == '"'
        start = index
        index += 1
        escaped = false
        while index < text.length
          current = text[index]
          if escaped
            escaped = false
          elsif current == "\\"
            escaped = true
          elsif current == '"'
            break
          end
          index += 1
        end
        raise JSON::ParserError, "unterminated string" if index >= text.length
        token = text[start..index]
        following = index + 1
        following += 1 while following < text.length && text[following].match?(/\s/)
        if text[following] == ":" && !objects.empty?
          key = JSON.parse(token)
          raise JSON::ParserError, "duplicate object key" if objects.last.key?(key)
          objects.last[key] = true
        end
      elsif char == "{"
        objects << {}
      elsif char == "}"
        objects.pop
      end
      index += 1
    end
  end

  def validate_relative_path!(path)
    parts = path.split("/")
    raise JSON::ParserError, "invalid inventory path" if path.start_with?("/") || parts.any? { |part| part.empty? || part == "." || part == ".." } || !FILES.include?(path)
  end

  def validate_digest!(value)
    raise JSON::ParserError, "invalid SHA-256 digest" unless value.is_a?(String) && value.match?(/\A[0-9a-f]{64}\z/)
  end

  def scan_payload(root)
    files = {}
    dirs = []
    walk = lambda do |relative|
      directory = relative.empty? ? root : File.join(root, relative)
      Dir.children(directory).sort.each do |name|
        child = [relative, name].reject(&:empty?).join("/")
        stat = File.lstat(File.join(root, child))
        if stat.directory? && !stat.symlink?
          raise UnsafeInstall, "unsafe managed directory #{child}" unless safe_object?(stat, :directory)
          dirs << child
          walk.call(child)
        elsif stat.file? && !stat.symlink?
          raise UnsafeInstall, "unsafe managed file #{child}" unless safe_object?(stat, :file)
          unless child == MANIFEST
            raise UnsafeInstall, "unexpected managed file #{child}" unless FILES.include?(child)
            files[child] = Digest::SHA256.file(File.join(root, child)).hexdigest
          end
        else
          raise UnsafeInstall, "unexpected filesystem object #{child}"
        end
      end
    end
    walk.call("")
    # The manifest is explicit and excluded from the payload file digest map.
    files.delete(MANIFEST)
    [files, dirs]
  end

  def install
    source = source_package
    before = inspect_installation
    before_signature = ownership_signature if %w[current outdated].include?(before)
    if before == "current"
      puts "ads-agent-runs is current"
      return path_notice
    end
    raise "refusing to replace #{before} installation" unless %w[missing outdated].include?(before)

    prepare_directory(@bin, 0o755)
    prepare_directory(@data_parent, 0o755)
    payload_tx = wrapper_tx = nil
    payload_moved = wrapper_moved = payload_published = wrapper_published = false
    begin
      payload_tx = Dir.mktmpdir(".ads-agent-runs-", @data_parent, mode: 0o700)
      wrapper_tx = Dir.mktmpdir(".ads-agent-runs-", @bin, mode: 0o700)
      payload_stage = File.join(payload_tx, "new-payload")
      payload_backup = File.join(payload_tx, "old-payload")
      wrapper_stage = File.join(wrapper_tx, "new-executable")
      wrapper_backup = File.join(wrapper_tx, "old-executable")
      stage_payload(payload_stage, source)
      write_exclusive(wrapper_stage, wrapper_bytes, 0o755)
      verify_stage(payload_stage, wrapper_stage, source)
      source.each do |relative, bytes|
        raise "source changed during staging: #{relative}" unless File.binread(File.join(@source_root, relative)) == bytes
      end
      current = inspect_installation
      current_signature = ownership_signature if %w[current outdated].include?(current)
      raise "installation changed during staging (now #{current})" unless current == before && current_signature == before_signature
      if before == "outdated"
        raise "installation changed before update publication" unless inspect_installation == before && ownership_signature == before_signature
        move_path(@payload, payload_backup)
        payload_moved = true
        raise "executable changed before update publication" unless safe_object?(lstat_or_nil(@executable), :file) && Digest::SHA256.file(@executable).hexdigest == JSON.parse(File.binread(File.join(payload_backup, MANIFEST))).fetch("executable_sha256")
        move_path(@executable, wrapper_backup)
        wrapper_moved = true
      end
      raise "payload destination appeared during installation" if lstat_or_nil(@payload)
      move_path(payload_stage, @payload)
      payload_published = true
      raise "executable destination appeared during installation" if lstat_or_nil(@executable)
      move_path(wrapper_stage, @executable)
      wrapper_published = true
      raise "published installation verification failed" unless inspect_installation == "current"
    rescue => original
      begin
        if wrapper_published
          raise "published executable changed during rollback" unless safe_object?(lstat_or_nil(@executable), :file) && Digest::SHA256.file(@executable).hexdigest == Digest::SHA256.hexdigest(wrapper_bytes)
          File.unlink(@executable)
        end
        if payload_published
          raise "published payload changed during rollback" unless valid_payload_for_source?(@payload, source)
          remove_payload(@payload)
        end
        if payload_moved && lstat_or_nil(payload_backup)
          raise "payload path occupied during rollback" if lstat_or_nil(@payload)
          move_path(payload_backup, @payload)
        end
        if wrapper_moved && lstat_or_nil(wrapper_backup)
          raise "executable path occupied during rollback" if lstat_or_nil(@executable)
          move_path(wrapper_backup, @executable)
        end
      rescue => rollback
        @recovery_workspaces = [payload_tx, wrapper_tx]
        raise "#{original.message}; rollback incomplete, recovery artefacts preserved in #{payload_tx} and #{wrapper_tx}: #{rollback.message}"
      end
      raise original
    end
    puts "Installed #{@executable}"
    path_notice
  ensure
    cleanup_workspace(payload_tx) if payload_tx && !recovery_workspace?(payload_tx)
    cleanup_workspace(wrapper_tx) if wrapper_tx && !recovery_workspace?(wrapper_tx)
  end

  def stage_payload(root, source)
    Dir.mkdir(root, 0o700)
    DIRECTORIES.each { |relative| Dir.mkdir(File.join(root, relative), 0o755) }
    digests = {}
    source.each do |relative, bytes|
      path = File.join(root, relative)
      write_exclusive(path, bytes, (relative == "scripts/ads-agent-runs") ? 0o755 : 0o644)
      digests[relative] = Digest::SHA256.hexdigest(bytes)
    end
    manifest = {"owner" => OWNER, "manifest_version" => 2,
                "bundle_digest" => Digest::SHA256.hexdigest(digests.keys.sort.map { |n| "#{n}\0#{digests[n]}" }.join("\n")),
                "files" => digests, "directories" => DIRECTORIES, "executable_sha256" => Digest::SHA256.hexdigest(wrapper_bytes)}
    write_exclusive(File.join(root, MANIFEST), JSON.generate(manifest) + "\n", 0o600)
  end

  def verify_stage(payload_stage, wrapper_stage, source)
    files, dirs = scan_payload(payload_stage)
    expected = source.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
    raise "staged payload verification failed" unless files == expected && dirs.sort == DIRECTORIES
    raise "staged executable verification failed" unless File.lstat(wrapper_stage).file? && Digest::SHA256.file(wrapper_stage).hexdigest == Digest::SHA256.hexdigest(wrapper_bytes)
    parsed = parse_manifest(File.binread(File.join(payload_stage, MANIFEST)))
    raise "staged manifest verification failed" unless parsed[:files] == expected && parsed[:bundle_digest] == bundle_digest(source)
  end

  def valid_payload_for_source?(path, source)
    root_stat = lstat_or_nil(path)
    return false unless safe_object?(root_stat, :directory)
    manifest_path = File.join(path, MANIFEST)
    return false unless safe_object?(lstat_or_nil(manifest_path), :file)
    files, dirs = scan_payload(path)
    expected = source.transform_values { |bytes| Digest::SHA256.hexdigest(bytes) }
    manifest = parse_manifest(File.binread(manifest_path))
    files == expected && dirs.sort == DIRECTORIES && manifest[:files] == expected && manifest[:bundle_digest] == bundle_digest(source)
  rescue
    false
  end

  def ownership_signature
    files, = scan_payload(@payload)
    paths = files.keys + [MANIFEST]
    payload = paths.sort.map { |relative| "#{relative}\0#{Digest::SHA256.file(File.join(@payload, relative)).hexdigest}" }.join("\n")
    Digest::SHA256.hexdigest([payload, Digest::SHA256.file(@executable).hexdigest].join("\n"))
  end

  def wrapper_bytes
    "#!/bin/sh\nexec #{shell_quote(RbConfig.ruby)} #{shell_quote(File.join(@payload, "scripts/ads-agent-runs"))} \"$@\"\n"
  end

  def shell_quote(value)
    "'#{value.gsub("'", %q('"'"'))}'"
  end

  def prepare_directory(path, mode)
    current = File::SEPARATOR
    path.delete_prefix(File::SEPARATOR).split(File::SEPARATOR).each do |part|
      current = File.join(current, part)
      begin
        stat = File.lstat(current)
        valid = stat.directory? && !stat.symlink? && ((stat.uid == @uid && (stat.mode & 0o022).zero?) || (stat.uid == 0 && (stat.mode & 0o022).zero?) || (stat.uid == 0 && (stat.mode & 0o1000) != 0))
        raise "unsafe installation directory #{current}" unless valid
      rescue Errno::ENOENT
        Dir.mkdir(current, mode)
      end
    end
  end

  def write_exclusive(path, bytes, mode)
    File.open(path, File::WRONLY | File::CREAT | File::EXCL, mode) { |f|
      f.write(bytes)
      f.flush
      f.fsync
    }
  end

  def move_path(source, destination)
    File.rename(source, destination)
  end

  def lstat_or_nil(path)
    File.lstat(path)
  rescue Errno::ENOENT
    nil
  end

  def remove_payload(path)
    files, dirs = scan_payload(path)
    (files.keys + [MANIFEST]).each { |relative| File.unlink(File.join(path, relative)) }
    dirs.sort_by { |d| -d.length }.each { |relative| Dir.rmdir(File.join(path, relative)) }
    Dir.rmdir(path)
  end

  def uninstall
    state = inspect_installation
    if state == "missing"
      puts "ads-agent-runs is not installed"
      return 0
    end
    raise "refusing to remove #{state} installation" unless %w[current outdated].include?(state)
    raise "installation changed before removal" unless inspect_installation == state
    _, _ = scan_payload(@payload)
    raise "installation changed before removal" unless inspect_installation == state
    removal_signature = ownership_signature
    payload_tx = Dir.mktmpdir(".ads-agent-runs-remove-", @data_parent, mode: 0o700)
    wrapper_tx = Dir.mktmpdir(".ads-agent-runs-remove-", @bin, mode: 0o700)
    saved_payload = File.join(payload_tx, "payload")
    saved_executable = File.join(wrapper_tx, "executable")
    moved_payload = movement_complete = false
    begin
      raise "installation changed before removal" unless inspect_installation == state
      raise "payload path changed before removal" unless ownership_signature == removal_signature
      move_path(@payload, saved_payload)
      moved_payload = true
      expected_wrapper = parse_manifest(File.binread(File.join(saved_payload, MANIFEST))).fetch(:executable_sha256)
      raise "executable changed before removal" unless safe_object?(lstat_or_nil(@executable), :file) && Digest::SHA256.file(@executable).hexdigest == expected_wrapper
      move_path(@executable, saved_executable)
      movement_complete = true
    rescue => original
      begin
        if moved_payload && lstat_or_nil(saved_payload)
          raise "payload path occupied during rollback" if lstat_or_nil(@payload)
          move_path(saved_payload, @payload)
        end
      rescue => rollback
        @recovery_workspaces = [payload_tx, wrapper_tx]
        raise "removal failed: #{original.message}; rollback incomplete, recovery artefacts preserved in #{payload_tx} and #{wrapper_tx}: #{rollback.message}"
      end
      raise original
    ensure
      unless movement_complete || recovery_workspace?(payload_tx) || recovery_workspace?(wrapper_tx)
        cleanup_workspace(payload_tx)
        cleanup_workspace(wrapper_tx)
      end
    end
    begin
      raise "saved executable changed during removal" unless safe_object?(lstat_or_nil(saved_executable), :file) && Digest::SHA256.file(saved_executable).hexdigest == Digest::SHA256.hexdigest(wrapper_bytes)
      File.unlink(saved_executable)
      remove_payload(saved_payload)
    rescue => e
      @recovery_workspaces = [payload_tx, wrapper_tx]
      raise "verified installation moved to recovery workspace #{payload_tx} / #{wrapper_tx}; cleanup failed: #{e.message}"
    end
    cleanup_workspace(payload_tx)
    cleanup_workspace(wrapper_tx)
    puts "Removed ADS-managed ads-agent-runs files"
    0
  end

  def cleanup_workspace(path)
    stat = lstat_or_nil(path)
    return unless stat && safe_object?(stat, :directory) && (stat.mode & 0o777) == 0o700
    FileUtils.remove_entry_secure(path)
  rescue SystemCallError => e
    warn "ads-agent-runs installer: could not clean transaction workspace #{path}: #{e.message}"
  end

  def recovery_workspace?(path)
    @recovery_workspaces&.include?(path)
  end

  def path_notice
    unless @env.fetch("PATH", "").split(File::PATH_SEPARATOR).include?(@bin)
      warn "Add #{@bin} to PATH to run ads-agent-runs from your terminal."
    end
    0
  end

  def safe_message(value)
    value.to_s.gsub(/[[:cntrl:]]/) { |c| format("\\u%04X", c.ord) }
  end
end

if $PROGRAM_NAME == __FILE__
  exit AgentRunsInstaller.run(ARGV)
end
