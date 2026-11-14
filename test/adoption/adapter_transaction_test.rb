# frozen_string_literal: true

require_relative "../adapters/support"
require_relative "../../lib/agentic_developer_setup/adoption/manage_cli"

class AdapterAdoptionTransactionTest < AdapterTest
  T = AgenticDeveloperSetup::Adoption::TransactionSupport
  AD = AgenticDeveloperSetup::Adoption

  def setup
    super
    FileUtils.cp_r(File.join(ROOT, "baseline"), @framework)
    FileUtils.cp_r(File.join(ROOT, "schemas"), @framework)
    register("ruby", contributions: {"commands" => [command]})
    write_target("README.md", "Synthetic public target\n")
    init_git(@framework)
    init_git(@target)
    @selection_path = File.join(@temporary, "selection.yml")
    @decisions_path = File.join(@temporary, "decisions.yml")
    @plan_path = File.join(@temporary, "plan.yml")
    @result_path = File.join(@temporary, "result.yml")
    @selection_document = selected(["ecosystem", "ruby"])
    @decisions_document = {"schema_version" => 1, "selection_reviewed" => true, "adapter_changes" => [], "commands" => [], "components" => [], "retained_files" => []}
    save_inputs
  end

  def init_git(root)
    git(root, "init", "-q")
    git(root, "config", "user.name", "Synthetic Test")
    git(root, "config", "user.email", "synthetic@example.invalid")
    commit(root)
  end

  def git(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, "-c", "core.hooksPath=/dev/null", *args)
    raise err unless status.success?
    out
  end

  def commit(root)
    git(root, "add", ".")
    git(root, "commit", "-qm", "Synthetic public fixture")
  end

  def save_inputs
    File.write(@selection_path, YAML.dump(@selection_document))
    File.write(@decisions_path, YAML.dump(@decisions_document))
  end

  def build(operation: "adopt_adapters", date: "2026-11-07", **extra)
    AD::Planner.new(target: @target, source: @framework, operation: operation, effective_date: date, scope: ".",
      adapter_selection: @selection_path, adapter_decisions: @decisions_path, **extra).write(@plan_path)
  end

  def apply_plan(plan, hook: nil)
    AD::Application.new(AD::PlanValidator.new(plan), hook: hook).apply(accept_plan_id: plan["plan_id"], result: @result_path, plan_path: @plan_path)
  end

  def adopted_metadata
    YAML.safe_load_file(File.join(@target, AD::METADATA_PATH))
  end

  def approve
    @decisions_document["commands"] = [{"command_id" => "ruby-test", "disposition" => "approve", "reviewed" => true, "rationale" => "Explicit synthetic approval."}]
    save_inputs
  end

  def file_decision(disposition = "create_specialised")
    reviewed = File.join(@temporary, "reviewed.md")
    File.write(reviewed, "Reviewed synthetic repository instructions\n")
    {"id" => "agent_instructions", "disposition" => disposition, "content_path" => reviewed, "local_ownership" => ["commands"], "reviewed" => true,
     "rationale" => "Reviewed synthetic command documentation.", "contribution_ids" => ["ruby-test"], "approved_command_ids" => ["ruby-test"]}
  end

  def test_metadata_only_complete_lifecycle_and_no_implicit_execution
    approve
    plan = build
    assert_equal 2, plan["schema_version"]
    assert_empty plan["actions"]
    assert_empty plan["validation_commands"]
    assert AD::PlanValidator.new(plan).check!
    preview, code = AD::Preview.new(AD::PlanValidator.new(plan)).render
    assert_equal 0, code
    assert_includes preview, "Complete metadata diff"
    assert_includes preview, "ruby-test"
    result, code = apply_plan(plan)
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    assert_empty result["actions"]
    assert result["metadata"]["verified"]
    assert_equal 2, adopted_metadata["schema_version"]
    assert_empty adopted_metadata["components"]
    assert_equal %w[bundle exec rspec], adopted_metadata.dig("adapters", "command_bindings", 0, "argv")
    output = File.join(@temporary, "validation.yml")
    evidence, code = AD::TransactionValidation.new(AD::PlanValidator.new(plan)).run(application_result: @result_path, output: output, plan_path: @plan_path)
    assert_equal "skipped", evidence["status"]
    assert_equal 2, evidence["schema_version"]
    assert_equal 4, code
  end

  def test_empty_binding_set_and_true_no_change_on_later_date
    plan = build
    apply_plan(plan)
    assert_empty adopted_metadata.dig("adapters", "command_bindings")
    commit(@target)
    File.unlink(@result_path)
    plan = build(operation: "update_adapters", date: "2026-11-08")
    refute AD::PlanValidator.new(plan).changed?
    result, code = apply_plan(plan)
    assert_equal 0, code
    assert_equal "no_changes", result["status"]
    assert_equal "2026-11-07", adopted_metadata.dig("adapters", "updated_at")
  end

  def test_reviewed_file_and_metadata_last_with_partial_failure_evidence
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    plan = build
    observed = []
    result, code = apply_plan(plan, hook: ->(event, _action) do
      observed << event
      raise IOError, "synthetic interruption" if event == :after_file
    end)
    assert_equal 5, code
    assert_equal "partially_applied", result["status"]
    assert result.dig("recovery", "mutation_occurred")
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
    assert File.file?(File.join(@target, "AGENTS.md"))
    refute_includes observed, :before_metadata
    assert_includes result.dig("recovery", "inspect_paths"), "AGENTS.md"
  end

  def test_reviewed_file_success_and_read_only_inspection
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    plan = build
    events = []
    result, code = apply_plan(plan, hook: ->(event, _) { events << event })
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    assert_operator events.index(:after_file), :<, events.index(:before_metadata)
    result = AD::Inspector.new(@target, framework_root: @framework).inspect(framework_source: @framework)
    assert_equal 2, result["schema_version"]
    assert_equal "in_sync", result.dig("adapters", "reviewed_files", 0, "local_state")
    assert_equal "unchanged", result.dig("adapters", "candidate", "selected", 0, "status")
    invalid = Marshal.load(Marshal.dump(adopted_metadata))
    invalid["adapters"]["reviewed_files"].first["source_adapter_provenance"].first["adapter_version"] = "0.9.0"
    assert AD::Validator.new(root: @target, framework_root: @framework).validate(invalid).any? { |item| item.code == "invalid_adapters" }
    File.write(File.join(@target, "AGENTS.md"), "Local change\n")
    result = AD::Inspector.new(@target, framework_root: @framework).inspect
    assert_equal "modified", result.dig("adapters", "reviewed_files", 0, "local_state")
  end

  def test_fabricated_projection_or_metadata_cannot_be_blessed_by_checksum
    approve
    plan = build
    plan["adapter_transaction"]["composition"]["approved_contributions"]["commands"] = []
    plan["plan_id"] = T.plan_id(plan)
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    plan = build
    plan["proposed_metadata"]["document"]["adapters"]["command_bindings"] = []
    plan["proposed_metadata"]["digest"] = T.digest(T.metadata_bytes(plan.dig("proposed_metadata", "document")))
    plan["plan_id"] = T.plan_id(plan)
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_selected_and_unselected_supported_sources_are_verified_before_execution
    register("docker", "runtime")
    install_provider("docker", construction: 'raise "must never construct drifted provider"')
    commit(@framework)
    provider = File.join(@framework, "adapters/runtimes/docker/adapter.rb")
    original = File.binread(provider)
    git(@framework, "update-index", "--assume-unchanged", provider)
    File.write(provider, original + "\n# hidden drift\n")
    error = assert_raises(AD::TransactionError) { build }
    assert_includes error.message, "bytes/mode"
    refute_includes error.message, "construction"
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_provider_drift_and_bound_input_changes_refuse_pre_mutation
    plan = build
    provider = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    File.write(provider, File.read(provider) + "\n# provider change without version bump\n")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    result, code = apply_plan(plan)
    assert_equal "refused", result["status"]
    assert_equal 3, code
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_explicit_approval_and_command_retirement
    approve
    apply_plan(build)
    commit(@target)
    @decisions_document["commands"] = []
    save_inputs
    assert_raises(AD::TransactionError) { build(operation: "update_adapters") }
    @decisions_document["commands"] = [{"command_id" => "ruby-test", "disposition" => "retire", "reviewed" => true, "rationale" => "Retire reviewed declaration."}]
    save_inputs
    plan = build(operation: "update_adapters")
    assert_empty plan.dig("proposed_metadata", "document", "adapters", "command_bindings")
  end

  def baseline_plan(operation:, id: "issue_template_config", disposition: "inherited")
    path = File.join(@temporary, "baseline-decisions.yml")
    File.write(path, YAML.dump({"schema_version" => 1, "components" => [{"id" => id, "disposition" => disposition}]}))
    AD::Planner.new(target: @target, source: @framework, operation: operation, effective_date: "2026-11-07", scope: ".",
      components: [id], decisions: (operation == "update_inherited") ? nil : path).build
  end

  def test_v1_migration_exact_component_preservation_and_baseline_v2_addition
    initial = baseline_plan(operation: "initial_adoption")
    assert_equal 1, initial["schema_version"]
    apply_plan(initial)
    commit(@target)
    original = adopted_metadata
    File.unlink(@result_path)
    plan = build(date: "2026-11-08")
    assert_equal original["components"], plan.dig("proposed_metadata", "document", "components")
    assert_equal original.dig("framework", "adopted_at"), plan.dig("proposed_metadata", "document", "framework", "adopted_at")
    apply_plan(plan)
    commit(@target)
    state = adopted_metadata["adapters"]
    File.unlink(@result_path)
    additional = baseline_plan(operation: "add_components", id: "review_policy")
    assert_equal 2, additional["schema_version"]
    assert_nil additional["adapter_transaction"]
    assert_equal state, additional.dig("proposed_metadata", "document", "adapters")
    result, code = apply_plan(additional)
    assert_equal 0, code
    assert_equal 2, result["schema_version"]
    assert_equal state, adopted_metadata["adapters"]
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(initial).check! }
  end

  def test_initial_migration_refuses_framework_revision_mismatch
    apply_plan(baseline_plan(operation: "initial_adoption"))
    commit(@target)
    File.write(File.join(@framework, "public-fixture.txt"), "New committed source
")
    commit(@framework)
    error = assert_raises(AD::TransactionError) { build }
    assert_equal "provenance_unavailable", error.code
    assert_equal 1, adopted_metadata["schema_version"]
  end

  def test_update_requires_exact_adapter_changes_and_historical_retention
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    apply_plan(build)
    commit(@target)
    old = adopted_metadata["adapters"]
    original_review = old["reviewed_files"].first
    @decisions_document["components"] = []
    mutate_manifest("ruby") { |manifest| manifest["version"] = "1.1.0" }
    commit(@framework)
    proposed = registry.fetch(category: "ecosystem", id: "ruby").to_h.slice("category", "id", "version", "manifest_digest", "provider_digest").merge("selection_source" => "explicit")
    save_inputs
    assert_raises(AD::TransactionError) { build(operation: "update_adapters") }
    @decisions_document["adapter_changes"] = [{"category" => "ecosystem", "previous" => old["selected"].first, "proposed" => proposed, "reviewed" => true, "rationale" => "Review synthetic new version."}]
    save_inputs
    assert_raises(AD::TransactionError) { build(operation: "update_adapters") }
    @decisions_document["retained_files"] = [{"component_id" => "agent_instructions", "reviewed" => true, "rationale" => "Keep historical reviewed text."}]
    save_inputs
    File.unlink(@result_path)
    plan = build(operation: "update_adapters", date: "2026-11-08")
    result, code = apply_plan(plan)
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    review = adopted_metadata.dig("adapters", "reviewed_files", 0)
    assert_equal "retained_after_adapter_change", review["review_state"]
    assert_equal original_review.except("review_state"), review.except("review_state")
    inspection = AD::Inspector.new(@target, framework_root: @framework).inspect
    assert_equal "historical_retained", inspection.dig("adapters", "reviewed_files", 0, "local_state")
  end

  def test_replace_specialisation_preserves_lineage_and_refuses_pinned_or_dirty_files
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    apply_plan(build)
    commit(@target)
    old = adopted_metadata["components"].first
    @decisions_document["components"] = [file_decision("replace_reviewed_specialisation")]
    File.write(@decisions_document["components"].first["content_path"], "Explicit replacement
")
    save_inputs
    plan = build(operation: "update_adapters")
    assert_equal "replace_reviewed_specialisation", plan["actions"].first["action"]
    assert_equal old, plan["actions"].first["metadata_record"]
    File.write(File.join(@target, "AGENTS.md"), "Uncommitted modification
")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    git(@target, "checkout", "--", "AGENTS.md")
    changed = adopted_metadata
    changed["components"].first.merge!("update_policy" => "pinned", "rationale" => "Synthetic pin.")
    File.write(File.join(@target, AD::METADATA_PATH), T.metadata_bytes(changed))
    commit(@target)
    assert_raises(AD::TransactionError) { build(operation: "update_adapters") }
  end

  def test_unsupported_category_retirement_and_optional_category_addition
    apply_plan(build)
    commit(@target)
    old = adopted_metadata["adapters"]
    register("docker", "runtime")
    commit(@framework)
    @selection_document["selected"] << {"category" => "runtime", "id" => "docker", "source" => "explicit"}
    proposed = registry.fetch(category: "runtime", id: "docker").to_h.slice("category", "id", "version", "manifest_digest", "provider_digest").merge("selection_source" => "explicit")
    @decisions_document["adapter_changes"] = [{"category" => "runtime", "previous" => nil, "proposed" => proposed, "reviewed" => true, "rationale" => "Approve optional synthetic environment."}]
    save_inputs
    plan = build(operation: "update_adapters")
    assert_equal 2, plan.dig("proposed_metadata", "document", "adapters", "selected").size
    assert_equal old, plan.dig("adapter_transaction", "previous_adapters")
    File.unlink(@result_path)
    apply_plan(plan)
    commit(@target)
    @selection_document["selected"].pop
    @decisions_document["adapter_changes"] = []
    save_inputs
    error = assert_raises(AD::TransactionError) { build(operation: "update_adapters") }
    assert_equal "unsupported_operation", error.code
  end

  def test_metadata_schema_unknown_fields_and_duplicate_yaml_rejected
    plan = build
    document = plan.dig("proposed_metadata", "document")
    validator = AD::Validator.new(root: @target, framework_root: @framework)
    assert_empty validator.validate(document)
    document["adapters"]["source"]["extra"] = "forbidden"
    assert validator.validate(document).any? { |item| item.code == "schema_violation" }
    File.write(@selection_path, File.read(@selection_path) + "schema_version: 1\n")
    assert_raises(AD::TransactionError) { build }
  end

  def test_explicit_plan_acceptance_and_no_git_mutation
    plan = build
    head = git(@target, "rev-parse", "HEAD")
    index = git(@target, "ls-files", "--stage")
    result, code = AD::Application.new(AD::PlanValidator.new(plan)).apply(accept_plan_id: "sha256:" + "f" * 64, result: @result_path, plan_path: @plan_path)
    assert_equal "refused", result["status"]
    refute_equal 0, code
    assert_equal head, git(@target, "rev-parse", "HEAD")
    assert_equal index, git(@target, "ls-files", "--stage")
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_v2_inherited_update_and_reconciliation_preserve_adapters
    apply_plan(baseline_plan(operation: "initial_adoption"))
    commit(@target)
    File.unlink(@result_path)
    apply_plan(build)
    commit(@target)
    adapters = adopted_metadata["adapters"]
    component = adopted_metadata["components"].first
    File.write(File.join(@framework, component["source_path"]), "Reviewed new synthetic baseline bytes\n")
    commit(@framework)
    update = baseline_plan(operation: "update_inherited")
    assert_equal 2, update["schema_version"]
    assert_equal adapters, update.dig("proposed_metadata", "document", "adapters")
    File.unlink(@result_path)
    result, code = apply_plan(update)
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    commit(@target)
    component = adopted_metadata["components"].first
    File.write(File.join(@target, component["target_path"]), "Committed repository specialisation\n")
    commit(@target)
    path = File.join(@temporary, "reconcile.yml")
    File.write(path, YAML.dump({"schema_version" => 1, "components" => [{"id" => component["id"], "disposition" => "convert_to_specialised", "local_ownership" => ["native rules"], "rationale" => "Reviewed committed specialisation."}]}))
    plan = AD::Planner.new(target: @target, source: @framework, operation: "reconcile_inherited", effective_date: "2026-11-08", components: [component["id"]], decisions: path).build
    assert_equal adapters, plan.dig("proposed_metadata", "document", "adapters")
    File.unlink(@result_path)
    assert_equal 0, apply_plan(plan).last
    assert_equal "specialised", adopted_metadata["components"].first["ownership"]
    assert_equal component["adopted_revision"], adopted_metadata["components"].first["adopted_revision"]
  end

  def test_unselected_supported_manifest_and_provider_drift_each_refuse_before_provider_execution
    register("docker", "runtime")
    sentinel = File.join(@temporary, "provider-executed")
    install_provider("docker", construction: "File.write(#{sentinel.inspect}, 'synthetic execution')")
    commit(@framework)
    plan = build
    assert File.file?(sentinel)
    %w[adapter.yml adapter.rb].each do |file|
      path = File.join(@framework, "adapters/runtimes/docker", file)
      original = File.binread(path)
      File.unlink(sentinel) if File.exist?(sentinel)
      git(@framework, "update-index", "--assume-unchanged", path)
      File.write(path, original + "\n# hidden synthetic drift\n")
      assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
      refute File.exist?(sentinel)
      File.write(path, original)
      File.unlink(path)
      assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
      refute File.exist?(sentinel)
      File.write(path, original)
      git(@framework, "update-index", "--no-assume-unchanged", path)
    end
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_hidden_target_drift_and_reviewed_content_modes_stale_the_plan
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    plan = build
    content = @decisions_document["components"].first["content_path"]
    File.chmod(0o755, content)
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    File.chmod(0o644, content)
    apply_plan(build)
    commit(@target)
    @decisions_document["components"] = []
    save_inputs
    plan = build(operation: "update_adapters")
    path = File.join(@target, "AGENTS.md")
    git(@target, "update-index", "--assume-unchanged", path)
    File.write(path, "Hidden uncommitted change\n")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
  end

  def test_full_domain_projection_retains_base_refinement_wrapper_and_profile_provenance
    register("rails", "framework", contributions: {"commands" => [refinement], "validation_profiles" => [{"id" => "rails-profile", "profile" => "extended", "command_ids" => ["ruby-test"], "emphasis" => "Synthetic profile."}]})
    register("docker", "runtime", contributions: {"command_wrappers" => [wrapper]})
    commit(@framework)
    @selection_document = selected(["runtime", "docker"], ["framework", "rails"], ["ecosystem", "ruby"])
    approve
    plan = build
    projection = plan.dig("adapter_transaction", "composition", "approved_contributions")
    assert_equal AgenticDeveloperSetup::Adapters::DOMAINS.sort, projection.keys.sort
    assert_equal %w[rails-refinement ruby-test], projection["commands"].map { |item| item["id"] }
    assert_equal ["docker-test"], projection["command_wrappers"].map { |item| item["id"] }
    assert_equal ["rails-profile"], projection["validation_profiles"].map { |item| item["id"] }
    assert_equal %w[docker compose run --rm app bundle exec rspec], plan.dig("proposed_metadata", "document", "adapters", "command_bindings", 0, "argv")
  end

  def test_canonical_embedded_ordering_preserves_exact_raw_input_identity
    register("docker", "runtime")
    commit(@framework)
    @selection_document = selected(["runtime", "docker"], ["ecosystem", "ruby"])
    approve
    first_bytes = File.binread(@selection_path)
    first = build
    assert_equal first, build.except("created_at").merge("created_at" => first["created_at"])
    @selection_document["selected"].reverse!
    save_inputs
    reordered = build
    assert_equal first.dig("adapter_transaction", "selection_document"), reordered.dig("adapter_transaction", "selection_document")
    assert_equal first.dig("adapter_transaction", "approved_decisions"), reordered.dig("adapter_transaction", "approved_decisions")
    refute_equal first.dig("inputs", "adapter_selection", "digest"), reordered.dig("inputs", "adapter_selection", "digest")
    refute_equal first["plan_id"], reordered["plan_id"]
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(first).check! }
    File.binwrite(@selection_path, first_bytes)
    assert_equal first["plan_id"], build["plan_id"]
    File.write(@decisions_path, File.read(@decisions_path) + "# raw-byte change\n")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(first).check! }
  end

  def test_cli_adapter_transaction_preview_check_dry_run_apply_and_validation
    script = File.join(ROOT, "scripts/manage_adoption.rb")
    args = ["plan", @target, "--operation", "adopt_adapters", "--framework-source", @framework, "--scope", ".",
      "--adapter-selection", @selection_path, "--adapter-decisions", @decisions_path, "--effective-date", "2026-11-07", "--output", @plan_path]
    out, err, status = Open3.capture3(RbConfig.ruby, script, *args)
    assert status.success?, "#{out} #{err}"
    plan = YAML.safe_load_file(@plan_path)
    ["preview", "check"].each do |operation|
      out, err, status = Open3.capture3(RbConfig.ruby, script, operation, @plan_path)
      assert status.success?, "#{out} #{err}"
    end
    out, err, status = Open3.capture3(RbConfig.ruby, script, "apply", @plan_path, "--dry-run")
    assert status.success?, "#{out} #{err}"
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
    out, err, status = Open3.capture3(RbConfig.ruby, script, "apply", @plan_path, "--accept-plan-id", plan["plan_id"], "--result", @result_path)
    assert status.success?, "#{out} #{err}"
    assert_includes out, "applied_unvalidated"
    out, err, status = Open3.capture3(RbConfig.ruby, script, "validate", @plan_path, "--application-result", @result_path, "--output", File.join(@temporary, "validation.yml"))
    assert_equal 4, status.exitstatus, "#{out} #{err}"
    assert_includes out, "skipped"
    out, err, status = Open3.capture3(RbConfig.ruby, script, *args, "--component", "agent_instructions")
    assert_equal 2, status.exitstatus, "#{out} #{err}"
    out, err, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/inspect_adoption.rb"), @target)
    assert status.success?, "#{out} #{err}"
    assert_equal 2, YAML.safe_load(out)["schema_version"]
  end

  def test_blocked_composition_missing_input_and_incompatible_selection
    mutate_manifest("ruby") { |manifest| manifest["inputs"] = [input("ecosystem/ruby.choice")] }
    commit(@framework)
    plan = build
    assert_equal "blocked", plan.dig("adapter_transaction", "composition", "status")
    error = assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    assert_equal "preflight_failed", error.code
    result, code = apply_plan(plan)
    assert_equal "refused", result["status"]
    refute_equal 0, code
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
    @selection_document["inputs"] = [{"key" => "ecosystem/ruby.choice", "value" => "explicit"}]
    register("rails", "framework", incompatible: [requirement("ecosystem", "ruby")])
    commit(@framework)
    @selection_document["selected"] << {"category" => "framework", "id" => "rails", "source" => "explicit"}
    save_inputs
    plan = build
    assert_equal "blocked", plan.dig("adapter_transaction", "composition", "status")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
  end

  def test_external_inputs_aliases_unknown_versions_and_file_output_tampering
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    plan = build
    tampered = Marshal.load(Marshal.dump(plan))
    tampered["actions"].first["target_file"]["path"] = "arbitrary.txt"
    tampered["plan_id"] = T.plan_id(tampered)
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(tampered).check! }
    tampered = Marshal.load(Marshal.dump(plan))
    tampered["schema_version"] = 3
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(tampered) }
    tampered = Marshal.load(Marshal.dump(plan))
    tampered["adapter_transaction"] = nil
    tampered["plan_id"] = T.plan_id(tampered)
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(tampered).check! }
    linked = File.join(@temporary, "linked-selection.yml")
    File.link(@selection_path, linked)
    assert_raises(AD::TransactionError) { build }
    File.unlink(linked)
    assert_raises(AD::TransactionError) { AD::Planner.new(target: @target, source: @framework, operation: "adopt_adapters", effective_date: "2026-11-07", scope: ".", adapter_selection: @selection_path, adapter_decisions: @decisions_path).write(@selection_path) }
  end

  def test_v2_validation_requires_matching_evidence_and_explicit_specification
    approve
    spec = File.join(@temporary, "validation-spec.yml")
    File.write(spec, YAML.dump({"schema_version" => 1, "commands" => [{"id" => "synthetic_check", "argv" => [RbConfig.ruby, "-e", "puts 'explicit validation'"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}]}))
    plan = build(validation_spec: spec)
    apply_plan(plan)
    output = File.join(@temporary, "validation-result.yml")
    result, code = AD::TransactionValidation.new(AD::PlanValidator.new(plan)).run(application_result: @result_path, output: output, plan_path: @plan_path)
    assert_equal 0, code
    assert_equal "passed", result["status"]
    assert_equal ["synthetic_check"], result["commands"].map { |item| item["id"] }
    assert_includes result["commands"].first["stdout"], "explicit validation"
    evidence = YAML.safe_load_file(@result_path)
    evidence["adapter_transaction_digest"] = "sha256:" + "f" * 64
    File.write(@result_path, YAML.dump(evidence))
    assert_raises(AD::TransactionError) { AD::TransactionValidation.new(AD::PlanValidator.new(plan)).run(application_result: @result_path, output: File.join(@temporary, "bad-validation.yml"), plan_path: @plan_path) }
  end

  def test_metadata_failure_and_hard_interruption_keep_durable_manual_recovery_evidence
    plan = build
    result, code = apply_plan(plan, hook: ->(event, _) { raise IOError, "synthetic post-metadata failure" if event == :after_metadata })
    assert_equal 5, code
    assert_equal "partially_applied", result["status"]
    assert result.dig("recovery", "metadata_written")
    assert result.dig("recovery", "fresh_plan_required")
    assert File.exist?(File.join(@target, AD::METADATA_PATH))
    commit(@target)
    File.unlink(@result_path)
    plan = build(operation: "update_adapters")
    assert_raises(Interrupt) do
      apply_plan(plan, hook: ->(event, _) { raise Interrupt if event == :after_verify })
    end
    durable = YAML.safe_load_file(@result_path)
    assert_equal "in_progress", durable["status"]
    assert durable.dig("recovery", "interruption_uncertainty")
  end

  def test_decision_record_order_is_canonical_but_raw_decision_changes_stale_all_preflights
    mutate_manifest("ruby") { |manifest| manifest["capabilities"] << "lint" }
    commands = [command, command("ruby-lint", capability: "lint", argv: ["synthetic-lint"])]
    install_provider("ruby", contribute: {"commands" => commands}.inspect)
    commit(@framework)
    @decisions_document["commands"] = %w[ruby-test ruby-lint].map { |id| {"command_id" => id, "disposition" => "approve", "reviewed" => true, "rationale" => "Synthetic explicit decision."} }
    save_inputs
    original_bytes = File.binread(@decisions_path)
    original = build
    @decisions_document["commands"].reverse!
    save_inputs
    reordered = build
    assert_equal original.dig("adapter_transaction", "approved_decisions"), reordered.dig("adapter_transaction", "approved_decisions")
    assert_equal original["proposed_metadata"], reordered["proposed_metadata"]
    refute_equal original["plan_id"], reordered["plan_id"]
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(original).check! }
    result, code = apply_plan(original)
    assert_equal "refused", result["status"]
    refute_equal 0, code
    File.binwrite(@decisions_path, original_bytes)
    assert_equal original["plan_id"], build["plan_id"]
  end

  def test_manifest_only_provider_only_and_replacement_updates_are_explicit
    apply_plan(build)
    commit(@target)
    initial_framework_revision = adopted_metadata.dig("framework", "revision")
    ["manifest", "provider", "replacement"].each do |kind|
      previous = adopted_metadata.dig("adapters", "selected", 0)
      if kind == "manifest"
        mutate_manifest("ruby") { |manifest| manifest["description"] = "Reviewed synthetic manifest-only candidate." }
      elsif kind == "provider"
        path = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
        File.write(path, File.read(path) + "\n# Reviewed synthetic provider-only change\n")
      else
        register("elixir")
        @selection_document = selected(["ecosystem", "elixir"])
      end
      commit(@framework)
      id = (kind == "replacement") ? "elixir" : "ruby"
      proposed = registry.fetch(category: "ecosystem", id: id).to_h.slice("category", "id", "version", "manifest_digest", "provider_digest").merge("selection_source" => "explicit")
      @decisions_document["adapter_changes"] = [{"category" => "ecosystem", "previous" => previous, "proposed" => proposed, "reviewed" => true, "rationale" => "Reviewed synthetic #{kind} change."}]
      save_inputs
      plan = build(operation: "update_adapters")
      File.unlink(@result_path)
      assert_equal 0, apply_plan(plan).last
      assert_equal initial_framework_revision, adopted_metadata.dig("framework", "revision")
      assert_equal git(@framework, "rev-parse", "HEAD").strip, adopted_metadata.dig("adapters", "source", "revision")
      assert_equal proposed, adopted_metadata.dig("adapters", "selected", 0)
      commit(@target)
    end
  end

  def test_inspection_reports_missing_unsafe_and_unavailable_without_losing_historical_state
    approve
    @decisions_document["components"] = [file_decision]
    save_inputs
    apply_plan(build)
    commit(@target)
    original = adopted_metadata["adapters"]
    @metadata["adapters"]["available"] = []
    save_catalogue
    commit(@framework)
    result = AD::Inspector.new(@target, framework_root: @framework).inspect(framework_source: @framework)
    assert_equal "valid", result.dig("metadata", "status")
    assert_equal "missing", result.dig("adapters", "candidate", "selected", 0, "status")
    assert_equal original, result.dig("adapters", "adopted")
    result = AD::Inspector.new(@target, framework_root: @framework).inspect(framework_source: File.join(@temporary, "unavailable-source"))
    assert_equal "unavailable", result.dig("adapters", "candidate", "status")
    assert_empty result.dig("adapters", "candidate", "selected")
    path = File.join(@target, "AGENTS.md")
    File.unlink(path)
    result = AD::Inspector.new(@target, framework_root: @framework).inspect
    assert_equal "missing", result.dig("adapters", "reviewed_files", 0, "local_state")
    File.symlink(File.join(@target, "README.md"), path)
    result = AD::Inspector.new(@target, framework_root: @framework).inspect
    assert_equal "unsafe", result.dig("adapters", "reviewed_files", 0, "local_state")
  end

  def test_workspace_migration_preserves_v1_specialisation_without_fabricated_reviewed_provenance
    install_provider("ruby", contribute: "{}")
    commit(@framework)
    workspace = "apps/synthetic"
    FileUtils.mkdir_p(File.join(@target, workspace))
    File.write(File.join(@target, workspace, ".keep"), "Synthetic workspace\n")
    commit(@target)
    content = file_decision["content_path"]
    decisions = File.join(@temporary, "v1-specialised.yml")
    File.write(decisions, YAML.dump({"schema_version" => 1, "components" => [{"id" => "agent_instructions", "disposition" => "specialised", "content_path" => content, "local_ownership" => ["native rules"], "reviewed" => true}]}))
    initial = AD::Planner.new(target: @target, source: @framework, operation: "initial_adoption", effective_date: "2026-11-07", scope: workspace, components: ["agent_instructions"], decisions: decisions).build
    apply_plan(initial)
    commit(@target)
    original = adopted_metadata
    @selection_document["scope"] = {"type" => "workspace", "path" => workspace}
    save_inputs
    plan = AD::Planner.new(target: @target, source: @framework, operation: "adopt_adapters", effective_date: "2026-11-08", adapter_selection: @selection_path, adapter_decisions: @decisions_path).build
    assert_equal original["scope"], plan.dig("proposed_metadata", "document", "scope")
    assert_equal original["components"], plan.dig("proposed_metadata", "document", "components")
    assert_empty plan.dig("proposed_metadata", "document", "adapters", "reviewed_files")
    File.unlink(@result_path)
    assert_equal 0, apply_plan(plan).last
    assert_equal original["components"], adopted_metadata["components"]
  end

  def test_no_change_preserves_exact_existing_metadata_layout
    apply_plan(build)
    path = File.join(@target, AD::METADATA_PATH)
    raw = "# Synthetic reviewed layout\n" + File.binread(path)
    File.binwrite(path, raw)
    commit(@target)
    plan = build(operation: "update_adapters", date: "2026-11-08")
    validator = AD::PlanValidator.new(plan)
    refute validator.changed?
    refute validator.metadata_changed?
    assert_equal T.digest(raw), plan.dig("proposed_metadata", "digest")
    File.unlink(@result_path)
    result, code = apply_plan(plan)
    assert_equal 0, code
    assert_equal "no_changes", result["status"]
    refute result.dig("metadata", "attempted")
    assert_equal raw, File.binread(path)
  end

  def test_explicit_proposed_inspection_is_read_only_and_invalid_selection_is_an_error
    apply_plan(build)
    before = File.binread(File.join(@target, AD::METADATA_PATH))
    git_before = git(@target, "status", "--porcelain=v1")
    result = AD::Inspector.new(@target, framework_root: @framework).inspect(framework_source: @framework, adapter_selection: @selection_path)
    assert_equal "ready", result.dig("adapters", "proposed_assessment", "composition", "status")
    assert_empty result.dig("adapters", "adopted", "command_bindings")
    assert_equal before, File.binread(File.join(@target, AD::METADATA_PATH))
    assert_equal git_before, git(@target, "status", "--porcelain=v1")
    @selection_document["selected"].first["id"] = "unknown"
    save_inputs
    assert_raises(AgenticDeveloperSetup::Assessment::Error) { AD::Inspector.new(@target, framework_root: @framework).inspect(framework_source: @framework, adapter_selection: @selection_path) }
  end

  def test_hidden_native_evidence_drift_is_refused_before_provider_execution
    sentinel = File.join(@temporary, "native-evidence-provider-executed")
    register("docker", "runtime")
    install_provider("docker", construction: "File.write(#{sentinel.inspect}, 'synthetic execution')")
    commit(@framework)
    plan = build
    assert_includes plan.dig("inputs", "target_files").map { |item| item["path"] }, "README.md"
    File.unlink(sentinel)
    path = File.join(@target, "README.md")
    git(@target, "update-index", "--assume-unchanged", path)
    File.write(path, "Hidden native evidence change\n")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    refute File.exist?(sentinel)
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end
end
