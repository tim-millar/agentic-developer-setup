# frozen_string_literal: true

require "open3"
require "pathname"

module AgenticDeveloperSetup
  module GitCommand
    Result = Struct.new(:stdout, :stderr, :success?, :filters_disabled)

    module_function

    def revision(root)
      supplied_root = Pathname.new(root).expand_path.realpath
      return nil unless worktree_root(root) == supplied_root

      result = capture(root, "rev-parse", "--verify", "HEAD^{commit}")
      revision = result.stdout.strip
      revision if result.success? && revision.match?(/\A[0-9a-f]{40}\z/)
    rescue SystemCallError
      nil
    end

    def worktree_root(root)
      result = capture(root, "rev-parse", "--show-toplevel")
      return nil unless result.success?

      top_level = result.stdout.strip
      return nil if top_level.empty?

      Pathname.new(top_level).expand_path.realpath
    rescue SystemCallError
      nil
    end

    def status(root, *arguments)
      drivers = filter_drivers(Pathname.new(root))
      return Result.new("", "", false) unless drivers

      # Empty commands disable Git's clean/process conversions. Clear required
      # too, so Git can compare bytes using its remaining built-in conversions.
      settings = drivers.flat_map { |driver| [["#{driver}.clean", ""], ["#{driver}.process", ""], ["#{driver}.required", "false"]] }
      config = {"GIT_CONFIG_COUNT" => settings.length.to_s}
      settings.each_with_index do |(key, value), index|
        config["GIT_CONFIG_KEY_#{index}"] = key
        config["GIT_CONFIG_VALUE_#{index}"] = value
      end
      capture(root, "status", *arguments, config: config).tap { |result| result.filters_disabled = !drivers.empty? }
    end

    def filter_drivers(root)
      names = capture(root, "config", "--null", "--name-only", "--list")
      entries = capture(root, "ls-files", "--stage", "-z")
      return unless names.success? && entries.success?

      drivers = names.stdout.split("\0").filter_map do |key|
        key.rpartition(".").first if key.b.match?(/\Afilter\..*\.(?:clean|process|required)\z/)
      end

      # Status can spawn status in an initialized submodule. Include its
      # locally configured drivers in the command overrides inherited by Git.
      gitlinks = entries.stdout.split("\0").filter_map { |entry| entry.split("\t", 2).last if entry.start_with?("160000 ") }
      gitlinks.uniq.each do |relative|
        child = root.join(relative)
        next if child.ascend.take_while { |path| path != root }.any?(&:symlink?)
        next unless child.join(".git").exist? && worktree_root(child) == child.realpath

        child_drivers = filter_drivers(child)
        return nil unless child_drivers
        drivers.concat(child_drivers)
      end
      drivers.uniq
    rescue SystemCallError
      nil
    end
    private_class_method :filter_drivers

    def capture(root, *arguments, stdin_data: nil, config: {})
      stdout, stderr, status = Open3.capture3(
        environment.merge(config), *command(arguments), chdir: root.to_s, stdin_data: stdin_data
      )
      Result.new(stdout, stderr, status.success?)
    rescue SystemCallError
      Result.new("", "", false)
    end

    def stream_stdout(root, *arguments)
      Open3.popen2(environment, *command(arguments), chdir: root.to_s, err: File::NULL) do |input, output, wait|
        input.close
        value = yield output.binmode
        output.close
        Result.new(value, "", wait.value.success?)
      end
    rescue SystemCallError
      Result.new(nil, "", false)
    end

    def command(arguments)
      ["git", "--no-optional-locks", "-c", "core.fsmonitor=false", *arguments]
    end
    private_class_method :command

    def environment
      ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }.merge("GIT_OPTIONAL_LOCKS" => "0")
    end
    private_class_method :environment
  end
end
