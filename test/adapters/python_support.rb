# frozen_string_literal: true

require "socket"
require_relative "support"

module PublicPythonFixture
  def python_selection(manager: nil, scope: @scope, resolutions: [])
    inputs = manager ? [{"key" => "ecosystem/python.package_manager", "value" => manager}] : []
    selected(["ecosystem", "python"], inputs: inputs, scope: scope, resolutions: resolutions)
  end

  def uv_project(prefix: "")
    write_target("#{prefix}pyproject.toml", <<~TOML)
      [build-system]
      requires = ["setuptools"]
      build-backend = "setuptools.build_meta"

      [project]
      name = "synthetic-python"
      version = "0.1.0"
      requires-python = ">=3.12,<3.14"

      [dependency-groups]
      dev = ["pytest>=8", "ruff"]

      [tool.uv]
      required-version = ">=0.8"

      [tool.pytest.ini_options]
      testpaths = ["tests"]
    TOML
    write_target("#{prefix}uv.lock", "version = 1\n")
    write_target("#{prefix}.python-version", "3.12.4\n")
    write_target("#{prefix}Makefile", "test:\n\tuv run --locked pytest -q\n")
  end

  def python_commands(result)
    result.dig("composition", "commands")
  end

  def python_findings(result)
    result.dig("composition", "contributions", "findings")
  end

  def finding_ids(result)
    python_findings(result).map { |item| item["id"] }
  end

  def invocations(result = assess(python_selection))
    python_commands(result).map { |command| command["argv"] }
  end

  def git(root, *args)
    env = {"GIT_CONFIG_GLOBAL" => File::NULL, "GIT_CONFIG_NOSYSTEM" => "1"}
    out, err, status = Open3.capture3(env, "git", "-C", root, "-c", "core.hooksPath=#{File::NULL}", *args)
    assert status.success?, err
    out
  end

  def commit(root)
    git(root, "add", "--", ".")
    git(root, "-c", "user.name=Synthetic Public Test", "-c", "user.email=synthetic@example.invalid", "commit", "-qm", "Independent public fixture")
  end

  def snapshot_target
    Dir.glob(File.join(@target, "**/*"), File::FNM_DOTMATCH).sort.filter_map do |file|
      relative = file.delete_prefix("#{@target}/")
      next if relative == "." || relative == ".git" || relative.start_with?(".git/")
      [relative, File.file?(file) ? File.binread(file) : :directory]
    end.to_h
  end

  # Permit the real local Git plumbing while rejecting execution of target
  # tools and network clients before they can run.
  def guard_static_operations(prohibited_reads: nil, &body)
    git_read = ->(original, *args, **options, &block) {
      command = args.drop(5).take_while { |argument| argument.is_a?(String) }
      while command[0] == "-c" && command[1].is_a?(String) &&
          command[1].match?(/\Afilter\.[\w.-]+\.(?:(?:clean|process)=|required=false)\z/)
        command = command.drop(2)
      end
      read_only = %w[rev-parse status symbolic-ref ls-files check-ignore ls-tree cat-file diff diff-index show].include?(command[0]) ||
        command == %w[config --null --name-only --list]
      allowed = args[1, 4] == ["git", "--no-optional-locks", "-c", "core.fsmonitor=false"] && read_only
      flunk "unexpected subprocess during static processing (#{command.first.inspect})" unless allowed
      original.call(*args, **options, &block)
    }
    prohibited = ->(*) { flunk "process or network execution attempted during static processing" }
    seams = [[Open3.singleton_class, :capture3, git_read], [Open3.singleton_class, :popen3, git_read],
      [Open3.singleton_class, :popen2, git_read],
      [Kernel, :spawn, git_read], [Process.singleton_class, :spawn, git_read],
      [Kernel, :system, prohibited], [Kernel, :exec, prohibited], [Kernel, :`, prohibited],
      [IO.singleton_class, :popen, prohibited], [Socket.singleton_class, :tcp, prohibited], [TCPSocket.singleton_class, :new, prohibited]]
    if prohibited_reads
      read = ->(original, file, *args, **options, &block) {
        flunk "prohibited bounded evidence read" if prohibited_reads.match?(file.to_s)
        original.call(file, *args, **options, &block)
      }
      %i[binread read open].each { |method| seams << [File.singleton_class, method, read] }
    end
    guarded = seams.reverse.inject(body) do |inner, (owner, name, replacement)|
      -> { with_replaced_method(owner, name, replacement, &inner) }
    end
    guarded.call
  end
end
