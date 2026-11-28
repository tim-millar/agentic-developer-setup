# frozen_string_literal: true

require "fileutils"
require "json"
require "minitest/autorun"
require "open3"
require "rbconfig"
require "tmpdir"
require_relative "../lib/agent_run_cli"
require_relative "../scripts/manage_agent_runs"

class AgentRunReportingTest < Minitest::Test
  SCRIPT = File.expand_path("../scripts/report_agent_runs.rb", __dir__)
  RUNS_CLI = File.expand_path("../scripts/ads-agent-runs", __dir__)
  REPOSITORY = "example-owner/example-repo"
  FIRST = "2026-01-31T23:50:00.000Z"
  FINISHED = "2026-02-01T00:20:00.000Z"
  MARCH = "2026-03-01T00:00:00.000Z"
  APRIL = "2026-04-01T00:00:00.000Z"
  AS_OF = "2026-05-01T00:00:00Z"
  SHA = "a" * 40

  def setup
    @scratch = Dir.mktmpdir("ads-report-test-")
    @root = File.join(@scratch, "runs")
    Dir.mkdir(@root)
    @ordinal = 0
  end

  def teardown
    FileUtils.remove_entry_secure(@scratch)
  end

  def test_empty_roots_are_explicit_and_implicit_missing_root_is_not_created
    markdown = report
    assert_includes markdown, "No valid run data"
    assert_includes markdown, "- Complete usage coverage: 0/0 (unavailable)"
    assert_includes markdown, "- Creation-to-merge calendar time, median: unavailable"

    FileUtils.rmdir(@root)
    assert_includes report(explicit: false), "No valid run data"
    refute File.exist?(@root)
    _, error, status = cli("--output", @root, explicit: false)
    assert_equal 1, status.exitstatus
    assert_includes error, "outside telemetry storage"
    refute File.exist?(@root)
    _, error, status = cli
    assert_equal 1, status.exitstatus
    assert_includes error, "Selected telemetry root does not exist"

    File.write(@root, "")
    _, error, status = cli
    assert_equal 1, status.exitstatus
    assert_includes error, "Cannot read selected telemetry root"
  end

  def test_cli_root_precedence_and_invalid_arguments
    run = add_run
    xdg = File.join(@scratch, "data")
    home = File.join(@scratch, "home")
    [xdg, File.join(home, ".local/share")].each do |base|
      root = File.join(base, "agent-development-framework/telemetry/runs")
      FileUtils.mkdir_p(root)
      FileUtils.cp_r(File.join(@root, run), root)
    end
    assert_includes report(explicit: false, env: {"XDG_DATA_HOME" => xdg, "HOME" => home}), "- Source run count: 1"
    assert_includes report(explicit: false, env: {"XDG_DATA_HOME" => xdg, "HOME" => home, "AGENT_TELEMETRY_DIR" => nil}), "- Source run count: 1"
    assert_includes report(explicit: false, env: {"XDG_DATA_HOME" => "", "HOME" => home, "AGENT_TELEMETRY_DIR" => nil}), "- Source run count: 1"
    [
      %w[--repository invalid],
      %w[--telemetry-dir relative],
      %w[--output relative.md],
      %w[--as-of 2026-02-30T00:00:00Z],
      %w[--unknown],
      %w[extra]
    ].each do |arguments|
      _, error, status = cli(*arguments, explicit: false)
      assert_equal 2, status.exitstatus, arguments.inspect
      assert_includes error, "Usage:"
    end
  end

  def test_usage_populations_model_attribution_resumes_and_weighted_cache
    first = add_run
    second = add_run(start: MARCH, state: "interrupted")
    add_usage(first, codex("model-a", input: 100, cache: 90), codex("model-b", input: 20, cache: 0, write: nil))
    add_usage(second, codex("model-a", input: 80, cache: 10))
    markdown = report
    assert_includes markdown, "- Recorded valid runs: 2"
    assert_includes markdown, "| interrupted | 1 |"
    assert_includes markdown, "| openai | model-a | complete | 2 | 2 |"
    assert_includes markdown, "| openai | model-b | complete | 1 | 1 |"
    refute_includes markdown, "requested-model"
    resources = section(markdown, "## Computational resource consumption")
    assert_includes resources, "- Recorded measurements: 3"
    assert_includes resources, "| input_total | 200 | 2/2 |"
    assert_includes resources, "| input_uncached | 100 | 2/2 |"
    assert_includes resources, "| input_cache_write | 5 | 1/2 |"
    assert_includes resources, "| output_total | 21 | 2/2 |"
    assert_includes resources, "| output_reasoning | 9 | 2/2 |"
    assert_includes resources, "100/200 (50.00%) · 3/3 measurements"
    assert_includes resources, "| unavailable | 2 |"
    assert_includes resources, "Measurements with observed cost: 0/3 (0.00%)"
    assert_includes section(markdown, "### Run start cohorts"), "#### 2026-02\n\nZero recorded activity."
  end

  def test_complete_zero_missing_dimensions_and_partial_or_unavailable_usage
    add_run
    add_usage(add_run, state: "unavailable")
    add_usage(add_run, state: "disabled")
    add_usage(add_run, state: "complete")
    add_usage(add_run, codex("zero", input: 0, cache: 0))
    add_usage(add_run, codex("retained", input: 10, cache: 11), state: "partial",
      reason: "normalization_inconsistent", warnings: ["codex_cached_input_exceeds_total"])
    markdown = report
    coverage = section(markdown, "## Evidence coverage")
    assert_includes coverage, "- Complete usage coverage: 2/6 (33.33%)"
    %w[partial unavailable disabled].each { |state| assert_includes coverage, "| #{state} | 1 |" }
    assert_includes coverage, "| sidecar absent | 1 |"
    complete = section(markdown, "### Complete recorded usage")
    assert_includes complete, "| input_total | 0 | 2/2 |"
    assert_includes complete, "0/0 (unavailable) · 0/1 measurements"
    partial = section(markdown, "### Partial observed usage")
    assert_includes partial, "- Recorded measurements: 1"
    assert_includes partial, "| input_cache_read | 11 | 1/1 |"
    assert_includes partial, "| input_uncached | unavailable | 0/1 |"
    assert_includes partial, "0/0 (unavailable) · 0/1 measurements"
  end

  def test_claude_provider_estimates_preserve_cost_states_and_price_coverage
    add_usage(add_run(client: "claude-code"), claude(cost: 0), claude(cost: 7))
    add_usage(add_run(client: "claude-code"), claude(cost: 13))
    add_usage(add_run(client: "claude-code"), claude(cost: 9), claude(cost: nil))
    add_usage(add_run, codex("openai-model"))
    markdown = report
    resources = section(markdown, "## Computational resource consumption")
    assert_includes resources, "| complete | runtime_estimated | USD | 20 | 2 | 3/3 |"
    assert_includes resources, "| partial | runtime_estimated | USD | 9 | 1 | 1/2 |"
    assert_includes resources, "Measurements with observed cost: 4/6 (66.67%)"
    assert_includes resources, "| output_reasoning | 3 | 1/4 |"
    assert_includes markdown, "| claude-code | 3 |"
  end

  def test_many_to_many_associations_and_latest_current_snapshot_across_cohorts
    first = add_run
    second = add_run(start: MARCH, repository: "EXAMPLE-OWNER/EXAMPLE-REPO")
    add_usage(first, codex("model-a"))
    add_usage(second, codex("model-a"))
    add_outcome(first, pull(42, observed: FINISHED), pull(61, created: nil, lifecycle: "merged", merged: FINISHED, observed: FINISHED))
    add_outcome(second, pull(42, observed: APRIL, lifecycle: "merged", merged: MARCH, reviews: [SHA, SHA]),
      pull(74, created: MARCH, observed: APRIL, reviews: [nil]), at: APRIL)
    markdown = report("--as-of", "2026-02-04T00:00:00Z")
    assert_includes markdown, "- Source run count: 2"
    assert_includes markdown, "- Latest available outcome reconciliation: #{APRIL}"
    assert_includes section(markdown, "### Complete recorded usage"), "- Recorded measurements: 2"
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- Distinct associated PRs: 3"
    assert_includes outcomes, "- Runs with confirmed associations in this PR population: 2"
    assert_includes outcomes, "- Confirmed run–PR relationships: 4"
    assert_includes outcomes, "| merged | 2 |"
    assert_includes outcomes, "| open | 1 |"
    assert_includes outcomes, "| 1 | 1 |"
    assert_includes outcomes, "- PRs with usable reviewed-revision evidence: 2"
    assert_includes outcomes, "- PRs with no qualifying submitted review in complete evidence: 1"
    assert_includes outcomes, "- PRs with incomplete or unavailable review evidence: 1"
    assert_includes outcomes, "- Creation-to-merge eligible PRs: 1/2"
    assert_includes outcomes, "- Creation-to-merge calendar time, median: 28d 00h 10m 00.0000s"
    assert_includes outcomes, "- Merged PRs excluded for missing or inconsistent timestamps: 1"
    cohorts = section(markdown, "### PR creation cohorts")
    assert_includes cohorts, "#### 2026-01"
    assert_includes cohorts, "#### 2026-03"
    assert_includes cohorts, "#### Unknown cohort"
    assert_includes cohorts, "creation month is after the report timestamp"
    assert_includes cohorts, "Zero recorded PR creations in this cohort."
  end

  def test_ties_and_newer_unavailable_snapshots_preserve_reliable_evidence
    add_outcome(add_run, pull(42, lifecycle: "merged", merged: MARCH, observed: APRIL), at: APRIL)
    add_outcome(add_run, pull(42, lifecycle: "open", observed: APRIL), at: APRIL)
    placeholder = pull(73, lifecycle: "unavailable", observed: APRIL, created: nil, post: "unavailable")
    add_outcome(add_run, placeholder, state: "partial", at: APRIL)
    add_outcome(add_run, pull(73, lifecycle: "closed_unmerged", observed: MARCH),
      pull(90, lifecycle: "merged", merged: FIRST, created: MARCH, observed: APRIL),
      pull(91, lifecycle: "merged", created: MARCH, observed: APRIL), at: APRIL)
    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "| closed_unmerged | 1 |"
    assert_includes outcomes, "| unavailable/conflicting | 1 |"
    assert_includes outcomes, "- Creation-to-merge calendar time, median: unavailable"
    assert_includes outcomes, "- Merged PRs excluded for missing or inconsistent timestamps: 2"
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for lifecycle, merged_at."
  end

  def test_equal_time_unavailable_lifecycle_conflicts_with_open_in_either_order
    first_run = add_run
    second_run = add_run
    known = pull(42)
    unknown = pull(42, lifecycle: "unavailable")
    add_outcome(first_run, known)
    add_outcome(second_run, unknown)

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- Distinct associated PRs: 1"
    assert_includes outcomes, "| unavailable/conflicting | 1 |"
    assert_includes outcomes, "| open | 0 |"
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for lifecycle."

    add_outcome(first_run, unknown)
    add_outcome(second_run, known)
    assert_equal markdown, report
  end

  def test_equal_time_null_creation_timestamp_conflicts_without_falling_back
    add_outcome(add_run, pull(42))
    add_outcome(add_run, pull(42, observed: APRIL), at: APRIL)
    add_outcome(add_run, pull(42, created: nil, observed: APRIL), at: APRIL)

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- Distinct associated PRs: 1"
    assert_includes outcomes, "| open | 1 |"
    cohorts = section(markdown, "### PR creation cohorts")
    assert_includes cohorts, "#### Unknown cohort"
    refute_match(/^#### \d{4}-\d{2}$/, cohorts)
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for created_at."
  end

  def test_equal_time_null_merge_timestamp_excludes_interval_but_preserves_merge
    add_outcome(add_run, pull(42, lifecycle: "merged", merged: MARCH, observed: APRIL), at: APRIL)
    add_outcome(add_run, pull(42, lifecycle: "merged", observed: APRIL), at: APRIL)

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- Distinct associated PRs: 1"
    assert_includes outcomes, "| merged | 1 |"
    assert_includes outcomes, "- Creation-to-merge eligible PRs: 0/1 merged PRs"
    assert_includes outcomes, "- Merged PRs excluded for missing or inconsistent timestamps: 1"
    assert_includes outcomes, "- Creation-to-merge calendar time, median: unavailable"
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for merged_at."
  end

  def test_unavailable_lifecycle_with_draft_evidence_is_an_eligible_snapshot
    add_outcome(add_run, pull(42))
    latest = pull(42, lifecycle: "unavailable", created: nil, observed: APRIL)
    latest.fetch("current")["draft"] = false
    add_outcome(add_run, latest, at: APRIL)

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "| unavailable/conflicting | 1 |"
    assert_includes outcomes, "| open | 0 |"
    assert_includes section(markdown, "### PR creation cohorts"), "#### Unknown cohort"
    assert_includes markdown, "- PRs with conflicting observations: 0"
  end

  def test_agreed_positive_revision_count_can_have_incomplete_review_evidence
    add_outcome(add_run, pull(42, reviews: [SHA], post: "no"))
    add_outcome(add_run, pull(42, reviews: [SHA, nil], post: "no"), state: "partial")

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- PRs with usable reviewed-revision evidence: 1"
    assert_includes outcomes, "| 1 | 1 |"
    assert_includes outcomes, "- PRs with incomplete or unavailable review evidence: 1"
    assert_includes outcomes, "- PRs with no qualifying submitted review in complete evidence: 0"
    assert_includes markdown, "- PRs with conflicting observations: 0"
  end

  def test_equal_time_reviewed_revision_count_conflict_is_unavailable
    add_outcome(add_run, pull(42, reviews: [SHA], post: "no"))
    add_outcome(add_run, pull(42, reviews: [SHA, "b" * 40], post: "no"))

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- PRs with usable reviewed-revision evidence: 0"
    assert_includes outcomes, "- PRs with incomplete or unavailable review evidence: 1"
    assert_includes outcomes, "- PRs with no qualifying submitted review in complete evidence: 0"
    refute_match(/^\| [012] \| \d+ \|$/, outcomes)
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for reviewed_revision_count."
  end

  def test_zero_reviewed_revisions_require_complete_evidence_from_each_selected_observation
    add_outcome(add_run, pull(42), pull(43))
    add_outcome(add_run, pull(42), state: "partial")
    add_outcome(add_run, pull(43))

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "- Distinct associated PRs: 2"
    assert_includes outcomes, "- PRs with no qualifying submitted review in complete evidence: 1"
    assert_includes outcomes, "- PRs with usable reviewed-revision evidence: 1"
    assert_includes outcomes, "- PRs with incomplete or unavailable review evidence: 1"
    assert_includes outcomes, "| 0 | 1 |"
    assert_includes markdown, "- PRs with conflicting observations: 0"
  end

  def test_equal_time_post_first_review_change_disagreement_is_unavailable
    changed = pull(42, reviews: [SHA], post: "yes")
    changed.fetch("current")["head_sha"] = "b" * 40
    add_outcome(add_run, changed)
    add_outcome(add_run, pull(42, reviews: [SHA], post: "no"))

    markdown = report
    outcomes = section(markdown, "## Observable engineering outcomes")
    assert_includes outcomes, "| 1 | 1 |"
    assert_includes outcomes, "| unavailable | 1 |"
    assert_includes outcomes, "| yes | 0 |"
    assert_includes outcomes, "| no | 0 |"
    assert_includes markdown, "#{REPOSITORY}#42 has conflicting observations for post_first_review_change_observed."
  end

  def test_unmatched_candidates_partial_reconciliation_and_repository_scope
    add_outcome(add_run, correlation: "unmatched")
    add_outcome(add_run, correlation: "ambiguous", candidates: [{"repository" => REPOSITORY, "number" => 42, "evidence" => []}])
    add_outcome(add_run, pull(73, reviews: [SHA, nil], post: "unavailable"), state: "partial")
    add_outcome(add_run(kind: "path_digest", repository: "sha256:#{"c" * 64}"), state: "not_applicable", correlation: "not_applicable")
    add_outcome(add_run(repository: "another/example"), pull(73, repository: "another/example"))
    add_run
    markdown = report
    assert_includes markdown, "Local path digest sha256:"
    assert_includes markdown, "- Usable outcome coverage among applicable GitHub runs: 4/5 (80.00%)"
    assert_includes markdown, "- Distinct associated PRs: 2"
    coverage = section(markdown, "## Evidence coverage")
    %w[unmatched ambiguous not_applicable partial].each { |state| assert_includes coverage, "| #{state} | 1 |" }
    filtered = report("--repository", REPOSITORY.upcase)
    assert_includes filtered, "- Source run count: 4"
    assert_includes filtered, "- Distinct associated PRs: 1"
    outcomes = section(filtered, "## Observable engineering outcomes")
    assert_includes outcomes, "- PRs with usable reviewed-revision evidence: 1"
    assert_includes outcomes, "| 1 | 1 |"
    assert_includes outcomes, "- PRs with incomplete or unavailable review evidence: 1"
    assert_includes outcomes, "| unavailable | 1 |"
    assert_includes outcomes, "| no | 0 |"
    refute_includes filtered, "another/example"
  end

  def test_invalid_runs_and_sidecars_are_isolated_without_printing_private_fields
    bad_run = add_run
    File.write(File.join(@root, bad_run, "run.json"), '{"SYNTHETIC PRIVATE')
    add_usage(bad_run, codex("excluded-model"))
    future = add_run
    update(future, "run.json") { |run| run["schema_version"] = 2 }
    mismatched = add_run
    update(mismatched, "run.json") { |run| run["run_id"] = future }
    valid = add_run
    add_usage(valid, codex("excluded-model"))
    update(valid, "usage.json") { |usage| usage["run_id"] = future }
    add_outcome(valid, pull(73))
    update(valid, "outcome.json") { |outcome| outcome["pull_requests"].first["identity"]["repository"] = 42 }
    negative = add_run
    add_usage(negative, codex("excluded-model"))
    update(negative, "usage.json") { |usage| usage["observed_totals"]["input_total"] = -1 }
    add_outcome(negative, pull(73))
    update(negative, "outcome.json") { |outcome| outcome["source_run_schema_version"] = 2 }

    markdown = report
    assert_includes markdown, "- Source run count: 2"
    assert_includes markdown, "Invalid or skipped run records in selected root (before filtering): 3"
    assert_includes markdown, "| sidecar invalid or unsupported | 2 |"
    assert_includes markdown, "run.json · malformed JSON (1): #{bad_run}"
    assert_includes markdown, "run.json · unsupported schema version (1): #{future}"
    assert_includes markdown, "run.json · run ID does not match its directory (1): #{mismatched}"
    assert_includes markdown, "usage.json · run ID does not match its directory (1): #{valid}"
    assert_includes markdown, "usage.json · failed v1 field or consistency validation (1): #{negative}"
    assert_includes markdown, "outcome.json · failed v1 field or consistency validation (1): #{valid}"
    assert_includes markdown, "outcome.json · unsupported schema version (1): #{negative}"
    refute_includes markdown, "SYNTHETIC PRIVATE"
    refute_includes markdown, "excluded-model"
  end

  def test_snapshot_is_deterministic_and_read_only_and_output_is_protected
    run = add_run
    add_usage(run, codex("model|[output]"))
    add_outcome(run, pull(73))
    task = File.join(@root, run, "task.txt")
    File.write(task, "SYNTHETIC TASK SNAPSHOT")
    contents = source_contents
    expected = report
    refute_includes expected, "SYNTHETIC TASK SNAPSHOT"
    refute_includes expected, @scratch
    assert_includes expected, "model&#124;&#91;output&#93;"
    assert_equal(expected, report)
    output = File.join(@scratch, "report.md")
    File.write(output, "old report")
    assert_empty report("--output", output)
    assert_equal expected, File.read(output)
    assert_equal contents, source_contents

    alias_root = File.join(@scratch, "aliased-root")
    File.symlink(@root, alias_root)
    alias_file = File.join(@scratch, "aliased-run.md")
    File.symlink(File.join(@root, run, "run.json"), alias_file)
    [File.join(alias_root, "report.md"), alias_file, task].each do |destination|
      _, error, status = cli("--output", destination)
      assert_equal 1, status.exitstatus
      assert_match(/outside telemetry storage|without links/, error)
    end
    assert_equal contents, source_contents
  end

  def test_linked_records_are_skipped
    first = add_run
    second = add_run
    File.symlink(File.join(@root, first, "run.json"), File.join(@root, second, "usage.json"))
    linked_id = "run-20260131T235000Z-#{"f" * 32}"
    File.symlink(File.join(@root, first), File.join(@root, linked_id))
    markdown = report
    assert_includes markdown, "- Source run count: 2"
    assert_includes markdown, "usage.json · expected a regular file without a symbolic link (1): #{second}"
    assert_includes markdown, "run.json · run directory is not a regular directory (1): #{linked_id}"
  end

  def test_human_cli_lists_shows_and_reuses_the_existing_reporter
    run = add_run
    add_usage(run, codex("observed-model"))
    File.write(File.join(@root, run, "task.txt"), "SYNTHETIC PRIVATE TASK CONTENT")
    list, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--telemetry-dir", @root)
    assert status.success?, error
    assert_match(/Started UTC\s+Run ID/, list)
    assert_includes list, run
    show, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", run, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes show, "Initial effective model: unavailable"
    assert_includes show, "Requested model: requested-model"
    assert_includes show, "observed-model"
    assert_includes show, "task.txt:"
    refute_includes show, "SYNTHETIC PRIVATE TASK CONTENT"
    expected = report("--as-of", AS_OF)
    actual, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "report", "--telemetry-dir", @root, "--as-of", AS_OF)
    assert status.success?, error
    assert_equal expected, actual
  end

  def test_human_cli_argument_errors_and_ambiguous_prefix
    first = add_run
    second = add_run
    _, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--all", "--limit", "2", "--telemetry-dir", @root)
    assert_equal 2, status.exitstatus
    assert_includes error, "cannot be combined"
    prefix = first[0, 12]
    _, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", prefix, "--telemetry-dir", @root)
    assert_equal 2, status.exitstatus
    assert_includes error, "ambiguous"
    _, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "unknown")
    assert_equal 2, status.exitstatus
    assert_includes error, "unknown command"
    help, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "report", "--help")
    assert status.success?, error
    assert_includes help, "Usage: ads-agent-runs report"
    refute_equal first, second
  end

  def test_public_cli_help_and_selector_argument_contract
    [[[], /Usage: ads-agent-runs/], [["-h"], /Usage: ads-agent-runs/], [["--help"], /Usage: ads-agent-runs/],
      [["list", "--help"], /Usage: ads-agent-runs list/], [["list", "-h"], /Usage: ads-agent-runs list/],
      [["show", "--help"], /Usage: ads-agent-runs show <run_id\|unique-prefix\|latest>/],
      [["show", "-h"], /Usage: ads-agent-runs show <run_id\|unique-prefix\|latest>/],
      [["report", "--help"], /Usage: ads-agent-runs report/], [["report", "-h"], /Usage: ads-agent-runs report/]].each do |args, usage|
      output, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, *args)
      assert_equal 0, status.exitstatus, error
      assert_match usage, output
    end
    [["show"], ["show", ""], ["show", "/tmp/run.json"], ["show", "nonsense"],
      ["show", "latest", "extra"], ["list", "--help", "extra"], ["--help", "extra"]].each do |args|
      _, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, *args)
      assert_equal 2, status.exitstatus, args.inspect
      refute_match(/No valid run|selected telemetry root/, error)
    end
  end

  def test_usage_measurement_count_distinguishes_disabled_partial_and_zero
    disabled = add_run
    add_usage(disabled, state: "disabled")
    partial = add_run
    add_usage(partial, codex("partial-model"), state: "partial", reason: "collector_parse_failed")
    zero = add_run
    add_usage(zero)
    update(zero, "usage.json") do |record|
      record["observed_totals"] = record["observed_totals"].transform_values { 0 }
      record["measurements"] = []
      record["provider_sessions"] = []
      record["cost_summary"].merge!("state" => "not_applicable", "observed_usd_micros" => nil, "semantics" => nil, "currency" => nil, "measurement_count" => 0, "priced_measurement_count" => 0)
    end
    disabled_show, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", disabled, "--telemetry-dir", @root)
    assert status.success?, error
    assert_match(/Successful-response measurements: unavailable/, disabled_show)
    refute_match(/Successful-response measurements: 0/, disabled_show)
    partial_show, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", partial, "--telemetry-dir", @root)
    assert status.success?, error
    assert_match(/Observed successful-response measurements \(partial\): 1/, partial_show)
    assert_match(/Observed input total \(partial\): 10/, partial_show)
    zero_show, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", zero, "--telemetry-dir", @root)
    assert status.success?, error
    assert_match(/Successful-response measurements: 0/, zero_show)
    assert_match(/Input total: 0/, zero_show)
  end

  def test_cli_counts_rejected_symlinked_canonical_runs_without_following_them
    run = add_run
    target = File.join(@scratch, "external-run")
    FileUtils.mkdir_p(target)
    File.write(File.join(target, "run.json"), "private sentinel")
    linked_id = "run-20260131T235001Z-#{"f" * 32}"
    File.symlink(target, File.join(@root, linked_id))
    output, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes output, run
    assert_match(/Skipped 1 invalid base record/, error)
    _, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", linked_id, "--telemetry-dir", @root)
    assert_equal 1, status.exitstatus
    assert_includes error, "unusable base evidence"
    assert_equal "private sentinel", File.read(File.join(target, "run.json"))
  end

  def test_selected_sidecars_are_read_once_and_limited_listing_stays_lazy
    run_ids = 21.times.map { add_run }
    reads = Hash.new(0)
    reader = AgentRunReporting::RecordReader.method(:read)
    spy = lambda do |directory, id, name, validator, **options|
      reads[name] += 1 if %w[usage.json outcome.json].include?(name)
      reader.call(directory, id, name, validator, **options)
    end
    AgentRunReporting::RecordReader.define_singleton_method(:read, spy)
    begin
      output, _error = capture_io do
        @cli_status = AgentRunCLI::Command.new.run(["list", "--telemetry-dir", @root])
      end
      assert_equal 0, @cli_status
      assert_includes output, run_ids.last
    ensure
      AgentRunReporting::RecordReader.define_singleton_method(:read, reader)
    end
    assert_equal 20, reads["usage.json"]
    assert_equal 20, reads["outcome.json"]

    reads.clear
    AgentRunReporting::RecordReader.define_singleton_method(:read, spy)
    begin
      capture_io { @cli_status = AgentRunCLI::Command.new.run(["show", run_ids.first, "--telemetry-dir", @root]) }
    ensure
      AgentRunReporting::RecordReader.define_singleton_method(:read, reader)
    end
    assert_equal 1, reads["usage.json"]
    assert_equal 1, reads["outcome.json"]
  end

  def test_listing_filters_before_limits_and_handles_large_limits
    codex_run = add_run(repository: REPOSITORY, client: "codex-cli")
    claude_run = add_run(repository: "Other-Owner/Other-Repo", client: "claude-code")
    path_run = add_run(kind: "path_digest", repository: "sha256:#{"c" * 64}")
    19.times { add_run }
    output, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes output, path_run
    assert_match(/Displayed 20 run\(s\); 2 additional valid run\(s\) omitted\./, output)
    all, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--all", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes all, codex_run
    assert_includes all, claude_run

    filtered, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--repository", "OTHER-OWNER/OTHER-REPO", "--limit", "1", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes filtered, claude_run
    refute_includes filtered, codex_run
    refute_includes filtered, path_run
    huge, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "list", "--limit", "999999999999999999999999999999", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes huge, path_run
    assert_equal 22, huge.scan(/run-\d{8}T\d{6}Z-[0-9a-f]{32}/).length
  end

  def test_snapshot_is_never_opened_and_terminal_controls_are_escaped
    run = add_run
    update(run, "run.json") do |record|
      record["task"] = {"source" => "local_prompt", "identifier" => "safe\nINJECTED", "content_sha256" => "sha256:#{"a" * 64}", "snapshot" => "task.txt"}
    end
    snapshot = File.join(@root, run, "task.txt")
    File.write(snapshot, "synthetic private task contents")
    original_open = File.method(:open)
    guarded_open = lambda do |path, *args, **kwargs, &block|
      raise "task snapshot must not be opened" if File.expand_path(path.to_s) == File.expand_path(snapshot)
      original_open.call(path, *args, **kwargs, &block)
    end
    output = nil
    File.define_singleton_method(:open, guarded_open)
    begin
      output, _error = capture_io do
        @cli_status = AgentRunCLI::Command.new.run(["show", run, "--telemetry-dir", @root])
      end
    ensure
      File.define_singleton_method(:open, original_open)
    end
    assert_equal 0, @cli_status
    assert_includes output, "safe\\u000AINJECTED"
    refute_includes output, "synthetic private task contents"
    refute_includes output, "\nINJECTED"

    FileUtils.rm(snapshot)
    external = File.join(@scratch, "private-task")
    File.write(external, "external private sentinel")
    File.symlink(external, snapshot)
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", run, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "unavailable or unusable"
    refute_includes shown, "external private sentinel"
    assert_equal "external private sentinel", File.read(external)
  end

  def test_show_execution_lifecycles_and_latest_or_unique_selection
    %w[completed preflight_failed launch_failed runtime_failed launcher_failed interrupted].each do |state|
      run = add_run(state: state)
      shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", run, "--telemetry-dir", @root)
      assert status.success?, error
      assert_includes shown, "State: #{state}"
    end

    started = add_run(state: "started")
    update(started, "run.json") do |record|
      record["timing"].merge!("child_finished_at" => nil, "run_finished_at" => nil, "calendar_elapsed_ms" => nil)
      record["termination"] = {"child_exit_code" => nil, "signal" => nil, "reason" => nil}
    end
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", started, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "State: started / not finalised"
    assert_includes shown, "Finished UTC: unavailable"
    assert_includes shown, "Calendar elapsed: unavailable"

    older = add_run(start: FIRST)
    unique_id = older.sub(/-[0-9a-f]{32}\z/, "-f#{"0" * 31}")
    File.rename(File.join(@root, older), File.join(@root, unique_id))
    update_record = JSON.parse(File.read(File.join(@root, unique_id, "run.json")))
    update_record["run_id"] = unique_id
    File.write(File.join(@root, unique_id, "run.json"), JSON.generate(update_record))
    older = unique_id
    latest = add_run(start: MARCH)
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", "latest", "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Run ID: #{latest}"
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", older[0, 22], "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Run ID: #{older}"
  end

  def test_show_projects_usage_and_all_outcome_correlation_states_without_promotion
    usage_run = add_run
    add_usage(usage_run, codex("model-one"), codex("model-two", input: 4))
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", usage_run, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "openai/model-one, openai/model-two"
    assert_includes shown, "Successful-response measurements: 2"
    assert_includes shown, "Runtime monetary evidence: unavailable"
    refute_match(/billed|invoiced/, shown)

    claude_run = add_run(client: "claude-code")
    add_usage(claude_run, claude(cost: 123))
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", claude_run, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Output reasoning: unavailable"
    assert_includes shown, "123 USD micros (provider-reported/runtime estimate)"
    refute_match(/billed|invoiced/, shown)

    matched = add_run
    open_pull = pull(73, lifecycle: "open", reviews: [SHA], post: "yes")
    open_pull["current"]["head_sha"] = SHA
    open_pull["checks_by_sha"] = [
      {"sha" => "b" * 40, "check_runs" => [], "statuses" => [], "evidence" => {"checks" => "complete", "statuses" => "complete"}, "observed_check_rollup" => "failing"},
      {"sha" => SHA, "check_runs" => [], "statuses" => [], "evidence" => {"checks" => "complete", "statuses" => "complete"}, "observed_check_rollup" => "passing"}
    ]
    add_outcome(matched, open_pull, pull(74, lifecycle: "merged", merged: FINISHED), pull(75, lifecycle: "closed_unmerged"))
    matched_evidence = JSON.parse(File.read(File.join(@root, matched, "outcome.json")))
    matched_validator = AgentRunOutcomes::Validator.new(matched_evidence)
    assert matched_validator.validate, matched_validator.errors.join("; ")
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", matched, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Correlation state: matched"
    assert_includes shown, "example-owner/example-repo#73 · open"
    assert_includes shown, "example-owner/example-repo#74 · merged"
    assert_includes shown, "example-owner/example-repo#75 · closed_unmerged"
    assert_includes shown, "Reviewed revisions: 1"
    assert_includes shown, "Post-first-review change observed: yes"
    assert_includes shown, "Current-head checks: passing"
    refute_includes shown, "Current-head checks: failing"

    [
      ["unmatched", "complete", "unmatched", "github", REPOSITORY, []],
      ["ambiguous", "complete", "ambiguous", "github", REPOSITORY, [{"repository" => REPOSITORY, "number" => 99, "evidence" => []}]],
      ["unavailable", "unavailable", "unavailable", "github", REPOSITORY, []],
      ["not_applicable", "not_applicable", "not_applicable", "path_digest", "sha256:#{"c" * 64}", []]
    ].each do |identifier, observation, correlation, kind, repository, candidates|
      run = add_run(kind: kind, repository: repository)
      add_outcome(run, state: observation, correlation: correlation, candidates: candidates)
      output, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", run, "--telemetry-dir", @root)
      assert status.success?, error
      assert_includes output, "Correlation state: #{correlation}"
      assert_includes output, "Observation state: #{observation}"
      refute_includes output, "Confirmed PR: #{repository}#99" if correlation == "ambiguous"
    end

    invalid_optional = add_run
    add_usage(invalid_optional, codex("still-valid-usage"))
    add_outcome(invalid_optional, pull(80))
    File.write(File.join(@root, invalid_optional, "outcome.json"), "{invalid optional record")
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", invalid_optional, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Observed provider/model: openai/still-valid-usage"
    assert_includes shown, "Evidence: invalid or unsupported"
    assert_includes shown, "outcome.json (invalid or unsupported)"

    unavailable_usage = add_run
    add_usage(unavailable_usage, state: "unavailable", reason: "collector_unavailable")
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", unavailable_usage, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Collection: unavailable"
    assert_includes shown, "Successful-response measurements: unavailable"
    refute_match(/Successful-response measurements: 0/, shown)

    invalid_usage = add_run
    add_outcome(invalid_usage, pull(81))
    File.write(File.join(@root, invalid_usage, "usage.json"), "{invalid usage record")
    shown, error, status = Open3.capture3(RbConfig.ruby, RUNS_CLI, "show", invalid_usage, "--telemetry-dir", @root)
    assert status.success?, error
    assert_includes shown, "Correlation state: matched"
    assert_includes shown, "Collection: invalid or unsupported"
  end

  def test_installed_report_matches_populated_corpus_from_outside_checkout
    first = add_run
    add_usage(first, codex("report-model"))
    add_outcome(first, pull(71, lifecycle: "merged", merged: FINISHED, reviews: ["b" * 40], post: "yes"))
    add_run(repository: "other-owner/other-repo") # Historical incomplete run: both sidecars absent.
    install_home = File.join(@scratch, "installed-home")
    FileUtils.mkdir_p(install_home)
    data = File.join(install_home, "data")
    env = {"HOME" => install_home, "XDG_DATA_HOME" => data, "PATH" => "/usr/bin:/bin"}
    source_copy = File.join(@scratch, "install-source")
    AgentRunsInstaller::FILES.each do |relative|
      source = File.expand_path("../#{relative}", __dir__)
      target = File.join(source_copy, relative)
      FileUtils.mkdir_p(File.dirname(target))
      FileUtils.cp(source, target)
    end
    install_output, install_error = capture_io do
      @install_status = AgentRunsInstaller.run(["install"], env: env, source_root: source_copy)
    end
    assert_equal 0, @install_status, install_error
    assert_includes install_output, "Installed"
    installed = File.join(install_home, ".local/bin/ads-agent-runs")
    options = ["--telemetry-dir", @root, "--as-of", AS_OF]
    expected, error, status = Open3.capture3(RbConfig.ruby, SCRIPT, *options)
    assert status.success?, error
    unavailable_copy = "#{source_copy}.unavailable"
    File.rename(source_copy, unavailable_copy)
    begin
      actual, error, status = Open3.capture3(env, installed, "report", *options, chdir: "/tmp")
      assert status.success?, error
      assert_equal expected, actual
      listed, error, status = Open3.capture3(env, installed, "list", "--telemetry-dir", @root, chdir: "/tmp")
      assert status.success?, error
      assert_includes listed, first
      shown, error, status = Open3.capture3(env, installed, "show", first, "--telemetry-dir", @root, chdir: "/tmp")
      assert status.success?, error
      %w[Run Task Execution Usage Outcome Evidence].each { |heading| assert_includes shown, heading }
      assert_includes shown, "example-owner/example-repo#71"
    ensure
      File.rename(unavailable_copy, source_copy) if File.exist?(unavailable_copy)
    end
  end

  private

  def cli(*arguments, explicit: true, env: {})
    defaults = {"AGENT_TELEMETRY_DIR" => @root, "XDG_DATA_HOME" => nil, "HOME" => @scratch}
    root = explicit ? ["--telemetry-dir", @root] : []
    Open3.capture3(defaults.merge(env), RbConfig.ruby, SCRIPT, "--as-of", AS_OF, *root, *arguments)
  end

  def report(...)
    output, error, status = cli(...)
    assert status.success?, error
    assert_empty error
    output
  end

  def section(markdown, title)
    level = title[/\A#+/].length
    content = markdown.split("#{title}\n", 2).fetch(1)
    content.split(/^\#{1,#{level}} /, 2).first
  end

  def source_contents
    Dir.glob(File.join(@root, "*", "*")).sort.to_h { |path| [path, File.binread(path)] }
  end

  def store(run_id, name, record)
    File.write(File.join(@root, run_id, name), JSON.generate(record))
  end

  def update(run_id, name)
    record = JSON.parse(File.read(File.join(@root, run_id, name)))
    yield record
    store(run_id, name, record)
  end

  def add_run(start: FIRST, state: "completed", kind: "github", repository: REPOSITORY, client: "codex-cli")
    @ordinal += 1
    run_id = format("run-20260131T235000Z-%032x", @ordinal)
    FileUtils.mkdir_p(File.join(@root, run_id))
    unavailable = {"evidence_kind" => "unavailable", "value" => nil}
    unavailable_config = unavailable.merge("source" => nil)
    requested = {"evidence_kind" => "launcher_requested", "value" => "requested-model", "source" => "argument"}
    harness = (client == "codex-cli") ? "codex" : "claude-explore"
    store(run_id, "run.json", {
      "schema_version" => 1, "run_id" => run_id, "state" => state,
      "runtime" => {"client" => {"id" => client, "version" => unavailable},
                    "harness" => {"id" => "agent-development-framework/#{harness}", "version" => 1, "revision" => "sha256:#{"a" * 64}"},
                    "session" => {"evidence_kind" => "launcher_requested", "value" => "shared-session"}},
      "configuration" => {"model" => {"requested" => requested, "initial_effective" => unavailable_config},
                          "reasoning_effort" => {"requested" => unavailable_config, "initial_effective" => unavailable_config}, "configuration_stability" => "unknown"},
      "repository" => {"identity" => {"kind" => kind, "value" => repository}, "start" => nil, "finish" => nil},
      "task" => {"source" => "unavailable", "identifier" => nil, "content_sha256" => nil, "snapshot" => nil},
      "timing" => {"run_started_at" => start, "child_started_at" => start, "child_finished_at" => [start, FINISHED].max,
                   "run_finished_at" => [start, FINISHED].max, "calendar_elapsed_ms" => 1_800_000},
      "termination" => {"child_exit_code" => (0 if state == "completed"), "signal" => ("INT" if state == "interrupted"), "reason" => state},
      "extensions" => {}
    })
    run_id
  end

  def codex(model, input: 10, cache: 2, write: 5)
    native = {"kind" => "codex_response_completed", "input_token_count" => input, "cached_token_count" => cache,
              "cache_write_token_count" => write, "output_token_count" => 7, "reasoning_token_count" => 3}
    tokens = [input, (input - cache if cache && cache <= input), cache, write, 7, 3]
    measurement("openai", model, native, tokens)
  end

  def claude(cost:)
    estimate = {"currency" => "USD", "semantics" => "runtime_estimated", "usd_micros" => cost} if cost
    native = {"kind" => "claude_code_api_request", "input_tokens" => 20, "cache_read_tokens" => 4,
              "cache_creation_tokens" => 6, "output_tokens" => 7}
    measurement("anthropic", "claude-model", native, [30, 20, 4, 6, 7, nil], estimate)
  end

  def measurement(provider, model, native, tokens, estimate = nil)
    {"provider" => provider, "model" => model, "provider_session_id" => "shared-session", "tokens" => token_fields.zip(tokens).to_h,
     "native_usage" => native, "runtime_cost" => estimate, "request_source" => nil, "service_tier" => nil, "reasoning_effort" => nil, "duration_ms" => nil}
  end

  def token_fields
    %w[input_total input_uncached input_cache_read input_cache_write output_total output_reasoning]
  end

  def add_usage(run, *measurements, state: "complete", reason: nil, warnings: [])
    is_claude = measurements.first&.fetch("provider") == "anthropic"
    count = measurements.length
    numeric = token_fields.to_h do |field|
      values = measurements.map { |item| item.dig("tokens", field) }
      [field, (values.sum if %w[complete partial].include?(state) && values.none?(&:nil?))]
    end
    amounts = measurements.filter_map { |item| item.dig("runtime_cost", "usd_micros") }
    cost_state, cost_reason = if count.zero?
      ["not_applicable", nil]
    elsif amounts.empty?
      ["unavailable", is_claude ? "runtime_cost_missing" : "source_does_not_report_cost"]
    elsif amounts.length < count
      ["partial", "runtime_cost_missing"]
    else
      ["complete", nil]
    end
    source = if %w[complete partial].include?(state)
      is_claude ? "claude_code_otel_api_request_v1" : "codex_otel_response_completed_v1"
    end
    reason ||= {"unavailable" => "collector_unavailable", "disabled" => "usage_telemetry_disabled"}[state]
    store(run, "usage.json", {
      "schema_version" => 1, "run_id" => run,
      "collection" => {"state" => state, "source_interface" => source, "client_version" => nil, "finalized_at" => FINISHED, "reason" => reason, "warnings" => warnings},
      "measurements" => measurements.each_with_index.map { |item, index| item.merge("sequence" => index + 1) },
      "provider_sessions" => count.zero? ? [] : ["shared-session"],
      "observed_totals" => numeric.merge("measurement_count" => count),
      "cost_summary" => {"state" => cost_state, "reason" => cost_reason, "observed_usd_micros" => (amounts.sum unless amounts.empty?),
                         "semantics" => ("runtime_estimated" unless amounts.empty?), "currency" => ("USD" unless amounts.empty?),
                         "measurement_count" => count, "priced_measurement_count" => amounts.length}
    })
  end

  def pull(number, lifecycle: "open", created: FIRST, merged: nil, observed: FINISHED, reviews: [], post: nil, repository: REPOSITORY)
    identity = {"repository" => repository, "number" => number}
    current = %w[draft head_repository head_ref head_sha base_repository base_ref base_sha updated_at closed_at merge_commit_sha].to_h { |key| [key, nil] }
    history = reviews.each_with_index.map do |sha, index|
      {"commit_id" => sha, "state" => "COMMENTED", "source_id" => "review-#{index}", "submitted_at" => FIRST, "dismissed_at" => nil,
       "reviewer_login" => nil, "reviewer_type" => nil, "source_kind" => "github_pull_review", "first_observed_at" => observed, "last_observed_at" => observed}
    end
    first = if reviews.empty?
      "not_applicable"
    else
      reviews.first ? "available" : "unavailable"
    end
    {
      "identity" => identity.merge("node_id" => nil),
      "association" => identity.merge("first_observed_at" => observed, "last_observed_at" => observed,
        "established_by" => ["unique_head_branch"], "supporting_evidence" => []),
      "current" => current.merge("lifecycle" => lifecycle, "created_at" => created, "merged_at" => merged, "observed_at" => observed),
      "head_history" => [], "commits" => [], "timeline_events" => [], "reviews" => history, "checks_by_sha" => [],
      "derived" => {"reviewed_revision_count" => reviews.compact.uniq.length, "first_reviewed_revision" => {"state" => first, "sha" => reviews.first},
                    "post_first_review_change_observed" => post || ((first == "available") ? "yes" : first), "merged_on_first_reviewed_revision" => "not_applicable"}
    }
  end

  def add_outcome(run, *pulls, at: FINISHED, state: "complete", correlation: "matched", candidates: [])
    store(run, "outcome.json", {
      "schema_version" => 1, "source_run_schema_version" => 1, "run_id" => run,
      "reconciliation" => {"last_attempted_at" => at, "last_successful_at" => at, "attempt_count" => 1, "observation_state" => state,
                           "automatic_state" => "quiescent", "next_eligible_at" => nil, "last_error" => nil},
      "correlation" => {"state" => correlation, "associations" => pulls.map { |pull| pull.fetch("association") }, "candidates" => candidates},
      "pull_requests" => pulls
    })
  end
end
