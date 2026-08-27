# frozen_string_literal: true

require "fileutils"
require "open3"
require "rbconfig"
require "tmpdir"

class ClaudeExploreHarness
  REPOSITORY_ROOT = File.expand_path("../..", __dir__)
  INSTALLER = File.join(REPOSITORY_ROOT, "agent-runtimes/claude-explore/install.sh")

  attr_reader :root, :home, :fake_bin, :env, :claude_launcher, :claude_target

  def initialize(prefix: "claude-explore-test-")
    @root = Dir.mktmpdir(prefix)
    @home = File.join(root, "home")
    @fake_bin = File.join(root, "fake-bin")
    FileUtils.mkdir_p([home, fake_bin])
    @claude_target = File.join(root, "claude-2.1.224")
    @claude_launcher = File.join(fake_bin, "claude")
    write_executable(claude_target, fake_claude("2.1.224"))
    File.symlink(claude_target, claude_launcher)
    %w[git psql].each { |name| write_executable(File.join(fake_bin, name), fake_delegate(name)) }
    @env = {
      "HOME" => home,
      "XDG_DATA_HOME" => File.join(root, "data"),
      "XDG_CONFIG_HOME" => File.join(root, "config"),
      "XDG_RUNTIME_DIR" => File.join(root, "run"),
      "PATH" => "#{fake_bin}:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
      "FAKE_CLAUDE_LOG" => File.join(root, "claude.log"),
      "FAKE_DELEGATE_LOG" => File.join(root, "delegate.log"),
      "FAKE_SETTINGS_COPY" => File.join(root, "settings.json"),
      "FAKE_MCP_COPY" => File.join(root, "mcp.json"),
      "FAKE_ENV_LOG" => File.join(root, "environment.log"),
      "FAKE_GIT_INJECTION_MARKER" => File.join(root, "git-injection"),
      "FAKE_PSQLRC_MARKER" => File.join(root, "psqlrc-ran"),
      "FAKE_PGPASS_MARKER" => File.join(root, "pgpass-used"),
      "FAKE_PSQL_STDIN_MARKER" => File.join(root, "psql-stdin-used")
    }
    FileUtils.mkdir_p(env.fetch("XDG_RUNTIME_DIR"))
  end

  def cleanup
    FileUtils.remove_entry_secure(root) if File.exist?(root)
  end

  def install(operation = "install", claude: claude_launcher, extra_env: {})
    install_from(INSTALLER, operation, claude:, extra_env:)
  end

  def install_from(installer, operation = "install", claude: claude_launcher, extra_env: {})
    arguments = ["/bin/sh", installer, operation]
    arguments.concat(["--claude-bin", claude]) if claude
    run(arguments, extra_env: extra_env)
  end

  def runtime(*arguments, extra_env: {})
    run([installed_launcher, *arguments], extra_env: extra_env)
  end

  def run(command, extra_env: {})
    Open3.capture3(env.merge(extra_env), *command, chdir: REPOSITORY_ROOT)
  end

  def installed_launcher
    File.join(home, ".local/bin/claude-explore")
  end

  def metadata
    File.join(env.fetch("XDG_CONFIG_HOME"), "agent-development-framework/claude-explore/install.meta")
  end

  def data_root
    File.join(env.fetch("XDG_DATA_HOME"), "agent-development-framework/claude-explore")
  end

  def current_runtime
    File.realpath(File.join(data_root, "current"))
  end

  def replace_claude(version: "2.1.225")
    replacement = File.join(root, "claude-#{version}")
    write_executable(replacement, fake_claude(version))
    FileUtils.rm(claude_launcher)
    File.symlink(replacement, claude_launcher)
    replacement
  end

  def runtime_source_path(name)
    File.join(current_runtime, "lib", name)
  end

  def copy_runtime_source(version: nil, fail_metadata_activation: false)
    source = File.join(REPOSITORY_ROOT, "agent-runtimes", "claude-explore")
    destination = File.join(root, "source-#{version || "copy"}")
    FileUtils.cp_r(source, destination, preserve: true)
    if version
      policy = File.join(destination, "policy.sh")
      contents = File.read(policy).sub("CLAUDE_EXPLORE_RUNTIME_VERSION=1", "CLAUDE_EXPLORE_RUNTIME_VERSION=#{version}")
      File.write(policy, contents)
      File.chmod(0o600, policy)
    end
    if fail_metadata_activation
      installer = File.join(destination, "lib/claude_explore_installer.sh")
      contents = File.read(installer).sub(
        'mv "$STAGED_METADATA" "$METADATA_FILE" || activation_fail "cannot activate installation metadata"',
        'false || activation_fail "injected metadata activation failure"'
      )
      File.write(installer, contents)
      File.chmod(0o700, installer)
    end
    destination
  end

  def replace_installed_runtime_text(file, before, after)
    path = File.join(current_runtime, file)
    contents = File.read(path)
    raise "test replacement was not found" unless contents.include?(before)

    File.write(path, contents.sub(before, after))
    File.chmod(0o700, path)
  end

  def replace_claude_with_signal_runtime
    replacement = File.join(root, "claude-signal-runtime")
    script = <<~RUBY
      #!#{RbConfig.ruby}
      if ARGV.first == "--version"
        puts "Claude Code 2.1.224"
        exit 0
      end
      File.write(ENV.fetch("FAKE_STARTED"), "started\n")
      Signal.trap("INT") { exit 130 }
      Signal.trap("TERM") { exit 143 }
      sleep
    RUBY
    write_executable(replacement, script)
    FileUtils.rm(claude_launcher)
    File.symlink(replacement, claude_launcher)
    replacement
  end

  def write_executable(path, contents)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents)
    File.chmod(0o700, path)
  end

  def read(path)
    File.exist?(path) ? File.read(path) : ""
  end

  private

  def fake_claude(default_version)
    <<~SH
      #!/bin/sh
      if [ "\${1:-}" = "--version" ]; then
        echo "Claude Code \${FAKE_CLAUDE_VERSION:-#{default_version}}"
        exit "\${FAKE_VERSION_EXIT:-0}"
      fi
      : > "\$FAKE_CLAUDE_LOG"
      previous=
      for argument in "\$@"; do
        printf '%s\n' "\$argument" >> "\$FAKE_CLAUDE_LOG"
        if [ "\$previous" = settings ]; then /bin/cp "\$argument" "\$FAKE_SETTINGS_COPY"; fi
        if [ "\$previous" = mcp ]; then /bin/cp "\$argument" "\$FAKE_MCP_COPY"; fi
        previous=
        [ "\$argument" = --settings ] && previous=settings
        [ "\$argument" = --mcp-config ] && previous=mcp
      done
      /usr/bin/env > "\$FAKE_ENV_LOG"
      case "\${FAKE_INNER_SCENARIO:-}" in
        blocked) "\$FAKE_COMMAND" ; exit \$? ;;
        git-allowed) git status ; exit \$? ;;
        git-env) GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.status GIT_CONFIG_VALUE_0='!marker-command' git status ; exit \$? ;;
        git-push) git push origin main ; exit \$? ;;
        psql-db) psql -d mydb ; exit \$? ;;
        psql-command) psql -d mydb -c 'select 1' ; exit \$? ;;
        psql-meta) psql -d mydb -c '\\connect postgresql://remote.example/db' ; exit \$? ;;
        psql-file) psql -d mydb -f commands.sql ; exit \$? ;;
        psql-stdin) printf '\\connect postgresql://remote.example/db\n' | psql -d mydb ; exit \$? ;;
        psql-env) PGHOST=remote.example psql ; exit \$? ;;
        psql-query) psql 'postgresql://localhost/db?host=remote.example' ; exit \$? ;;
      esac
      if [ "\${FAKE_WAIT:-}" = 1 ]; then
        trap 'exit 130' INT
        trap 'exit 143' TERM
        : > "\$FAKE_STARTED"
        while :; do sleep 1; done
      fi
      exit "\${FAKE_CLAUDE_EXIT:-0}"
    SH
  end

  def fake_delegate(name)
    <<~SH
      #!/bin/sh
      if [ "#{name}" = git ] && [ "\${GIT_CONFIG_COUNT-unset}" != unset ]; then
        : > "\$FAKE_GIT_INJECTION_MARKER"
      fi
      if [ "#{name}" = psql ]; then
        case " \$* " in *" -X "*) ;; *) [ -z "\${FAKE_PSQLRC_MARKER:-}" ] || : > "\$FAKE_PSQLRC_MARKER" ;; esac
        if [ -z "\${PGPASSFILE:-}" ] || [ "\$PGPASSFILE" = "\$HOME/.pgpass" ]; then
          [ -z "\${FAKE_PGPASS_MARKER:-}" ] || : > "\$FAKE_PGPASS_MARKER"
        fi
        if IFS= read -r ignored; then [ -z "\${FAKE_PSQL_STDIN_MARKER:-}" ] || : > "\$FAKE_PSQL_STDIN_MARKER"; fi
      fi
      printf '#{name}' >> "$FAKE_DELEGATE_LOG"
      for argument in "\$@"; do printf ' <%s>' "\$argument" >> "$FAKE_DELEGATE_LOG"; done
      printf ' PGHOST=%s GIT_CONFIG_COUNT=%s GIT_CONFIG_KEY_0=%s GIT_CONFIG_VALUE_0=%s PGPASSFILE=%s\n' \
        "\${PGHOST-unset}" "\${GIT_CONFIG_COUNT-unset}" "\${GIT_CONFIG_KEY_0-unset}" "\${GIT_CONFIG_VALUE_0-unset}" "\${PGPASSFILE-unset}" >> "$FAKE_DELEGATE_LOG"
      exit 0
    SH
  end
end
