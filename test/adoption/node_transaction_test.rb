# frozen_string_literal: true

require_relative "../adapters/node_support"
require_relative "../../lib/agentic_developer_setup/adoption/manage_cli"

class PublicNodeAdoptionTest < AdapterTest
  include PublicNodeFixture

  AD = AgenticDeveloperSetup::Adoption

  def setup
    super
    install_public_ecosystems
    FileUtils.cp_r(File.join(ROOT, "baseline"), @framework)
    FileUtils.cp_r(File.join(ROOT, "schemas"), @framework)
    f1
    init_git(@framework)
    init_git(@target)
    @selection_path = File.join(@temporary, "selection.yml")
    @decisions_path = File.join(@temporary, "decisions.yml")
    @plan_path = File.join(@temporary, "plan.yml")
    @result_path = File.join(@temporary, "result.yml")
    @decisions = {"schema_version" => 1, "selection_reviewed" => true, "adapter_changes" => [], "commands" => [], "components" => [], "retained_files" => []}
    File.write(@selection_path, YAML.dump(node_selection))
    save_decisions
  end

  def git(root, *args)
    out, err, status = Open3.capture3("git", "-C", root, "-c", "core.hooksPath=/dev/null", *args)
    raise err unless status.success?
    out
  end

  def init_git(root)
    git(root, "init", "-q")
    git(root, "config", "user.name", "Synthetic Public Test")
    git(root, "config", "user.email", "synthetic@example.invalid")
    commit(root)
  end

  def commit(root)
    git(root, "add", ".")
    git(root, "commit", "-qm", "Independent public fixture")
  end

  def save_decisions(command_id = nil)
    @decisions["commands"] = command_id ? [{"command_id" => command_id, "disposition" => "approve", "reviewed" => true, "rationale" => "Explicit review of this synthetic command binding only."}] : []
    File.write(@decisions_path, YAML.dump(@decisions))
  end

  def build
    AD::Planner.new(target: @target, source: @framework, operation: "adopt_adapters", effective_date: "2026-11-15", scope: ".",
      adapter_selection: @selection_path, adapter_decisions: @decisions_path).write(@plan_path)
  end

  def apply(plan, accepted: plan["plan_id"], **extra)
    AD::Application.new(AD::PlanValidator.new(plan), **extra).apply(accept_plan_id: accepted, result: @result_path, plan_path: @plan_path)
  end

  def snapshot
    Dir.glob(File.join(@target, "**/*"), File::FNM_DOTMATCH).select { |file| File.file?(file) && !file.include?("/.git/") }.to_h do |file|
      [file.delete_prefix("#{@target}/"), File.binread(file)]
    end
  end

  def test_real_node_complete_lifecycle_exact_provenance_and_no_execution
    # A real recommendation may invoke arbitrary target code if later executed;
    # sentinel verifies the adoption path never grants that execution authority.
    sentinel = File.join(@temporary, "script-executed")
    data = JSON.parse(File.read(File.join(@target, "package.json")))
    data["scripts"]["test"] = "node --test; touch #{sentinel}"
    data["scripts"]["postinstall"] = "touch #{sentinel}"
    package(data)
    commit(@target)
    before = snapshot
    detected = assess
    assert_equal "not_selected", detected.dig("composition", "status")
    assert_equal "detected", detected["candidates"].first["status"]
    composition = assess(node_selection)["composition"]
    assert_equal "ready", composition["status"]
    assert_equal 4, composition["commands"].size
    save_decisions("node-test")
    plan = build
    assert_equal 2, plan["schema_version"]
    assert_empty plan["actions"]
    assert_empty plan["validation_commands"]
    assert_equal "ready", plan.dig("adapter_transaction", "composition", "status")
    assert AD::PlanValidator.new(plan).check!
    preview, code = AD::Preview.new(AD::PlanValidator.new(plan)).render
    assert_equal 0, code
    assert_includes preview, "node-test"
    assert_includes preview, "Complete metadata diff"
    assert_includes preview, "Command binding effects"
    # Run the supported CLI dry-run with independent file-based preflight.
    output, error, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/manage_adoption.rb"), "apply", @plan_path, "--dry-run")
    assert status.success?, "#{output} #{error}"
    assert_equal before, snapshot
    events = []
    result, code = apply(plan, hook: ->(event, _) { events << event })
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    assert result.dig("metadata", "verified")
    assert_includes events, :before_metadata
    assert_includes events, :after_metadata
    assert_equal result, YAML.safe_load_file(@result_path)
    after = snapshot
    assert_equal [AD::METADATA_PATH], (after.keys - before.keys)
    before.each { |file, bytes| assert_equal bytes, after[file] }
    refute File.exist?(sentinel)
    refute File.exist?(File.join(@target, "node_modules"))
    metadata = YAML.safe_load_file(File.join(@target, AD::METADATA_PATH))
    assert_equal 2, metadata["schema_version"]
    assert_empty metadata["components"]
    state = metadata["adapters"]
    assert_equal composition["composition_digest"], state["composition_digest"]
    assert_equal composition["adapter_set_digest"], state["adapter_set_digest"]
    assert_empty state["inputs"]
    binding = state["command_bindings"].fetch(0)
    assert_equal ["node-test"], state["command_bindings"].map { |item| item["command_id"] }
    assert_equal %w[npm run test], binding["argv"]
    proposed = composition["commands"].find { |command| command["id"] == "node-test" }
    assert_equal proposed["provenance"], binding["provenance"]
    definition = registry.supported.first
    assert_equal definition.to_h.slice("id", "category", "version", "manifest_digest", "provider_digest"), state["selected"].first.except("selection_source")
    assert_equal git(@framework, "rev-parse", "HEAD").strip, state.dig("source", "revision")
    assert AD::AdapterMetadata.validate!(metadata)
    # An approved binding still supplies no executable validation specification.
    validation, code = AD::TransactionValidation.new(AD::PlanValidator.new(plan)).run(application_result: @result_path,
      output: File.join(@temporary, "validation.yml"), plan_path: @plan_path)
    assert_equal 4, code
    assert_equal "skipped", validation["status"]
    refute File.exist?(sentinel)
  end

  def test_true_metadata_only_with_explicit_manager_input
    package({"scripts" => {"test" => "node --test"}})
    File.unlink(File.join(@target, "package-lock.json"))
    commit(@target)
    File.write(@selection_path, YAML.dump(node_selection(manager: "pnpm")))
    before = snapshot
    plan = build
    assert_empty plan["actions"]
    assert_empty plan.dig("proposed_metadata", "document", "adapters", "command_bindings")
    result, code = apply(plan)
    assert_equal 0, code
    assert_equal "applied_unvalidated", result["status"]
    state = YAML.safe_load_file(File.join(@target, AD::METADATA_PATH))["adapters"]
    assert_equal [{"key" => "ecosystem/node.package_manager", "value" => "pnpm"}], state["inputs"]
    assert_empty state["command_bindings"]
    assert_equal [AD::METADATA_PATH], snapshot.keys - before.keys
  end

  def test_conflicting_manager_withholds_commands_but_allows_metadata_only
    write_target("yarn.lock", "# independent synthetic conflict\n")
    commit(@target)
    result = assess(node_selection)
    assert_empty node_commands(result)
    assert_equal "ready", result.dig("composition", "status")
    save_decisions("node-test")
    assert_raises(AD::TransactionError) { build }
    save_decisions
    plan = build
    assert AD::PlanValidator.new(plan).check!
    _, code = apply(plan)
    assert_equal 0, code
  end

  def test_nonexistent_command_approval_is_refused
    save_decisions("node-unrecommended")
    assert_raises(AD::TransactionError) { build }
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_exact_plan_id_required_and_input_bytes_stale_plans
    save_decisions("node-test")
    plan = build
    result, code = apply(plan, accepted: "sha256:#{"0" * 64}")
    assert_equal 4, code
    assert_equal "refused", result["status"]
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
    [@selection_path, @decisions_path].each do |input|
      original = File.binread(input)
      File.binwrite(input, original + "\n# same semantics, changed reviewed bytes\n")
      assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
      File.binwrite(input, original)
    end
    assert AD::PlanValidator.new(plan).check!
  end

  def test_real_node_source_drift_is_refused_before_provider_evaluation
    plan = build
    provider = File.join(@framework, "adapters/ecosystems/node/adapter.rb")
    # Hidden working-tree drift must still fail the committed-byte check.
    git(@framework, "update-index", "--assume-unchanged", provider)
    File.open(provider, "a") { |file| file.puts '\nraise "must never evaluate drifted adapter"' }
    error = assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    assert_includes error.message, "bytes/mode"
    refute_includes error.message, "must never evaluate"
    result, code = apply(plan)
    assert_equal 4, code
    assert_equal "refused", result["status"]
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_multi_root_cannot_bypass_generic_scope_conflict
    package({"packageManager" => "npm@10"}, prefix: "packages/other/")
    commit(@target)
    plan = build
    assert_equal "blocked", plan.dig("adapter_transaction", "composition", "status")
    assert_raises(AD::TransactionError) { AD::PlanValidator.new(plan).check! }
    result, code = apply(plan)
    assert_equal 4, code
    assert_equal "refused", result["status"]
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end
end
