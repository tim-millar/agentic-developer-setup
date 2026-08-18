# frozen_string_literal: true

require "fileutils"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

class LauncherHarness
  REPOSITORY_ROOT = File.expand_path("../..", __dir__)
  BASELINE_LAUNCHER = File.join(REPOSITORY_ROOT, "baseline", "scripts", "run_codex.sh")
  OWNER = "example-owner"
  REPOSITORY = "example-repository"
  APP_ID = "12345"
  INSTALLATION_ID = "67890"
  INSTALLATION_TOKEN = "synthetic-installation-token-canary"
  RENEWED_INSTALLATION_TOKEN = "synthetic-renewed-installation-token-canary"
  PRIVATE_KEY_CONTENT = "SYNTHETIC PRIVATE KEY CANARY - NOT A REAL KEY\n"
  APP_SLUG = "synthetic-launcher-app"
  TOKEN_EXPIRY = "2030-01-02T03:04:05Z"
  ALLOW_LOGIN_SHELL_CONFIG = "allow_login_shell=false"
  USE_SHELL_PROFILE_CONFIG = "shell_environment_policy.experimental_use_profile=false"
  BASH_DIRECTORY = ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).find do |directory|
    File.executable?(File.join(directory, "bash"))
  end || "/bin"

  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)

  attr_reader :root, :repository, :home, :tmpdir, :launcher, :prompt_file,
              :extra_prompt_file, :event_log, :codex_log, :started_marker,
              :signal_log, :key_file, :app_json, :token_json, :repository_json,
              :issue_json, :renewal_control_dir, :token_sequence_json,
              :token_attempt_file

  def initialize
    @root = File.realpath(Dir.mktmpdir("launcher-test-"))
    @repository = File.join(root, "adopted-repository")
    @home = File.join(root, "home")
    @tmpdir = File.join(root, "tmp")
    @fake_bin = File.join(root, "fake-bin")
    @event_log = File.join(root, "events.log")
    @codex_log = File.join(root, "codex.jsonl")
    @started_marker = File.join(root, "codex.started")
    @signal_log = File.join(root, "signals.log")
    @app_json = File.join(root, "app.json")
    @token_json = File.join(root, "token.json")
    @repository_json = File.join(root, "repository.json")
    @issue_json = File.join(root, "issue.json")
    @key_file = File.join(root, "synthetic-key.pem")
    @renewal_control_dir = File.join(root, "renewal-control")
    @token_sequence_json = File.join(root, "token-sequence.json")
    @token_attempt_file = File.join(root, "token-attempts")

    [repository, home, tmpdir, @fake_bin, renewal_control_dir].each { |path| FileUtils.mkdir_p(path) }
    build_fakes
    build_api_fixtures
    build_repository
  end

  def close
    FileUtils.remove_entry_secure(root) if root && File.exist?(root)
  end

  def base_env
    launcher_path = [@fake_bin, BASH_DIRECTORY, "/usr/bin", "/bin"].uniq.join(File::PATH_SEPARATOR)
    {
      "PATH" => launcher_path,
      "HOME" => home,
      "XDG_CONFIG_HOME" => File.join(home, ".config"),
      "TMPDIR" => tmpdir,
      "GIT_CONFIG_NOSYSTEM" => "1",
      "GIT_TERMINAL_PROMPT" => "0",
      "EXPECTED_OWNER" => OWNER,
      "EXPECTED_REPO" => REPOSITORY,
      "CODEX_BIN" => File.join(@fake_bin, "codex"),
      "GITHUB_ACCESS_MODE" => "disabled",
      "AGENT_NAME" => "test-agent",
      "AGENT_GIT_MODE" => "developer-author",
      "DEVELOPER_NAME" => "Test Developer",
      "DEVELOPER_EMAIL" => "developer@example.test",
      "FAKE_EVENT_LOG" => event_log,
      "FAKE_CODEX_LOG" => codex_log,
      "FAKE_CODEX_STARTED" => started_marker,
      "FAKE_CODEX_RELEASE" => codex_release_marker,
      "FAKE_SIGNAL_LOG" => signal_log,
      "FAKE_APP_JSON" => app_json,
      "FAKE_TOKEN_JSON" => token_json,
      "FAKE_REPOSITORY_JSON" => repository_json,
      "FAKE_ISSUE_JSON" => issue_json,
      "FAKE_EXPECTED_OWNER" => OWNER,
      "FAKE_EXPECTED_REPO" => REPOSITORY,
      "FAKE_EXPECTED_INSTALLATION_ID" => INSTALLATION_ID,
      "FAKE_EXPECTED_LAUNCHER_PATH" => launcher_path,
      "FAKE_KEY_VALID" => "1",
      "LANG" => "C.UTF-8"
    }
  end

  def app_env
    base_env.merge(
      "GITHUB_ACCESS_MODE" => "app",
      "GITHUB_APP_ID" => APP_ID,
      "GITHUB_APP_INSTALLATION_ID" => INSTALLATION_ID,
      "GITHUB_APP_PRIVATE_KEY_PATH" => key_file,
      "FAKE_CURL_MODE" => "app"
    )
  end

  def renewable_app_env
    app_env.merge(
      "AGENT_LAUNCHER_TEST_MODE" => "1",
      "FAKE_RENEWAL_CONTROL_DIR" => renewal_control_dir,
      "FAKE_TOKEN_SEQUENCE_JSON" => token_sequence_json,
      "FAKE_TOKEN_ATTEMPT_FILE" => token_attempt_file
    )
  end

  def run(*arguments, env: {}, chdir: root, stdin_data: "")
    stdout, stderr, status = Open3.capture3(
      base_env.merge(env),
      launcher,
      *arguments,
      chdir: chdir,
      stdin_data: stdin_data,
      unsetenv_others: true
    )
    Result.new(stdout: stdout, stderr: stderr, status: status)
  end

  def run_app(*arguments, env: {}, chdir: root)
    run(*arguments, env: app_env.merge(env), chdir: chdir)
  end

  def spawn(*arguments, env: {})
    Open3.popen3(
      base_env.merge(env),
      launcher,
      *arguments,
      chdir: root,
      unsetenv_others: true
    )
  end

  def write_repository_file(path, contents)
    absolute = File.join(repository, path)
    FileUtils.mkdir_p(File.dirname(absolute))
    File.write(absolute, contents)
    absolute
  end

  def remove_repository_file(path)
    FileUtils.rm_f(File.join(repository, path))
  end

  def commit_all(message = "Update fixture")
    git("add", "--all")
    git("commit", "-q", "-m", message)
  end

  def set_origin(url)
    git("remote", "set-url", "origin", url)
  end

  def remove_origin
    git("remote", "remove", "origin")
  end

  def codex_invocations
    return [] unless File.exist?(codex_log)

    File.readlines(codex_log, chomp: true).reject(&:empty?).map { |line| JSON.parse(line) }
  end

  def invocation
    codex_invocations.fetch(0)
  end

  def events
    return [] unless File.exist?(event_log)

    File.readlines(event_log, chomp: true)
  end

  def signals
    return [] unless File.exist?(signal_log)

    File.readlines(signal_log, chomp: true)
  end

  def launcher_temporary_paths
    Dir[File.join(tmpdir, "codex.{credentials,gh,askpass,host-env}.*")]
  end

  def inherited_path
    base_env.fetch("PATH")
  end

  def path_config(path = inherited_path)
    escaped = path
      .gsub("\\") { "\\\\" }
      .gsub('"') { '\\"' }
      .gsub(/[\x01-\x07\x0b\x0e-\x1f\x7f]/) { |character| format("\\u%04x", character.ord) }
      .gsub("\b") { "\\b" }
      .gsub("\t") { "\\t" }
      .gsub("\n") { "\\n" }
      .gsub("\f") { "\\f" }
      .gsub("\r") { "\\r" }
    %(shell_environment_policy.set.PATH="#{escaped}")
  end

  def expected_codex_args(*arguments, path: inherited_path)
    [*launcher_policy_args(path), *arguments]
  end

  def launcher_policy_args(path = inherited_path)
    [
      "-c", ALLOW_LOGIN_SHELL_CONFIG,
      "-c", USE_SHELL_PROFILE_CONFIG,
      "-c", path_config(path)
    ]
  end

  def write_host_env_hook(contents)
    write_repository_file("scripts/agent_host_env.sh", contents)
  end

  def debug_prompt_paths
    Dir[File.join(tmpdir, "codex.prompt.*")]
  end

  def write_json(path, value)
    File.write(path, JSON.generate(value))
  end

  def configure_token_sequence(*entries)
    write_json(token_sequence_json, entries)
  end

  def token_response(token, expires_at: TOKEN_EXPIRY)
    {"token" => token, "expires_at" => expires_at}
  end

  def renewal_failure
    {"failure" => true}
  end

  def renewal_timeout
    {"failure" => "timeout"}
  end

  def remove_renewal_wait_executable
    FileUtils.rm_f(File.join(@fake_bin, "launcher-test-sleep"))
  end

  def release_renewal_wait(ordinal)
    File.write(File.join(renewal_control_dir, "release-#{ordinal}"), "release\n")
  end

  def renewal_wait_started?(ordinal)
    File.exist?(File.join(renewal_control_dir, "wait-#{ordinal}.started"))
  end

  def renewal_wait_pid(ordinal)
    path = File.join(renewal_control_dir, "wait-#{ordinal}.pid")
    File.exist?(path) ? Integer(File.read(path), 10) : nil
  end

  def token_attempts
    File.exist?(token_attempt_file) ? Integer(File.read(token_attempt_file), 10) : 0
  end

  def release_codex
    File.write(File.join(root, "codex.release"), "release\n")
  end

  def codex_release_marker
    File.join(root, "codex.release")
  end

  def run_generated_helper(path, *arguments)
    stdout, stderr, status = Open3.capture3(
      {"PATH" => [BASH_DIRECTORY, "/usr/bin", "/bin"].uniq.join(File::PATH_SEPARATOR)},
      path,
      *arguments,
      unsetenv_others: true
    )
    Result.new(stdout: stdout, stderr: stderr, status: status)
  end

  def default_prompt
    File.read(prompt_file).sub(/\n\z/, "")
  end

  def expected_prompt(base: default_prompt, mode: "disabled", issue: nil, skipped: false,
                      extra_path: nil, extra: nil, prompt_path: "docs/AGENT_PROMPT.txt",
                      agent_name: "test-agent", git_mode: "developer-author",
                      developer_name: "Test Developer", developer_email: "developer@example.test")
    app = mode == "app"
    lines = [
      base,
      "",
      "----",
      "Session context:",
      "- Repository root: #{repository}",
      "- Current branch: main",
      "- GitHub repository: #{OWNER}/#{REPOSITORY}",
      "- GitHub access mode: #{mode}",
      "- GitHub App slug: #{app ? APP_SLUG : 'disabled'}",
      "- GitHub token expires at: #{app ? TOKEN_EXPIRY : 'n/a'}",
      "- Agent: #{agent_name}",
      "- Git mode: #{git_mode}",
      "- Prompt file: #{prompt_path}",
      "- Issue fetch skipped: #{skipped ? 1 : 0}",
      "GitHub tool-use policy for this session:"
    ]

    if app
      lines.concat([
        "- App mode provides repository write capability for this session.",
        "- Autonomous implementation of a supplied issue may activate the repository publication contract in AGENTS.md, including commit, push, pull-request publication, and verification when required.",
        "- Issue context alone does not require publication, and App mode alone does not require publication; determine the working mode from the task, human instructions, and repository state.",
        "- Use shell tools for GitHub operations.",
        "- Prefer git, gh, and curl with the provided environment credentials.",
        "- Git authentication reads launcher-managed renewable credentials automatically.",
        '- The launch-time gh and API token is static. If a gh or direct GitHub API operation fails with a possible authentication failure, obtain the current token from "$AGENT_GITHUB_TOKEN_HELPER" and retry the exact same operation once with that token.',
        "- If that one retry fails, do not retry again, seek GitHub App source credentials, or use ambient developer credentials; report the failure clearly.",
        "- Do not use internal GitHub tools, connectors, or built-in GitHub actions for pull requests, issues, branches, labels, comments, or repository mutations.",
        "- Do not fall back to any non-shell GitHub integration if a shell-based GitHub command fails.",
        "- If a GitHub operation cannot be completed through shell tools with the provided credentials, stop and report the failure clearly."
      ])
    else
      lines.concat([
        "- GitHub access is disabled for this session.",
        "- Do not use git, gh, curl, SSH, credential helpers, internal GitHub tools, connectors, or built-in GitHub actions to access GitHub.",
        "- Do not attempt to use human developer credentials or ambient machine credentials for GitHub access.",
        "- If GitHub access is required to complete a task, stop and report that this session was launched with GitHub disabled."
      ])
    end

    lines << "- Extra prompt file: #{extra_path}" if extra_path
    if developer_name || developer_email
      display_name = developer_name.to_s.empty? ? "unknown" : developer_name
      display_email = developer_email.to_s.empty? ? "" : " <#{developer_email}>"
      lines << "- Launched by: #{display_name}#{display_email}"
    end

    lines.concat(["", "----", "Issue context:"])
    if issue.nil?
      lines << "- No GitHub issue was provided for this session"
    elsif skipped
      lines << "- Issue: ##{issue}"
      lines << if app
                 "- GitHub issue fetch was skipped by --skip-issue-fetch"
               else
                 "- GitHub issue fetch was skipped because GitHub access is disabled"
               end
    else
      fixture = JSON.parse(File.read(issue_json))
      lines.concat([
        "- Issue: ##{issue}",
        "- Title: #{fixture.fetch('title')}",
        "- URL: #{fixture.fetch('html_url')}"
      ])
      labels = fixture.fetch("labels").map { |label| label.fetch("name") }.join(", ")
      lines << "- Labels: #{labels}" unless labels.empty?
      lines.concat(["", "Issue body:", fixture.fetch("body")])
    end

    lines.concat(["", "----", "Additional instructions:", extra]) if extra_path
    lines.join("\n")
  end

  private

  def build_repository
    FileUtils.mkdir_p(File.join(repository, "scripts"))
    FileUtils.mkdir_p(File.join(repository, "docs"))
    @launcher = File.join(repository, "scripts", "run_codex.sh")
    @prompt_file = File.join(repository, "docs", "AGENT_PROMPT.txt")
    @extra_prompt_file = File.join(repository, "docs", "EXTRA_PROMPT.txt")
    FileUtils.cp(BASELINE_LAUNCHER, launcher, preserve: true)
    File.chmod(0o755, launcher)
    File.write(prompt_file, "Base prompt for launcher tests.\n")

    git("init", "-q", "-b", "main")
    git("config", "user.name", "Fixture Committer")
    git("config", "user.email", "fixture@example.test")
    git("remote", "add", "origin", "https://github.com/#{OWNER}/#{REPOSITORY}.git")
    commit_all("Initial synthetic repository")
  end

  def git(*arguments)
    stdout, stderr, status = Open3.capture3(
      {
        "HOME" => home,
        "XDG_CONFIG_HOME" => File.join(home, ".config"),
        "GIT_CONFIG_NOSYSTEM" => "1",
        "PATH" => "/usr/bin:/bin",
        "TMPDIR" => tmpdir
      },
      "git",
      *arguments,
      chdir: repository,
      unsetenv_others: true
    )
    return stdout if status.success?

    raise "fixture git command failed: git #{arguments.join(' ')}\n#{stderr}"
  end

  def executable(name, content)
    path = File.join(@fake_bin, name)
    File.write(path, content)
    File.chmod(0o755, path)
    path
  end

  def build_fakes
    executable("codex", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"

      def state(name)
        return "unset" unless ENV.key?(name)
        return "empty" if ENV[name].empty?
        "set"
      end

      token = JSON.parse(File.read(ENV.fetch("FAKE_TOKEN_JSON")))["token"]
      safe_values = %w[
        AGENT_NAME AGENT_GIT_MODE AGENT_LAUNCHED_BY_NAME AGENT_LAUNCHED_BY_EMAIL
        AGENT_REPO_ROOT AGENT_GITHUB_ACCESS_MODE AGENT_PROMPT_FILE AGENT_ISSUE_NUMBER
        AGENT_EXTRA_PROMPT_FILE AGENT_GITHUB_TOKEN_HELPER GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME
        GIT_COMMITTER_EMAIL GH_CONFIG_DIR GIT_ASKPASS GIT_TERMINAL_PROMPT
        GCM_INTERACTIVE SSH_AUTH_SOCK GIT_SSH GIT_SSH_COMMAND SSH_ASKPASS
        GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_KEY_1
        GIT_CONFIG_VALUE_1 GIT_CONFIG_KEY_2 GIT_CONFIG_VALUE_2 PATH
        SYNTHETIC_UNRELATED_VARIABLE
      ]
      secrets = %w[GH_TOKEN GITHUB_TOKEN GITHUB_PAT INSTALL_TOKEN]
      sources = %w[
        GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH
        JWT TOKEN_JSON AGENT_LAUNCHER_TEST_MODE FAKE_RENEWAL_CONTROL_DIR
        FAKE_TOKEN_SEQUENCE_JSON FAKE_TOKEN_ATTEMPT_FILE
      ]
      record = {
        "executable" => File.basename($PROGRAM_NAME),
        "args" => ARGV,
        "cwd" => Dir.pwd,
        "env" => safe_values.to_h { |name| [name, {"state" => state(name), "value" => ENV[name]}] },
        "secret_env" => secrets.to_h { |name| [name, {"state" => state(name), "matches_installation_token" => ENV[name] == token}] },
        "source_env" => sources.to_h { |name| [name, {"state" => state(name)}] }
      }
      record["stdin"] = STDIN.read if ENV["FAKE_CODEX_READ_STDIN"] == "1"
      File.open(ENV.fetch("FAKE_CODEX_LOG"), "a", 0o600) { |file| file.puts(JSON.generate(record)) }
      File.open(ENV.fetch("FAKE_EVENT_LOG"), "a", 0o600) { |file| file.puts("codex:start") }
      File.write(ENV.fetch("FAKE_CODEX_STARTED"), Process.pid.to_s)

      if ENV["FAKE_CODEX_WAIT"] == "1"
        Signal.trap("INT") do
          File.open(ENV.fetch("FAKE_SIGNAL_LOG"), "a", 0o600) { |file| file.puts("INT") }
          File.open(ENV.fetch("FAKE_EVENT_LOG"), "a", 0o600) { |file| file.puts("codex:signal:INT") }
          exit 130
        end
        Signal.trap("TERM") do
          File.open(ENV.fetch("FAKE_SIGNAL_LOG"), "a", 0o600) { |file| file.puts("TERM") }
          File.open(ENV.fetch("FAKE_EVENT_LOG"), "a", 0o600) { |file| file.puts("codex:signal:TERM") }
          exit 143
        end
        sleep 0.01 until File.exist?(ENV.fetch("FAKE_CODEX_RELEASE"))
      end

      exit Integer(ENV.fetch("FAKE_CODEX_EXIT", "0"), 10)
    RUBY
    FileUtils.cp(File.join(@fake_bin, "codex"), File.join(@fake_bin, "alternate-codex"))

    executable("curl", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"

      abort "unexpected fake curl invocation" unless ENV["FAKE_CURL_MODE"] == "app"
      abort "launcher PATH changed before a security-sensitive command" unless ENV["PATH"] == ENV.fetch("FAKE_EXPECTED_LAUNCHER_PATH")
      method = "GET"
      headers = []
      connect_timeout = nil
      max_time = nil
      url = nil
      index = 0
      while index < ARGV.length
        case ARGV[index]
        when "-X"
          method = ARGV.fetch(index + 1)
          index += 2
        when "-H"
          headers << ARGV.fetch(index + 1)
          index += 2
        when "-d"
          index += 2
        when "--connect-timeout"
          connect_timeout = ARGV.fetch(index + 1)
          index += 2
        when "--max-time"
          max_time = ARGV.fetch(index + 1)
          index += 2
        else
          value = ARGV[index]
          url = value if value.start_with?("https://")
          index += 1
        end
      end
      authorization = headers.find { |header| header.start_with?("Authorization: ") }.to_s
      token = JSON.parse(File.read(ENV.fetch("FAKE_TOKEN_JSON"))).fetch("token")
      owner = ENV.fetch("FAKE_EXPECTED_OWNER")
      repository = ENV.fetch("FAKE_EXPECTED_REPO")
      installation = ENV.fetch("FAKE_EXPECTED_INSTALLATION_ID")
      app_auth = authorization.start_with?("Authorization: Bearer ") && (token.nil? || !authorization.end_with?(token))
      installation_auth = !token.to_s.empty? && authorization == "Authorization: Bearer \#{token}"
      issue_prefix = "https://api.github.com/repos/\#{owner}/\#{repository}/issues/"
      issue_id = url.to_s.delete_prefix(issue_prefix)
      endpoint, expected_method, fixture, auth_matches = if url == "https://api.github.com/app"
        ["app", "GET", ENV.fetch("FAKE_APP_JSON"), app_auth]
      elsif url == "https://api.github.com/app/installations/\#{installation}/access_tokens"
        ["token", "POST", ENV.fetch("FAKE_TOKEN_JSON"), app_auth]
      elsif url == "https://api.github.com/repos/\#{owner}/\#{repository}"
        ["repository", "GET", ENV.fetch("FAKE_REPOSITORY_JSON"), installation_auth]
      elsif url.start_with?(issue_prefix) && !issue_id.empty? && issue_id.each_char.all? { |character| character >= "0" && character <= "9" }
        ["issue", "GET", ENV.fetch("FAKE_ISSUE_JSON"), installation_auth]
      else
        abort "unexpected curl URL"
      end
      abort "unexpected curl method for \#{endpoint}" unless method == expected_method

      response = nil
      sequence_attempt = nil
      if endpoint == "token" && ENV["FAKE_TOKEN_SEQUENCE_JSON"]
        sequence = JSON.parse(File.read(ENV.fetch("FAKE_TOKEN_SEQUENCE_JSON")))
        sequence_attempt = if File.exist?(ENV.fetch("FAKE_TOKEN_ATTEMPT_FILE"))
          Integer(File.read(ENV.fetch("FAKE_TOKEN_ATTEMPT_FILE")), 10)
        else
          0
        end
        File.write(ENV.fetch("FAKE_TOKEN_ATTEMPT_FILE"), (sequence_attempt + 1).to_s)
        response = sequence.fetch(sequence_attempt, sequence.last)
      end

      File.open(ENV.fetch("FAKE_EVENT_LOG"), "a", 0o600) do |file|
        attempt = sequence_attempt.nil? ? "" : " attempt=\#{sequence_attempt + 1}"
        failure = response&.fetch("failure", false)
        outcome = if sequence_attempt.nil?
          ""
        elsif failure
          " outcome=\#{failure == true ? 'failure' : failure}"
        else
          " outcome=success"
        end
        timeouts = if connect_timeout || max_time
          " connect_timeout=\#{connect_timeout || 'unset'} max_time=\#{max_time || 'unset'}"
        else
          ""
        end
        file.puts("curl:\#{endpoint}\#{attempt}\#{outcome} method=\#{method} url=\#{url} auth_matches_expected=\#{auth_matches}\#{timeouts}")
      end
      abort "unexpected authorization category for \#{endpoint}" unless auth_matches
      abort "synthetic GitHub request failure" if response&.fetch("failure", false)
      STDOUT.write(response ? JSON.generate(response) : File.read(fixture))
    RUBY

    executable("jq", <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"

      query = ARGV.reject { |argument| argument == "-r" }.last
      begin
        value = JSON.parse(STDIN.read)
      rescue JSON::ParserError
        warn "invalid synthetic JSON"
        exit 4
      end
      result = case query
      when ".slug // empty" then value["slug"]
      when ".token // empty" then value["token"]
      when ".expires_at // empty" then value["expires_at"]
      when ".id // empty" then value["id"]
      when ".full_name // empty" then value["full_name"]
      when ".default_branch // empty" then value["default_branch"]
      when ".number // empty" then value["number"]
      when ".pull_request != null" then !value["pull_request"].nil?
      when '.title // ""' then value.fetch("title", "")
      when '.html_url // .url // ""' then value["html_url"] || value["url"] || ""
      when '.body // ""' then value.fetch("body", "")
      when '[.labels[].name] | join(", ")' then Array(value["labels"]).map { |label| label["name"] }.join(", ")
      when "del(.token)" then value.reject { |key, _| key == "token" }
      when "." then value
      else
        warn "unsupported synthetic jq query"
        exit 5
      end
      if result.is_a?(Hash) || result.is_a?(Array)
        puts JSON.generate(result)
      elsif result == true || result == false
        puts result
      elsif !result.nil?
        puts result
      end
    RUBY

    executable("openssl", <<~RUBY)
      #!#{RbConfig.ruby}
      require "base64"

      events = ENV.fetch("FAKE_EVENT_LOG")
      case ARGV.first
      when "pkey"
        File.open(events, "a", 0o600) { |file| file.puts("openssl:key-check") }
        exit(ENV["FAKE_KEY_VALID"] == "1" ? 0 : 1)
      when "base64"
        STDOUT.write(Base64.strict_encode64(STDIN.read))
      when "dgst"
        sources_present = %w[GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH].all? do |name|
          ENV.key?(name) && !ENV[name].empty?
        end
        File.open(events, "a", 0o600) { |file| file.puts("openssl:sign source_credentials_present=\#{sources_present}") }
        STDIN.read
        STDOUT.write("synthetic-signature")
      else
        warn "unexpected synthetic openssl invocation"
        exit 2
      end
    RUBY

    executable("launcher-test-sleep", <<~RUBY)
      #!#{RbConfig.ruby}

      control_dir = ENV.fetch("FAKE_RENEWAL_CONTROL_DIR")
      ordinal_path = File.join(control_dir, "wait-count")
      ordinal = File.exist?(ordinal_path) ? Integer(File.read(ordinal_path), 10) + 1 : 1
      File.write(ordinal_path, ordinal.to_s)
      File.write(File.join(control_dir, "wait-\#{ordinal}.pid"), Process.pid.to_s)
      File.write(File.join(control_dir, "wait-\#{ordinal}.started"), ARGV.fetch(0))
      File.open(ENV.fetch("FAKE_EVENT_LOG"), "a", 0o600) do |file|
        file.puts("renewal:wait seconds=\#{ARGV.fetch(0)} ordinal=\#{ordinal}")
      end
      release = File.join(control_dir, "release-\#{ordinal}")
      sleep 0.01 until File.exist?(release)
    RUBY
  end

  def build_api_fixtures
    File.write(key_file, PRIVATE_KEY_CONTENT)
    File.chmod(0o600, key_file)
    write_json(app_json, {"slug" => APP_SLUG})
    write_json(token_json, {"token" => INSTALLATION_TOKEN, "expires_at" => TOKEN_EXPIRY})
    configure_token_sequence(
      token_response(INSTALLATION_TOKEN),
      token_response(RENEWED_INSTALLATION_TOKEN)
    )
    write_json(repository_json, {
      "id" => 4242,
      "full_name" => "#{OWNER}/#{REPOSITORY}",
      "default_branch" => "main"
    })
    write_json(issue_json, {
      "number" => 7,
      "title" => "Synthetic issue with 'single' and \"double\" quotes",
      "html_url" => "https://github.com/#{OWNER}/#{REPOSITORY}/issues/7",
      "labels" => [{"name" => "testing"}, {"name" => "safety"}],
      "body" => "## Markdown and Unicode ✓\n\n`backticks` $(touch SHOULD_NOT_EXIST); pipe | redirect > file\nA final line."
    })
  end
end
