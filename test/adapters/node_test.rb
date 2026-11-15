# frozen_string_literal: true

require_relative "node_support"
require "socket"

class PublicNodeAdapterTest < AdapterTest
  include PublicNodeFixture

  def setup
    super
    install_node
  end

  def test_registered_manifest_and_real_provider_interface
    live = A::Registry.load(framework_root: ROOT)
    assert_equal ["node"], live.supported.map(&:id)
    definition = live.fetch(category: "ecosystem", id: "node")
    assert_equal "1.0.0", definition.version
    assert_equal "supported", definition.status
    assert_equal 5, live.entries.count { |entry| entry.status == "planned" }
    provider = live.provider(definition)
    assert_equal 1, provider.method(:detect).arity
    assert_includes provider.method(:contribute).parameters, [:keyreq, :inputs]
    assert_equal ["ecosystem/node.package_manager"], definition.input_definitions.map { |item| item["key"] }
    refute definition.input_definitions.first.key?("default")
  end

  def test_detection_is_not_selection_and_references_are_stable
    f1
    result = assess
    assert_equal "detected", result["candidates"].first["status"]
    assert_equal "high", result["candidates"].first["confidence"]
    assert_equal "not_selected", result.dig("composition", "status")
    assert_empty result["selected"]
    assert_empty result.dig("composition", "commands")
    assert_equal result, assess
    refs = result["evidence"].map { |item| item["id"] }
    refute_empty result["candidates"].first["evidence"]
    assert_empty result["candidates"].first["evidence"] - refs
  end

  def test_no_evidence_and_config_without_manifest
    assert_equal "not_detected", assess["candidates"].first["status"]
    result = assess(node_selection)
    assert_empty node_commands(result)
    assert result["candidates"].first["ambiguities"].any?
    write_target("tsconfig.app.json", "{}")
    assert_equal "ambiguous", assess["candidates"].first["status"]
    assert_empty node_commands
  end

  def test_language_states_without_source_level_certainty
    package({"packageManager" => "npm@10", "main" => "index.js"})
    result = assess(node_selection)
    summary = node_findings(result).find { |item| item["id"] == "node-language-evidence" }["summary"]
    assert_includes summary, "JavaScript entrypoint"
    assert_includes summary, "does not establish JavaScript-only"
    write_target("tsconfig.json", "{}")
    result = assess(node_selection)
    assert_includes node_findings(result).find { |item| item["id"] == "node-language-evidence" }["summary"], "Both JavaScript"
    File.unlink(File.join(@target, "tsconfig.json"))
    package({"devDependencies" => {"typescript" => "5"}})
    result = assess(node_selection)
    assert_includes node_findings(result).find { |item| item["id"] == "node-language-evidence" }["summary"], "No TypeScript configuration"
  end

  def test_package_manager_outcome_matrix
    cases = [
      ["npm@10.0.0", ["package-lock.json"], nil, "npm"],
      ["yarn@4.0.0", ["yarn.lock"], nil, "yarn"],
      ["pnpm@9.0.0", ["pnpm-lock.yaml"], nil, "pnpm"],
      [nil, ["yarn.lock"], nil, "yarn"],
      ["pnpm@9.0.0", [], nil, "pnpm"],
      [nil, [], nil, nil], [nil, [], "pnpm", "pnpm"],
      ["npm@10", ["yarn.lock"], nil, nil],
      [nil, ["yarn.lock", "pnpm-lock.yaml"], nil, nil],
      ["bun@1.0.0", ["package-lock.json"], nil, nil],
      ["npm@10", [], "yarn", nil],
      [nil, ["package-lock.json"], "pnpm", nil],
      ["yarn@4", ["yarn.lock"], "yarn", "yarn"],
      [nil, ["npm-shrinkwrap.json"], nil, "npm"],
      [nil, ["package-lock.json", "npm-shrinkwrap.json"], nil, "npm"]
    ]
    cases.each do |declaration, locks, input, expected|
      %w[package-lock.json npm-shrinkwrap.json yarn.lock pnpm-lock.yaml].each { |file| FileUtils.rm_f(File.join(@target, file)) }
      data = {"scripts" => {"test" => "node --test"}}
      data["packageManager"] = declaration if declaration
      package(data)
      locks.each { |file| write_target(file, "{}") }
      result = assess(node_selection(manager: input))
      commands = node_commands(result)
      expected ? assert_equal([[expected, "run", "test"]], commands.map { |item| item["argv"] }, cases.inspect) : assert_empty(commands)
      assert_equal "ready", result.dig("composition", "status"), "provider findings must not fabricate composer conflicts"
      assert_includes finding_ids(result), "node-npm-lockfile-coexistence" if locks.size == 2 && locks.all? { |file| file.include?("json") }
    end
  end

  def test_supported_corepack_declarations_and_unsupported_forms
    ["yarn@3.2.3+sha224.#{"a" * 56}", "pnpm@10.0.0-rc.1", "npm@^10.0.0", "npm@latest"].each do |declaration|
      package({"packageManager" => declaration, "scripts" => {"test" => "node --test"}})
      assert_equal 1, node_commands.size, declaration
      assert_includes assess(node_selection)["evidence"].map { |item| item["summary"] }.join, declaration.split("@", 2).last
    end
    ["npm", "npm@", "npm@https://example.invalid/tool.js", "bun@1", {}, 1, "yarn@4\n", "npm@1.", "npm@1..0", "yarn@4+sha224.abc", "npm@^", "pnpm@01.0.0"].each do |declaration|
      package({"packageManager" => declaration, "scripts" => {"test" => "node --test"}})
      result = assess(node_selection(manager: "npm"))
      assert_empty node_commands(result)
      assert_includes finding_ids(result), "node-manager-unsupported"
    end
  end

  def test_every_script_mapping_and_profile_without_duplicate_typecheck
    definitions = {"test" => "node --test", "test:unit" => "vitest run", "test:e2e" => "playwright test", "lint" => "eslint .",
                   "format:check" => "prettier --check .", "typecheck" => "tsc --noEmit", "type-check" => "tsc --noEmit",
                   "build" => "tsc", "verify" => "npm run test", "check" => "vitest run", "validate" => "tsc", "format" => "prettier --write ."}
    %w[npm yarn pnpm].each do |manager|
      package({"packageManager" => "#{manager}@1.0.0", "scripts" => definitions})
      result = assess(node_selection)
      commands = node_commands(result)
      assert_equal %w[node-build node-format-check node-lint node-test node-test-e2e node-test-unit node-typecheck node-verify], commands.map { |item| item["id"] }.sort
      expected = {"test" => ["standard"], "test_unit" => ["standard"], "test_e2e" => ["extended"], "lint" => %w[fast standard],
                  "format_check" => %w[fast standard], "typecheck" => ["standard"], "build" => ["extended"], "verify" => []}
      commands.each do |command|
        assert_equal [manager, "run"], command["argv"].first(2)
        assert_equal ".", command["scope"]
        assert_equal ".", command["cwd"]
        assert_equal({}, command["env"])
        assert_equal expected.fetch(command["capability"]), command["profiles"].sort
        assert command["provenance"].all? { |origin| origin["adapter_id"] == "node" }
      end
      assert_equal 1, commands.count { |item| item["capability"] == "typecheck" }
      assert_equal "typecheck", commands.find { |item| item["id"] == "node-typecheck" }["argv"].last
      assert_includes finding_ids(result), "node-typecheck-alternative"
      assert_equal 3, result.dig("composition", "contributions", "validation_profiles").size
    end
  end

  def test_placeholder_mutating_missing_and_invalid_scripts
    package({"packageManager" => "npm@10", "scripts" => {"test" => 'echo "Error: no test specified" && exit 1', "lint" => "eslint . --fix",
                                                         "format:check" => "prettier --write .", "build" => "true", "verify" => 3, "typecheck" => ""}})
    result = assess(node_selection)
    assert_empty node_commands(result)
    assert_includes finding_ids(result), "node-script-test-placeholder"
    assert_includes finding_ids(result), "node-script-lint-mutating"
    assert_includes finding_ids(result), "node-scripts-incomplete"
    package({"packageManager" => "npm@10"})
    assert_empty node_commands
  end

  def test_malformed_duplicate_nonobject_and_oversized_manifests
    ["{", "[]", "null", '{"packageManager":"npm@10","packageManager":"yarn@4"}',
      '{"packageManager":"npm@10","scripts":{"test":"node --test","test":"vitest"}}',
      " " * (AgenticDeveloperSetup::Assessment::Inventory::MAX_READ_BYTES + 1)].each do |content|
      write_target("package.json", content)
      result = assess(node_selection(manager: "npm"))
      assert_equal "ambiguous", result["candidates"].first["status"]
      assert_empty node_commands(result)
      assert_includes finding_ids(result), "node-manifest-invalid"
    end
  end

  def test_tool_evidence_without_fabricated_commands_and_strict_tsconfig_options
    package({"devDependencies" => {"typescript" => "5", "eslint" => "9", "prettier" => "3", "jest" => "29", "vitest" => "2"}})
    write_target("tsconfig.json", '{"compilerOptions":{"module":"nodenext","moduleResolution":"nodenext","noEmit":false,"outDir":"artifacts/types"}}')
    write_target("eslint.config.js", 'throw new Error("must not load")')
    write_target(".prettierrc", "{}")
    result = assess(node_selection)
    %w[typescript eslint prettier].each { |tool| assert_includes finding_ids(result), "node-#{tool}-script-missing" }
    assert_empty node_commands(result)
    paths = result.dig("composition", "contributions", "paths")
    assert_includes paths.map { |item| item["path"] }, "artifacts/types"
    assert_includes paths.map { |item| item["path"] }, "node_modules"
    refute_includes paths.map { |item| item["path"] }, "dist"
    assert paths.none? { |item| item.key?("owner") }
    summaries = result["evidence"].map { |item| item["summary"] }.join("\n")
    %w[typescript eslint prettier jest vitest].each { |tool| assert_includes summaries, "#{tool} dependency declared" }
    assert_includes summaries, "moduleResolution declares nodenext"
    write_target("tsconfig.json", '{/* JSONC is deferred */"compilerOptions":{"outDir":"untrusted"}}')
    refute_includes assess(node_selection).dig("composition", "contributions", "paths").map { |item| item["path"] }, "untrusted"
  end

  def test_jest_vitest_node_runner_and_lifecycle_are_observations
    package({"packageManager" => "npm@10", "scripts" => {"test" => "jest", "test:unit" => "vitest run", "test:e2e" => "node --test",
                                                         "postinstall" => "node setup.js", "prepare" => "node prepare.js"}})
    result = assess(node_selection)
    summaries = result["evidence"].map { |item| item["summary"] }.join("\n")
    %w[jest vitest node_test_runner].each { |tool| assert_includes summaries, "#{tool} referenced by a script" }
    assert_includes finding_ids(result), "node-lifecycle-hooks"
    refute_includes JSON.generate(result), "node setup.js"
    refute_includes JSON.generate(result), "node prepare.js"
  end

  def test_node_versions_exact_disagreement_and_ranges_are_not_false_conflicts
    package({"engines" => {"node" => ">=20"}, "volta" => {"node" => "20.1.0"}})
    write_target(".nvmrc", "22.1.0\n")
    write_target(".node-version", "^20 || ^22\n")
    result = assess(node_selection)
    assert_includes finding_ids(result), "node-node-version-disagreement"
    assert_includes finding_ids(result), "node-node-version-uncertain"
    package({"engines" => {"node" => ">=20"}, "volta" => {"node" => "20.1.0"}})
    write_target(".nvmrc", "v20.1.0\n")
    result = assess(node_selection)
    refute_includes finding_ids(result), "node-node-version-disagreement"
    assert_includes finding_ids(result), "node-node-version-uncertain"
  end

  def test_literal_ci_matches_diverges_and_remains_incomplete
    package({"packageManager" => "npm@10", "scripts" => {"test" => "node --test", "lint" => "eslint .", "typecheck" => "tsc --noEmit"}})
    write_target(".nvmrc", "20.1.0")
    write_target(".github/workflows/check.yml", <<~YAML)
      on: push
      jobs:
        check:
          runs-on: ubuntu-latest
          steps:
            - uses: actions/setup-node@v4
              with:
                node-version: '22.1.0'
            - run: npm run test
            - run: yarn run lint --max-warnings 0
            - run: npm run build
            - run: npm run custom
            - run: npm run ${{ matrix.script }}
    YAML
    result = assess(node_selection)
    assert_equal "npm", node_commands(result).first["argv"].first
    ids = finding_ids(result).join(" ")
    %w[ci-manager ci-script-0-matching arguments-differ missing-local ci-only ci-indeterminate ci-absent-typecheck node-version-disagreement].each { |part| assert_includes ids, part }
    assert_equal "ready", result.dig("composition", "status")
    write_target(".github/workflows/check.yml", "jobs:\n  x:\n    steps: []\n    steps: [{run: npm run test}]\n")
    assert finding_ids(assess(node_selection)).any? { |id| id.include?("-incomplete") }
  end

  def test_scope_conflict_and_isolated_workspace_no_parent_policy_import
    package({"packageManager" => "pnpm@9", "workspaces" => {"packages" => ["packages/*"]}, "scripts" => {"test" => "node --test"}})
    write_target("pnpm-lock.yaml", "{}")
    write_target("pnpm-workspace.yaml", "packages:\n  - packages/*\n")
    package({"scripts" => {"lint" => "eslint ."}}, prefix: "packages/web/")
    result = assess(node_selection)
    assert_equal "blocked", result.dig("composition", "status")
    assert_includes codes(result), "scope_conflict"
    assert_includes finding_ids(result), "node-workspaces-declared"
    assert_includes finding_ids(result), "node-pnpm-workspaces"
    scope = {"type" => "workspace", "path" => "packages/web"}
    result = assess(node_selection(scope: scope))
    assert_equal "ready", result.dig("composition", "status")
    assert_empty node_commands(result)
    assert_includes finding_ids(result), "node-workspace-isolation"
    result = assess(node_selection(scope: scope, manager: "yarn"))
    assert_equal [["yarn", "run", "lint"]], node_commands(result).map { |item| item["argv"] }
    assert_equal ["packages/web"], node_commands(result).map { |item| item["cwd"] }
    assert result["evidence"].all? { |item| !item["path"] || item["path"].start_with?("packages/web/") }
    refute_includes JSON.generate(result), "pnpm@9"
  end

  def test_unsafe_scope_symlinks_and_excluded_scope_are_rejected
    f1
    File.symlink(@temporary, File.join(@target, "outside"))
    FileUtils.mkdir_p(File.join(@target, "node_modules"))
    ["outside", "node_modules"].each do |scope|
      assert_raises(A::Error) { assess(node_selection(scope: {"type" => "workspace", "path" => scope})) }
    end
  end

  def test_npm_bare_cli_operations_are_not_promoted_to_matching_scripts
    package({"packageManager" => "npm@10", "scripts" => {"test" => "node --test", "build" => "tsc", "lint" => "eslint ."}})
    write_target(".github/workflows/check.yml", <<~YAML)
      jobs:
        check:
          steps:
            - run: npm test
            - run: npm build
            - run: npm lint
            - run: npm ci
    YAML
    result = assess(node_selection)
    matches = node_findings(result).select { |item| item["id"].end_with?("-matching") }
    assert_equal 1, matches.size
    assert_includes matches.first["summary"], "CI test invocation"
    assert_includes finding_ids(result), "node-ci-absent-build"
    assert_includes finding_ids(result), "node-ci-absent-lint"
  end

  def test_ci_job_working_directories_do_not_leak_into_another_job
    package({"packageManager" => "npm@10", "scripts" => {"test" => "node --test"}})
    write_target(".github/workflows/check.yml", <<~YAML)
      jobs:
        a:
          defaults:
            run:
              working-directory: packages/elsewhere
          steps:
            - run: npm run test
        b:
          steps:
            - run: npm run test
    YAML
    result = assess(node_selection)
    assert finding_ids(result).any? { |id| id.include?("matching") }
    refute_includes finding_ids(result), "node-ci-absent-test"
    assert finding_ids(result).any? { |id| id.include?("ci-indeterminate") }
  end

  def test_yaml_duplicate_alias_deep_and_unsupported_workspace_data_is_controlled
    package({"workspaces" => ["packages/*"]})
    ["packages: [packages/*]\npackages: [apps/*]\n", "packages: &p [packages/*]\nother: *p\n", "packages: " + "[" * 100 + "x" + "]" * 100,
      "packages: 1\n", "---\npackages: [packages/*]\n---\npackages: [apps/*]\n"].each do |raw|
      write_target("pnpm-workspace.yaml", raw)
      result = assess(node_selection)
      item = node_findings(result).find { |finding| finding["id"] == "node-pnpm-workspaces" }
      assert_includes item["summary"], "incomplete or unsupported"
      assert_empty node_commands(result)
    end
    assert_includes finding_ids(assess(node_selection)), "node-workspaces-declared"
  end

  def test_deep_workflow_is_refused_before_generic_yaml_construction
    f1
    write_target(".github/workflows/check.yml", "jobs: " + "[" * 5000 + "x" + "]" * 5000)
    result = assess(node_selection)
    assert_equal "ready", result.dig("composition", "status")
    assert finding_ids(result).any? { |id| id.include?("ci-") && id.end_with?("-incomplete") }
    assert_equal 4, node_commands(result).size
  end

  def test_output_paths_require_explicit_safe_emitting_configuration
    package({})
    ["../outside", "/absolute", ".", "output/../source"].each do |directory|
      write_target("tsconfig.json", JSON.generate({"compilerOptions" => {"outDir" => directory}}))
      assert_equal ["node_modules"], assess(node_selection).dig("composition", "contributions", "paths").map { |item| item["path"] }
    end
    [true, "true", 1].each do |no_emit|
      write_target("tsconfig.json", JSON.generate({"compilerOptions" => {"outDir" => "output", "noEmit" => no_emit}}))
      refute_includes assess(node_selection).dig("composition", "contributions", "paths").map { |item| item["path"] }, "output"
    end
  end

  def test_security_no_execution_network_mutation_or_script_contents_disclosure
    sentinel = File.join(@temporary, "executed")
    credential = "ghp_" + "SyntheticCredential" * 3
    package({"packageManager" => "npm@10", "scripts" => {"test" => "node --test; touch #{sentinel}", "lint" => "eslint . --token=#{credential}"}})
    before = File.binread(File.join(@target, "package.json"))
    reg = registry
    provider = reg.provider(reg.supported.first)
    evidence = AgenticDeveloperSetup::Assessment::Evidence.new
    inventory = AgenticDeveloperSetup::Assessment::Inventory.new(Pathname.new(@target)).discover
    context = A::Context.new(scope: @scope, inventory: inventory, root: Pathname.new(@target), evidence: evidence)
    forbidden = ->(*) { flunk "static provider attempted a subprocess" }
    seams = [[Open3.singleton_class, :capture3], [Kernel, :system], [Kernel, :`], [Process.singleton_class, :spawn],
      [IO.singleton_class, :popen], [Socket.singleton_class, :tcp], [TCPSocket.singleton_class, :new]]
    guarded = lambda do |remaining, &body|
      if remaining.empty?
        body.call
      else
        owner, name = remaining.first
        with_replaced_method(owner, name, forbidden) { guarded.call(remaining.drop(1), &body) }
      end
    end
    guarded.call(seams) do
      provider.detect(context)
      output = provider.contribute(context, inputs: {})
      assert_equal ["node-test"], output["commands"].map { |item| item["id"] }
      refute_includes JSON.generate(output), credential
    end
    result = assess(node_selection)
    refute_includes JSON.generate(result), credential
    refute_includes JSON.generate(result), "touch #{sentinel}"
    refute File.exist?(sentinel)
    assert_equal before, File.binread(File.join(@target, "package.json"))
    assert_equal ["package.json"], Dir.children(@target)
    assert_raises(A::Error) { A::Contributions.tokens!(["sh", "-c", "npm test"]) }
    assert_raises(A::Error) { A::Contributions.tokens!([credential]) }
  end

  def test_recognised_credentials_in_generic_script_and_ci_labels_are_not_disclosed
    credential = "ghp_" + "SyntheticCredential" * 3
    package({"packageManager" => "npm@10", "scripts" => {credential => "jest", "test" => "node --test"}, "engines" => {"node" => credential}})
    write_target(".github/workflows/check.yml", "jobs:\n  x:\n    steps:\n      - run: npm run #{credential}\n")
    result = assess(node_selection)
    refute_includes JSON.generate(result), credential
    assert_equal ["node-test"], node_commands(result).map { |item| item["id"] }
  end

  def test_material_script_changes_change_evidence_and_composition_digest
    package({"packageManager" => "npm@10", "scripts" => {"test" => "node --test"}})
    before = assess(node_selection)
    package({"packageManager" => "npm@10", "scripts" => {"test" => "vitest run"}})
    after = assess(node_selection)
    refute_equal before["evidence"], after["evidence"]
    refute_equal before.dig("composition", "composition_digest"), after.dig("composition", "composition_digest")
  end

  def test_determinism_after_filesystem_creation_order_changes
    f1
    write_target(".nvmrc", "20.1.0")
    first = assess(node_selection)
    files = Dir.glob(File.join(@target, "**/*"), File::FNM_DOTMATCH).select { |file| File.file?(file) }.map { |file| [file, File.binread(file)] }
    files.each { |file, _| File.unlink(file) }
    files.reverse_each { |file, bytes| File.binwrite(file, bytes) }
    assert_equal first, assess(node_selection)
  end
end
