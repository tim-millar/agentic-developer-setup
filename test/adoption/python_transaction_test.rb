# frozen_string_literal: true

require_relative "../adapters/python_support"
require_relative "../../lib/agentic_developer_setup/adoption/manage_cli"

class PublicPythonAdoptionTest < AdapterTest
  include PublicPythonFixture

  AD = AgenticDeveloperSetup::Adoption

  def setup
    super
    install_public_ecosystems
    FileUtils.cp_r(File.join(ROOT, "baseline"), @framework)
    FileUtils.cp_r(File.join(ROOT, "schemas"), @framework)
    uv_project
    @sentinel = File.join(@temporary, "python-project-executed")
    write_target("tests/test_sample.py", <<~PYTHON)
      from pathlib import Path

      def test_sample():
          Path(#{@sentinel.inspect}).touch()
    PYTHON
    write_target("setup.py", "raise AssertionError('must never execute')\n")
    write_target("noxfile.py", "raise AssertionError('must never execute')\n")
    [@framework, @target].each do |root|
      git(root, "init", "-q")
      commit(root)
    end
    @selection_file = File.join(@temporary, "selection.yml")
    @decisions_file = File.join(@temporary, "decisions.yml")
    @plan_file = File.join(@temporary, "plan.yml")
    @result_file = File.join(@temporary, "result.yml")
    File.write(@selection_file, YAML.dump(python_selection(manager: "uv")))
    review_commands
  end

  def review_commands(*ids)
    commands = ids.map do |id|
      {"command_id" => id, "disposition" => "approve", "reviewed" => true, "rationale" => "Reviewed this synthetic binding."}
    end
    document = {"schema_version" => 1, "selection_reviewed" => true, "adapter_changes" => [],
                "commands" => commands, "components" => [], "retained_files" => []}
    File.write(@decisions_file, YAML.dump(document))
  end

  def cli(*args, expect: 0)
    code = nil
    stdout, stderr = capture_io { code = AD::ManageCLI.run(args) }
    assert_equal expect, code, "#{stdout}\n#{stderr}"
    [stdout, stderr]
  end

  def create_plan(expect: 0)
    cli("plan", @target, "--operation", "adopt_adapters", "--framework-source", @framework, "--scope", ".",
      "--adapter-selection", @selection_file, "--adapter-decisions", @decisions_file, "--effective-date", "2026-11-21",
      "--output", @plan_file, expect: expect)
    YAML.safe_load_file(@plan_file) if File.file?(@plan_file)
  end

  def test_cli_lifecycle_preserves_provenance_exact_approval_and_non_execution
    assert_empty git(@target, "status", "--porcelain")
    before = snapshot_target
    blocked_reads = %r{/(?:setup|noxfile)\.py$}
    composition = guard_static_operations(prohibited_reads: blocked_reads) do
      out = StringIO.new
      assert_equal 0, A::CLI.run([@target], stdout: out, framework_root: @framework)
      detected = YAML.safe_load(out.string)
      assert_equal "not_selected", detected.dig("composition", "status")
      assert_equal "detected", detected["candidates"].find { |item| item["id"] == "python" }["status"]
      out = StringIO.new
      assert_equal 0, A::CLI.run([@target, "--selection", @selection_file], stdout: out, framework_root: @framework)
      YAML.safe_load(out.string).fetch("composition")
    end
    assert_equal before, snapshot_target
    guard_static_operations do
      command = composition["commands"].fetch(0)
      assert_equal %w[make test], command["argv"]
      review_commands(command["id"])
      plan = create_plan
      assert_empty plan["actions"]
      assert_empty plan["validation_commands"]
      preview, = cli("preview", @plan_file)
      assert_includes preview, command["id"]
      assert_includes preview, "Complete metadata diff"
      cli("check", @plan_file)
      cli("apply", @plan_file, "--dry-run")
      refute File.exist?(File.join(@target, AD::METADATA_PATH))
      cli("apply", @plan_file, "--accept-plan-id", "sha256:#{"0" * 64}", "--result", @result_file, expect: 4)
      assert_equal "refused", YAML.safe_load_file(@result_file)["status"]
      File.unlink(@result_file)
      cli("apply", @plan_file, "--accept-plan-id", plan["plan_id"], "--result", @result_file)
      result = YAML.safe_load_file(@result_file)
      assert_equal "applied_unvalidated", result["status"]
      assert result.dig("metadata", "verified")
      metadata = YAML.safe_load_file(File.join(@target, AD::METADATA_PATH))
      assert AD::AdapterMetadata.validate!(metadata)
      assert_empty metadata["components"]
      state = metadata["adapters"]
      assert_equal @scope, metadata["scope"]
      assert_equal composition["composition_digest"], state["composition_digest"]
      assert_equal [{"key" => "ecosystem/python.package_manager", "value" => "uv"}], state["inputs"]
      definition = registry.fetch(category: "ecosystem", id: "python")
      assert_equal definition.to_h.slice("id", "category", "version", "manifest_digest", "provider_digest"), state["selected"].fetch(0).except("selection_source")
      binding = state["command_bindings"].fetch(0)
      assert_equal command.values_at("argv", "provenance"), binding.values_at("argv", "provenance")
      assert_equal command["id"], binding["command_id"]
    end
    after = snapshot_target
    added = [File.dirname(AD::METADATA_PATH), AD::METADATA_PATH]
    assert_equal added, after.keys - before.keys
    assert_equal before, after.except(*added)
    refute File.exist?(@sentinel)
    refute File.exist?(File.join(@target, ".venv"))
    assert_equal git(@framework, "rev-parse", "HEAD").strip, YAML.safe_load_file(File.join(@target, AD::METADATA_PATH)).dig("adapters", "source", "revision")
  end

  def test_unknown_command_and_unresolved_policy_allow_only_metadata_review
    write_target("poetry.lock", "# Competing lockfile evidence\n")
    commit(@target)
    review_commands("python-unknown")
    create_plan(expect: 2)
    refute File.exist?(@plan_file)
    review_commands
    plan = create_plan
    assert_empty plan.dig("proposed_metadata", "document", "adapters", "command_bindings")
    cli("check", @plan_file)
    cli("apply", @plan_file, "--accept-plan-id", plan["plan_id"], "--result", @result_file)
    assert_equal "applied_unvalidated", YAML.safe_load_file(@result_file)["status"]
    refute File.exist?(@sentinel)
  end

  def test_scope_conflict_remains_blocking_at_preflight
    write_target("apps/secondary/setup.cfg", "[metadata]\nname = secondary\n")
    commit(@target)
    plan = create_plan(expect: 4)
    assert_equal "blocked", plan.dig("adapter_transaction", "composition", "status")
    cli("apply", @plan_file, "--dry-run", expect: 4)
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end

  def test_input_bytes_and_committed_source_must_match_reviewed_plan
    plan = create_plan
    selection = File.binread(@selection_file)
    File.binwrite(@selection_file, selection + "# Changed reviewed input bytes\n")
    cli("check", @plan_file, expect: 4)
    File.binwrite(@selection_file, selection)
    cli("check", @plan_file)
    provider = File.join(@framework, "adapters/ecosystems/python/adapter.rb")
    git(@framework, "update-index", "--assume-unchanged", provider)
    File.open(provider, "a") { |file| file.puts "raise 'drifted provider must never load'" }
    _, stderr = cli("check", @plan_file, expect: 4)
    assert_includes stderr, "bytes/mode"
    refute_includes stderr, "drifted provider"
    cli("apply", @plan_file, "--accept-plan-id", plan["plan_id"], "--result", @result_file, expect: 4)
    assert_equal "refused", YAML.safe_load_file(@result_file)["status"]
    refute File.exist?(@sentinel)
    refute File.exist?(File.join(@target, AD::METADATA_PATH))
  end
end
