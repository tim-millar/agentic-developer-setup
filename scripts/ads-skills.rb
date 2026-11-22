# frozen_string_literal: true

require "digest"
require "json"
require "tmpdir"

module AdsSkills
  SKILL = "show-me"
  MANAGER = "tim-millar/agentic-developer-setup"
  SCHEMA_VERSION = 1
  FILES = %w[LICENSE SKILL.md UPSTREAM.md].freeze
  METADATA = ".ads-install.json"
  ENTRIES = [METADATA, *FILES].freeze
  AGENTS = {"claude" => ".claude", "codex" => ".agents"}.freeze
  OPERATIONS = %w[install status uninstall].freeze
  USAGE = <<~TEXT
    Usage: ruby scripts/ads-skills.rb <install|status|uninstall> show-me [--agent <claude|codex|both>]
           ruby scripts/ads-skills.rb --help

    The default agent selection is both. Install also updates unchanged ADS-managed copies.
  TEXT

  class Error < StandardError; end

  class UniqueKeys < Hash
    def []=(key, value)
      raise JSON::ParserError, "duplicate key #{key.inspect}" if key?(key)

      super
    end
  end

  Target = Struct.new(:agent, :path, :state, :detail, :manifest, :identity)

  Change = Struct.new(:target, :workspace, :staged_identity) do
    def stage
      File.join(workspace, "new")
    end

    def backup
      File.join(workspace, "previous")
    end
  end

  class Manager
    def initialize(home:, source:, out:, err:)
      @home = home
      @source = source
      @out = out
      @err = err
    end

    def run(operation, agents)
      validate_home!
      destinations = agents.map { |agent| [agent, File.join(@home, AGENTS.fetch(agent), "skills", SKILL)] }
      load_source! unless operation == "uninstall"
      targets = destinations.map { |agent, path| inspect_target(agent, path) }

      if operation == "status"
        targets.each { |target| report(@out, target) }
        return (targets.all? { |target| target.state == :current }) ? 0 : 1
      end

      if targets.any? { |target| %i[modified conflict].include?(target.state) }
        targets.each { |target| report(@err, target) }
        @err.puts "#{operation} blocked for all selected agents"
        return 1
      end

      apply(operation, targets)
    rescue Error, SystemCallError, IOError => error
      destinations&.each { |agent, path| @err.puts "#{agent} #{path}: #{operation} unavailable" }
      @err.puts error.message
      1
    end

    private

    def validate_home!
      unless @home&.start_with?("/") && !@home.include?("\0")
        raise Error, "HOME must be an existing absolute directory"
      end

      components = @home.split("/").reject(&:empty?)
      if components.empty? || components.intersect?(%w[. ..])
        raise Error, "HOME must be an absolute directory below / without . or .. components"
      end

      path = "/"
      components.each do |component|
        path = File.join(path, component)
        raise Error, "unsafe HOME directory: #{path}" unless lstat(path)&.directory?
      end
      @home = path
    end

    def load_source!
      [File.dirname(@source), @source].each do |path|
        raise Error, "canonical source must be a real directory: #{path}" unless lstat(path)&.directory?
      end
      @contents = FILES.to_h { |name| [name, read_regular(File.join(@source, name))] }
      @canonical = @contents.transform_values { |bytes| digest(bytes) }
    rescue Error, SystemCallError, IOError => error
      raise Error, "cannot read canonical #{SKILL} bundle: #{error.message}"
    end

    def lstat(path)
      File.lstat(path)
    rescue Errno::ENOENT
      nil
    end

    def identity(stat)
      [stat.dev, stat.ino]
    end

    def read_regular(path)
      raise Error, "expected a regular file: #{path}" unless lstat(path)&.file?

      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        raise Error, "expected a regular file: #{path}" unless file.stat.file?

        file.binmode.read
      end
    end

    def digest(bytes)
      "sha256:#{Digest::SHA256.hexdigest(bytes)}"
    end

    def parents(path)
      skills = File.dirname(path)
      [File.dirname(skills), skills]
    end

    def directory_present?(path)
      stat = lstat(path)
      raise Error, "unsafe parent directory: #{path}" if stat && !stat.directory?

      !stat.nil?
    end

    def inspect_target(agent, path)
      target = Target.new(agent: agent, path: path, state: :missing)
      return target unless parents(path).all? { |parent| directory_present?(parent) }

      stat = lstat(path)
      return target unless stat

      raise Error, "target is not a real directory" unless stat.directory?

      target.identity = identity(stat)
      target.manifest = read_manifest(path)
      target.detail = content_problem(path, target.manifest)
      target.state = if target.detail
        :modified
      elsif !@canonical
        :managed
      elsif target.manifest == @canonical
        :current
      else
        :outdated
      end
      target
    rescue Error, SystemCallError, IOError => error
      target.state = :conflict
      target.detail = error.message
      target
    end

    def read_manifest(path)
      file = File.join(path, METADATA)
      contents = read_regular(file).force_encoding(Encoding::UTF_8)
      raise JSON::ParserError unless contents.valid_encoding?

      record = JSON.parse(contents, object_class: UniqueKeys)
      unless record.is_a?(Hash) && record.keys.sort == %w[files managed_by schema_version skill] &&
          SCHEMA_VERSION.eql?(record["schema_version"]) && record["managed_by"] == MANAGER &&
          record["skill"] == SKILL
        raise Error, "invalid ADS ownership metadata: #{file}"
      end

      manifest = record["files"]
      unless manifest.is_a?(Hash) && manifest.keys.sort == FILES &&
          manifest.values.all? { |value| value.is_a?(String) && /\Asha256:[0-9a-f]{64}\z/.match?(value.b) }
        raise Error, "invalid ADS ownership manifest: #{file}"
      end

      manifest
    rescue JSON::ParserError
      raise Error, "malformed ADS ownership metadata: #{file}"
    end

    def content_problem(path, manifest)
      entries = Dir.children(path).sort
      if entries != ENTRIES
        return "unexpected or missing managed entries"
      end

      FILES.each do |name|
        file = File.join(path, name)
        return "#{name} is not a regular file" unless lstat(file)&.file?
        return "#{name} digest differs from the ownership manifest" unless digest(read_regular(file)) == manifest.fetch(name)
      end
      nil
    end

    def report(stream, target, outcome = target.state)
      suffix = " (#{target.detail})" if target.detail
      stream.puts "#{target.agent} #{target.path}: #{outcome}#{suffix}"
    end

    def apply(operation, targets)
      installing = operation == "install"
      no_change = installing ? :current : :missing
      changes = targets.reject { |target| target.state == no_change }.map { |target| Change.new(target: target) }
      created = []

      begin
        changes.each { |change| prepare(change, installing, created) }
        changes.each { |change| publish(change, installing) }
      rescue Error, SystemCallError, IOError, Interrupt => error
        @err.puts "#{operation} failed: #{error.message}"
        rollback(changes, created)
        targets.each { |target| report(@err, inspect_target(target.agent, target.path)) }
        return 1
      end

      clean = cleanup(changes)
      targets.each do |target|
        outcome = if installing
          {missing: :installed, outdated: :updated, current: :current}.fetch(target.state)
        else
          (target.state == :missing) ? :missing : :removed
        end
        report(@out, target, outcome)
      end
      @err.puts "#{operation} applied, but workspace cleanup failed" unless clean
      clean ? 0 : 1
    end

    def prepare(change, installing, created)
      parents(change.target.path).each do |parent|
        next if directory_present?(parent)

        Dir.mkdir(parent, 0o700)
        created << parent
      end
      change.workspace = Dir.mktmpdir(".ads-show-me-", File.dirname(change.target.path))
      return unless installing

      Dir.mkdir(change.stage, 0o700)
      record = {
        "schema_version" => SCHEMA_VERSION,
        "managed_by" => MANAGER,
        "skill" => SKILL,
        "files" => @canonical
      }
      write_file(File.join(change.stage, METADATA), "#{JSON.pretty_generate(record)}\n")
      %w[LICENSE UPSTREAM.md SKILL.md].each do |name|
        write_file(File.join(change.stage, name), @contents.fetch(name))
      end
      manifest = read_manifest(change.stage)
      problem = content_problem(change.stage, manifest)
      if manifest != @canonical || problem
        raise Error, "invalid staged bundle at #{change.stage}: #{problem || "manifest differs from source"}"
      end
    end

    def write_file(path, bytes)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode.write(bytes)
      end
    end

    def publish(change, installing)
      target = change.target
      unless inspect_target(target.agent, target.path) == target
        raise Error, "target changed after preflight: #{target.path}"
      end

      validate_workspace!(change)
      File.rename(target.path, change.backup) unless target.state == :missing
      return unless installing

      assert_target_absent!(target.path)
      change.staged_identity = identity(File.lstat(change.stage))
      File.rename(change.stage, target.path)
    end

    def assert_target_absent!(path)
      raise Error, "target already exists: #{path}" if lstat(path)
    end

    def rollback(changes, created)
      recoverable = changes.reverse_each.select do |change|
        restore(change)
      rescue Error, SystemCallError, IOError => error
        @err.puts "restoration failed for #{change.target.path}: #{error.message}"
        @err.puts "workspace retained for recovery: #{change.workspace}"
        false
      end
      cleanup(recoverable)
      created.reverse_each do |path|
        Dir.rmdir(path) if lstat(path)&.directory? && Dir.empty?(path)
      rescue SystemCallError, IOError => error
        @err.puts "could not clean up created parent #{path}: #{error.message}"
      end
    end

    def restore(change)
      return true unless change.workspace

      validate_workspace!(change)
      target = change.target
      if change.staged_identity && !lstat(change.stage)
        published = inspect_target(target.agent, target.path)
        unless published.identity == change.staged_identity && published.state == :current
          raise Error, "published directory changed"
        end
        File.rename(target.path, change.stage)
      end
      if lstat(change.backup)
        assert_target_absent!(target.path)
        File.rename(change.backup, target.path)
      end
      true
    end

    def cleanup(changes)
      failures = changes.filter_map do |change|
        next unless change.workspace

        validate_workspace!(change)
        remove_snapshot(change.stage)
        remove_snapshot(change.backup)
        Dir.rmdir(change.workspace)
        nil
      rescue Error, SystemCallError, IOError => error
        @err.puts "could not clean up #{change.workspace}: #{error.message}"
        change.workspace
      end
      failures.empty?
    end

    def validate_workspace!(change)
      paths = [*parents(change.target.path), change.workspace]
      unless paths.all? { |path| directory_present?(path) }
        raise Error, "workspace hierarchy is missing"
      end
    end

    def remove_snapshot(path)
      stat = lstat(path)
      return unless stat

      raise Error, "unsafe workspace directory: #{path}" unless stat.directory?

      entries = Dir.children(path)
      unless (entries - ENTRIES).empty? && entries.all? { |entry| lstat(File.join(path, entry))&.file? }
        raise Error, "unexpected workspace contents: #{path}"
      end

      entries.each { |entry| File.unlink(File.join(path, entry)) }
      Dir.rmdir(path)
    end
  end

  def self.run(args, home: ENV["HOME"], out: $stdout, err: $stderr)
    if args == ["--help"]
      out.puts USAGE
      return 0
    end

    operation, skill, flag, agent = args
    agent = "both" if args.size == 2
    valid_selection = agent == "both" || AGENTS.key?(agent)
    valid_syntax = args.size == 2 || (args.size == 4 && flag == "--agent")
    unless OPERATIONS.include?(operation) && skill == SKILL && valid_syntax && valid_selection
      err.puts "Invalid arguments", USAGE
      return 2
    end

    if (RUBY_VERSION.split(".").first(2).map(&:to_i) <=> [3, 3]).negative?
      err.puts "Ruby 3.3.0 or later is required"
      return 1
    end

    source = File.expand_path("../skills/#{SKILL}", __dir__)
    Manager.new(home: home, source: source, out: out, err: err)
      .run(operation, (agent == "both") ? AGENTS.keys : [agent])
  end
end

exit AdsSkills.run(ARGV) if $PROGRAM_NAME == __FILE__
