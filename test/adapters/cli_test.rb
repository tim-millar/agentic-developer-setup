# frozen_string_literal: true

require_relative "support"

class AdapterCLITest < AdapterTest
  def run_cli(*arguments)
    stdout, stderr = StringIO.new, StringIO.new
    status = A::CLI.run(arguments, stdout: stdout, stderr: stderr, framework_root: @framework)
    [stdout.string, stderr.string, status]
  end

  def test_stdout_without_selection
    stdout, stderr, status = run_cli(@target)
    assert_equal 0, status
    assert_empty stderr
    assert_equal "not_selected", YAML.safe_load(stdout).dig("composition", "status")
  end

  def test_explicit_selection_through_cli_and_safe_external_output
    register("ruby", contributions: {"commands" => [command]})
    selection = File.join(@temporary, "selection.yml")
    File.write(selection, YAML.dump(selected(["ecosystem", "ruby"])))
    output = File.join(@temporary, "output.yml")
    stdout, stderr, status = run_cli(@target, "--selection", selection, "--output", output)
    assert_equal 0, status
    assert_empty stdout
    assert_empty stderr
    assert_equal "ready", YAML.safe_load_file(output).dig("composition", "status")
    refute File.exist?(File.join(@target, ".agent-framework"))
  end

  def test_blocked_is_valid_informational_cli_result
    document = conflict_fixture
    selection = File.join(@temporary, "selection.yml")
    File.write(selection, YAML.dump(document))
    stdout, stderr, status = run_cli(@target, "--selection", selection)
    assert_equal 0, status
    assert_empty stderr
    assert_equal "blocked", YAML.safe_load(stdout).dig("composition", "status")
  end

  def test_output_inside_target_rejected
    stdout, stderr, status = run_cli(@target, "--output", File.join(@target, "assessment.yml"))
    assert_equal 1, status
    assert_empty stdout
    assert_match(/outside/, stderr)
    refute File.exist?(File.join(@target, "assessment.yml"))
  end

  def test_symlink_and_parent_alias_outputs_rejected
    File.symlink(@target, File.join(@temporary, "alias"))
    [File.join(@temporary, "alias/output.yml"), File.join(@temporary, "alias/../target/output.yml")].each do |output|
      stdout, stderr, status = run_cli(@target, "--output", output)
      assert_equal 1, status
      assert_empty stdout
      assert_match(/outside/, stderr)
    end
  end

  def test_existing_output_symlink_to_target_rejected
    write_target("protected.yml", "untouched")
    output = File.join(@temporary, "output.yml")
    File.symlink(File.join(@target, "protected.yml"), output)
    _, _, status = run_cli(@target, "--output", output)
    assert_equal 1, status
    assert_equal "untouched", File.read(File.join(@target, "protected.yml"))
  end

  def test_invalid_selection_is_nonzero
    selection = File.join(@temporary, "selection.yml")
    File.write(selection, "schema_version: 99\n")
    stdout, stderr, status = run_cli(@target, "--selection", selection)
    assert_equal 1, status
    assert_empty stdout
    assert_match(/invalid adapter selection/, stderr)
  end

  def test_invalid_registry_is_nonzero
    register("ruby")
    mutate_manifest("ruby") { |manifest| manifest["unknown"] = true }
    stdout, stderr, status = run_cli(@target)
    assert_equal 1, status
    assert_empty stdout
    assert_match(/invalid adapter manifest/, stderr)
  end

  def test_missing_or_extra_arguments_are_nonzero
    assert_equal 1, run_cli.last
    assert_equal 1, run_cli(@target, "extra").last
    assert_equal 1, run_cli(@target, "--unknown").last
  end

  def test_public_script_has_stdlib_only_entrypoint
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts/assess_adapters.rb"), @target)
    assert status.success?, stderr
    assert_equal "adapter_assessment", YAML.safe_load(stdout)["kind"]
    assert_empty stderr
  end

  def test_make_wrapper_is_opt_in_and_generic_assess_is_unchanged
    stdout, stderr, status = Open3.capture3("make", "-n", "assess-adapters", "REPO=#{@target}", chdir: ROOT)
    assert status.success?, stderr
    assert_includes stdout, "scripts/assess_adapters.rb"
    generic, _, status = Open3.capture3("make", "-n", "assess", "REPO=#{@target}", chdir: ROOT)
    assert status.success?
    assert_includes generic, "scripts/assess_repository.rb"
    refute_includes generic, "scripts/assess_adapters.rb"
  end

  def test_credential_selection_never_reaches_provider_outputs_or_target_files
    register("ruby", inputs: [input("ecosystem/ruby.choice", required: false)])
    sentinel = File.join(@temporary, "provider-called")
    install_provider("ruby", contribute: "File.write(#{sentinel.inspect}, 'called'); {}")
    selection = File.join(@temporary, "selection.yml")
    output = File.join(@temporary, "output.yml")
    credentials = ["Bearer synthetic_sensitive_selection", "ghp_" + "SyntheticValue" * 3, "API_TOKEN=synthetic-sensitive-value"]
    credentials.each do |credential|
      document = selected(["ecosystem", "ruby"], inputs: [{"key" => "ecosystem/ruby.choice", "value" => credential}])
      File.write(selection, YAML.dump(document))
      stdout, stderr, status = run_cli(@target, "--selection", selection, "--output", output)
      assert_equal 1, status
      assert_empty stdout
      refute_includes stderr, credential
      refute File.exist?(output)
      refute File.exist?(sentinel)
      assert_empty Dir.children(@target)
    end
  end

  def test_duplicate_yaml_keys_are_rejected_in_all_selection_mappings
    register("ruby")
    command_yaml = YAML.dump(command("repository")).delete_prefix("---\n").lines.map { |line| "      #{line}" }.join
    documents = [
      "schema_version: 1\nschema_version: 1\n",
      "scope:\n  type: repository\n  path: .\n  path: .\n",
      "selected:\n- category: ecosystem\n  id: ruby\n  id: ruby\n",
      "inputs:\n- key: ecosystem/ruby.choice\n  value: ordinary\n  value: synthetic-sensitive-value\n",
      "resolutions:\n- conflict_id: duplicate\n  kind: choose_command\n  kind: override_command\n",
      "resolutions:\n- value:\n    command:\n#{command_yaml}      argv: [other]\n"
    ]
    selection = File.join(@temporary, "selection.yml")
    output = File.join(@temporary, "output.yml")
    documents.each do |yaml|
      File.write(selection, yaml)
      stdout, stderr, status = run_cli(@target, "--selection", selection, "--output", output)
      assert_equal 1, status
      assert_empty stdout
      assert_match(/duplicate/, stderr)
      refute_includes stderr, "synthetic-sensitive-value"
      refute File.exist?(output)
    end
  end

  def test_strict_yaml_rejects_aliases_tags_and_complex_keys_without_echo
    selection = File.join(@temporary, "selection.yml")
    output = File.join(@temporary, "output.yml")
    ["a: &synthetic-sensitive-value [1]\nb: *synthetic-sensitive-value\n",
      "--- !ruby/object:SyntheticSensitiveValue {}\n", "? [synthetic-sensitive-value]\n: value\n",
      "key: [synthetic-sensitive-value\n"].each do |yaml|
      File.write(selection, yaml)
      stdout, stderr, status = run_cli(@target, "--selection", selection, "--output", output)
      assert_equal 1, status
      assert_empty stdout
      refute_match(/synthetic-sensitive|SyntheticSensitive/, stderr)
      refute File.exist?(output)
    end
  end

  def test_provider_failures_do_not_produce_partial_successful_cli_output
    register("ruby")
    selection = File.join(@temporary, "selection.yml")
    File.write(selection, YAML.dump(selected(["ecosystem", "ruby"])))
    output = File.join(@temporary, "output.yml")
    [{source: 'require "missing_synthetic_sensitive_dependency"'}, {source: "class SyntheticSensitive <"},
      {construction: 'raise "synthetic-sensitive-value"'}, {detect: 'raise "synthetic-sensitive-value"'},
      {contribute: 'raise "synthetic-sensitive-value"'}].each do |arguments|
      install_provider("ruby", **arguments)
      stdout, stderr, status = run_cli(@target, "--selection", selection, "--output", output)
      assert_equal 1, status
      assert_empty stdout
      assert_includes stderr, "ecosystem/ruby"
      refute_match(/synthetic-sensitive|synthetic_sensitive|SyntheticSensitive/, stderr)
      refute File.exist?(output)
    end
  end
end
