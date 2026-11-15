# frozen_string_literal: true

require_relative "../assessment_test_helper"

class NodeMetadataInventoryTest < Minitest::Test
  include AssessmentTestSupport

  I = AgenticDeveloperSetup::Assessment::Inventory

  def inventory
    I.new(Pathname.new(@target)).discover
  end

  def test_new_metadata_is_bounded_at_root_and_nested_packages
    %w[.nvmrc .node-version npm-shrinkwrap.json].each do |file|
      write(file, "20.1.0")
      write("packages/web/#{file}", "20.1.0")
      write("node_modules/hidden/#{file}", "private")
      write("dist/#{file}", "generated")
      write("docs/examples/#{file}", "documentation sample")
      write("arbitrary/deep/#{file}", "not traversed")
    end
    write(".npmrc", "private configuration")
    result = inventory
    %w[.nvmrc .node-version npm-shrinkwrap.json].each do |file|
      assert_equal "20.1.0", result.read(file)
      assert_equal "20.1.0", result.read("packages/web/#{file}")
      %w[node_modules/hidden dist docs/examples arbitrary/deep].each { |prefix| assert_nil result.read("#{prefix}/#{file}") }
    end
    assert_nil result.read(".npmrc")
    assert_nil result.read("../outside")
  end

  def test_ignored_unsafe_oversized_and_tracked_excluded_metadata_stays_inaccessible
    init_git
    write(".gitignore", ".nvmrc\npackages/ignored/\n")
    write(".nvmrc", "private ignored value")
    write("packages/ignored/.node-version", "private")
    write("npm-shrinkwrap.json", "x" * (I::MAX_READ_BYTES + 1))
    outside = File.join(@temporary_root, "outside-version")
    File.write(outside, "private")
    File.symlink(outside, File.join(@target, ".node-version"))
    write("node_modules/package/npm-shrinkwrap.json", "private dependency")
    write("build/.nvmrc", "private generated metadata")
    _, err, status = Open3.capture3("git", "-C", @target, "add", "-f", "node_modules", "build")
    assert status.success?, err
    result = inventory
    %w[.nvmrc packages/ignored/.node-version npm-shrinkwrap.json .node-version node_modules/package/npm-shrinkwrap.json build/.nvmrc].each do |file|
      assert_nil result.read(file), file
    end
    assert_includes result.ignored_paths, ".nvmrc"
    assert_includes result.symlink_boundaries, ".node-version"
    assert_equal 256 * 1024, I::MAX_READ_BYTES
  end

  def test_generic_detector_handles_nonobject_and_invalid_script_fields
    %w[null false 1 []].each do |raw|
      write("package.json", raw)
      assert_schema assess
    end
    write("package.json", '{"scripts":{"test":{"command":"jest"},"lint":null,"build":3}}')
    assert_schema assess
  end

  def manager_sources(result, manager)
    manager.fetch("evidence_ids").map { |id| result["evidence"].find { |item| item["id"] == id } }
  end

  def test_generic_npm_lockfile_forms_keep_one_family_and_source_evidence
    write("package.json", '{"name":"independent-public-fixture"}')
    [["npm-shrinkwrap.json"], ["package-lock.json"], %w[package-lock.json npm-shrinkwrap.json]].each do |locks|
      %w[package-lock.json npm-shrinkwrap.json].each { |file| FileUtils.rm_f(File.join(@target, file)) }
      locks.each { |file| write(file, "{}") }
      result = assess
      assert_schema result
      managers = result.dig("tooling", "package_managers")
      assert_equal ["npm"], managers.map { |item| item["name"] }
      assert_equal "detected", managers.first["status"]
      assert_equal "high", managers.first["confidence"]
      sources = manager_sources(result, managers.first)
      assert_equal locks.sort, sources.map { |item| item["path"] }.sort
      assert sources.all? { |item| item["method"] == "package_manager_lockfile" }
      node = result["ecosystem"].find { |item| item["name"] == "node" }
      assert_equal (["package.json"] + locks).sort, node["paths"].sort
      node_sources = node["evidence_ids"].map { |id| result["evidence"].find { |item| item["id"] == id } }
      locks.each { |file| assert node_sources.any? { |item| item["path"] == file && item["method"] == "package_manager_lockfile" } }
    end
  end

  def test_generic_npm_lockfile_only_evidence_does_not_require_a_manifest
    %w[package-lock.json npm-shrinkwrap.json].each do |lock|
      write(lock, "{}")
      result = assess
      assert_equal [lock], result["ecosystem"].find { |item| item["name"] == "node" }["paths"]
      managers = result.dig("tooling", "package_managers")
      assert_equal ["npm"], managers.map { |item| item["name"] }
      assert_equal ["high"], managers.map { |item| item["confidence"] }
      assert_equal [lock], manager_sources(result, managers.first).map { |item| item["path"] }
      File.unlink(File.join(@target, lock))
    end
  end

  def test_generic_shrinkwrap_conflicts_with_other_manager_families
    write("package.json", "{}")
    write("npm-shrinkwrap.json", "{}")
    {"yarn.lock" => "yarn", "pnpm-lock.yaml" => "pnpm"}.each do |lock, name|
      write(lock, "{}")
      result = assess
      managers = result.dig("tooling", "package_managers")
      assert_equal ["npm", name].sort, managers.map { |item| item["name"] }.sort
      assert managers.all? { |item| item["status"] == "conflicting" && item["confidence"] == "low" }
      assert_equal ["npm-shrinkwrap.json", lock].sort, managers.flat_map { |manager| manager_sources(result, manager).map { |item| item["path"] } }.sort
      File.unlink(File.join(@target, lock))
    end
  end

  def test_generic_shrinkwrap_evidence_obeys_ignore_exclusion_and_symlink_boundaries
    init_git
    write("package.json", "{}")
    write(".gitignore", "npm-shrinkwrap.json\n")
    write("npm-shrinkwrap.json", "ignored synthetic metadata")
    write("node_modules/pkg/npm-shrinkwrap.json", "excluded synthetic metadata")
    _, error, status = Open3.capture3("git", "-C", @target, "add", "-f", "node_modules")
    assert status.success?, error
    result = assess
    assert_includes result.dig("scope", "ignored_paths"), "npm-shrinkwrap.json"
    refute result["evidence"].any? { |item| item["path"].to_s.end_with?("npm-shrinkwrap.json") }
    assert_equal ["medium"], result.dig("tooling", "package_managers").map { |manager| manager["confidence"] }
    write(".gitignore", "")
    File.unlink(File.join(@target, "npm-shrinkwrap.json"))
    outside = File.join(@temporary_root, "outside-shrinkwrap")
    File.write(outside, "{}")
    File.symlink(outside, File.join(@target, "npm-shrinkwrap.json"))
    result = assess
    assert_includes result.dig("scope", "symlink_boundaries"), "npm-shrinkwrap.json"
    refute result["evidence"].any? { |item| item["path"].to_s.end_with?("npm-shrinkwrap.json") && item["method"] == "package_manager_lockfile" }
    assert_equal ["package.json"], result["ecosystem"].find { |item| item["name"] == "node" }["paths"]
  end

  def assert_no_package_field_observations(raw)
    write("package.json", raw)
    assert_no_package_field_result(assess)
  end

  def assert_no_package_field_result(result)
    assert_schema result
    assert_empty result.dig("tooling", "package_managers")
    %w[test_frameworks linters formatters type_checkers task_runners].each { |kind| assert_empty result.dig("tooling", kind) }
    assert_empty result.dig("tooling", "command_surface", "commands")
    assert_empty result.dig("validation", "local_commands")
    assert result["evidence"].any? { |item| item["path"] == "package.json" && item["method"] == "package_json_project_metadata" }
    result
  end

  def ambiguous_packages
    [
      '{"packageManager":"npm@10","packageManager":"yarn@4","scripts":{"test":"vitest run"},"devDependencies":{"eslint":"9"}}',
      '{"packageManager":"npm@10","scripts":{"test":"node --test","test":"vitest run"},"devDependencies":{"typescript":"5"}}',
      '{"packageManager":"pnpm@9","dependencies":{"nested":{"version":"1","version":"2"}},"scripts":{"test":"jest"}}',
      '{"packageManager":"npm@10","metadata":{"items":[{"name":"first","name":"last"}]},"scripts":{"lint":"eslint ."}}',
      '{"packageManager":"npm@10","\u0070ackageManager":"yarn@4"}'
    ]
  end

  def test_generic_duplicate_package_keys_withhold_all_field_observations
    ambiguous_packages.each { |raw| assert_no_package_field_observations(raw) }
    credential = "ghp_" + "SyntheticCredential" * 3
    raw = %({"#{credential}":1,"#{credential}":2,"scripts":{"test":"vitest run"}})
    result = assert_no_package_field_observations(raw)
    refute_includes YAML.dump(result), credential
  end

  def test_generic_duplicate_rejection_with_default_json_that_ignores_parser_option
    samples = File.join(@temporary_root, "ambiguous-packages.json")
    File.write(samples, JSON.generate(ambiguous_packages))
    script = <<~RUBY
      require "agentic_developer_setup/assessment"
      ignored = begin
        JSON.parse('{"key":1,"key":2}', allow_duplicate_key: false)["key"] == 2
      rescue JSON::ParserError
        false
      end
      results = JSON.parse(File.read(ARGV[1])).map do |raw|
        File.write(File.join(ARGV[0], "package.json"), raw)
        AgenticDeveloperSetup::Assessment::Assessor.new(ARGV[0]).assess
      end
      puts JSON.generate({"json_version" => JSON::VERSION, "option_ignored" => ignored, "results" => results})
    RUBY
    # The supported Ruby includes default JSON independently of the locked
    # bundle. Exercise that actual parser, not a mock of duplicate handling.
    stdout, stderr, status = Open3.capture3({"RUBYOPT" => nil, "RUBYLIB" => nil}, RbConfig.ruby,
      "--disable-gems", "-I#{File.join(ROOT, "lib")}", "-e", script, @target, samples)
    assert status.success?, stderr
    output = JSON.parse(stdout)
    assert output["option_ignored"], "expected the supported Ruby's default JSON to exercise the ignored option: #{output["json_version"]}"
    output["results"].each { |result| assert_no_package_field_result(result) }
  end

  def test_rejected_package_fields_do_not_erase_independent_lockfile_evidence
    write("package.json", ambiguous_packages.first)
    write("package-lock.json", "{}")
    result = assess
    assert_equal ["npm"], result.dig("tooling", "package_managers").map { |manager| manager["name"] }
    assert_equal ["package-lock.json"], manager_sources(result, result.dig("tooling", "package_managers").first).map { |item| item["path"] }
    assert_empty result.dig("validation", "local_commands")
  end

  def test_generic_valid_unique_objects_keep_manager_scripts_and_dependencies
    %w[npm yarn pnpm].each do |manager|
      write("package.json", JSON.generate({"packageManager" => "#{manager}@10", "scripts" => {"test" => "vitest run", "typecheck" => "tsc --noEmit"},
        "devDependencies" => {"eslint" => "9", "typescript" => "5"}, "workspaces" => ["packages/*"], "metadata" => {"values" => [nil, true, false, 1, 1.5, {"key" => "value"}]}}))
      result = assess
      assert_schema result
      assert_equal [manager], result.dig("tooling", "package_managers").map { |item| item["name"] }
      assert_equal ["high"], result.dig("tooling", "package_managers").map { |item| item["confidence"] }
      assert_equal ["vitest"], result.dig("tooling", "test_frameworks").map { |item| item["name"] }
      assert_equal ["ESLint"], result.dig("tooling", "linters").map { |item| item["name"] }
      assert_equal ["TypeScript compiler"], result.dig("tooling", "type_checkers").map { |item| item["name"] }
      assert_equal ["package script test", "package script typecheck"], result.dig("validation", "local_commands")
      assert_equal "detected", result.dig("tooling", "workspace", "status")
    end
    write("package.json", "{}")
    assert_equal ["medium"], assess.dig("tooling", "package_managers").map { |item| item["confidence"] }
  end

  def test_generic_invalid_package_roots_malformed_and_oversized_documents
    ["[]", '"string"', "null", "false", "1", '{"scripts":', "{not JSON}", " " * (I::MAX_READ_BYTES + 1),
      '{"metadata":' + "[" * 101 + "null" + "]" * 101 + "}"].each { |raw| assert_no_package_field_observations(raw) }
  end
end
