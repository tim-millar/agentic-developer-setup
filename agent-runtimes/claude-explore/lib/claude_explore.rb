# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "pathname"
require "rbconfig"
require "tmpdir"
require "uri"
require "yaml"

module ClaudeExplore
  RUNTIME_ID = "claude-explore"
  RUNTIME_VERSION = 1
  POLICY_SCHEMA_VERSION = 1
  RUNTIME_GUIDANCE = <<~TEXT.strip.freeze
    A CLAUDE_EXPLORE_BLOCKED result is an intentional runtime authority boundary. Report the blocked
    action and the state of local work for human-controlled follow-up. Do not recommend unrestricted
    Claude, restoring stripped credentials, locating an alternate real binary, disabling the guard
    path, editing installed policy, or using an unrestricted shell to bypass the runtime.
  TEXT

  class Error < StandardError; end

  def self.load_yaml(path)
    YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false, filename: path)
  end

  Result = Struct.new(:decision, :category, :rule, :operation, :reason, keyword_init: true) do
    def allowed?
      decision == "allowed"
    end
  end

  class Policy
    attr_reader :data, :path

    def initialize(path)
      @path = File.expand_path(path)
      @data = ClaudeExplore.load_yaml(@path)
      validate!
    rescue Psych::Exception => e
      raise Error, "invalid runtime policy: #{e.message.lines.first.strip}"
    end

    def runtime; data.fetch("runtime"); end
    def commands; data.fetch("commands"); end
    def environment; data.fetch("environment"); end
    def credential_files; data.fetch("credential_files").fetch("deny_read"); end
    def native_controls; data.fetch("native_controls"); end
    def policy_version; runtime.fetch("version"); end
    def minimum_claude_version; runtime.fetch("minimum_claude_version"); end
    def denied_exit_status; commands.fetch("denied_exit_status"); end
    def blocked_identifier; data.dig("diagnostics", "blocked_identifier"); end
    def classification_identifier; data.dig("diagnostics", "classification_identifier"); end
    def next_action; data.dig("diagnostics", "next_action"); end

    def blocked_executables
      commands.fetch("blocked").each_with_object({}) do |(category, definition), result|
        definition.fetch("executables").each { |name| result[name] = [category, definition] }
      end
    end

    def guarded_names
      (blocked_executables.keys + %w[git psql]).uniq.sort
    end

    private

    def validate!
      raise Error, "runtime policy must be a mapping" unless data.is_a?(Hash)
      raise Error, "unsupported policy schema version; expected 1" unless data["schema_version"] == POLICY_SCHEMA_VERSION
      raise Error, "unexpected runtime identity" unless data.dig("runtime", "id") == RUNTIME_ID
      raise Error, "unexpected runtime version" unless data.dig("runtime", "version") == RUNTIME_VERSION
      raise Error, "denied command exit status must be 126" unless data.dig("commands", "denied_exit_status") == 126
      raise Error, "minimum Claude version must be 2.1.224" unless minimum_claude_version == "2.1.224"
      required_native = {
        ["sandbox", "enabled"] => true,
        ["sandbox", "fail_if_unavailable"] => true,
        ["sandbox", "allow_unsandboxed_commands"] => false,
        ["disable_all_hooks"] => true,
        ["disable_artifact"] => true,
        ["deny_mcp_tools"] => true
      }
      required_native.each do |keys, expected|
        actual = keys.reduce(native_controls) { |value, key| value.is_a?(Hash) ? value[key] : nil }
        raise Error, "runtime policy weakens required native control #{keys.join('.')}" unless actual == expected
      end
      raise Error, "runtime policy has invalid stable diagnostic identifiers" unless blocked_identifier == "CLAUDE_EXPLORE_BLOCKED" && classification_identifier == "CLAUDE_EXPLORE_CLASSIFICATION"
      raise Error, "runtime policy has an invalid safe next action" unless next_action.is_a?(String) && !next_action.empty?

      lists = [environment["unset"], credential_files, guarded_names,
               commands.dig("git", "allowed_local"), commands.dig("git", "blocked_remote")]
      raise Error, "runtime policy contains an invalid list" unless lists.all? { |list| list.is_a?(Array) }
      raise Error, "runtime policy contains duplicate list entries" unless lists.all? { |list| list.uniq == list }
      raise Error, "runtime policy contains a non-string list entry" unless lists.all? { |list| list.all? { |entry| entry.is_a?(String) && !entry.empty? } }
      raise Error, "runtime policy contains an invalid executable name" unless guarded_names.all? { |name| name.match?(/\A[a-z0-9][a-z0-9-]*\z/) }
      expected_environment = {"GIT_TERMINAL_PROMPT" => "0", "GCM_INTERACTIVE" => "never", "AWS_EC2_METADATA_DISABLED" => "true"}
      raise Error, "runtime policy weakens required safe environment values" unless environment["set"] == expected_environment
    end
  end

  class Classifier
    GIT_OPTIONS_WITH_VALUE = %w[-C -c --git-dir --work-tree --namespace --super-prefix --config-env].freeze
    GIT_BOOLEAN_OPTIONS = %w[--bare --no-pager --paginate -p --no-replace-objects --literal-pathspecs
                             --glob-pathspecs --noglob-pathspecs --icase-pathspecs --no-optional-locks].freeze
    BRANCH_MUTATIONS = %w[--set-upstream-to -u --unset-upstream].freeze
    CONFIG_READ_OPTIONS = %w[--get --get-all --get-regexp --list -l --show-origin --show-scope].freeze
    CONFIG_WRITE_OPTIONS = %w[--add --replace-all --unset --unset-all --rename-section --remove-section --edit -e].freeze
    TAG_READ_OPTIONS = %w[--list -l --contains --no-contains --merged --no-merged --points-at --column
                          --sort --format --color --ignore-case].freeze

    def initialize(policy)
      @policy = policy
    end

    def classify(argv)
      return blocked("command", "command.missing", "missing-command", "a command is required") if argv.empty?

      executable = File.basename(argv.first.to_s)
      args = argv.drop(1)
      return classify_git(args) if executable == "git"
      return classify_psql(args) if executable == "psql"

      blocked_definition = @policy.blocked_executables[executable]
      return allowed("command", "command.unclassified", executable) unless blocked_definition

      category, definition = blocked_definition
      blocked(category, definition.fetch("rule"), executable, definition.fetch("reason"))
    end

    private

    def classify_git(args)
      subcommand, subcommand_args = git_subcommand(args)
      return blocked_git("unclassified", "missing-subcommand") unless subcommand

      git = @policy.commands.fetch("git")
      if git.fetch("blocked_remote").include?(subcommand)
        return blocked_git("remote_mutation", subcommand)
      end
      return allowed_git(subcommand) if git.fetch("allowed_local").include?(subcommand)

      case subcommand
      when "branch" then classify_git_branch(subcommand_args)
      when "remote" then classify_git_remote(subcommand_args)
      when "config" then classify_git_config(subcommand_args)
      when "tag" then classify_git_tag(subcommand_args)
      when "submodule" then classify_git_submodule(subcommand_args)
      else blocked_git("unclassified", subcommand)
      end
    end

    def git_subcommand(args)
      index = 0
      while index < args.length
        argument = args[index]
        return [argument, args.drop(index + 1)] unless argument.start_with?("-")
        return [nil, []] if argument == "--"

        if GIT_OPTIONS_WITH_VALUE.include?(argument)
          index += 2
        elsif GIT_OPTIONS_WITH_VALUE.any? { |option| argument.start_with?("#{option}=") }
          index += 1
        elsif GIT_BOOLEAN_OPTIONS.include?(argument) || argument == "--version" || argument == "--help"
          index += 1
        else
          return [nil, []]
        end
      end
      [nil, []]
    end

    def classify_git_branch(args)
      if args.any? { |arg| BRANCH_MUTATIONS.include?(arg) || arg.start_with?("--set-upstream-to=") }
        blocked_git("upstream_mutation", "branch upstream-change")
      else
        allowed_git("branch")
      end
    end

    def classify_git_remote(args)
      return allowed_git("remote list") if args.empty? || args.all? { |arg| %w[-v --verbose].include?(arg) }

      get_url_index = args.index("get-url")
      if get_url_index && args.take(get_url_index).all? { |arg| %w[-v --verbose].include?(arg) }
        rest = args.drop(get_url_index + 1)
        names = rest.reject { |arg| arg == "--all" }
        return allowed_git("remote get-url") if names.length == 1 && rest.all? { |arg| arg == "--all" || !arg.start_with?("-") }
      end
      blocked_git("remote_configuration", "remote mutation-or-query")
    end

    def classify_git_config(args)
      return blocked_git("config_mutation", "config mutation") if args.any? { |arg| CONFIG_WRITE_OPTIONS.include?(arg) }

      read_option = args.any? do |arg|
        CONFIG_READ_OPTIONS.include?(arg) || CONFIG_READ_OPTIONS.any? { |option| arg.start_with?("#{option}=") }
      end
      mutating_value_form = args.reject { |arg| arg.start_with?("-") }.length > 1 && !read_option
      if read_option && !mutating_value_form
        allowed_git("config read")
      else
        blocked_git("config_mutation", "config unclassified")
      end
    end

    def classify_git_tag(args)
      return allowed_git("tag list") if args.empty?
      return blocked_git("tag_mutation", "tag mutation") if args.any? { |arg| %w[-d --delete -a --annotate -s --sign -u --local-user -f --force].include?(arg) }

      options = args.select { |arg| arg.start_with?("-") }
      values = args.reject { |arg| arg.start_with?("-") }
      recognised = options.all? do |arg|
        TAG_READ_OPTIONS.include?(arg) || TAG_READ_OPTIONS.any? { |option| arg.start_with?("#{option}=") }
      end
      recognised && (!options.empty? || values.empty?) ? allowed_git("tag list") :
        blocked_git("tag_mutation", "tag mutation")
    end

    def classify_git_submodule(args)
      operation = args.find { |arg| !arg.start_with?("-") } || "unclassified"
      blocked_git("submodule_network", "submodule #{operation}")
    end

    def classify_psql(args)
      host = nil
      explicit_connection = nil
      index = 0
      while index < args.length
        argument = args[index]
        case argument
        when "-h", "--host"
          return blocked_psql("ambiguous", "missing-host") unless args[index + 1]
          host = args[index + 1]
          index += 2
          next
        when /\A--host=(.*)\z/
          host = Regexp.last_match(1)
        when "-d", "--dbname"
          return blocked_psql("ambiguous", "missing-database") unless args[index + 1]
          explicit_connection = args[index + 1]
          index += 2
          next
        when /\A--dbname=(.*)\z/
          explicit_connection = Regexp.last_match(1)
        else
          if !argument.start_with?("-") && connection_value?(argument)
            explicit_connection ||= argument
          end
        end
        index += 1
      end

      return classify_connection_value(explicit_connection) if explicit_connection
      return allowed_psql("local-socket") unless host
      return allowed_psql("local-host") if local_host?(host)

      blocked_psql("remote", "remote-connection")
    end

    def connection_value?(value)
      value.start_with?("postgres://", "postgresql://") || value.include?("=")
    end

    def classify_connection_value(value)
      return blocked_psql("ambiguous", "service-connection") if value.match?(/(?:\A|\s)service\s*=/i)
      return blocked_psql("ambiguous", "key-value-connection") if value.include?("=") && !value.start_with?("postgres://", "postgresql://")
      return blocked_psql("ambiguous", "ambiguous-connection") unless value.start_with?("postgres://", "postgresql://")

      uri = URI.parse(value)
      return blocked_psql("ambiguous", "ambiguous-connection") unless uri.host
      uri_host = uri.host.sub(/\A\[(.*)\]\z/, "\\1")
      local_host?(uri_host) ? allowed_psql("local-uri") : blocked_psql("remote", "remote-connection")
    rescue URI::InvalidURIError
      blocked_psql("ambiguous", "ambiguous-connection")
    end

    def local_host?(host)
      host.start_with?("/") || @policy.commands.dig("psql", "local_hosts").include?(host)
    end

    def allowed_git(operation); allowed("git", @policy.commands.dig("git", "rules", "allowed"), operation); end
    def blocked_git(rule_key, operation); blocked("git", @policy.commands.dig("git", "rules", rule_key), operation, @policy.commands.dig("git", "reasons", rule_key)); end
    def allowed_psql(operation); allowed("database", @policy.commands.dig("psql", "rules", "allowed"), "psql #{operation}"); end
    def blocked_psql(rule_key, operation); blocked("database", @policy.commands.dig("psql", "rules", rule_key), "psql #{operation}", @policy.commands.dig("psql", "reasons", rule_key)); end
    def allowed(category, rule, operation); Result.new(decision: "allowed", category: category, rule: rule, operation: operation, reason: nil); end
    def blocked(category, rule, operation, reason); Result.new(decision: "blocked", category: category, rule: rule, operation: operation, reason: reason); end
  end

  module Diagnostics
    module_function

    def blocked(policy, result, io: $stderr)
      io.puts policy.blocked_identifier
      io.puts "runtime=#{RUNTIME_ID}"
      io.puts "policy_version=#{policy.policy_version}"
      io.puts "category=#{result.category}"
      io.puts "operation=#{result.operation}"
      io.puts "rule=#{result.rule}"
      io.puts "reason=#{result.reason}"
      io.puts "next_action=#{policy.next_action}"
    end

    def classification(policy, result, io: $stdout)
      io.puts policy.classification_identifier
      io.puts "decision=#{result.decision}"
      io.puts "category=#{result.category}"
      io.puts "rule=#{result.rule}"
      io.puts "operation=#{result.operation}"
      io.puts "expected_exit=#{result.allowed? ? 'delegate' : policy.denied_exit_status}"
    end
  end

  module Executable
    module_function

    def resolve(name, path: ENV.fetch("PATH", ""), reject: [])
      path.split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.expand_path(name, directory.empty? ? Dir.pwd : directory)
        resolved = canonical(candidate, reject: reject)
        return resolved if resolved
      end
      nil
    end

    def canonical(path, reject: [])
      real = File.realpath(path)
      return unless File.file?(real) && File.executable?(real)
      return if reject.map { |item| File.expand_path(item) }.include?(real)

      real
    rescue Errno::ENOENT, Errno::ELOOP, Errno::EACCES
      nil
    end

    def version(path)
      stdout, stderr, status = Open3.capture3(path, "--version")
      raise Error, "Claude version command failed" unless status.success?

      match = "#{stdout}\n#{stderr}".match(/(?<!\d)(\d+\.\d+\.\d+)(?!\d)/)
      raise Error, "Claude version could not be parsed" unless match

      match[1]
    end

    def require_version!(actual, minimum)
      actual_parts = actual.split(".").map { |part| Integer(part, 10) }
      minimum_parts = minimum.split(".").map { |part| Integer(part, 10) }
      raise Error, "Claude Code #{actual} is unsupported; require >= #{minimum}" if (actual_parts <=> minimum_parts) == -1
    rescue ArgumentError
      raise Error, "Claude version could not be parsed"
    end
  end

  module Guard
    module_function

    def run(command, args, policy_path: ENV.fetch("CLAUDE_EXPLORE_POLICY"))
      policy = Policy.new(policy_path)
      result = Classifier.new(policy).classify([command, *args])
      unless result.allowed?
        Diagnostics.blocked(policy, result)
        return policy.denied_exit_status
      end

      real = Executable.resolve(command, path: ENV.fetch("CLAUDE_EXPLORE_ORIGINAL_PATH", ""), reject: [File.expand_path($PROGRAM_NAME)])
      raise Error, "allowed executable is unavailable: #{command}" unless real

      pid = Process.spawn(real, *args, in: :in, out: :out, err: :err)
      _pid, status = Process.wait2(pid)
      status.exitstatus || 128 + status.termsig
    rescue Error => e
      warn "claude-explore: #{e.message}"
      125
    end
  end

  class Runtime
    attr_reader :runtime_root, :metadata, :policy

    def initialize(runtime_root:, metadata_path: self.class.default_metadata_path)
      @runtime_root = File.realpath(runtime_root)
      @metadata_path = File.expand_path(metadata_path)
      @metadata = ClaudeExplore.load_yaml(@metadata_path)
      @policy = Policy.new(File.join(@runtime_root, "policy.yml"))
      validate_installation!
    rescue Errno::ENOENT, Psych::Exception => e
      raise Error, "installed runtime state is unavailable or invalid: #{e.message}"
    end

    def self.default_metadata_path
      config_home = ENV["XDG_CONFIG_HOME"] || File.join(Dir.home, ".config")
      File.join(config_home, "agent-development-framework", RUNTIME_ID, "installation.yml")
    end

    def run(argv)
      case argv.first
      when "--claude-explore-runtime-info"
        return invalid_invocation if argv.length != 1
        runtime_info
        0
      when "--claude-explore-check-command"
        return invalid_invocation unless argv[1] == "--" && argv.length > 2
        result = Classifier.new(policy).classify(argv.drop(2))
        Diagnostics.classification(policy, result)
        result.allowed? ? 0 : policy.denied_exit_status
      else
        launch(argv)
      end
    rescue Error => e
      warn "claude-explore: #{e.message}"
      1
    end

    def runtime_info(io: $stdout)
      claude, version = validated_claude
      io.puts "runtime_id=#{RUNTIME_ID}"
      io.puts "runtime_version=#{RUNTIME_VERSION}"
      io.puts "policy_schema_version=#{POLICY_SCHEMA_VERSION}"
      io.puts "policy_version=#{policy.policy_version}"
      io.puts "installed_runtime_path=#{runtime_root}"
      io.puts "real_claude_path=#{claude}"
      io.puts "claude_version=#{version}"
      io.puts "supported_platform=#{platform}"
      io.puts "sandbox_required=true"
      io.puts "unsandboxed_retry_allowed=false"
      io.puts "guarded_commands=#{policy.guarded_names.join(',')}"
      io.puts "stripped_environment=#{policy.environment.fetch('unset').join(',')}"
      io.puts "credential_file_denies=#{policy.credential_files.join(',')}"
      io.puts "known_limitations=not-hostile-code-containment,finite-command-list,absolute-path-bypass,residual-network-and-configuration-authority"
    end

    def generated_settings
      native = policy.native_controls
      sandbox = native.fetch("sandbox")
      credential_denies = policy.credential_files.flat_map { |path| ["Read(#{path})", "Read(#{path}/**)"] }
      denies = (native.fetch("deny_mcp_tools") ? ["mcp__*"] : []) + credential_denies
      {
        "sandbox" => {
          "enabled" => sandbox.fetch("enabled"),
          "failIfUnavailable" => sandbox.fetch("fail_if_unavailable"),
          "allowUnsandboxedCommands" => sandbox.fetch("allow_unsandboxed_commands"),
          "filesystem" => {"denyRead" => policy.credential_files}
        },
        "disableAllHooks" => native.fetch("disable_all_hooks"),
        "disableArtifact" => native.fetch("disable_artifact"),
        "permissions" => {"deny" => denies}
      }
    end

    private

    def launch(argv)
      claude, = validated_claude
      session_root = Dir.mktmpdir("claude-explore-")
      File.chmod(0o700, session_root)
      begin
        env, settings = prepare_session(session_root)
        command = [claude, "--settings", settings, "--append-system-prompt", RUNTIME_GUIDANCE, *argv]
        spawn_and_wait(env, command)
      ensure
        FileUtils.remove_entry_secure(session_root) if session_root && File.directory?(session_root)
      end
    end

    def prepare_session(session_root)
      guard_dir = File.join(session_root, "guard")
      gh_dir = File.join(session_root, "gh")
      FileUtils.mkdir_p([guard_dir, gh_dir], mode: 0o700)
      settings = File.join(session_root, "settings.json")
      File.write(settings, JSON.pretty_generate(generated_settings), mode: "w", perm: 0o600)
      askpass = File.join(session_root, "git-askpass")
      File.write(askpass, "#!/bin/sh\necho 'claude-explore: Git credential prompts are disabled' >&2\nexit 1\n", mode: "w", perm: 0o700)
      write_guards(guard_dir)

      env = ENV.to_h
      policy.environment.fetch("unset").each { |name| env[name] = nil }
      policy.environment.fetch("set").each { |name, value| env[name] = value }
      env["GH_CONFIG_DIR"] = gh_dir
      env["GIT_ASKPASS"] = askpass
      env["CLAUDE_EXPLORE_ORIGINAL_PATH"] = env.fetch("PATH", "")
      env["CLAUDE_EXPLORE_POLICY"] = policy.path
      env["PATH"] = [guard_dir, env.fetch("PATH", "")].join(File::PATH_SEPARATOR)
      [env, settings]
    end

    def write_guards(guard_dir)
      library = File.join(runtime_root, "lib", "claude_explore.rb")
      policy.guarded_names.each do |command|
        path = File.join(guard_dir, command)
        source = <<~RUBY
          #!#{RbConfig.ruby}
          require #{library.dump}
          exit ClaudeExplore::Guard.run(#{command.dump}, ARGV)
        RUBY
        File.write(path, source, mode: "w", perm: 0o700)
      end
    end

    def spawn_and_wait(env, command)
      pid = Process.spawn(env, *command, in: :in, out: :out, err: :err)
      previous = {}
      %w[INT TERM].each do |signal|
        previous[signal] = Signal.trap(signal) { Process.kill(signal, pid) rescue nil }
      end
      _pid, status = Process.wait2(pid)
      status.exitstatus || 128 + status.termsig
    ensure
      previous&.each { |signal, handler| Signal.trap(signal, handler) }
    end

    def validated_claude
      recorded = metadata.fetch("claude_path")
      claude = Executable.canonical(recorded, reject: [File.join(runtime_root, "bin", RUNTIME_ID)])
      raise Error, "recorded Claude executable is missing or unsafe; repair the installation" unless claude == recorded

      version = Executable.version(claude)
      Executable.require_version!(version, policy.minimum_claude_version)
      [claude, version]
    end

    def validate_installation!
      raise Error, "installed metadata has the wrong runtime identity" unless metadata["runtime_id"] == RUNTIME_ID
      raise Error, "installed metadata has the wrong runtime version" unless metadata["runtime_version"] == RUNTIME_VERSION
      raise Error, "installed metadata points at another runtime" unless File.realpath(metadata.fetch("runtime_path")) == runtime_root
      raise Error, "unsupported platform" unless %w[darwin linux].include?(RbConfig::CONFIG.fetch("host_os").downcase.split(/[^a-z]/).first)

      %w[bin/claude-explore lib/claude_explore.rb policy.yml].each { |relative| validate_owned_file!(File.join(runtime_root, relative)) }
      validate_owned_file!(@metadata_path)
    rescue KeyError => e
      raise Error, "installed metadata is incomplete: #{e.message}"
    end

    def validate_owned_file!(path)
      raise Error, "security-relevant file must not be a symlink: #{path}" if File.symlink?(path)
      reject_runtime_symlink_traversal!(path) if File.expand_path(path).start_with?(runtime_root + File::SEPARATOR)
      real = File.realpath(path)
      root_prefix = runtime_root + File::SEPARATOR
      metadata_real = File.realpath(@metadata_path)
      unless (real == metadata_real || real.start_with?(root_prefix)) && File.file?(real)
        raise Error, "security-relevant file resolves outside its expected installation: #{path}"
      end
      stat = File.stat(real)
      raise Error, "security-relevant file is not owned by the current user: #{path}" unless stat.uid == Process.uid
      raise Error, "security-relevant file is group/world writable: #{path}" unless (stat.mode & 0o022).zero?
    end

    def reject_runtime_symlink_traversal!(path)
      relative = Pathname.new(File.expand_path(path)).relative_path_from(Pathname.new(runtime_root))
      current = runtime_root
      relative.each_filename do |component|
        current = File.join(current, component)
        raise Error, "security-relevant path traverses a symlink: #{path}" if File.symlink?(current)
      end
    end

    def platform
      RbConfig::CONFIG.fetch("host_os").include?("darwin") ? "macos" : "linux"
    end

    def invalid_invocation
      warn "claude-explore: invalid runtime-owned invocation"
      2
    end
  end
end
