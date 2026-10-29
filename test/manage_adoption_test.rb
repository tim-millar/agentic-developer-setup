# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "agentic_developer_setup/adoption/manage_cli"

class ManageAdoptionTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  CLI = File.join(ROOT, "scripts/manage_adoption.rb")
  T = AgenticDeveloperSetup::Adoption::TransactionSupport
  A = AgenticDeveloperSetup::Adoption
  CONFIG = "issue_template_config"
  REVIEW = "review_policy"

  def setup
    @tmp = Dir.mktmpdir("manage-adoption-")
    @source = File.join(@tmp, "source")
    @target = File.join(@tmp, "target")
    FileUtils.mkdir_p([@source, @target])
    FileUtils.cp(File.join(ROOT, "framework.yml"), @source)
    FileUtils.cp_r(File.join(ROOT, "baseline"), @source)
    FileUtils.mkdir_p(File.join(@source, "schemas"))
    FileUtils.cp(File.join(ROOT, "schemas/framework-adoption-v1.schema.json"), File.join(@source, "schemas"))
    init_git(@source)
    File.write(File.join(@target, "README.md"), "Native application\n")
    File.write(File.join(@target, "Makefile"), "verify:\n\t@echo native-check\n")
    FileUtils.mkdir_p(File.join(@target, "apps/storefront"))
    File.write(File.join(@target, "apps/storefront/.keep"), "workspace\n")
    init_git(@target)
    @plan = File.join(@tmp, "plan.yml")
    @decisions = File.join(@tmp, "decisions.yml")
    @result = File.join(@tmp, "application-result.yml")
    @validation_result = File.join(@tmp, "validation-result.yml")
  end

  def teardown
    FileUtils.remove_entry_secure(@tmp)
  end

  def test_initial_adoption_full_lifecycle_preserves_native_equivalent_and_specialised_bytes
    reviewed = File.join(@tmp, "reviewed.md")
    File.write(reviewed, "Reviewed local operating constraints\n")
    native = File.binread(File.join(@target, "Makefile"))
    decisions = [inherited, {"id" => "agent_instructions", "disposition" => "specialised", "content_path" => reviewed, "local_ownership" => ["native rules"], "reviewed" => true},
      {"id" => "command_interface", "disposition" => "repository_owned", "equivalent" => {"paths" => ["Makefile"], "commands" => ["make verify"]}, "rationale" => "Native commands remain authoritative."},
      {"id" => REVIEW, "disposition" => "deferred", "rationale" => "Later."},
      {"id" => "domain_context", "disposition" => "declined", "rationale" => "Outside scope."}]
    validation = validation_spec([{"id" => "verify", "argv" => ["make", "verify"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for(decisions, extra: ["--validation-spec", validation])
    initial = tree(@target)
    output = cli("preview", @plan)
    assert_includes output, "--- a/.agent-framework/adoption.yml"
    assert_includes output, "Manual specialisation attestation"
    cli("check", @plan)
    cli("apply", @plan, "--dry-run")
    assert_equal initial, tree(@target)
    refute File.exist?(@result)
    apply(plan)
    assert_equal "applied_unvalidated", read(@result)["status"]
    assert_equal native, File.binread(File.join(@target, "Makefile"))
    assert_equal File.binread(reviewed), File.binread(File.join(@target, "AGENTS.md"))
    metadata = read(File.join(@target, A::METADATA_PATH))
    assert_equal 1, metadata["schema_version"]
    assert_equal git(@source, "rev-parse", "HEAD").strip, metadata.dig("framework", "revision")
    config = metadata["components"].find { |item| item["id"] == CONFIG }
    assert_equal T.digest(File.binread(File.join(@source, config["source_path"]))), config["adopted_source_digest"]
    assert_equal decisions.map { |item| item["id"] }.sort, metadata["components"].map { |item| item["id"] }.sort
    result_digest = T.digest(File.binread(@result))
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result)
    result = read(@validation_result)
    assert_equal "passed", result["status"]
    assert_includes result.dig("commands", 0, "stdout"), "native-check"
    assert_equal result_digest, T.digest(File.binread(@result))
  end

  def test_workspace_mapping_and_canonical_metadata_location
    plan = plan_for([inherited], scope: "apps/storefront")
    apply(plan)
    record = read(File.join(@target, A::METADATA_PATH))["components"].first
    assert_equal "apps/storefront/.github/ISSUE_TEMPLATE/config.yml", record["target_path"]
    assert File.file?(File.join(@target, record["target_path"]))
    refute File.exist?(File.join(@target, "apps/storefront", A::METADATA_PATH))
  end

  def test_tiers_are_cumulative_and_exclusions_follow_expansion
    catalogue = read(File.join(@source, "framework.yml"))
    ids = catalogue["baseline"].values_at("required", "recommended").flatten.to_h { |item| [item["target_path"], item["name"]] }
    expected = catalogue["adoption_tiers"].first(2).flat_map { |tier| tier["includes"].map { |path| ids.fetch(path) } }.uniq.sort
    excluded = expected.last
    decisions = (expected - [excluded]).map { |id| {"id" => id, "disposition" => "deferred", "rationale" => "Explicit tier decision."} }
    plan = plan_for(decisions, tier: "tier-2", exclusions: [excluded])
    assert_equal expected - [excluded], plan.dig("selection", "resolved_components")
    assert_empty plan.dig("selection", "requested_components")
    apply(plan)
    assert_equal decisions.length, read(File.join(@target, A::METADATA_PATH))["components"].length
  end

  def test_add_components_preserves_existing_records_and_provenance
    adopt_and_commit
    old = read(File.join(@target, A::METADATA_PATH))["components"].first
    plan = plan_for([{"id" => REVIEW, "disposition" => "inherited"}], operation: "add_components")
    apply(plan)
    assert_equal old, read(File.join(@target, A::METADATA_PATH))["components"].find { |item| item["id"] == CONFIG }
  end

  def test_add_rejects_existing_active_and_inactive_records
    ["inherited", "deferred"].each do |disposition|
      decisions = [{"id" => CONFIG, "disposition" => disposition}]
      decisions.first["rationale"] = "Later" if disposition == "deferred"
      plan = plan_for(decisions)
      apply(plan)
      commit(@target)
      plan_for([inherited], operation: "add_components", expected: 4)
      assert_includes read(@plan)["diagnostics"].map { |d| d["code"] }, "ownership_conflict"
      cli("apply", @plan, "--dry-run", expected: 4)
      reset_target
    end
  end

  def test_add_and_reconcile_require_framework_level_revision
    adopt_and_commit
    File.write(File.join(@source, "extra"), "another revision")
    commit(@source)
    plan_for([{"id" => REVIEW, "disposition" => "inherited"}], operation: "add_components", expected: 4)
  end

  def test_safe_update_advances_selected_and_framework_provenance_only
    adopt_and_commit([inherited, {"id" => REVIEW, "disposition" => "inherited"}])
    before = read(File.join(@target, A::METADATA_PATH))
    change_source(CONFIG, "candidate bytes\n", executable: true)
    plan = plan_for([update_decision], operation: "update_inherited", date: "2026-10-30")
    cli("preview", @plan)
    cli("check", @plan)
    apply(plan)
    after = read(File.join(@target, A::METADATA_PATH))
    assert_equal before["components"].find { |r| r["id"] == REVIEW }, after["components"].find { |r| r["id"] == REVIEW }
    assert_equal before.dig("framework", "adopted_at"), after.dig("framework", "adopted_at")
    assert_equal "2026-10-30", after.dig("framework", "updated_at")
    assert_equal git(@source, "rev-parse", "HEAD").strip, after.dig("framework", "revision")
    record = after["components"].find { |r| r["id"] == CONFIG }
    assert_equal "candidate bytes\n", File.binread(File.join(@target, record["target_path"]))
    assert_equal "0755", T.mode(Pathname.new(@target).join(record["target_path"]))
    assert_equal after.dig("framework", "revision"), record["adopted_revision"]
  end

  def test_equal_candidate_bytes_preserve_provenance_and_do_not_perform_mode_only_update
    adopt_and_commit
    old_metadata = File.binread(File.join(@target, A::METADATA_PATH))
    source_path = source_path(CONFIG)
    File.chmod(0o755, source_path)
    commit(@source)
    plan = plan_for([update_decision], operation: "update_inherited")
    assert_equal "no_change", plan.dig("actions", 0, "action")
    assert_includes plan["diagnostics"].map { |d| d["code"] }, "mode_change_requires_review"
    apply(plan)
    assert_equal "no_changes", read(@result)["status"]
    assert_equal old_metadata, File.binread(File.join(@target, A::METADATA_PATH))
    assert_equal "0644", T.mode(Pathname.new(target_path(CONFIG)))
  end

  def test_path_movement_blocks_changed_bytes_but_equal_bytes_are_no_change
    adopt_and_commit
    old = source_path(CONFIG)
    catalogue = read(File.join(@source, "framework.yml"))
    entry = catalogue["baseline"]["required"].find { |r| r["name"] == CONFIG } || catalogue["baseline"]["recommended"].find { |r| r["name"] == CONFIG }
    moved = File.join(@source, "baseline/moved.yml")
    FileUtils.mv(old, moved)
    entry["source_path"] = "baseline/moved.yml"
    entry["target_path"] = "moved.yml"
    File.write(File.join(@source, "framework.yml"), YAML.dump(catalogue))
    commit(@source)
    plan = plan_for([update_decision], operation: "update_inherited")
    assert_equal "no_change", plan.dig("actions", 0, "action")
    File.write(moved, "different\n")
    commit(@source)
    plan_for([update_decision], operation: "update_inherited", expected: 4)
    assert_includes read(@plan)["diagnostics"].map { |d| d["code"] }, "path_migration_unsupported"
  end

  def test_committed_local_modification_can_be_reconciled_without_content_or_provenance_changes
    adopt_and_commit
    path = target_path(CONFIG)
    File.write(path, "committed local constraints\n")
    commit(@target)
    old = read(File.join(@target, A::METADATA_PATH))["components"].first
    plan = plan_for([{"id" => CONFIG, "disposition" => "convert_to_specialised", "local_ownership" => ["local policy"], "rationale" => "Committed specialisation."}], operation: "reconcile_inherited")
    apply(plan)
    record = read(File.join(@target, A::METADATA_PATH))["components"].first
    assert_equal old.merge("ownership" => "specialised", "update_policy" => "manual_merge", "local_ownership" => ["local policy"]), record
    assert_equal "committed local constraints\n", File.binread(path)
    assert_equal "convert_to_specialised", read(@result).dig("actions", 0, "action")
  end

  def test_unrelated_inherited_mismatch_blocks_reconciliation
    adopt_and_commit([inherited, {"id" => REVIEW, "disposition" => "inherited"}])
    [CONFIG, REVIEW].each { |id| File.write(target_path(id), "local #{id}\n") }
    commit(@target)
    plan_for([{"id" => CONFIG, "disposition" => "convert_to_specialised", "local_ownership" => ["local policy"], "rationale" => "Reason."}], operation: "reconcile_inherited", expected: 4)
  end

  def test_reconciliation_requires_real_mismatch_and_ownership_declaration
    adopt_and_commit
    decision = {"id" => CONFIG, "disposition" => "convert_to_specialised", "local_ownership" => ["local policy"], "rationale" => "Reason."}
    plan_for([decision], operation: "reconcile_inherited", expected: 4)
    decision.delete("local_ownership")
    plan_for([decision], operation: "reconcile_inherited", expected: 2)
  end

  def test_plan_id_is_deterministic_and_ignores_timestamp_and_map_key_order
    plan = plan_for([inherited])
    duplicate = plan_for([inherited])
    assert_equal plan["plan_id"], duplicate["plan_id"]
    duplicate["created_at"] = "2026-01-01T01:01:01Z"
    assert_equal plan["plan_id"], T.plan_id(duplicate)
    reversed = duplicate.to_a.reverse.to_h
    assert_equal plan["plan_id"], T.plan_id(reversed)
    duplicate["effective_date"] = "2026-10-30"
    refute_equal plan["plan_id"], T.plan_id(duplicate)
  end

  def test_tampered_plan_and_rehashed_undeclared_effects_are_rejected
    plan = plan_for([inherited])
    plan["actions"][0]["rationale"] = "tampered"
    File.write(@plan, YAML.dump(plan))
    cli("check", @plan, expected: 4)
    plan["plan_id"] = T.plan_id(plan)
    plan["actions"][0]["target_file"]["path"] = "unapproved.yml"
    plan["plan_id"] = T.plan_id(plan)
    File.write(@plan, YAML.dump(plan))
    cli("apply", @plan, "--dry-run", expected: 2)
    refute File.exist?(File.join(@target, "unapproved.yml"))
  end

  def test_unknown_fields_duplicate_ids_and_invalid_decision_combinations_fail_without_plan
    [[inherited.merge("extra" => true)], [inherited, inherited], [inherited.merge("reviewed" => true)], [{"id" => "unknown_component", "disposition" => "inherited"}]].each do |decisions|
      FileUtils.rm_f(@plan)
      plan_for(decisions, expected: 2)
      refute File.exist?(@plan)
    end
  end

  def test_unselected_decisions_and_conflicting_exclusions_are_rejected
    write_decisions([inherited, {"id" => REVIEW, "disposition" => "deferred", "rationale" => "Later."}])
    cli("plan", @target, "--operation", "initial_adoption", "--framework-source", @source, "--scope", ".", "--component", CONFIG, "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", @plan, expected: 2)
    plan_for([inherited], exclusions: [CONFIG], expected: 2)
  end

  def test_dirty_source_and_target_staged_and_untracked_are_refused
    [@source, @target].each do |root|
      File.write(File.join(root, "untracked"), "x")
      plan_for([inherited], expected: 3)
      git(root, "add", "untracked")
      plan_for([inherited], expected: 3)
      commit(root)
    end
  end

  def test_existing_unowned_and_ignored_file_collisions_are_blockers
    target = File.join(@target, ".github/ISSUE_TEMPLATE/config.yml")
    FileUtils.mkdir_p(File.dirname(target))
    File.write(target, "native\n")
    File.write(File.join(@target, ".gitignore"), ".github/\n")
    commit(@target)
    plan_for([inherited], expected: 4)
    assert_equal "native\n", File.binread(target)
    cli("preview", @plan, expected: 4)
  end

  def test_stale_inputs_and_heads_refuse_before_mutation
    mutations = [
      -> { File.write(@decisions, File.binread(@decisions) + "\n") },
      -> { File.write(source_path(CONFIG), "changed\n") },
      -> { File.write(File.join(@target, "README.md"), "changed\n") },
      -> { git(@target, "commit", "--allow-empty", "-qm", "new HEAD") },
      -> { git(@source, "commit", "--allow-empty", "-qm", "new HEAD") }
    ]
    mutations.each_with_index do |mutation, index|
      plan = plan_for([inherited])
      before = File.binread(File.join(@target, "README.md"))
      mutation.call
      cli("apply", @plan, "--accept-plan-id", plan["plan_id"], "--result", File.join(@tmp, "refused-#{index}.yml"), expected: [3, 4])
      refute File.exist?(File.join(@target, A::METADATA_PATH))
      assert_equal before, File.binread(File.join(@target, "README.md")) unless index == 2
      git(@source, "reset", "--hard", "-q")
      git(@target, "reset", "--hard", "-q")
    end
  end

  def test_symlink_parent_final_dangling_and_directory_conflicts_are_rejected
    path = File.join(@target, ".github")
    outside = File.join(@tmp, "outside")
    FileUtils.mkdir_p(outside)
    [outside, File.join(@tmp, "dangling")].each do |destination|
      File.symlink(destination, path)
      git(@target, "add", ".github")
      commit(@target)
      plan_for([inherited], expected: 4)
      git(@target, "rm", "-q", ".github")
      commit(@target)
    end
    FileUtils.mkdir_p(File.join(path, "ISSUE_TEMPLATE/config.yml"))
    File.write(File.join(path, "ISSUE_TEMPLATE/config.yml/.keep"), "x")
    commit(@target)
    plan_for([inherited], expected: 4)
  end

  def test_external_output_and_input_aliases_into_protected_worktrees_are_refused
    plan_for([inherited])
    cli("plan", @target, "--operation", "initial_adoption", "--framework-source", @source, "--scope", ".", "--component", CONFIG, "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", File.join(@target, "plan.yml"), expected: 2)
    link = File.join(@tmp, "alias.yml")
    File.symlink(File.join(@target, "README.md"), link)
    cli("apply", @plan, "--accept-plan-id", read(@plan)["plan_id"], "--result", link, expected: 2)
    cli("apply", @plan, "--accept-plan-id", read(@plan)["plan_id"], "--result", @plan, expected: 4)
  end

  def test_wrong_approval_writes_refused_evidence_without_target_changes
    plan_for([inherited])
    before = tree(@target)
    cli("apply", @plan, "--accept-plan-id", "sha256:#{"f" * 64}", "--result", @result, expected: 4)
    assert_equal "refused", read(@result)["status"]
    assert_equal false, read(@result).dig("recovery", "mutation_occurred")
    assert_equal before, tree(@target)
  end

  def test_partial_failure_and_metadata_failure_leave_exact_evidence_and_never_roll_back
    plan = plan_for([inherited, {"id" => REVIEW, "disposition" => "inherited"}])
    hook = ->(event, action) { raise Errno::EIO, "injected" if event == :before_file && action["component_id"] == REVIEW }
    validator = A::PlanValidator.new(plan)
    result, code = A::Application.new(validator, hook: hook).apply(accept_plan_id: plan["plan_id"], result: @result, plan_path: @plan)
    assert_equal 5, code
    assert_equal "partially_applied", result["status"]
    assert_equal %w[completed failed], result["actions"].map { |action| action["state"] }
    assert File.file?(File.join(@target, ".github/ISSUE_TEMPLATE/config.yml"))
    refute File.exist?(File.join(@target, A::METADATA_PATH))
    assert_equal result, read(@result)
  end

  def test_metadata_last_failure_and_progress_journal
    plan = plan_for([inherited])
    hook = lambda do |event, _action|
      if event == :before_metadata
        progress = read(@result)
        assert_equal "in_progress", progress["status"]
        assert_equal "completed", progress.dig("actions", 0, "state")
        refute File.exist?(File.join(@target, A::METADATA_PATH))
        raise Errno::EIO, "injected metadata failure"
      end
    end
    result, code = A::Application.new(A::PlanValidator.new(plan), hook: hook).apply(accept_plan_id: plan["plan_id"], result: @result, plan_path: @plan)
    assert_equal 5, code
    assert_equal "partially_applied", result["status"]
    assert_equal false, result.dig("metadata", "written")
    assert File.file?(File.join(@target, ".github/ISSUE_TEMPLATE/config.yml"))
  end

  def test_failure_before_first_mutation_is_refused
    plan = plan_for([inherited])
    before = tree(@target)
    hook = ->(event, _action) { raise Errno::EIO, "injected" if event == :before_file }
    result, code = A::Application.new(A::PlanValidator.new(plan), hook: hook).apply(accept_plan_id: plan["plan_id"], result: @result, plan_path: @plan)
    assert_equal 5, code
    assert_equal "refused", result["status"]
    assert_equal before, tree(@target)
  end

  def test_reapplication_and_existing_result_overwrite_are_refused
    plan = plan_for([inherited])
    apply(plan)
    before = tree(@target)
    cli("apply", @plan, "--accept-plan-id", plan["plan_id"], "--result", @result, expected: 4)
    cli("apply", @plan, "--accept-plan-id", plan["plan_id"], "--result", File.join(@tmp, "another-result.yml"), expected: 3)
    assert_equal before, tree(@target)
  end

  def test_validation_no_commands_skips_and_does_not_change_application_evidence
    plan = plan_for([inherited])
    apply(plan)
    raw = File.binread(@result)
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 4)
    assert_equal "skipped", read(@validation_result)["status"]
    assert_equal raw, File.binread(@result)
  end

  def test_validation_order_environment_cwd_direct_exec_and_output_limits
    code = 'require "json"; puts JSON.generate([Dir.pwd, ENV["APPROVED"], ENV["SESSION_TOKEN"]]); STDOUT.write("x" * 70000); STDERR.write("y" * 70000)'
    spec = validation_spec([
      {"id" => "first", "argv" => [RbConfig.ruby, "-e", code, "$(touch forbidden)"], "cwd" => "scope", "env" => {"APPROVED" => "yes"}, "expected_exit_code" => 0},
      {"id" => "second", "argv" => [RbConfig.ruby, "-e", "puts ARGV[0]", "$(touch forbidden)"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}
    ])
    plan = plan_for([inherited], scope: "apps/storefront", extra: ["--validation-spec", spec])
    apply(plan)
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, env: {"SESSION_TOKEN" => "must-not-forward"})
    result = read(@validation_result)
    assert_equal %w[first second], result["commands"].map { |c| c["id"] }
    assert_includes result.dig("commands", 0, "stdout"), '"yes",null'
    assert_equal File.realpath(File.join(@target, "apps/storefront")), result.dig("commands", 0, "cwd")
    assert_equal true, result.dig("commands", 0, "stdout_truncated")
    assert_equal true, result.dig("commands", 0, "stderr_truncated")
    assert_equal 65_536, result.dig("commands", 0, "stderr").bytesize
    assert_equal "$(touch forbidden)\n", result.dig("commands", 1, "stdout")
    refute File.exist?(File.join(@target, "forbidden"))
  end

  def test_failed_and_unavailable_validation_stop_command_sequence
    [["-e", "exit 7"], nil].each_with_index do |args, index|
      argv = args ? [RbConfig.ruby, *args] : ["/nonexistent/ads-command"]
      spec = validation_spec([
        {"id" => "first", "argv" => argv, "cwd" => "repository", "env" => {}, "expected_exit_code" => 0},
        {"id" => "never", "argv" => [RbConfig.ruby, "-e", "abort"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}
      ])
      plan = plan_for([inherited], extra: ["--validation-spec", spec])
      apply(plan)
      cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 6)
      assert_equal index.zero? ? "failed" : "unavailable", read(@validation_result)["status"]
      assert_equal 1, read(@validation_result)["commands"].length
      reset_target
    end
  end

  def test_validation_reports_unexpected_repository_mutation
    spec = validation_spec([{"id" => "mutate", "argv" => [RbConfig.ruby, "-e", 'File.write("unexpected", "x")'], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for([inherited], extra: ["--validation-spec", spec])
    apply(plan)
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 6)
    assert_equal "failed", read(@validation_result)["status"]
  end

  def test_validation_spec_rejects_secret_fields_duplicate_commands_and_invalid_exit_codes
    [{"MY_TOKEN" => "hidden"}, {"PASSWORD" => "hidden"}, {"PRIVATE_KEY_PATH" => "hidden"}].each do |env|
      spec = validation_spec([{"id" => "verify", "argv" => ["true"], "cwd" => "repository", "env" => env, "expected_exit_code" => 0}])
      plan_for([inherited], extra: ["--validation-spec", spec], expected: 2)
    end
    spec = validation_spec([{"id" => "verify", "argv" => ["true"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 256}])
    plan_for([inherited], extra: ["--validation-spec", spec], expected: 2)
  end

  def test_plan_and_apply_never_execute_repository_commands
    File.write(File.join(@target, "Makefile"), "verify:\n\t@touch executed\n")
    commit(@target)
    spec = validation_spec([{"id" => "verify", "argv" => ["make", "verify"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for([inherited], extra: ["--validation-spec", spec])
    cli("preview", @plan)
    cli("check", @plan)
    apply(plan)
    refute File.exist?(File.join(@target, "executed"))
  end

  def test_sanitised_git_identity_rejects_parent_leakage_and_ignores_ambient_git_config
    plan_for([inherited], env: {"GIT_DIR" => File.join(@target, ".git"), "GIT_WORK_TREE" => @target, "GIT_CONFIG_COUNT" => "1", "GIT_CONFIG_KEY_0" => "core.bare", "GIT_CONFIG_VALUE_0" => "true"})
    nested = File.join(@source, "nested")
    FileUtils.mkdir_p(nested)
    cli("plan", nested, "--operation", "initial_adoption", "--framework-source", @target, "--scope", ".", "--component", CONFIG, "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", @plan, expected: 3)
  end

  def test_update_refuses_pinned_specialised_repository_owned_missing_and_locally_modified_targets
    variants = [:pinned, :specialised, :repository_owned, :missing, :modified]
    variants.each do |variant|
      adopt_and_commit
      path = target_path(CONFIG)
      document = read(File.join(@target, A::METADATA_PATH))
      record = document["components"].first
      case variant
      when :pinned
        record["update_policy"] = "pinned"
        record["rationale"] = "Pinned explicitly."
      when :specialised
        record.merge!("ownership" => "specialised", "update_policy" => "manual_merge", "local_ownership" => ["local policy"])
      when :repository_owned
        document["components"] = [{"id" => CONFIG, "status" => "active", "ownership" => "repository_owned", "update_policy" => "repository_managed", "equivalent" => {"paths" => ["README.md"]}, "rationale" => "Native equivalent."}]
      when :missing
        File.unlink(path)
      when :modified
        File.write(path, "committed local modification")
      end
      File.write(File.join(@target, A::METADATA_PATH), YAML.dump(document))
      commit(@target)
      change_source(CONFIG, "candidate #{variant}\n")
      before = tree(@target)
      plan_for([update_decision], operation: "update_inherited", expected: 4)
      cli("check", @plan, expected: 4)
      assert_equal before, tree(@target)
      reset_target
    end
  end

  def test_multiple_updates_and_source_version_labels_do_not_imply_chronology
    adopt_and_commit([inherited, {"id" => REVIEW, "disposition" => "inherited"}])
    [CONFIG, REVIEW].each { |id| File.write(source_path(id), "changed #{id}\n") }
    catalogue = read(File.join(@source, "framework.yml"))
    catalogue["framework"]["framework_version"] = "0.0.1"
    File.write(File.join(@source, "framework.yml"), YAML.dump(catalogue))
    commit(@source)
    plan = plan_for([update_decision, {"id" => REVIEW, "disposition" => "update_inherited"}], operation: "update_inherited")
    apply(plan)
    document = read(File.join(@target, A::METADATA_PATH))
    assert_equal "0.0.1", document.dig("framework", "version")
    assert_equal [git(@source, "rev-parse", "HEAD").strip], document["components"].map { |record| record["adopted_revision"] }.uniq
  end

  def test_missing_candidate_source_produces_inspectable_blocked_plan
    adopt_and_commit
    File.unlink(source_path(CONFIG))
    commit(@source)
    plan = plan_for([update_decision], operation: "update_inherited", expected: 4)
    assert_includes plan["diagnostics"].map { |d| d["code"] }, "source_unavailable"
    cli("preview", @plan, expected: 4)
    cli("apply", @plan, "--dry-run", expected: 4)
  end

  def test_reviewed_content_and_metadata_changes_stale_a_plan
    content = File.join(@tmp, "reviewed.md")
    File.write(content, "reviewed\n")
    decision = {"id" => "agent_instructions", "disposition" => "specialised", "content_path" => content, "local_ownership" => ["local"], "reviewed" => true}
    plan_for([decision])
    File.write(content, "different\n")
    cli("check", @plan, expected: 4)
    File.write(content, "reviewed\n")
    adopt_and_commit
    plan_for([{"id" => REVIEW, "disposition" => "inherited"}], operation: "add_components")
    path = File.join(@target, A::METADATA_PATH)
    File.write(path, File.binread(path) + "\n")
    commit(@target)
    cli("check", @plan, expected: 4)
  end

  def test_source_symlinks_ignored_sources_and_git_mode_mismatch_are_refused
    original = File.binread(source_path(CONFIG))
    File.unlink(source_path(CONFIG))
    File.symlink(File.join(@target, "README.md"), source_path(CONFIG))
    commit(@source)
    plan_for([inherited], expected: 4)
    File.unlink(source_path(CONFIG))
    File.write(source_path(CONFIG), original)
    commit(@source)
    git(@source, "config", "core.filemode", "false")
    File.chmod(0o755, source_path(CONFIG))
    plan_for([inherited], expected: 4)
    File.chmod(0o644, source_path(CONFIG))
    git(@source, "rm", "--cached", source_path(CONFIG))
    File.write(File.join(@source, ".gitignore"), "baseline/.github/ISSUE_TEMPLATE/config.yml\n")
    commit(@source)
    plan_for([inherited], expected: 4)
  end

  def test_scope_traversal_and_nested_worktree_are_rejected
    ["../escape", "apps/../escape", "apps//storefront", "apps/storefront/", ".git", "apps\\storefront"].each do |scope|
      plan_for([inherited], scope: scope, expected: 4)
    end
    nested = File.join(@target, ".github")
    FileUtils.mkdir_p(nested)
    File.write(File.join(nested, "keep"), "nested")
    init_git(nested)
    File.write(File.join(@target, ".gitignore"), ".github/\n")
    commit(@target)
    plan_for([inherited], expected: 4)
  end

  def test_case_folding_and_special_file_collisions
    FileUtils.mkdir_p(File.join(@target, ".GITHUB"))
    File.write(File.join(@target, ".GITHUB/keep"), "existing")
    commit(@target)
    plan_for([inherited], expected: 4)
    reset_target
    FileUtils.mkdir_p(File.join(@target, ".github/ISSUE_TEMPLATE"))
    fifo = File.join(@target, ".github/ISSUE_TEMPLATE/config.yml")
    File.mkfifo(fifo)
    File.write(File.join(@target, ".gitignore"), ".github/\n")
    commit(@target)
    plan_for([inherited], expected: 4)
  end

  def test_target_mode_precondition_remains_authoritative_when_git_ignores_mode_changes
    adopt_and_commit
    git(@target, "config", "core.filemode", "false")
    change_source(CONFIG, "candidate\n")
    plan_for([update_decision], operation: "update_inherited")
    File.chmod(0o755, target_path(CONFIG))
    cli("check", @plan, expected: 4)
  end

  def test_duplicate_target_ownership_blocks_addition
    adopt_and_commit([inherited, {"id" => REVIEW, "disposition" => "inherited"}])
    path = File.join(@target, A::METADATA_PATH)
    document = read(path)
    document["components"].last["target_path"] = document["components"].first["target_path"]
    File.write(path, YAML.dump(document))
    commit(@target)
    plan_for([{"id" => "agent_instructions", "disposition" => "deferred", "rationale" => "Later."}], operation: "add_components", expected: 4)
  end

  def test_unknown_plan_fields_and_duplicate_yaml_keys_are_rejected
    plan = plan_for([inherited])
    plan["source"]["unexpected"] = true
    plan["plan_id"] = T.plan_id(plan)
    File.write(@plan, YAML.dump(plan))
    cli("check", @plan, expected: 2)
    File.write(@decisions, "schema_version: 1\nschema_version: 1\ncomponents: []\n")
    cli("plan", @target, "--operation", "initial_adoption", "--framework-source", @source, "--scope", ".", "--component", CONFIG, "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", @plan, expected: 2)
  end

  def test_validation_rejects_unmatched_application_evidence_and_changed_spec
    spec = validation_spec([{"id" => "verify", "argv" => ["make", "verify"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for([inherited], extra: ["--validation-spec", spec])
    apply(plan)
    File.write(spec, File.binread(spec) + "\n")
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 4)
    result = read(@result)
    result["plan_id"] = "sha256:#{"f" * 64}"
    File.write(@result, YAML.dump(T.canonical(result)))
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 4)
  end

  def test_validation_detects_mutating_an_already_untracked_adopted_file
    spec = validation_spec([{"id" => "mutate", "argv" => [RbConfig.ruby, "-e", 'File.write(".github/ISSUE_TEMPLATE/config.yml", "tampered")'], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for([inherited], extra: ["--validation-spec", spec])
    apply(plan)
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 6)
    assert_equal "failed", read(@validation_result)["status"]
  end

  def test_application_records_post_install_verification_failure
    plan = plan_for([inherited])
    hook = lambda do |event, action|
      if event == :after_file
        File.write(File.join(@target, action["target_file"]["path"]), "corrupt")
      end
    end
    result, code = A::Application.new(A::PlanValidator.new(plan), hook: hook).apply(accept_plan_id: plan["plan_id"], result: @result, plan_path: @plan)
    assert_equal 5, code
    assert_equal "partially_applied", result["status"]
    refute result.dig("metadata", "written")
  end

  def test_public_demonstrations_run_offline_in_disposable_repositories
    %w[initial_adoption update_inherited].each do |name|
      out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/examples/#{name}.rb"))
      assert status.success?, "#{out}\n#{err}"
      assert_includes out, "PASS #{name}:"
    end
  end

  def test_explicit_update_operation_and_components_do_not_require_a_decision_file
    adopt_and_commit
    change_source(CONFIG, "candidate\n")
    cli("plan", @target, "--operation", "update_inherited", "--framework-source", @source, "--component", CONFIG, "--effective-date", "2026-10-29", "--output", @plan)
    plan = read(@plan)
    assert_nil plan.dig("inputs", "decisions")
    apply(plan)
    assert_equal "candidate\n", File.binread(target_path(CONFIG))
  end

  def test_plan_apply_leave_source_and_target_git_storage_unchanged_and_invoke_no_network_tools
    plan = plan_for([inherited])
    source_before = tree(@source)
    git_before = tree(File.join(@target, ".git"))
    guard = File.join(@tmp, "guard")
    FileUtils.mkdir_p(guard)
    forbidden = File.join(@tmp, "forbidden-command")
    %w[curl wget ssh gh node python python3].each do |name|
      File.write(File.join(guard, name), "#!/bin/sh\necho forbidden > '#{forbidden}'\nexit 90\n")
      File.chmod(0o755, File.join(guard, name))
    end
    env = {"PATH" => "#{guard}:#{ENV.fetch("PATH")}"}
    cli("preview", @plan, env: env)
    cli("check", @plan, env: env)
    cli("apply", @plan, "--dry-run", env: env)
    cli("apply", @plan, "--accept-plan-id", plan["plan_id"], "--result", @result, env: env)
    refute File.exist?(forbidden)
    assert_equal source_before, tree(@source)
    assert_equal git_before, tree(File.join(@target, ".git"))
  end

  def test_blocked_specialisation_never_overwrites_its_reviewed_input_with_plan_output
    content = File.join(@tmp, "reviewed.md")
    File.write(content, "reviewed bytes remain intact\n")
    decision = {"id" => "agent_instructions", "disposition" => "specialised", "content_path" => content, "local_ownership" => ["local"], "reviewed" => true}
    File.write(File.join(@target, "AGENTS.md"), "existing native file\n")
    commit(@target)
    write_decisions([decision])
    cli("plan", @target, "--operation", "initial_adoption", "--framework-source", @source, "--scope", ".", "--component", "agent_instructions", "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", content, expected: 4)
    assert_equal "reviewed bytes remain intact\n", File.binread(content)
    File.unlink(source_path("agent_instructions"))
    commit(@source)
    cli("plan", @target, "--operation", "initial_adoption", "--framework-source", @source, "--scope", ".", "--component", "agent_instructions", "--decisions", @decisions, "--effective-date", "2026-10-29", "--output", content, expected: 4)
    assert_equal "reviewed bytes remain intact\n", File.binread(content)
  end

  def test_transactions_use_the_running_tools_metadata_schema_not_source_schema
    schema = File.join(@source, "schemas/framework-adoption-v1.schema.json")
    File.unlink(schema)
    commit(@source)
    plan = plan_for([inherited])
    apply(plan)
    reset_target
    external_schema = File.join(@tmp, "untrusted-schema")
    File.write(external_schema, "must never be read")
    File.symlink(external_schema, schema)
    commit(@source)
    plan = plan_for([inherited])
    apply(plan)
    assert_equal "applied_unvalidated", read(@result)["status"]
    assert_equal "must never be read", File.binread(external_schema)
  end

  def test_validation_retains_durable_evidence_when_project_command_breaks_git_inspection
    spec = validation_spec([{"id" => "break_git", "argv" => [RbConfig.ruby, "-e", 'File.rename(".git", ".git-moved")'], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}])
    plan = plan_for([inherited], extra: ["--validation-spec", spec])
    apply(plan)
    original_application = File.binread(@result)
    cli("validate", @plan, "--application-result", @result, "--output", @validation_result, expected: 6)
    result = read(@validation_result)
    assert_equal "failed", result["status"]
    assert_equal 0, result.dig("commands", 0, "actual_exit_code")
    assert_includes result["diagnostics"].map { |item| item["message"] }.join, "inspection unavailable"
    assert_equal original_application, File.binread(@result)
  end

  def test_uninitialised_submodule_gitlink_is_never_a_mutation_destination
    sha = git(@source, "rev-parse", "HEAD").strip
    git(@target, "update-index", "--add", "--cacheinfo", "160000,#{sha},.github")
    git(@target, "commit", "-qm", "Record uninitialised submodule")
    FileUtils.mkdir_p(File.join(@target, ".github"))
    assert_empty git(@target, "status", "--porcelain")
    plan = plan_for([inherited], expected: 4)
    assert_includes plan["diagnostics"].map { |item| item["code"] }, "unsafe_path"
    cli("apply", @plan, "--dry-run", expected: 4)
    refute File.exist?(File.join(@target, ".github/ISSUE_TEMPLATE/config.yml"))
  end

  def test_unselected_unsafe_catalogue_paths_invalidate_the_complete_catalogue
    catalogue = read(File.join(@source, "framework.yml"))
    record = catalogue["baseline"]["recommended"].find { |item| item["name"] == "domain_context" }
    record["source_path"] = "../outside.md"
    File.write(File.join(@source, "framework.yml"), YAML.dump(catalogue))
    commit(@source)
    output = plan_for([inherited], expected: 3)
    assert_nil output
  end

  private

  def read(path)
    YAML.safe_load(File.binread(path), permitted_classes: [], aliases: false)
  end

  def inherited
    {"id" => CONFIG, "disposition" => "inherited"}
  end

  def update_decision
    {"id" => CONFIG, "disposition" => "update_inherited"}
  end

  def init_git(root)
    git(root, "init", "-q")
    git(root, "config", "user.email", "public-test@example.invalid")
    git(root, "config", "user.name", "Public fixture")
    git(root, "config", "core.hooksPath", File::NULL)
    commit(root)
  end

  def git(root, *args)
    result = AgenticDeveloperSetup::GitCommand.capture(root, *args)
    assert result.success?, "git #{args.inspect}: #{result.stderr}"
    result.stdout
  end

  def commit(root)
    git(root, "add", "--all")
    git(root, "commit", "-qm", "fixture snapshot")
  end

  def cli(*args, expected: 0, env: {})
    out, err, status = Open3.capture3(env, RbConfig.ruby, CLI, *args)
    assert_includes Array(expected), status.exitstatus, "#{args.inspect}\n#{out}\n#{err}"
    out + err
  end

  def write_decisions(decisions)
    File.write(@decisions, YAML.dump({"schema_version" => 1, "components" => decisions}))
  end

  def plan_for(decisions, operation: "initial_adoption", scope: ".", date: "2026-10-29", tier: nil, exclusions: [], extra: [], expected: 0, env: {})
    write_decisions(decisions)
    args = ["plan", @target, "--operation", operation, "--framework-source", @source, "--scope", scope, "--decisions", @decisions, "--effective-date", date, "--output", @plan]
    if tier
      args += ["--tier", tier]
    else
      decisions.each { |decision| args += ["--component", decision["id"]] }
    end
    exclusions.each { |id| args += ["--exclude", id] }
    cli(*args, *extra, expected: expected, env: env)
    read(@plan) if File.file?(@plan)
  end

  def apply(plan)
    FileUtils.rm_f(@result)
    cli("apply", @plan, "--accept-plan-id", plan["plan_id"], "--result", @result)
  end

  def adopt_and_commit(decisions = [inherited])
    plan = plan_for(decisions)
    apply(plan)
    commit(@target)
  end

  def source_path(id)
    catalogue = read(File.join(@source, "framework.yml"))
    entry = catalogue["baseline"].values_at("required", "recommended").flatten.find { |item| item["name"] == id }
    File.join(@source, entry["source_path"])
  end

  def target_path(id)
    record = read(File.join(@target, A::METADATA_PATH))["components"].find { |item| item["id"] == id }
    File.join(@target, record["target_path"])
  end

  def change_source(id, bytes, executable: false)
    path = source_path(id)
    File.write(path, bytes)
    File.chmod(0o755, path) if executable
    commit(@source)
  end

  def validation_spec(commands)
    path = File.join(@tmp, "validation.yml")
    File.write(path, YAML.dump({"schema_version" => 1, "commands" => commands}))
    path
  end

  def tree(root)
    Dir.glob("**/*", File::FNM_DOTMATCH, base: root).reject { |path| path == "." || path == ".." }.sort.to_h do |path|
      full = File.join(root, path)
      [path, if File.directory?(full)
               "directory"
             else
               File.symlink?(full) ? File.readlink(full) : [File.binread(full), File.stat(full).mode]
             end]
    end
  end

  def reset_target
    FileUtils.rm_rf(@target)
    FileUtils.mkdir_p(@target)
    File.write(File.join(@target, "README.md"), "Native application\n")
    init_git(@target)
    FileUtils.rm_f([@result, @plan, @validation_result])
  end
end
