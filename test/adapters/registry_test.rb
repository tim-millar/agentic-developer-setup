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
end
