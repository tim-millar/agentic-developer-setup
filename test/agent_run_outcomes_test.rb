# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"

class AgentRunOutcomesTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  RECONCILER = File.join(ROOT, "baseline/scripts/agent_run_outcomes.sh")
  VALIDATOR = File.join(ROOT, "scripts/validate_agent_run_outcome.rb")
  REPOSITORY = "example-owner/example-repository"
  SHA_A = "a" * 40
  SHA_B = "b" * 40
  SHA_MERGE = "c" * 40
  NOW = "2026-01-02T12:00:00.000Z"

  def setup
    @root = Dir.mktmpdir("agent-run-outcomes-")
    @repository = File.join(@root, "repository")
    @telemetry = File.join(@root, "telemetry")
    @fake_bin = File.join(@root, "bin")
    @fixtures = File.join(@root, "github.json")
    @gh_log = File.join(@root, "gh.log")
    FileUtils.mkdir_p([@repository, @telemetry, @fake_bin])
    git("init", "-q", "-b", "main")
    git("remote", "add", "origin", "https://github.com/#{REPOSITORY}.git")
    write_fake_gh
    write_fixtures({})
  end

  def teardown
    FileUtils.remove_entry_secure(@root) if @root && File.exist?(@root)
  end

  def test_exact_commit_correlation_preserves_lifecycle_reviews_checks_and_source_record
    run_id = create_run(finish_sha: SHA_A, finish_branch: "issue-57")
    run_path = File.join(@telemetry, run_id, "run.json")
    original = File.binread(run_path)
    write_fixtures(full_fixtures)

    result = reconcile("--run", run_id)
    assert result.status.success?, result.stderr

    outcome = read_outcome(run_id)
    assert_equal 1, outcome["schema_version"]
    assert_equal run_id, outcome["run_id"]
    assert_equal "matched", outcome.dig("correlation", "state")
    assert_equal ["finish_head_in_pr_commits"], outcome.dig("correlation", "associations", 0, "established_by")
    pr = outcome.fetch("pull_requests").first
    assert_equal "merged", pr.dig("current", "lifecycle")
    assert_equal SHA_MERGE, pr.dig("current", "merge_commit_sha")
    assert_equal 2, pr.dig("derived", "reviewed_revision_count")
    assert_equal SHA_A, pr.dig("derived", "first_reviewed_revision", "sha")
    assert_equal "yes", pr.dig("derived", "post_first_review_change_observed")
    assert_equal "no", pr.dig("derived", "merged_on_first_reviewed_revision")
    assert_equal %w[passing passing], pr.fetch("checks_by_sha").map { |group| group["observed_check_rollup"] }
    assert_equal 3, pr.fetch("reviews").length
    refute_includes JSON.generate(outcome), "review body must not persist"
    refute_includes JSON.generate(outcome), "synthetic-secret-token"
    assert_equal original, File.binread(run_path)
    assert_equal 0o600, File.stat(File.join(@telemetry, run_id, "outcome.json")).mode & 0o777

    stdout, stderr, status = Open3.capture3(RbConfig.ruby, VALIDATOR, File.join(@telemetry, run_id, "outcome.json"))
    assert status.success?, "#{stdout}\n#{stderr}"
  end

  def test_later_api_omissions_do_not_erase_association_or_history
    run_id = create_run(finish_sha: SHA_A, finish_branch: "issue-57")
    write_fixtures(full_fixtures)
    assert reconcile("--run", run_id).status.success?

    changed = pr(head_sha: SHA_B, head_ref: "rewritten-branch", state: "open", merged: false)
    write_fixtures(
      pulls_endpoint => [[changed]],
      commit_pulls_endpoint(SHA_A) => {"__error" => "HTTP 404 rewritten commit", "__status" => 1},
      pr_endpoint => changed,
      commits_endpoint => [[{"sha" => SHA_B}]],
      timeline_endpoint => [[]],
      reviews_endpoint => [[]],
      checks_endpoint(SHA_A) => [{"check_runs" => []}], statuses_endpoint(SHA_A) => {"statuses" => []},
      checks_endpoint(SHA_B) => [{"check_runs" => []}], statuses_endpoint(SHA_B) => {"statuses" => []}
    )
    assert reconcile("--run", run_id).status.success?

    outcome = read_outcome(run_id)
    assert_equal "matched", outcome.dig("correlation", "state")
    assert_equal [SHA_A, SHA_B], outcome.dig("pull_requests", 0, "commits").map { |item| item["sha"] }
    assert_equal 3, outcome.dig("pull_requests", 0, "reviews").length
    assert_operator outcome.dig("reconciliation", "attempt_count"), :>=, 2
  end

  def test_path_digest_is_not_applicable_without_github_queries
    digest = "sha256:#{Digest::SHA256.hexdigest(File.realpath(@repository))}"
    run_id = create_run(identity_kind: "path_digest", identity_value: digest)
    git("remote", "remove", "origin")
    result = reconcile("--run", run_id)
    assert result.status.success?, result.stderr
    outcome = read_outcome(run_id)
    assert_equal "not_applicable", outcome.dig("correlation", "state")
    assert_equal "not_applicable", outcome.dig("reconciliation", "observation_state")
    assert_equal "quiescent", outcome.dig("reconciliation", "automatic_state")
    refute File.exist?(@gh_log)
  end

  def test_branch_reuse_is_ambiguous_and_text_or_task_number_does_not_establish_association
    run_id = create_run(finish_sha: SHA_A, finish_branch: "reused", task_identifier: "#{REPOSITORY}#57")
    first = pr(number: 10, head_sha: SHA_B, head_ref: "reused", created_at: "2026-01-01T10:30:00.000Z", title: "Issue 57")
    second = pr(number: 11, head_sha: "d" * 40, head_ref: "reused", created_at: "2026-01-01T11:00:00.000Z", body: "Closes #57")
    write_fixtures(
      pulls_endpoint => [[first, second]],
      commit_pulls_endpoint(SHA_A) => [[]],
      timeline_endpoint(10) => [[{"event" => "cross-referenced", "source" => {"issue" => {"number" => 57}}}]],
      timeline_endpoint(11) => [[]]
    )

    assert reconcile("--run", run_id).status.success?
    outcome = read_outcome(run_id)
    assert_equal "ambiguous", outcome.dig("correlation", "state")
    assert_empty outcome.dig("correlation", "associations")
    assert_equal [10, 11], outcome.dig("correlation", "candidates").map { |candidate| candidate["number"] }
    assert_includes outcome.dig("correlation", "candidates", 0, "evidence"), "task_issue_link"
    refute_includes JSON.generate(outcome), "Closes #57"
  end

  def test_automatic_sweep_is_oldest_first_and_bounded_to_three
    digest = "sha256:#{Digest::SHA256.hexdigest(File.realpath(@repository))}"
    ids = 4.times.map do |index|
      create_run(
        identity_kind: "path_digest",
        identity_value: digest,
        started_at: format("2026-01-01T%02d:00:00.000Z", index),
        finished_at: format("2026-01-01T%02d:10:00.000Z", index)
      )
    end
    result = reconcile("--automatic")
    assert result.status.success?, result.stderr
    assert_equal ids.first(3), ids.select { |id| File.file?(File.join(@telemetry, id, "outcome.json")) }
  end

  def test_selected_other_repository_is_rejected_without_crossing_scope
    run_id = create_run(identity_value: "another-owner/another-repository")
    result = reconcile("--run", run_id)
    refute result.status.success?
    assert_includes result.stderr, "another repository"
    refute File.exist?(File.join(@telemetry, run_id, "outcome.json"))
    refute File.exist?(@gh_log)
  end

  def test_malformed_nested_source_record_is_rejected_without_sidecar
    run_id = create_run
    path = File.join(@telemetry, run_id, "run.json")
    record = JSON.parse(File.binread(path))
    record.fetch("runtime").fetch("client").delete("version")
    File.write(path, JSON.generate(record))

    result = reconcile("--run", run_id)

    refute result.status.success?
    assert_includes result.stderr, "unsupported or inconsistent source record"
    refute File.exist?(File.join(@telemetry, run_id, "outcome.json"))
    refute File.exist?(@gh_log)
  end

  def test_busy_lock_is_skipped_automatically_and_rejected_explicitly
    run_id = create_run
    lock = File.join(@telemetry, run_id, ".outcome.lock")
    Dir.mkdir(lock, 0o700)
    automatic = reconcile("--automatic")
    assert automatic.status.success?, automatic.stderr
    refute File.file?(File.join(@telemetry, run_id, "outcome.json"))
    explicit = reconcile("--run", run_id)
    refute explicit.status.success?
    assert_includes explicit.stderr, "busy"
  end

  def test_stale_lock_is_recovered
    digest = "sha256:#{Digest::SHA256.hexdigest(File.realpath(@repository))}"
    run_id = create_run(identity_kind: "path_digest", identity_value: digest)
    lock = File.join(@telemetry, run_id, ".outcome.lock")
    Dir.mkdir(lock, 0o700)
    File.utime(Time.utc(2026, 1, 1), Time.utc(2026, 1, 1), lock)
    result = reconcile("--run", run_id)
    assert result.status.success?, result.stderr
    assert File.file?(File.join(@telemetry, run_id, "outcome.json"))
    refute File.exist?(lock)
  end

  def test_competing_explicit_reconcilers_do_not_enter_the_same_run
    run_id = create_run
    write_fixtures(pulls_endpoint => [[]], commit_pulls_endpoint(SHA_A) => [[]])
    stdin, stdout, stderr, thread = Open3.popen3(
      reconcile_env.merge("FAKE_GH_DELAY" => "0.3"),
      RECONCILER, "--run", run_id,
      chdir: @repository,
      unsetenv_others: true
    )
    stdin.close
    lock = File.join(@telemetry, run_id, ".outcome.lock")
    deadline = Time.now + 3
    sleep 0.01 until File.directory?(lock) || Time.now >= deadline
    assert File.directory?(lock), "first reconciler did not acquire its per-run lock"

    competing = reconcile("--run", run_id)
    refute competing.status.success?
    assert_includes competing.stderr, "busy"
    assert thread.value.success?, stderr.read
    stdout.close
    stderr.close
    refute File.exist?(lock)
  ensure
    stdin&.close unless stdin&.closed?
    stdout&.close unless stdout&.closed?
    stderr&.close unless stderr&.closed?
    Process.kill("KILL", thread.pid) if thread&.alive?
  end

  def test_telemetry_opt_out_and_usage_status
    run_id = create_run
    result = reconcile("--run", run_id, env: {"AGENT_TELEMETRY" => "0"})
    assert result.status.success?
    refute File.exist?(File.join(@telemetry, run_id, "outcome.json"))
    invalid = reconcile("--automatic", "--all")
    assert_equal 2, invalid.status.exitstatus
  end

  def test_unavailable_api_evidence_records_safe_error_and_one_hour_retry
    run_id = create_run
    write_fixtures(pulls_endpoint => {"__error" => "HTTP 403 synthetic arbitrary response body", "__status" => 1})

    result = reconcile("--run", run_id)

    refute result.status.success?
    outcome = read_outcome(run_id)
    assert_equal "unavailable", outcome.dig("correlation", "state")
    assert_equal "unavailable", outcome.dig("reconciliation", "observation_state")
    assert_equal "authorization", outcome.dig("reconciliation", "last_error", "category")
    assert_equal 403, outcome.dig("reconciliation", "last_error", "http_status")
    assert_equal "2026-01-02T13:00:00.000Z", outcome.dig("reconciliation", "next_eligible_at")
    refute_includes JSON.generate(outcome), "arbitrary response body"
  end

  def test_unresolved_record_becomes_dormant_after_thirty_days
    run_id = create_run
    write_fixtures(pulls_endpoint => [[]], commit_pulls_endpoint(SHA_A) => [[]])

    result = reconcile("--run", run_id, env: {"AGENT_OUTCOME_NOW" => "2026-02-05T12:00:00.000Z"})

    assert result.status.success?, result.stderr
    outcome = read_outcome(run_id)
    assert_equal "unmatched", outcome.dig("correlation", "state")
    assert_equal "dormant", outcome.dig("reconciliation", "automatic_state")
    assert_nil outcome.dig("reconciliation", "next_eligible_at")
    attempts = outcome.dig("reconciliation", "attempt_count")
    assert reconcile("--automatic", env: {"AGENT_OUTCOME_NOW" => "2026-02-06T12:00:00.000Z"}).status.success?
    assert_equal attempts, read_outcome(run_id).dig("reconciliation", "attempt_count")
  end

  def test_reopened_branch_lifecycle_can_establish_temporal_compatibility
    run_id = create_run(finish_branch: "reopened")
    pull = pr(head_sha: SHA_B, head_ref: "reopened", state: "closed", created_at: "2025-12-01T09:00:00.000Z")
    pull["closed_at"] = "2025-12-15T09:00:00.000Z"
    events = [
      {"id" => 1, "event" => "closed", "created_at" => "2025-12-15T09:00:00.000Z"},
      {"id" => 2, "event" => "reopened", "created_at" => "2026-01-01T09:00:00.000Z"},
      {"id" => 3, "event" => "closed", "created_at" => "2026-01-01T11:00:00.000Z"}
    ]
    write_fixtures(
      pulls_endpoint => [[pull]], commit_pulls_endpoint(SHA_A) => [[]], timeline_endpoint => [events],
      pr_endpoint => pull, commits_endpoint => [[{"sha" => SHA_B}]], reviews_endpoint => [[]],
      checks_endpoint(SHA_B) => [{"check_runs" => []}], statuses_endpoint(SHA_B) => {"statuses" => []}
    )

    assert reconcile("--run", run_id).status.success?
    outcome = read_outcome(run_id)
    assert_equal "matched", outcome.dig("correlation", "state")
    assert_equal ["unique_head_branch"], outcome.dig("correlation", "associations", 0, "established_by")
  end

  def test_check_rerun_history_is_retained_and_latest_logical_context_wins
    run_id = create_run(finish_sha: SHA_A)
    fixtures = full_fixtures
    fixtures[checks_endpoint(SHA_A)] = [{"check_runs" => [
      {"id" => 10, "name" => "test", "app" => {"id" => 1, "slug" => "ci"}, "head_sha" => SHA_A, "status" => "completed", "conclusion" => "failure", "started_at" => "2026-01-01T11:00:00.000Z", "completed_at" => "2026-01-01T11:01:00.000Z"},
      {"id" => 11, "name" => "test", "app" => {"id" => 1, "slug" => "ci"}, "head_sha" => SHA_A, "status" => "completed", "conclusion" => "success", "started_at" => "2026-01-01T12:00:00.000Z", "completed_at" => "2026-01-01T12:01:00.000Z"}
    ]}]
    write_fixtures(fixtures)

    assert reconcile("--run", run_id).status.success?
    group = read_outcome(run_id).dig("pull_requests", 0, "checks_by_sha").find { |item| item["sha"] == SHA_A }
    assert_equal 2, group.fetch("check_runs").length
    assert_equal "passing", group["observed_check_rollup"]
  end

  def test_schema_is_valid_json_and_forbidden_subjective_fields_are_absent
    schema = JSON.parse(File.binread(File.join(ROOT, "schemas/agent-run-outcome-v1.schema.json")))
    assert_equal 1, schema.dig("properties", "schema_version", "const")
    text = File.binread(RECONCILER)
    assert_equal text, File.binread(File.join(ROOT, "agent-runtimes/claude-explore/lib/agent_run_outcomes.sh"))
    %w[first_pass_rtm amendment_count primary_pr primary_run].each { |field| refute_includes text, field }
  end

  private

  # standard:disable Style/RedundantStructKeywordInit
  Result = Struct.new(:stdout, :stderr, :status, keyword_init: true)
  # standard:enable Style/RedundantStructKeywordInit

  def reconcile(*arguments, env: {})
    stdout, stderr, status = Open3.capture3(
      reconcile_env.merge(env),
      RECONCILER,
      *arguments,
      chdir: @repository,
      unsetenv_others: true
    )
    Result.new(stdout: stdout, stderr: stderr, status: status)
  end

  def reconcile_env
    {
      "HOME" => File.join(@root, "home"),
      "PATH" => [@fake_bin, File.dirname(RbConfig.ruby), "/usr/bin", "/bin"].join(File::PATH_SEPARATOR),
      "AGENT_TELEMETRY_DIR" => @telemetry,
      "AGENT_OUTCOME_NOW" => NOW,
      "OUTCOME_RUBY_BIN" => RbConfig.ruby,
      "OUTCOME_GH_BIN" => File.join(@fake_bin, "gh"),
      "FAKE_GH_FIXTURES" => @fixtures,
      "FAKE_GH_LOG" => @gh_log,
      "GH_TOKEN" => "synthetic-secret-token"
    }
  end

  def git(*arguments)
    _stdout, stderr, status = Open3.capture3("git", "-C", @repository, *arguments)
    raise stderr unless status.success?
  end

  def create_run(identity_kind: "github", identity_value: REPOSITORY, state: "completed", finish_sha: SHA_A, finish_branch: "issue-57", started_at: "2026-01-01T10:00:00.000Z", finished_at: "2026-01-01T10:20:00.000Z", task_identifier: nil)
    ordinal = Dir.glob(File.join(@telemetry, "run-*")).length + 1
    run_id = format("run-20260101T%06dZ-%032x", ordinal, ordinal)
    finish = {"branch" => finish_branch, "detached" => false, "head_sha" => finish_sha, "dirty" => false, "staged_count" => 0, "unstaged_count" => 0, "untracked_count" => 0}
    record = {
      "schema_version" => 1, "run_id" => run_id, "state" => state,
      "runtime" => {"client" => {"id" => "codex-cli", "version" => {"evidence_kind" => "runtime_observed", "value" => "1.2.3"}}, "harness" => {"id" => "agent-development-framework/codex", "version" => 1, "revision" => "sha256:#{"f" * 64}"}, "session" => {"evidence_kind" => "unavailable", "value" => nil}},
      "configuration" => {"model" => observation, "reasoning_effort" => observation, "configuration_stability" => "unknown"},
      "repository" => {"identity" => {"kind" => identity_kind, "value" => identity_value}, "start" => finish, "finish" => finish},
      "task" => {"source" => task_identifier ? "github_issue" : "unavailable", "identifier" => task_identifier, "content_sha256" => nil, "snapshot" => nil},
      "timing" => {"run_started_at" => started_at, "child_started_at" => started_at, "child_finished_at" => finished_at, "run_finished_at" => finished_at, "calendar_elapsed_ms" => 1_200_000},
      "termination" => {"child_exit_code" => 0, "signal" => nil, "reason" => "child_exited_successfully"}, "extensions" => {}
    }
    directory = File.join(@telemetry, run_id)
    FileUtils.mkdir_p(directory, mode: 0o700)
    File.write(File.join(directory, "run.json"), JSON.pretty_generate(record), mode: "w", perm: 0o600)
    run_id
  end

  def observation
    {"requested" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil}, "initial_effective" => {"evidence_kind" => "unavailable", "value" => nil, "source" => nil}}
  end

  def pr(number: 42, head_sha: SHA_B, head_ref: "issue-57", state: "open", merged: false, created_at: "2026-01-01T09:00:00.000Z", title: nil, body: nil)
    {
      "number" => number, "node_id" => "PR_#{number}", "state" => state, "draft" => false, "merged" => merged,
      "head" => {"sha" => head_sha, "ref" => head_ref, "repo" => {"full_name" => REPOSITORY}},
      "base" => {"sha" => "e" * 40, "ref" => "main", "repo" => {"full_name" => REPOSITORY}},
      "created_at" => created_at, "updated_at" => "2026-01-02T10:00:00.000Z",
      "closed_at" => merged ? "2026-01-02T10:00:00.000Z" : nil, "merged_at" => merged ? "2026-01-02T10:00:00.000Z" : nil,
      "merge_commit_sha" => merged ? SHA_MERGE : nil, "title" => title, "body" => body
    }
  end

  def full_fixtures
    pull = pr(state: "closed", merged: true)
    {
      pulls_endpoint => [[pull]], commit_pulls_endpoint(SHA_A) => [[pull]], pr_endpoint => pull,
      commits_endpoint => [[{"sha" => SHA_A}, {"sha" => SHA_B}]],
      timeline_endpoint => [[{"id" => 1, "event" => "ready_for_review", "created_at" => "2026-01-01T11:00:00.000Z", "actor" => {"login" => "developer", "type" => "User"}}]],
      reviews_endpoint => [[
        {"id" => 1, "user" => {"login" => "review-bot", "type" => "Bot"}, "state" => "APPROVED", "commit_id" => SHA_A, "submitted_at" => "2026-01-01T12:00:00.000Z", "body" => "review body must not persist"},
        {"id" => 2, "user" => {"login" => "human", "type" => "User"}, "state" => "COMMENTED", "commit_id" => SHA_A, "submitted_at" => "2026-01-01T12:05:00.000Z"},
        {"id" => 3, "user" => {"login" => "human", "type" => "User"}, "state" => "CHANGES_REQUESTED", "commit_id" => SHA_B, "submitted_at" => "2026-01-01T14:00:00.000Z"},
        {"id" => 4, "user" => {"login" => "human", "type" => "User"}, "state" => "PENDING", "commit_id" => SHA_B, "submitted_at" => nil}
      ]],
      checks_endpoint(SHA_A) => [{"check_runs" => [{"id" => 11, "name" => "test", "app" => {"id" => 1, "slug" => "ci"}, "head_sha" => SHA_A, "status" => "completed", "conclusion" => "success", "started_at" => "2026-01-01T12:00:00.000Z", "completed_at" => "2026-01-01T12:01:00.000Z", "output" => {"text" => "not persisted"}}]}],
      statuses_endpoint(SHA_A) => {"statuses" => [{"id" => 21, "context" => "legacy", "state" => "success", "created_at" => "2026-01-01T12:00:00.000Z", "updated_at" => "2026-01-01T12:01:00.000Z", "creator" => {"login" => "ci", "type" => "Bot"}}]},
      checks_endpoint(SHA_B) => [{"check_runs" => [{"id" => 12, "name" => "test", "app" => {"id" => 1, "slug" => "ci"}, "head_sha" => SHA_B, "status" => "completed", "conclusion" => "neutral", "started_at" => "2026-01-01T14:00:00.000Z", "completed_at" => "2026-01-01T14:01:00.000Z"}]}],
      statuses_endpoint(SHA_B) => {"statuses" => []}
    }
  end

  def pulls_endpoint = "repos/#{REPOSITORY}/pulls?state=all&per_page=100"
  def commit_pulls_endpoint(sha) = "repos/#{REPOSITORY}/commits/#{sha}/pulls?per_page=100"
  def pr_endpoint(number = 42) = "repos/#{REPOSITORY}/pulls/#{number}"
  def commits_endpoint(number = 42) = "repos/#{REPOSITORY}/pulls/#{number}/commits?per_page=100"
  def timeline_endpoint(number = 42) = "repos/#{REPOSITORY}/issues/#{number}/timeline?per_page=100"
  def reviews_endpoint(number = 42) = "repos/#{REPOSITORY}/pulls/#{number}/reviews?per_page=100"
  def checks_endpoint(sha) = "repos/#{REPOSITORY}/commits/#{sha}/check-runs?per_page=100"
  def statuses_endpoint(sha) = "repos/#{REPOSITORY}/commits/#{sha}/status"

  def read_outcome(run_id)
    JSON.parse(File.binread(File.join(@telemetry, run_id, "outcome.json")))
  end

  def write_fixtures(value)
    File.write(@fixtures, JSON.pretty_generate(value))
  end

  def write_fake_gh
    path = File.join(@fake_bin, "gh")
    File.write(path, <<~RUBY)
      #!#{RbConfig.ruby}
      require "json"
      endpoint = ARGV.last
      File.open(ENV.fetch("FAKE_GH_LOG"), "a") { |file| file.puts(endpoint) }
      sleep Float(ENV["FAKE_GH_DELAY"]) if ENV["FAKE_GH_DELAY"]
      fixtures = JSON.parse(File.binread(ENV.fetch("FAKE_GH_FIXTURES")))
      value = fixtures.fetch(endpoint, ARGV.include?("--slurp") ? [[]] : {})
      if value.is_a?(Hash) && value["__error"]
        warn value["__error"]
        exit(value["__status"] || 1)
      end
      puts JSON.generate(value)
    RUBY
    File.chmod(0o700, path)
  end
end
