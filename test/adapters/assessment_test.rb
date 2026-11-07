# frozen_string_literal: true

require_relative "support"

class AdapterAssessmentTest < AdapterTest
  def test_default_empty_unselected_assessment
    result = assess
    assert_equal 1, result["schema_version"]
    assert_equal 2, result.dig("framework", "metadata_schema_version")
    assert_equal "adapter_assessment", result["kind"]
    assert_equal "not_selected", result.dig("composition", "status")
    assert_empty result["selected"]
    assert_nil result.dig("composition", "adapter_set_digest")
    assert_nil result.dig("composition", "composition_digest")
    assert_equal result, assess
  end

  def test_detection_reports_evidence_without_selecting
    write_target("Gemfile", "# static synthetic Ruby configuration")
    register("ruby", marker: "Gemfile", contributions: {"commands" => [command]})
    result = assess
    candidate = result["candidates"].first
    assert_equal "detected", candidate["status"]
    assert_equal "not_selected", result.dig("composition", "status")
    assert_empty result["selected"]
    assert_empty result.dig("composition", "commands")
    assert candidate["evidence"].all? { |id| result["evidence"].any? { |record| record["id"] == id && record["path"] == "Gemfile" } }
    assert_equal result, assess
  end

  def test_generic_detection_never_promotes_planned_adapters
    write_target("package.json", '{"name":"synthetic", "scripts":{"test":"never-executed"}}')
    register("node", status: "planned")
    result = assess
    assert_empty result["candidates"]
    assert result["evidence"].any? { |item| item["path"] == "package.json" }
    assert_empty result["selected"]
  end

  def test_accepted_detection_selection
    register("ruby", marker: "Gemfile")
    write_target("Gemfile")
    document = selected(["ecosystem", "ruby"])
    document["selected"][0]["source"] = "accepted_detection"
    result = assess(document)
    assert_equal "ready", result.dig("composition", "status")
    assert_equal "accepted_detection", result.dig("selected", 0, "source")
  end

  def test_accepted_detection_requires_current_matching_candidate
    register("ruby", marker: "Gemfile")
    document = selected(["ecosystem", "ruby"])
    document["selected"][0]["source"] = "accepted_detection"
    assert_raises(A::Error) { assess(document) }
  end

  def test_explicit_selection_without_positive_evidence
    register("ruby", marker: "Gemfile")
    result = assess(selected(["ecosystem", "ruby"]))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal "not_detected", result.dig("candidates", 0, "status")
  end

  def test_missing_ecosystem_selection_is_invalid
    register("docker", "runtime")
    assert_raises(A::Error) { assess(selected(["runtime", "docker"])) }
  end

  def test_duplicate_category_is_invalid
    register("ruby")
    register("python")
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], ["ecosystem", "python"])) }
  end

  def test_duplicate_identity_is_invalid
    register("ruby")
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], ["ecosystem", "ruby"])) }
  end

  def test_unknown_and_planned_selection_is_invalid
    register("ruby", status: "planned")
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
    assert_raises(A::Error) { assess(selected(["ecosystem", "unknown"])) }
  end

  def test_selection_unknown_fields_are_invalid
    register("ruby")
    document = selected(["ecosystem", "ruby"])
    document["authorised"] = true
    assert_raises(A::Error) { assess(document) }
  end

  def test_unknown_input_key_is_invalid
    register("ruby")
    document = selected(["ecosystem", "ruby"], inputs: [{"key" => "unknown", "value" => "value"}])
    assert_raises(A::Error) { assess(document) }
  end

  def test_workspace_scope_is_bounded_and_uses_repository_relative_evidence
    write_target("apps/storefront/Gemfile")
    write_target("apps/other/package.json", '{"name":"other"}')
    write_target("Gemfile", "root must not be read by the workspace provider")
    register("ruby", marker: "Gemfile", contributions: {"commands" => [command(cwd: "apps/storefront", scope: "apps/storefront")]})
    workspace = {"type" => "workspace", "path" => "apps/storefront"}
    result = assess(selected(["ecosystem", "ruby"], scope: workspace))
    assert_equal "ready", result.dig("composition", "status")
    assert_equal workspace, result["scope"]
    assert_equal workspace, result.dig("candidates", 0, "scope")
    assert result["evidence"].all? { |item| !item["path"] || item["path"].start_with?("apps/storefront/") }
    assert_equal "apps/storefront/Gemfile", result["evidence"].find { |item| item["method"] == "synthetic_static_marker" }["path"]
  end

  def test_ambiguous_multiple_project_scope_blocks_until_narrowed
    write_target("apps/one/package.json", '{"name":"one"}')
    write_target("apps/two/pyproject.toml", "[project]\nname = 'two'\n")
    register("node", marker: "package.json")
    document = selected(["ecosystem", "node"])
    assert_includes codes(assess(document)), "scope_conflict"
    document["scope"] = {"type" => "workspace", "path" => "apps/one"}
    assert_equal "ready", assess(document).dig("composition", "status")
  end

  def test_contradictory_ecosystem_evidence_in_one_root_blocks
    write_target("package.json", '{"name":"one"}')
    write_target("pyproject.toml", "[project]\nname = 'two'\n")
    register("node", marker: "package.json")
    register("python", marker: "pyproject.toml")
    result = assess(selected(["ecosystem", "node"]))
    assert_includes codes(result), "scope_conflict"
    assert_includes codes(result), "repository_evidence_conflict"
    assert_equal "blocked", result.dig("composition", "status")
  end

  def test_unsafe_or_nonexisting_workspace_rejected
    register("ruby")
    ["../outside", "/absolute", "missing", "a/../other", "./alias"].each do |path|
      assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], scope: {"type" => "workspace", "path" => path})) }
    end
  end

  def test_symlink_scope_and_command_paths_rejected
    write_target("real/Gemfile")
    File.symlink("real", File.join(@target, "alias"))
    register("ruby", contributions: {"commands" => [command(cwd: "alias")]})
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"], scope: {"type" => "workspace", "path" => "alias"})) }
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
  end

  def test_target_code_never_runs_and_files_are_unchanged
    write_target("package.json", '{"name":"synthetic", "scripts":{"test":"touch must-not-exist", "prepare":"touch must-not-exist"}}')
    write_target("Makefile", "test:\n\ttouch must-not-exist\n")
    write_target("adapter.rb", "raise 'target Ruby code must not load'\n")
    register("node", marker: "package.json", contributions: {"commands" => [command(argv: %w[npm test])]})
    files = Dir.glob(File.join(@target, "**/*")).select { |path| File.file?(path) }.to_h { |path| [path, File.binread(path)] }
    result = assess(selected(["ecosystem", "node"]))
    assert_equal "ready", result.dig("composition", "status")
    refute File.exist?(File.join(@target, "must-not-exist"))
    assert files.all? { |path, bytes| File.binread(path) == bytes }
    refute File.exist?(File.join(@target, ".agent-framework"))
  end

  def test_inventory_exclusions_remain_effective
    write_target("node_modules/package.json", '{"name":"excluded"}')
    register("node", marker: "node_modules/package.json")
    result = assess
    assert_equal "not_detected", result.dig("candidates", 0, "status")
    assert_empty result["evidence"]
  end

  def test_provider_unknown_output_and_unresolved_evidence_are_errors
    register("ruby", contributions: {"commands" => [command.merge("shell" => "arbitrary")]})
    assert_raises(A::Error) { assess(selected(["ecosystem", "ruby"])) }
    path = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    text = File.read(path)
    File.write(path, text.sub("return [] unless MARKER", 'return [IDENTITY.merge("scope" => context.scope, "status" => "detected", "confidence" => "high", "evidence" => ["missing"], "ambiguities" => [], "incompatible_evidence" => [])] unless MARKER'))
    assert_match(/unknown adapter evidence/, assert_raises(A::Error) { assess }.message)
  end

  def test_assessment_nested_shapes_are_closed
    result = assess
    result["framework"]["undeclared"] = true
    assert_raises(A::Error) { A::Contracts.validate!("assessment", result) }
  end
end
