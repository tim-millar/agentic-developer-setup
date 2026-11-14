# frozen_string_literal: true

require_relative "support"

class AdapterRegistryTest < AdapterTest
  def test_production_planned_adapters_remain_unimplemented
    live = A::Registry.load(framework_root: ROOT)
    assert_equal 6, live.entries.size
    assert_empty live.supported
    assert live.entries.all? { |entry| entry.status == "planned" && entry.version.nil? && entry.manifest_digest.nil? && entry.provider_digest.nil? }
  end

  def test_definition_is_immutable_and_serialisable
    register("ruby")
    entry = registry.fetch(category: "ecosystem", id: "ruby")
    assert entry.frozen?
    assert entry.capabilities.frozen?
    assert_raises(FrozenError) { entry.capabilities << "bad" }
    assert_equal entry.to_h, YAML.safe_load(YAML.dump(entry.to_h))
    assert_match(/\Asha256:[a-f0-9]{64}\z/, entry.provider_digest)
    assert_nil registry.fetch(category: "framework", id: "missing")
  end

  def test_entries_have_deterministic_order
    register("zeta")
    register("alpha")
    assert_equal %w[alpha zeta], registry.entries.map(&:id)
  end

  def test_supported_directory_required
    register("ruby", status: "planned")
    @metadata["adapters"]["available"][0]["status"] = "supported"
    save_catalogue
    assert_match(/directory does not exist/, assert_raises(A::Error) { registry }.message)
  end

  def test_manifest_and_provider_required
    register("ruby")
    %w[adapter.yml adapter.rb].each do |name|
      location = File.join(@framework, "adapters/ecosystems/ruby", name)
      content = File.binread(location)
      File.unlink(location)
      assert_raises(A::Error) { registry }
      File.binwrite(location, content)
    end
  end

  def test_duplicate_identity_rejected
    register("ruby")
    @metadata["adapters"]["available"] << @metadata["adapters"]["available"].first.dup
    save_catalogue
    assert_raises(A::Error) { registry }
  end

  def test_unknown_category_rejected
    register("ruby")
    @metadata["adapters"]["available"][0]["type"] = "environment"
    save_catalogue
    assert_raises(A::Error) { registry }
  end

  def test_taxonomy_cannot_add_noncanonical_categories
    @metadata["adapters"]["taxonomy"].last["type"] = "environment"
    save_catalogue
    assert_raises(A::Error) { registry }
  end

  {"schema_version" => 2, "id" => "other", "category" => "framework", "unknown" => true,
   "version" => "1.0", "capabilities" => [""], "detection_signals" => ["duplicate", "duplicate"],
   "contribution_domains" => ["shell"]}.each do |key, value|
    define_method("test_manifest_rejects_#{key}") do
      register("ruby")
      mutate_manifest("ruby") { |manifest| manifest[key] = value }
      assert_raises(A::Error) { registry }
    end
  end

  def test_semver_prerelease_and_build
    register("ruby", version: "1.2.3-rc.1+build.42")
    assert_equal "1.2.3-rc.1+build.42", registry.supported.first.version
    assert A::Registry.requirement(">= 1.0.0, < 2.0").satisfied_by?(A::Registry.version("1.2.3+build.1"))
  end

  def test_missing_dependency_reference
    register("rails", "framework", requires: [requirement("ecosystem", "ruby")])
    assert_match(/missing compatibility reference/, assert_raises(A::Error) { registry }.message)
  end

  def test_planned_dependency_is_valid_metadata
    register("ruby", status: "planned")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby")])
    assert_equal ["rails"], registry.supported.map(&:id)
  end

  def test_invalid_version_requirement
    register("ruby")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby", version: "nope")])
    assert_raises(A::Error) { registry }
  end

  def test_self_dependency
    register("ruby", requires: [requirement("ecosystem", "ruby")])
    assert_match(/self-dependency/, assert_raises(A::Error) { registry }.message)
  end

  def test_dependency_cycle
    register("ruby", requires: [requirement("framework", "rails")])
    register("rails", "framework", requires: [requirement("ecosystem", "ruby")])
    assert_match(/dependency cycle/, assert_raises(A::Error) { registry }.message)
  end

  def test_satisfiable_dependency_alternative_does_not_create_false_cycle
    register("ruby", requires: [requirement("framework", "rails", "sinatra")])
    register("rails", "framework", requires: [requirement("ecosystem", "ruby")])
    register("sinatra", "framework")
    assert_equal 3, registry.supported.size
  end

  def test_contradictory_constraints
    register("ruby")
    register("rails", "framework", requires: [requirement("ecosystem", "ruby")], incompatible: [requirement("ecosystem", "ruby")])
    assert_match(/contradictory/, assert_raises(A::Error) { registry }.message)
  end

  def test_duplicate_input_declarations
    declaration = input("ecosystem/ruby.choice")
    register("ruby", inputs: [declaration, declaration])
    assert_raises(A::Error) { registry }
  end

  def test_input_namespace
    register("ruby", inputs: [input("runtime/docker.service")])
    assert_raises(A::Error) { registry }
  end

  def test_provider_interface_mismatch
    register("ruby")
    provider = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    File.write(provider, File.read(provider).sub("def detect(context)", "def detect(context, extra)"))
    reg = registry
    assert_raises(A::Error) { reg.provider(reg.supported.first) }
  end

  def test_provider_change_after_registry_validation_is_rejected
    register("ruby")
    reg = registry
    File.open(File.join(@framework, "adapters/ecosystems/ruby/adapter.rb"), "a") { |file| file.puts "# changed" }
    assert_raises(A::Error) { reg.provider(reg.supported.first) }
  end

  def test_source_escape_and_symlinks
    register("ruby")
    path = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    File.unlink(path)
    File.symlink(File.join(FIXTURE, "provider.rb.template"), path)
    assert_match(/symlink/, assert_raises(A::Error) { registry }.message)
    @metadata["adapters"]["available"][0]["path"] = "../escape"
    save_catalogue
    assert_raises(A::Error) { registry }
  end

  def test_existing_planned_source_symlink_is_rejected_without_requiring_directory
    register("ruby", status: "planned")
    FileUtils.mkdir_p(File.join(@framework, "adapters/ecosystems"))
    File.symlink(@target, File.join(@framework, "adapters/ecosystems/ruby"))
    assert_match(/symlink/, assert_raises(A::Error) { registry }.message)
  end

  def test_manifest_credential_names_defaults_and_allowed_values_are_rejected_without_echo
    register("ruby", inputs: [input("ecosystem/ruby.choice", required: false)])
    names = %w[password passphrase api_key access-key access.token client_secret private_key credentials auth authorization_header session_cookie signing_key encryption.key apiToken clientSecret]
    names.each do |name|
      mutate_manifest("ruby") { |manifest| manifest["inputs"] = [input("ecosystem/ruby.#{name}", required: false)] }
      assert_raises(A::Error, name) { registry }
    end
    credential = "ghp_" + "SyntheticCredential" * 3
    [{"default" => credential}, {"allowed_values" => ["ordinary", credential]}].each do |fields|
      mutate_manifest("ruby") { |manifest| manifest["inputs"] = [input("ecosystem/ruby.choice", required: false).merge(fields)] }
      error = assert_raises(A::Error) { registry }
      refute_includes error.full_message, credential
    end
  end

  def test_manifest_duplicate_mapping_keys_are_rejected_at_every_depth
    register("ruby", inputs: [input("ecosystem/ruby.choice", required: false)])
    manifest = File.join(@framework, "adapters/ecosystems/ruby/adapter.yml")
    original = File.read(manifest)
    invalid = [original + "schema_version: 1\n",
      original.sub("  requires: []", "  requires: []\n  requires: []"),
      original.sub("  requires: []", "  requires:\n  - category: ecosystem\n    category: ecosystem\n    one_of: [ruby]"),
      original.sub("  type: string", "  type: string\n  type: string")]
    invalid.each do |yaml|
      refute_equal original, yaml
      File.write(manifest, yaml)
      assert_match(/duplicate/, assert_raises(A::Error) { registry }.message)
    end
  end

  def test_provider_loading_failures_are_sanitised_and_identify_phase
    register("ruby")
    cases = [
      ["source evaluation", {source: 'require "missing_synthetic_sensitive_dependency_12345"'}],
      ["source evaluation", {source: "class SyntheticSensitiveSyntax <"}],
      ["source evaluation", {source: 'raise "synthetic-sensitive-source-value"'}],
      ["constant resolution", {source: "module EmptySyntheticProvider; end"}],
      ["construction", {construction: 'raise "synthetic-sensitive-constructor-value"'}]
    ]
    cases.each do |phase, arguments|
      install_provider("ruby", **arguments)
      reg = registry
      error = assert_raises(A::Error) { reg.provider(reg.supported.first) }
      assert_includes error.message, "ecosystem/ruby"
      assert_includes error.message, phase
      refute_match(/sensitive|12345|SyntheticSensitive/, error.full_message)
      assert_nil error.cause
    end
  end

  def test_provider_boundary_preserves_critical_failures
    register("ruby")
    %w[SystemExit Interrupt NoMemoryError].each do |name|
      install_provider("ruby", construction: "raise #{name}")
      reg = registry
      assert_raises(Object.const_get(name)) { reg.provider(reg.supported.first) }
    end
  end

  def test_manifest_parse_and_digest_use_one_immutable_read
    register("ruby")
    path = File.join(@framework, "adapters/ecosystems/ruby/adapter.yml")
    original_bytes = File.binread(path)
    alternate = YAML.safe_load(original_bytes).merge("version" => "9.0.0")
    reads = 0
    around = lambda do |original, file, *args, **kwargs|
      bytes = original.call(file, *args, **kwargs)
      if File.realpath(file) == File.realpath(path)
        reads += 1
        File.binwrite(path, (reads == 1) ? YAML.dump(alternate) : original_bytes)
      end
      bytes
    end
    with_replaced_method(File.singleton_class, :binread, around) do
      definition = registry.supported.first
      assert_equal "1.0.0", definition.version
      assert_equal "sha256:#{Digest::SHA256.hexdigest(original_bytes)}", definition.manifest_digest
      assert_equal 1, reads
    end
  end

  def test_catalogue_snapshot_and_definitions_are_immutable
    register("ruby")
    bytes = File.binread(File.join(@framework, "framework.yml"))
    reg = registry
    assert reg.frozen?
    assert_equal File.realpath(@framework), reg.framework_root.to_s
    assert_equal "sha256:#{Digest::SHA256.hexdigest(bytes)}", reg.catalogue_digest
    assert_raises(FrozenError) { reg.catalogue.data["adapters"]["available"].clear }
    assert_raises(FrozenError) { reg.catalogue.components.clear }
  end

  def test_provider_evaluates_the_exact_string_whose_digest_was_checked
    register("ruby")
    reg = registry
    path = File.join(@framework, "adapters/ecosystems/ruby/adapter.rb")
    sentinel = File.join(@temporary, "replacement-provider-evaluated")
    replacement = "File.write(#{sentinel.inspect}, 'unverified')\n" + File.binread(path)
    reads = 0
    around = lambda do |original, file, *args, **kwargs|
      source = original.call(file, *args, **kwargs)
      if File.realpath(file) == File.realpath(path)
        reads += 1
        File.binwrite(path, replacement)
      end
      source
    end
    with_replaced_method(File.singleton_class, :binread, around) do
      assert reg.provider(reg.supported.first).respond_to?(:detect)
      assert_equal 1, reads
      refute File.exist?(sentinel)
    end
  end
end
