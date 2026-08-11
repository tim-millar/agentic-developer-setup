# frozen_string_literal: true

require "minitest/autorun"
require "timeout"
require_relative "support/launcher_harness"

class LauncherTest < Minitest::Test
  def setup
    @harness = LauncherHarness.new
  end

  def teardown
    @harness&.close
  end

  def test_help_flags_succeed_and_describe_the_supported_interface
    ["--help", "-h"].each do |flag|
      result = @harness.run(flag)

      assert_success(result, flag)
      %w[
        --issue --resume --prompt-file --extra-prompt-file --profile --allow-dirty
        --skip-issue-fetch --help
      ].each { |option| assert_includes result.stdout, option }
    end
    assert_empty @harness.codex_invocations
  end

  def test_missing_option_values_and_non_numeric_issue_are_usage_errors
    [
      ["--issue"], ["--resume"], ["--prompt-file"], ["--extra-prompt-file"], ["--profile"],
      ["--profile", "--issue", "7"], ["--issue", "not-a-number"]
    ].each do |arguments|
      result = @harness.run(*arguments)

      assert_equal 2, result.status.exitstatus, failure_message(arguments.join(" "), result)
      assert_includes result.stderr, "Error:"
    end
    assert_empty @harness.codex_invocations
  end

  def test_unsupported_access_and_git_modes_fail_clearly
    access = @harness.run(env: {"GITHUB_ACCESS_MODE" => "ambient"})
    assert_equal 2, access.status.exitstatus, failure_message("access mode", access)
    assert_includes access.stderr, "unsupported GITHUB_ACCESS_MODE"

    git_mode = @harness.run(env: {"AGENT_GIT_MODE" => "unknown"})
    assert_equal 2, git_mode.status.exitstatus, failure_message("git mode", git_mode)
    assert_includes git_mode.stderr, "unsupported AGENT_GIT_MODE"
    assert_empty @harness.codex_invocations
  end

  def test_unknown_and_double_dash_arguments_preserve_exact_boundaries
    arguments = ["--model", "model with spaces", "--", "$(touch NEVER_CREATED)", "semi;colon", "pipe|data", ""]
    result = @harness.run(*arguments)

    assert_success(result, "argument forwarding")
    assert_equal ["--model", "model with spaces", "$(touch NEVER_CREATED)", "semi;colon", "pipe|data", "", @harness.expected_prompt],
                 @harness.invocation.fetch("args")
    refute File.exist?(File.join(@harness.repository, "NEVER_CREATED"))
    assert_equal @harness.repository, @harness.invocation.fetch("cwd")
    assert_equal 1, @harness.codex_invocations.length
  end

  def test_codex_bin_and_profile_placement_are_exact
    result = @harness.run(
      "--profile", "cli-profile", "--sandbox", "workspace-write",
      env: {"CODEX_BIN" => File.join(@harness.root, "fake-bin", "alternate-codex")}
    )
    assert_success(result, "CLI profile")
    assert_equal "alternate-codex", @harness.invocation.fetch("executable")
    assert_equal ["--profile", "cli-profile", "--sandbox", "workspace-write", @harness.expected_prompt],
                 @harness.invocation.fetch("args")

    @harness.close
    @harness = LauncherHarness.new
    result = @harness.run("--quiet", env: {"CODEX_PROFILE" => "environment-profile"})
    assert_success(result, "environment profile")
    assert_equal ["--profile", "environment-profile", "--quiet", @harness.expected_prompt],
                 @harness.invocation.fetch("args")
  end

  def test_child_inherits_launcher_standard_input
    result = @harness.run(
      "--interactive-check",
      env: {"FAKE_CODEX_READ_STDIN" => "1"},
      stdin_data: "synthetic terminal input\n"
    )

    assert_success(result, "child stdin")
    assert_equal "synthetic terminal input\n", @harness.invocation.fetch("stdin")
  end

  def test_launcher_outside_a_git_repository_is_rejected
    outside = File.join(@harness.root, "outside", "scripts")
    FileUtils.mkdir_p(outside)
    launcher = File.join(outside, "run_codex.sh")
    FileUtils.cp(LauncherHarness::BASELINE_LAUNCHER, launcher, preserve: true)

    stdout, stderr, status = Open3.capture3(
      @harness.base_env,
      launcher,
      chdir: @harness.root,
      unsetenv_others: true
    )
    result = LauncherHarness::Result.new(stdout: stdout, stderr: stderr, status: status)
    refute status.success?, failure_message("outside repository", result)
    assert_includes stderr, "must be run from within a Git repository"
    assert_empty @harness.codex_invocations
  end

  def test_missing_origin_and_disallowed_origin_forms_are_rejected_before_codex
    @harness.remove_origin
    result = @harness.run
    refute result.status.success?
    assert_includes result.stderr, "origin remote is not configured"

    disallowed = [
      "git@github.com:#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}.git",
      "https://gitlab.com/#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}.git",
      "https://github.com/other-owner/#{LauncherHarness::REPOSITORY}.git",
      "https://github.com/#{LauncherHarness::OWNER}/other-repository.git"
    ]
    @harness = replace_harness
    disallowed.each do |origin|
      @harness.set_origin(origin)
      result = @harness.run
      refute result.status.success?, failure_message(origin, result)
      assert_includes result.stderr, "origin remote must be HTTPS and match"
    end
    assert_empty @harness.codex_invocations
  end

  def test_expected_https_origin_with_or_without_git_suffix_is_accepted
    [
      "https://github.com/#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}.git",
      "https://github.com/#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}"
    ].each do |origin|
      @harness.set_origin(origin)
      assert_success(@harness.run, origin)
    end
    assert_equal 2, @harness.codex_invocations.length
  end

  def test_dirty_tree_is_rejected_and_allow_dirty_bypasses_only_that_guard
    @harness.write_repository_file("dirty.txt", "uncommitted\n")
    rejected = @harness.run
    refute rejected.status.success?
    assert_includes rejected.stderr, "working tree has uncommitted changes"
    assert_empty @harness.codex_invocations

    assert_success(@harness.run("--allow-dirty"), "allow dirty")
    assert_equal 1, @harness.codex_invocations.length

    @harness.set_origin("https://github.com/other/#{LauncherHarness::REPOSITORY}.git")
    mismatched = @harness.run("--allow-dirty")
    refute mismatched.status.success?
    assert_includes mismatched.stderr, "origin remote must be HTTPS and match"
  end

  def test_prompt_files_are_validated_before_external_security_operations
    @harness.remove_repository_file("docs/AGENT_PROMPT.txt")
    result = @harness.run(env: @harness.app_env)
    refute result.status.success?
    assert_includes result.stderr, "prompt file not found: docs/AGENT_PROMPT.txt"
    assert_empty @harness.events

    @harness = replace_harness
    missing = @harness.run("--prompt-file", "docs/missing.txt", env: @harness.app_env)
    refute missing.status.success?
    assert_includes missing.stderr, "prompt file not found: docs/missing.txt"
    assert_empty @harness.events

    extra = @harness.run("--extra-prompt-file", "docs/missing-extra.txt", env: @harness.app_env)
    refute extra.status.success?
    assert_includes extra.stderr, "extra prompt file not found"
    assert_empty @harness.events
  end

  def test_prompt_override_and_extra_prompt_have_exact_composition
    @harness.write_repository_file("docs/ALTERNATE.txt", "Alternate base with spaces.\n")
    @harness.write_repository_file("docs/EXTRA_PROMPT.txt", "Extra line one.\nExtra `data`; $(inert).\n")
    @harness.commit_all("Add prompt fixtures")

    result = @harness.run(
      "--prompt-file", "docs/ALTERNATE.txt",
      "--extra-prompt-file", "docs/EXTRA_PROMPT.txt"
    )
    assert_success(result, "prompt sources")
    expected = @harness.expected_prompt(
      base: "Alternate base with spaces.",
      prompt_path: "docs/ALTERNATE.txt",
      extra_path: "docs/EXTRA_PROMPT.txt",
      extra: "Extra line one.\nExtra `data`; $(inert)."
    )
    assert_equal [expected], @harness.invocation.fetch("args")
    assert_equal 1, expected.scan("Alternate base with spaces.").length
    assert_equal 1, expected.scan("Additional instructions:").length
  end

  def test_issue_skip_fetch_works_offline_and_composes_exact_prompt
    result = @harness.run("--issue", "7", "--skip-issue-fetch")
    assert_success(result, "skipped issue")
    assert_equal [@harness.expected_prompt(issue: 7, skipped: true)], @harness.invocation.fetch("args")
    assert_empty @harness.events.grep(/^curl:/)

    rejected = replace_harness.run("--issue", "7")
    refute rejected.status.success?
    assert_includes rejected.stderr, "--issue requires GITHUB_ACCESS_MODE=app"
  end

  def test_resume_contract_without_prompt_and_with_profile_is_exact
    @harness.remove_repository_file("docs/AGENT_PROMPT.txt")
    @harness.commit_all("Remove prompt for resume")
    result = @harness.run("--resume", "session 123", "--", "arg with spaces", "semi;colon")
    assert_success(result, "resume")
    assert_equal ["resume", "session 123", "arg with spaces", "semi;colon"], @harness.invocation.fetch("args")
    assert_equal 1, @harness.codex_invocations.length
    assert_equal "unset", env_fact("AGENT_PROMPT_FILE", "state")
    assert_empty @harness.debug_prompt_paths
    assert_empty @harness.launcher_temporary_paths

    @harness = replace_harness
    profiled = @harness.run("--resume", "abc", "--profile", "focused", "--", "--last")
    assert_success(profiled, "profiled resume")
    assert_equal ["--profile", "focused", "resume", "abc", "--last"], @harness.invocation.fetch("args")
    assert_equal 1, @harness.codex_invocations.length
  end

  def test_resume_incompatibilities_fail_before_external_operations
    combinations = [
      ["--resume", "abc", "--issue", "7"],
      ["--resume", "abc", "--extra-prompt-file", "docs/EXTRA_PROMPT.txt"],
      ["--resume", "abc", "--prompt-file", "docs/missing.txt"],
      ["--resume", "abc", "--skip-issue-fetch"]
    ]
    combinations.each do |arguments|
      result = @harness.run(*arguments, env: @harness.app_env)
      assert_equal 2, result.status.exitstatus, failure_message(arguments.join(" "), result)
      assert_includes result.stderr, "--resume cannot be used"
    end
    assert_empty @harness.events
    assert_empty @harness.codex_invocations
  end

  def test_resume_enforces_dirty_tree_and_repository_identity
    @harness.write_repository_file("dirty.txt", "dirty\n")
    dirty = @harness.run("--resume", "abc")
    refute dirty.status.success?
    assert_includes dirty.stderr, "working tree has uncommitted changes"

    assert_success(@harness.run("--resume", "abc", "--allow-dirty"), "dirty resume override")
    @harness.set_origin("https://github.com/other/#{LauncherHarness::REPOSITORY}")
    mismatch = @harness.run("--resume", "abc", "--allow-dirty")
    refute mismatch.status.success?
    assert_includes mismatch.stderr, "origin remote must be HTTPS and match"
  end

  def test_disabled_mode_neutralises_credentials_and_unsets_app_sources
    ambient = {
      "GITHUB_APP_ID" => LauncherHarness::APP_ID,
      "GITHUB_APP_INSTALLATION_ID" => LauncherHarness::INSTALLATION_ID,
      "GITHUB_APP_PRIVATE_KEY_PATH" => @harness.key_file,
      "GH_TOKEN" => "ambient-gh",
      "GITHUB_TOKEN" => "ambient-github",
      "GITHUB_PAT" => "ambient-pat",
      "INSTALL_TOKEN" => "ambient-install",
      "AGENT_GITHUB_TOKEN_HELPER" => "/ambient/token-helper",
      "GIT_ASKPASS" => "/ambient/askpass",
      "SSH_AUTH_SOCK" => "/ambient/agent.sock",
      "GIT_SSH" => "/ambient/ssh",
      "GIT_SSH_COMMAND" => "ambient ssh command",
      "SSH_ASKPASS" => "/ambient/ssh-askpass"
    }
    result = @harness.run(env: ambient)
    assert_success(result, "disabled credential boundary")
    assert_empty @harness.events.grep(/^curl:/)

    %w[GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH].each do |name|
      assert_equal "unset", source_fact(name, "state")
    end
    %w[GH_TOKEN GITHUB_TOKEN GITHUB_PAT INSTALL_TOKEN].each do |name|
      assert_equal "empty", secret_fact(name, "state")
      refute secret_fact(name, "matches_installation_token")
    end
    assert_equal "unset", env_fact("AGENT_GITHUB_TOKEN_HELPER", "state")
    expected = {
      "GIT_ASKPASS" => "", "GIT_TERMINAL_PROMPT" => "0", "GCM_INTERACTIVE" => "never",
      "SSH_AUTH_SOCK" => "", "GIT_SSH" => "", "GIT_SSH_COMMAND" => "", "SSH_ASKPASS" => ""
    }
    expected.each { |name, value| assert_equal value, env_fact(name, "value") }
    assert_equal "set", env_fact("GH_CONFIG_DIR", "state")
    assert_match(%r{\A#{Regexp.escape(@harness.tmpdir)}/codex\.gh\.}, env_fact("GH_CONFIG_DIR", "value"))
    assert_empty @harness.launcher_temporary_paths
    prompt = @harness.invocation.fetch("args").last
    assert_includes prompt, "GitHub access is disabled for this session."
    refute_includes prompt, "App mode provides repository write capability"
    refute_includes prompt, "commit, push, pull-request publication, and verification"
  end

  def test_app_configuration_is_required_and_validated_before_api_access
    {
      "GITHUB_APP_ID" => "Set GITHUB_APP_ID",
      "GITHUB_APP_INSTALLATION_ID" => "Set GITHUB_APP_INSTALLATION_ID",
      "GITHUB_APP_PRIVATE_KEY_PATH" => "Set GITHUB_APP_PRIVATE_KEY_PATH"
    }.each do |name, message|
      env = @harness.app_env.reject { |key, _| key == name }
      result = @harness.run(env: env)
      refute result.status.success?
      assert_includes result.stderr, message
    end

    @harness = replace_harness
    invalid_app = @harness.run(env: @harness.app_env.merge("GITHUB_APP_ID" => "abc"))
    refute invalid_app.status.success?
    assert_includes invalid_app.stderr, "GITHUB_APP_ID must be numeric"
    invalid_installation = @harness.run(env: @harness.app_env.merge("GITHUB_APP_INSTALLATION_ID" => "abc"))
    refute invalid_installation.status.success?
    assert_includes invalid_installation.stderr, "GITHUB_APP_INSTALLATION_ID must be numeric"
    missing_key = @harness.run(env: @harness.app_env.merge("GITHUB_APP_PRIVATE_KEY_PATH" => File.join(@harness.root, "missing.pem")))
    refute missing_key.status.success?
    assert_includes missing_key.stderr, "private key file not found"
    assert_empty @harness.events
  end

  def test_invalid_private_key_fails_before_api_and_codex
    result = @harness.run(env: @harness.app_env.merge("FAKE_KEY_VALID" => "0"))
    refute result.status.success?
    assert_includes result.stderr, "invalid private key file"
    assert_equal ["openssl:key-check"], @harness.events
    assert_empty @harness.codex_invocations
  end

  def test_app_test_mode_requires_controlled_wait_executable_before_api_or_session_state
    @harness.remove_renewal_wait_executable
    result = @harness.run(env: @harness.renewable_app_env)

    refute result.status.success?
    assert_includes result.stderr, "AGENT_LAUNCHER_TEST_MODE=1 requires launcher-test-sleep on PATH"
    assert_empty @harness.events
    assert_empty @harness.codex_invocations
    refute @harness.renewal_wait_started?(1)
    assert_empty @harness.launcher_temporary_paths
  end

  def test_app_mode_resolves_identity_token_repository_and_issue_in_order
    result = @harness.run_app("--issue", "7")
    assert_success(result, "app issue launch")
    assert_equal [
      "openssl:key-check",
      "openssl:sign source_credentials_present=true",
      "curl:app method=GET url=https://api.github.com/app auth_matches_expected=true",
      "curl:token method=POST url=https://api.github.com/app/installations/#{LauncherHarness::INSTALLATION_ID}/access_tokens auth_matches_expected=true",
      "curl:repository method=GET url=https://api.github.com/repos/#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY} auth_matches_expected=true",
      "curl:issue method=GET url=https://api.github.com/repos/#{LauncherHarness::OWNER}/#{LauncherHarness::REPOSITORY}/issues/7 auth_matches_expected=true",
      "codex:start"
    ], @harness.events
    expected = @harness.expected_prompt(mode: "app", issue: 7)
    assert_equal [expected], @harness.invocation.fetch("args")
    refute File.exist?(File.join(@harness.repository, "SHOULD_NOT_EXIST"))
  end

  def test_app_mode_policy_describes_conditional_publication_capability_without_exposing_credentials
    result = @harness.run_app("--issue", "7")
    assert_success(result, "App publication capability policy")

    prompt = @harness.invocation.fetch("args").last
    assert_includes prompt, "App mode provides repository write capability for this session."
    assert_includes prompt, "Autonomous implementation of a supplied issue may activate the repository publication contract in AGENTS.md"
    assert_includes prompt, "commit, push, pull-request publication, and verification when required"
    assert_includes prompt, "Issue context alone does not require publication"
    assert_includes prompt, "App mode alone does not require publication"
    assert_includes prompt, 'obtain the current token from "$AGENT_GITHUB_TOKEN_HELPER" and retry the exact same operation once'
    refute_includes prompt, LauncherHarness::INSTALLATION_TOKEN
    refute_includes prompt, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes prompt, @harness.key_file
    refute_includes prompt, LauncherHarness::APP_ID
    refute_includes prompt, LauncherHarness::INSTALLATION_ID
  end

  def test_issue_response_validation_rejects_pull_requests_missing_numbers_and_malformed_json
    @harness.write_json(@harness.issue_json, {"number" => 7, "pull_request" => {"url" => "synthetic"}})
    pull_request = @harness.run_app("--issue", "7")
    refute pull_request.status.success?
    assert_includes pull_request.stderr, "is a pull request, not an issue"
    assert_empty @harness.codex_invocations

    @harness = replace_harness
    @harness.write_json(@harness.issue_json, {"number" => nil, "title" => "missing"})
    missing_number = @harness.run_app("--issue", "7")
    refute missing_number.status.success?
    assert_includes missing_number.stderr, "failed to fetch issue #7"

    @harness = replace_harness
    File.write(@harness.issue_json, "{not-json")
    malformed = @harness.run_app("--issue", "7")
    refute malformed.status.success?
    assert_includes malformed.stderr, "invalid synthetic JSON"
    assert_empty @harness.codex_invocations
  end

  def test_app_identity_token_and_repository_failures_are_clear
    @harness.write_json(@harness.app_json, {"slug" => nil})
    app = @harness.run_app
    refute app.status.success?
    assert_includes app.stderr, "JWT validation failed"

    @harness = replace_harness
    @harness.write_json(@harness.token_json, {"token" => nil, "expires_at" => nil})
    token = @harness.run_app
    refute token.status.success?
    assert_includes token.stderr, "failed to mint installation token"

    @harness = replace_harness
    @harness.write_json(@harness.repository_json, {"id" => nil, "full_name" => nil})
    repository = @harness.run_app
    refute repository.status.success?
    assert_includes repository.stderr, "failed to resolve repository metadata"
    assert_empty @harness.codex_invocations
  end

  def test_repository_metadata_mismatch_stops_before_issue_and_codex
    @harness.write_json(@harness.repository_json, {
      "id" => 4242, "full_name" => "other/repository", "default_branch" => "main"
    })
    result = @harness.run_app("--issue", "7")
    refute result.status.success?
    assert_includes result.stderr, "resolved repository mismatch"
    assert_equal 3, @harness.events.grep(/^curl:/).length
    assert_empty @harness.events.grep(/^curl:issue/)
    assert_empty @harness.codex_invocations
  end

  def test_app_child_receives_short_lived_credentials_but_not_source_credentials
    result = @harness.run_app
    assert_success(result, "app credential boundary")

    %w[GITHUB_APP_ID GITHUB_APP_INSTALLATION_ID GITHUB_APP_PRIVATE_KEY_PATH].each do |name|
      assert_equal "unset", source_fact(name, "state")
    end
    %w[GH_TOKEN GITHUB_TOKEN INSTALL_TOKEN].each do |name|
      assert_equal "set", secret_fact(name, "state")
      assert secret_fact(name, "matches_installation_token")
    end
    assert_equal "empty", secret_fact("GITHUB_PAT", "state")
    assert_equal "set", env_fact("GIT_ASKPASS", "state")
    assert_equal "set", env_fact("AGENT_GITHUB_TOKEN_HELPER", "state")
    assert_equal "0", env_fact("GIT_TERMINAL_PROMPT", "value")
    assert_equal "never", env_fact("GCM_INTERACTIVE", "value")
    assert_empty @harness.launcher_temporary_paths

    diagnostic_material = [result.stdout, result.stderr, @harness.events.join("\n"), File.read(@harness.codex_log)].join("\n")
    refute_includes diagnostic_material, LauncherHarness::INSTALLATION_TOKEN
    refute_includes diagnostic_material, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes result.stdout + result.stderr, @harness.key_file
    assert_includes result.stdout, "GitHub credential renewal: launcher-managed"
    assert_includes result.stdout, "GitHub credential refresh interval: 45 minutes"
  end

  def test_exported_ambient_jwt_and_token_json_never_enter_the_codex_child_or_diagnostics
    ambient_jwt = "ambient-exported-jwt-canary"
    ambient_token_json = "ambient-exported-token-json-canary"
    generated_jwt_header = "eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9"
    result = @harness.run_app(env: {
      "JWT" => ambient_jwt,
      "TOKEN_JSON" => ambient_token_json,
      "DEBUG_CODEX_PROMPT" => "1"
    })
    assert_success(result, "exported launcher credential containment")

    %w[JWT TOKEN_JSON].each do |name|
      assert_equal "unset", source_fact(name, "state")
    end

    debug_prompt = File.binread(@harness.debug_prompt_paths.fetch(0))
    diagnostic_material = [
      result.stdout,
      result.stderr,
      @harness.events.join("\n"),
      File.read(@harness.codex_log),
      @harness.invocation.fetch("args").join("\n"),
      debug_prompt
    ].join("\n")
    [
      ambient_jwt,
      ambient_token_json,
      generated_jwt_header,
      LauncherHarness::INSTALLATION_TOKEN,
      LauncherHarness::PRIVATE_KEY_CONTENT.strip,
      @harness.key_file
    ].each do |canary|
      assert !diagnostic_material.include?(canary), "launcher-only credential material entered child-visible diagnostics"
    end
    assert_empty @harness.launcher_temporary_paths
  end

  def test_initial_app_session_creates_private_dynamic_credential_state
    session = start_renewable_session("--issue", "7")
    helper = env_fact("AGENT_GITHUB_TOKEN_HELPER", "value")
    askpass = env_fact("GIT_ASKPASS", "value")
    credential_dir = File.dirname(helper)
    token_file = File.join(credential_dir, "current-token")

    assert_equal 0o700, File.stat(credential_dir).mode & 0o777
    assert_equal 0o600, File.stat(token_file).mode & 0o777
    assert_equal 0o700, File.stat(helper).mode & 0o777
    assert_equal 0o700, File.stat(askpass).mode & 0o777
    assert_equal credential_dir, File.dirname(env_fact("GH_CONFIG_DIR", "value"))
    assert_equal 1, @harness.token_attempts
    assert File.binread(token_file) == LauncherHarness::INSTALLATION_TOKEN,
           "authoritative token file did not contain exactly the initial token"
    events_before_helper = @harness.events.dup
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::INSTALLATION_TOKEN)
    assert_helper_token(
      @harness.run_generated_helper(askpass, "Password for 'https://github.com':"),
      LauncherHarness::INSTALLATION_TOKEN
    )
    username = @harness.run_generated_helper(askpass, "Username for 'https://github.com':")
    assert username.status.success?
    assert_equal "x-access-token\n", username.stdout
    assert_equal events_before_helper, @harness.events, "generated helpers minted credentials independently"
    assert_operator @harness.events.index { |event| event.start_with?("curl:issue ") }, :<,
                    @harness.events.index { |event| event.start_with?("renewal:wait ") }

    generated_material = File.read(helper) + File.read(askpass)
    refute_includes generated_material, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes generated_material, @harness.key_file
    refute_includes generated_material, LauncherHarness::APP_ID
    refute_includes generated_material, LauncherHarness::INSTALLATION_ID

    result = finish_renewable_session(session)
    assert_success(result, "initial renewable App session")
    assert_empty @harness.launcher_temporary_paths
  ensure
    stop_renewable_session(session)
  end

  def test_successful_renewal_updates_helper_and_askpass_atomically_without_restarting_codex
    session = start_renewable_session
    helper = env_fact("AGENT_GITHUB_TOKEN_HELPER", "value")
    askpass = env_fact("GIT_ASKPASS", "value")
    credential_dir = File.dirname(helper)
    codex_pid = File.read(@harness.started_marker)
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::INSTALLATION_TOKEN)
    %w[
      AGENT_LAUNCHER_TEST_MODE FAKE_RENEWAL_CONTROL_DIR
      FAKE_TOKEN_SEQUENCE_JSON FAKE_TOKEN_ATTEMPT_FILE
    ].each do |name|
      assert_equal "unset", source_fact(name, "state"), name
    end

    readings = []
    keep_reading = true
    reader = Thread.new do
      while keep_reading
        reading = @harness.run_generated_helper(helper)
        readings << [reading.status.success?, reading.stdout]
      end
    end

    @harness.release_renewal_wait(1)
    wait_until { @harness.token_attempts >= 2 && @harness.renewal_wait_started?(2) }
    keep_reading = false
    reader.join

    assert_equal codex_pid, File.read(@harness.started_marker)
    assert_equal 1, @harness.codex_invocations.length
    assert secret_fact("GH_TOKEN", "matches_installation_token")
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::RENEWED_INSTALLATION_TOKEN)
    assert_helper_token(
      @harness.run_generated_helper(askpass, "Password for 'https://github.com':"),
      LauncherHarness::RENEWED_INSTALLATION_TOKEN
    )
    assert readings.any?, "atomic reader did not observe the credential file"
    allowed = [LauncherHarness::INSTALLATION_TOKEN, LauncherHarness::RENEWED_INSTALLATION_TOKEN].map { |token| "#{token}\n" }
    assert readings.all? { |success, output| success && allowed.include?(output) },
           "atomic reader observed unavailable or partial credential state"
    assert_empty Dir[File.join(credential_dir, "current-token.tmp.*")]
    assert_equal "2700", File.read(File.join(@harness.renewal_control_dir, "wait-2.started"))
    assert_operator @harness.events.count { |event| event == "openssl:sign source_credentials_present=true" }, :>=, 2

    wait_pid = @harness.renewal_wait_pid(2)
    result = finish_renewable_session(session)
    assert_success(result, "successful renewable App session")
    diagnostic_material = [result.stdout, result.stderr, @harness.events.join("\n"), File.read(@harness.codex_log)].join("\n")
    refute_includes diagnostic_material, LauncherHarness::INSTALLATION_TOKEN
    refute_includes diagnostic_material, LauncherHarness::RENEWED_INSTALLATION_TOKEN
    refute_includes diagnostic_material, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes diagnostic_material, @harness.key_file
    refute process_alive?(wait_pid), "renewal wait process survived launcher cleanup"
    assert_empty @harness.launcher_temporary_paths
  ensure
    keep_reading = false
    reader&.join
    stop_renewable_session(session)
  end

  def test_failed_renewal_retains_token_retries_after_five_minutes_and_recovers
    sequence = [
      @harness.token_response(LauncherHarness::INSTALLATION_TOKEN),
      @harness.renewal_timeout,
      @harness.token_response(LauncherHarness::RENEWED_INSTALLATION_TOKEN)
    ]
    session = start_renewable_session(sequence: sequence)
    helper = env_fact("AGENT_GITHUB_TOKEN_HELPER", "value")
    initial_mint = @harness.events.find { |event| event.start_with?("curl:token attempt=1 ") }
    refute_includes initial_mint, "connect_timeout="
    refute_includes initial_mint, "max_time="

    @harness.release_renewal_wait(1)
    wait_until { @harness.token_attempts >= 2 && @harness.renewal_wait_started?(2) }
    assert_equal "300", File.read(File.join(@harness.renewal_control_dir, "wait-2.started"))
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::INSTALLATION_TOKEN)
    timed_out_renewal = @harness.events.find { |event| event.start_with?("curl:token attempt=2 ") }
    assert_includes timed_out_renewal, "outcome=timeout"
    assert_includes timed_out_renewal, "connect_timeout=10"
    assert_includes timed_out_renewal, "max_time=30"
    assert_equal 1, @harness.codex_invocations.length

    @harness.release_renewal_wait(2)
    wait_until { @harness.token_attempts >= 3 && @harness.renewal_wait_started?(3) }
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::RENEWED_INSTALLATION_TOKEN)
    assert_equal "2700", File.read(File.join(@harness.renewal_control_dir, "wait-3.started"))
    assert_equal 1, @harness.codex_invocations.length
    recovered_renewal = @harness.events.find { |event| event.start_with?("curl:token attempt=3 ") }
    assert_includes recovered_renewal, "connect_timeout=10"
    assert_includes recovered_renewal, "max_time=30"

    wait_pid = @harness.renewal_wait_pid(3)
    result = finish_renewable_session(session)
    assert_success(result, "renewal failure and recovery")
    assert_equal 1, result.stderr.scan("GitHub credential renewal failed").length
    warning_material = result.stderr
    refute_includes warning_material, LauncherHarness::INSTALLATION_TOKEN
    refute_includes warning_material, LauncherHarness::RENEWED_INSTALLATION_TOKEN
    refute_includes warning_material, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes warning_material, @harness.key_file
    refute process_alive?(wait_pid), "renewal wait process survived timeout recovery cleanup"
    assert_empty @harness.launcher_temporary_paths
  ensure
    stop_renewable_session(session)
  end

  def test_current_token_helper_fails_safely_when_authoritative_state_is_unavailable
    session = start_renewable_session
    helper = env_fact("AGENT_GITHUB_TOKEN_HELPER", "value")
    token_file = File.join(File.dirname(helper), "current-token")
    File.truncate(token_file, 0)

    unavailable = @harness.run_generated_helper(helper)
    refute unavailable.status.success?
    assert_empty unavailable.stdout
    assert_includes unavailable.stderr, "current GitHub session token is unavailable"
    refute_includes unavailable.stderr, LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes unavailable.stderr, @harness.key_file
    FileUtils.rm_f(token_file)
    missing = @harness.run_generated_helper(helper)
    refute missing.status.success?
    assert_empty missing.stdout

    result = finish_renewable_session(session)
    assert_success(result, "unavailable helper state")
    assert_empty @harness.launcher_temporary_paths
  ensure
    stop_renewable_session(session)
  end

  def test_app_resume_session_renews_without_prompt_or_restart
    session = start_renewable_session("--resume", "renewable-session")
    helper = env_fact("AGENT_GITHUB_TOKEN_HELPER", "value")
    codex_pid = File.read(@harness.started_marker)

    @harness.release_renewal_wait(1)
    wait_until { @harness.token_attempts >= 2 && @harness.renewal_wait_started?(2) }
    assert_helper_token(@harness.run_generated_helper(helper), LauncherHarness::RENEWED_INSTALLATION_TOKEN)
    assert_equal codex_pid, File.read(@harness.started_marker)
    assert_equal ["resume", "renewable-session"], @harness.invocation.fetch("args")
    assert_equal "unset", env_fact("AGENT_PROMPT_FILE", "state")

    result = finish_renewable_session(session)
    assert_success(result, "renewable resume")
    assert_empty @harness.launcher_temporary_paths
  ensure
    stop_renewable_session(session)
  end

  def test_disabled_mode_creates_no_renewal_infrastructure_even_with_test_hooks_present
    result = @harness.run(env: {
      "AGENT_LAUNCHER_TEST_MODE" => "1",
      "FAKE_RENEWAL_CONTROL_DIR" => @harness.renewal_control_dir,
      "FAKE_TOKEN_SEQUENCE_JSON" => @harness.token_sequence_json,
      "FAKE_TOKEN_ATTEMPT_FILE" => @harness.token_attempt_file
    })

    assert_success(result, "disabled renewal hooks")
    assert_equal "unset", env_fact("AGENT_GITHUB_TOKEN_HELPER", "state")
    %w[
      AGENT_LAUNCHER_TEST_MODE FAKE_RENEWAL_CONTROL_DIR
      FAKE_TOKEN_SEQUENCE_JSON FAKE_TOKEN_ATTEMPT_FILE
    ].each do |name|
      assert_equal "unset", source_fact(name, "state"), name
    end
    assert_equal 0, @harness.token_attempts
    refute @harness.renewal_wait_started?(1)
    assert_empty @harness.events.grep(/^curl:/)
    assert_empty @harness.launcher_temporary_paths
  end

  def test_local_validation_failures_precede_app_security_operations
    @harness.write_repository_file("dirty.txt", "dirty\n")
    dirty = @harness.run(env: @harness.app_env)
    refute dirty.status.success?
    assert_empty @harness.events

    @harness = replace_harness
    @harness.set_origin("https://github.com/other/#{LauncherHarness::REPOSITORY}")
    origin = @harness.run(env: @harness.app_env)
    refute origin.status.success?
    assert_empty @harness.events

    @harness = replace_harness
    invalid = @harness.run("--resume", "abc", "--issue", "7", env: @harness.app_env)
    refute invalid.status.success?
    assert_empty @harness.events
  end

  def test_git_metadata_and_provenance_for_developer_author
    result = @harness.run("--issue", "7", "--skip-issue-fetch", "--extra-prompt-file", prepare_extra)
    assert_success(result, "developer metadata")
    expected = {
      "GIT_AUTHOR_NAME" => "Test Developer",
      "GIT_COMMITTER_NAME" => "Test Developer",
      "GIT_AUTHOR_EMAIL" => "developer@example.test",
      "GIT_COMMITTER_EMAIL" => "developer@example.test",
      "AGENT_NAME" => "test-agent",
      "AGENT_GIT_MODE" => "developer-author",
      "AGENT_LAUNCHED_BY_NAME" => "Test Developer",
      "AGENT_LAUNCHED_BY_EMAIL" => "developer@example.test",
      "AGENT_REPO_ROOT" => @harness.repository,
      "AGENT_GITHUB_ACCESS_MODE" => "disabled",
      "AGENT_PROMPT_FILE" => "docs/AGENT_PROMPT.txt",
      "AGENT_ISSUE_NUMBER" => "7",
      "AGENT_EXTRA_PROMPT_FILE" => "docs/EXTRA_PROMPT.txt"
    }
    expected.each { |name, value| assert_equal value, env_fact(name, "value"), name }
  end

  def test_agent_author_uses_deterministic_local_identity
    result = @harness.run(env: {"AGENT_GIT_MODE" => "agent-author", "AGENT_NAME" => "review-agent"})
    assert_success(result, "agent author")
    assert_equal "review-agent", env_fact("GIT_AUTHOR_NAME", "value")
    assert_equal "review-agent@noreply.local", env_fact("GIT_AUTHOR_EMAIL", "value")
    assert_equal "review-agent", env_fact("GIT_COMMITTER_NAME", "value")
    assert_equal "review-agent@noreply.local", env_fact("GIT_COMMITTER_EMAIL", "value")
  end

  def test_absent_developer_identity_does_not_fail_or_modify_global_git_config
    synthetic_global = File.join(@harness.home, ".gitconfig")
    File.write(synthetic_global, "[alias]\n  synthetic = status\n")
    before = File.binread(synthetic_global)
    Open3.capture3(
      {"HOME" => @harness.home, "GIT_CONFIG_NOSYSTEM" => "1", "PATH" => "/usr/bin:/bin"},
      "git", "config", "--local", "--unset-all", "user.name",
      chdir: @harness.repository,
      unsetenv_others: true
    )
    Open3.capture3(
      {"HOME" => @harness.home, "GIT_CONFIG_NOSYSTEM" => "1", "PATH" => "/usr/bin:/bin"},
      "git", "config", "--local", "--unset-all", "user.email",
      chdir: @harness.repository,
      unsetenv_others: true
    )

    result = @harness.run(env: {"DEVELOPER_NAME" => "", "DEVELOPER_EMAIL" => ""})
    assert_success(result, "absent identity")
    assert_equal "unset", env_fact("GIT_AUTHOR_NAME", "state")
    assert_equal "unset", env_fact("GIT_AUTHOR_EMAIL", "state")
    assert_equal before, File.binread(synthetic_global)
  end

  def test_codex_exit_status_is_preserved_and_cleanup_runs_for_normal_and_resume
    failed = @harness.run(env: {"FAKE_CODEX_EXIT" => "17"})
    assert_equal 17, failed.status.exitstatus, failure_message("normal failure", failed)
    assert_equal 1, @harness.codex_invocations.length
    assert_empty @harness.launcher_temporary_paths

    @harness = replace_harness
    resumed = @harness.run("--resume", "abc", env: {"FAKE_CODEX_EXIT" => "23"})
    assert_equal 23, resumed.status.exitstatus, failure_message("resume failure", resumed)
    assert_equal 1, @harness.codex_invocations.length
    assert_empty @harness.launcher_temporary_paths
  end

  def test_app_temporary_config_and_askpass_are_cleaned_after_success_and_failure
    success = @harness.run_app
    assert_success(success, "app success cleanup")
    assert_equal "set", env_fact("GH_CONFIG_DIR", "state")
    assert_equal "set", env_fact("GIT_ASKPASS", "state")
    assert_empty @harness.launcher_temporary_paths

    @harness = replace_harness
    session = start_renewable_session(env: {"FAKE_CODEX_EXIT" => "19"})
    wait_pid = @harness.renewal_wait_pid(1)
    failure = finish_renewable_session(session)
    assert_equal 19, failure.status.exitstatus, failure_message("app failure cleanup", failure)
    refute process_alive?(wait_pid), "renewal wait process survived failed child cleanup"
    assert_empty @harness.launcher_temporary_paths
  ensure
    stop_renewable_session(session)
  end

  def test_sigint_is_forwarded_cleanup_runs_and_launcher_exits_130
    assert_signal_contract("INT", 130)
  end

  def test_sigterm_is_forwarded_cleanup_runs_and_launcher_exits_143
    assert_signal_contract("TERM", 143)
  end

  def test_debug_prompt_is_retained_private_exact_and_does_not_change_arguments
    result = @harness.run_app(env: {"DEBUG_CODEX_PROMPT" => "1"})
    assert_success(result, "debug prompt")
    paths = @harness.debug_prompt_paths
    assert_equal 1, paths.length
    path = paths.fetch(0)
    assert_includes result.stdout, "Debug prompt saved to: #{path}"
    assert_equal 0o600, File.stat(path).mode & 0o777
    assert_equal @harness.expected_prompt(mode: "app"), File.binread(path)
    assert_equal [File.binread(path)], @harness.invocation.fetch("args")
    refute_includes File.binread(path), LauncherHarness::INSTALLATION_TOKEN
    refute_includes File.binread(path), LauncherHarness::PRIVATE_KEY_CONTENT.strip
    refute_includes File.binread(path), @harness.key_file
    assert_empty @harness.launcher_temporary_paths
  end

  def test_resume_debug_mode_creates_no_prompt_artifact
    result = @harness.run("--resume", "abc", env: {"DEBUG_CODEX_PROMPT" => "1"})
    assert_success(result, "resume debug")
    assert_empty @harness.debug_prompt_paths
    assert_equal ["resume", "abc"], @harness.invocation.fetch("args")
  end

  private

  def replace_harness
    @harness.close
    LauncherHarness.new
  end

  def prepare_extra
    @harness.write_repository_file("docs/EXTRA_PROMPT.txt", "Extra provenance context.\n")
    @harness.commit_all("Add extra prompt")
    "docs/EXTRA_PROMPT.txt"
  end

  def env_fact(name, key)
    @harness.invocation.fetch("env").fetch(name).fetch(key)
  end

  def secret_fact(name, key)
    @harness.invocation.fetch("secret_env").fetch(name).fetch(key)
  end

  def source_fact(name, key)
    @harness.invocation.fetch("source_env").fetch(name).fetch(key)
  end

  def assert_success(result, scenario)
    assert result.status.success?, failure_message(scenario, result)
  end

  def assert_helper_token(result, expected_token)
    assert result.status.success?, "generated credential helper failed: #{result.stderr}"
    assert_empty result.stderr
    assert result.stdout == "#{expected_token}\n", "generated credential helper returned an unexpected token"
  end

  def wait_until(&condition)
    Timeout.timeout(5) do
      sleep 0.01 until condition.call
    end
  end

  def start_renewable_session(*arguments, sequence: nil, env: {})
    sequence ||= [
      @harness.token_response(LauncherHarness::INSTALLATION_TOKEN),
      @harness.token_response(LauncherHarness::RENEWED_INSTALLATION_TOKEN)
    ]
    @harness.configure_token_sequence(*sequence)
    stdin, stdout, stderr, wait_thread = @harness.spawn(
      *arguments,
      env: @harness.renewable_app_env.merge("FAKE_CODEX_WAIT" => "1").merge(env)
    )
    stdin.close
    session = {stdout: stdout, stderr: stderr, wait_thread: wait_thread, finished: false}
    wait_until do
      File.exist?(@harness.started_marker) &&
        @harness.codex_invocations.any? &&
        @harness.renewal_wait_started?(1)
    end
    session
  rescue StandardError
    stop_renewable_session(session)
    raise
  end

  def finish_renewable_session(session)
    @harness.release_codex
    status = Timeout.timeout(5) { session.fetch(:wait_thread).value }
    result = LauncherHarness::Result.new(
      stdout: session.fetch(:stdout).read,
      stderr: session.fetch(:stderr).read,
      status: status
    )
    session.fetch(:stdout).close
    session.fetch(:stderr).close
    session[:finished] = true
    result
  end

  def stop_renewable_session(session)
    return unless session

    wait_thread = session[:wait_thread]
    if wait_thread&.alive?
      Process.kill("TERM", wait_thread.pid)
      Timeout.timeout(5) { wait_thread.value }
    end
  rescue Errno::ESRCH
    nil
  ensure
    if session
      session[:stdout]&.close unless session[:stdout]&.closed?
      session[:stderr]&.close unless session[:stderr]&.closed?
    end
  end

  def process_alive?(pid)
    return false unless pid

    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def failure_message(scenario, result)
    <<~MESSAGE
      launcher scenario failed: #{scenario}
      exit: #{result.status.exitstatus.inspect}
      stdout:
      #{result.stdout}
      stderr:
      #{result.stderr}
      events: #{@harness.events.inspect}
      invocations: #{@harness.codex_invocations.inspect}
    MESSAGE
  end

  def assert_signal_contract(signal, expected_status)
    stdin, stdout, stderr, wait_thread = @harness.spawn(
      env: @harness.renewable_app_env.merge("FAKE_CODEX_WAIT" => "1")
    )
    stdin.close
    wait_until { File.exist?(@harness.started_marker) && @harness.renewal_wait_started?(1) }
    renewal_wait_pid = @harness.renewal_wait_pid(1)
    Process.kill(signal, wait_thread.pid)
    status = Timeout.timeout(5) { wait_thread.value }
    captured_stdout = stdout.read
    captured_stderr = stderr.read
    stdout.close
    stderr.close

    result = LauncherHarness::Result.new(stdout: captured_stdout, stderr: captured_stderr, status: status)
    assert_equal expected_status, status.exitstatus, failure_message("signal #{signal}", result)
    assert_equal [signal], @harness.signals
    assert_includes @harness.events, "codex:signal:#{signal}"
    assert_equal 1, @harness.codex_invocations.length
    refute process_alive?(renewal_wait_pid), "renewal wait process survived signal cleanup"
    assert_empty @harness.launcher_temporary_paths
  ensure
    if wait_thread&.alive?
      Process.kill("KILL", wait_thread.pid)
      wait_thread.value
    end
  end
end
