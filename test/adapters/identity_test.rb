# frozen_string_literal: true

require_relative "support"

class AdapterIdentityTest < AdapterTest
  def test_reordered_equivalent_contributions_and_selection_have_equal_digests
    register("ruby", contributions: {"commands" => [command("ruby-lint", capability: "lint", argv: %w[lint]), command]})
    register("rails", "framework", contributions: {"commands" => [refinement]})
    reg = registry
    set = A::Contributions.empty
    reg.supported.each do |entry|
      context = Object.new
      reg.provider(entry).contribute(context, inputs: {}).each do |domain, records|
        set[domain].concat(records.map { |item| item.merge("provenance" => [entry.provenance(item["id"], @scope)]) })
      end
    end
    first = pure_compose(set)
    reversed = set.to_a.reverse.to_h.transform_values(&:reverse)
    second = A::Composer.new(definitions: reg.supported.reverse, scope: @scope.to_a.reverse.to_h, contributions: reversed).compose
    assert_equal first.dig("composition", "adapter_set_digest"), second.dig("composition", "adapter_set_digest")
    assert_equal first.dig("composition", "composition_digest"), second.dig("composition", "composition_digest")
    assert_equal first, second
  end

  def test_profile_and_input_collection_order_does_not_change_digest
    register("ruby", inputs: [input("ecosystem/ruby.one"), input("ecosystem/ruby.two")], contributions: {"commands" => [command(profiles: %w[standard fast])]})
    set = stamped("commands", [command(profiles: %w[standard fast])])
    first = pure_compose(set, inputs: {"ecosystem/ruby.one" => "one", "ecosystem/ruby.two" => "two"})
    set["commands"][0]["profiles"].reverse!
    second = pure_compose(set, inputs: {"ecosystem/ruby.two" => "two", "ecosystem/ruby.one" => "one"})
    assert_equal first.dig("composition", "composition_digest"), second.dig("composition", "composition_digest")
  end

  def test_version_manifest_provider_changes_and_missing_comparison
    register("ruby")
    original = registry.supported.first.to_h
    document = selected(["ecosystem", "ruby"])
    digest = assess(document).dig("composition", "adapter_set_digest")
    assert_equal "unchanged", registry.compare(original)
    mutate_manifest("ruby") { |manifest| manifest["version"] = "1.1.0" }
    assert_equal "changed", registry.compare(original)
    refute_equal digest, assess(document).dig("composition", "adapter_set_digest")
    changed = registry.supported.first.to_h
    mutate_manifest("ruby") { |manifest| manifest["description"] = "Updated synthetic manifest description" }
    assert_equal "changed", registry.compare(changed)
    current = registry.supported.first.to_h
    current_digest = assess(document).dig("composition", "adapter_set_digest")
    File.open(File.join(@framework, "adapters/ecosystems/ruby/adapter.rb"), "a") { |file| file.puts "# Provider changed" }
    assert_equal "changed", registry.compare(current)
    refute_equal current_digest, assess(document).dig("composition", "adapter_set_digest")
    @metadata["adapters"]["available"][0]["status"] = "planned"
    save_catalogue
    assert_equal "missing", registry.compare(original)
    @metadata["adapters"]["available"] = []
    save_catalogue
    assert_equal "missing", registry.compare(original)
  end

  def test_fingerprints_exclude_absolute_target_location
    register("ruby", contributions: {"commands" => [command]})
    document = selected(["ecosystem", "ruby"])
    first = assess(document)
    different = File.join(@temporary, "different")
    FileUtils.mkdir_p(different)
    second = A::Assessor.new(target: different, framework_root: @framework, selection: document).assess
    assert_equal first["composition"], second["composition"]
  end

  def test_conflict_id_ignores_selection_order
    document = conflict_fixture
    first = assess(document)
    document["selected"].reverse!
    second = assess(document)
    assert_equal first["conflicts"].map { |item| item["id"] }, second["conflicts"].map { |item| item["id"] }
  end

  def test_resolutions_change_composition_identity
    document = conflict_fixture
    blocked = assess(document)
    document["resolutions"] = [decision(blocked, "choose_command", {"contribution_id" => "ruby-test"})]
    ready = assess(document)
    assert_equal blocked.dig("composition", "adapter_set_digest"), ready.dig("composition", "adapter_set_digest")
    refute_equal blocked.dig("composition", "composition_digest"), ready.dig("composition", "composition_digest")
  end
end
