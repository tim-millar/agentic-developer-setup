# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "stringio"
require_relative "../../lib/agentic_developer_setup/adapters"

class AdapterTest < Minitest::Test
  A = AgenticDeveloperSetup::Adapters
  ROOT = File.expand_path("../..", __dir__)
  FIXTURE = File.join(__dir__, "fixtures")

  def setup
    @temporary = Dir.mktmpdir("ads-adapters-")
    @framework = File.join(@temporary, "framework")
    @target = File.join(@temporary, "target")
    FileUtils.mkdir_p([@framework, @target])
    @metadata = YAML.safe_load_file(File.join(ROOT, "framework.yml"))
    @metadata["adapters"]["available"] = []
    save_catalogue
    @scope = {"type" => "repository", "path" => "."}
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary)
  end

  def save_catalogue
    File.write(File.join(@framework, "framework.yml"), YAML.dump(@metadata))
  end

  def register(id, category = "ecosystem", requires: [], incompatible: [], inputs: [], contributions: {}, marker: nil, version: "1.0.0", status: "supported")
    path = A::CATEGORIES.fetch(category).sub("<name>", id)
    @metadata["adapters"]["available"] << {"name" => id, "type" => category, "path" => path, "status" => status}
    save_catalogue
    return if status == "planned"
    directory = File.join(@framework, path)
    FileUtils.mkdir_p(directory)
    manifest = {"schema_version" => 1, "id" => id, "category" => category, "version" => version,
                "description" => "Synthetic #{id} test adapter; not production support.",
                "capabilities" => ["test"], "detection_signals" => ["static_configuration"], "contribution_domains" => A::DOMAINS,
                "compatibility" => {"requires" => requires, "incompatible" => incompatible}, "inputs" => inputs,
                "provider" => {"file" => "adapter.rb", "constant" => "AgenticDeveloperSetup::Adapters::Providers::Synthetic"}}
    File.write(File.join(directory, "adapter.yml"), YAML.dump(manifest))
    # Actual Ruby providers in a synthetic framework, exercised by Registry.
    source = File.read(File.join(FIXTURE, "provider.rb.template"))
      .sub("__IDENTITY__", {"category" => category, "id" => id}.inspect)
      .sub("__MARKER__", marker.inspect).sub("__CONTRIBUTIONS__", contributions.inspect)
    File.write(File.join(directory, "adapter.rb"), source)
  end

  def mutate_manifest(id)
    entry = @metadata["adapters"]["available"].find { |item| item["name"] == id }
    path = File.join(@framework, entry["path"], "adapter.yml")
    manifest = YAML.safe_load_file(path)
    yield manifest
    File.write(path, YAML.dump(manifest))
  end

  def registry
    A::Registry.load(framework_root: @framework)
  end

  def selected(*identities, inputs: [], resolutions: [], scope: @scope)
    {"schema_version" => 1, "scope" => scope,
     "selected" => identities.map { |category, id| {"category" => category, "id" => id, "source" => "explicit"} },
     "inputs" => inputs, "resolutions" => resolutions}
  end

  def assess(selection = nil)
    A::Assessor.new(target: @target, framework_root: @framework, selection: selection).assess
  end

  def command(id = "ruby-test", capability: "test", argv: %w[bundle exec rspec], cwd: ".", **extra)
    {"id" => id, "kind" => "base", "capability" => capability, "scope" => @scope["path"], "argv" => argv, "cwd" => cwd,
     "env" => {}, "profiles" => ["standard"], "preconditions" => [], "classification" => ["automated_test"]}.merge(extra.transform_keys(&:to_s))
  end

  def refinement(id = "rails-refinement", command_id: "ruby-test")
    {"id" => id, "kind" => "refinement", "command_id" => command_id, "profiles" => ["extended"],
     "preconditions" => ["migration review"], "classification" => ["integration_test"]}
  end

  def wrapper(id = "docker-test", command_id: "ruby-test", prefix: %w[docker compose run --rm app], **extra)
    {"id" => id, "command_id" => command_id, "prefix_argv" => prefix, "suffix_argv" => []}.merge(extra.transform_keys(&:to_s))
  end

  def path(id, name = "db", owner: nil, classifications: ["protected"], recursive: true)
    {"id" => id, "path" => name, "recursive" => recursive, "classifications" => classifications, "owner" => owner}
  end

  def input(key = "runtime/docker.service", type: "string", required: true, **extra)
    {"key" => key, "type" => type, "required" => required, "description" => "Explicit non-secret test input"}.merge(extra.transform_keys(&:to_s))
  end

  def requirement(category, *ids, version: nil)
    {"category" => category, "one_of" => ids}.tap { |item| item["version"] = version if version }
  end

  def write_target(path, content = "static fixture\n")
    destination = File.join(@target, path)
    FileUtils.mkdir_p(File.dirname(destination))
    File.write(destination, content)
  end

  def codes(result)
    result["conflicts"].map { |item| item["code"] }
  end

  def decision(result, kind, value, code: "incompatible_command_proposals")
    {"conflict_id" => result["conflicts"].find { |item| item["code"] == code }.fetch("id"),
     "kind" => kind, "value" => value, "rationale" => "Repository owner explicitly selected this recommendation."}
  end

  def conflict_fixture
    register("ruby", contributions: {"commands" => [command]})
    register("rails", "framework", contributions: {"commands" => [command("rails-test", argv: %w[bin rails test])]})
    selected(["ecosystem", "ruby"], ["framework", "rails"])
  end

  def pure_compose(set, inputs: {}, resolutions: [])
    A::Composer.new(definitions: registry.supported, scope: @scope, contributions: set,
      component_ids: @metadata["baseline"].values_at("required", "recommended").flatten.map { |item| item["name"] },
      inputs: inputs, resolutions: resolutions).compose
  end

  def stamped(domain, records, id: "ruby")
    definition = registry.supported.find { |item| item.id == id }
    A::Contributions.empty.merge(domain => records.map { |item| item.merge("provenance" => [definition.provenance(item["id"], @scope)]) })
  end

  def install_provider(id, detect: "[]", contribute: "{}", construction: "", source: nil)
    entry = @metadata["adapters"]["available"].find { |item| item["name"] == id }
    identity = {"category" => entry.fetch("type"), "id" => id}
    code = source || <<~PROVIDER
      module AgenticDeveloperSetup
        module Adapters
          module Providers
            class Synthetic
              IDENTITY = #{identity.inspect}.freeze
              def initialize
                #{construction}
              end
              def detect(context)
                #{detect}
              end
              def contribute(context, inputs:)
                #{contribute}
              end
            end
          end
        end
      end
    PROVIDER
    File.write(File.join(@framework, entry.fetch("path"), "adapter.rb"), code)
  end

  def provider_workspace_detection
    <<~PROVIDER
      context.inventory.files.select { |path| File.basename(path) == "Makefile" }.map do |path|
        root = File.dirname(path)
        scope = {"type" => root == "." ? "repository" : "workspace", "path" => root}
        status = context.inventory.read(path).strip
        evidence = status == "not_detected" ? [] : [context.add_evidence(type: "configuration", method: "synthetic_project", path: path, summary: "Synthetic project configuration")]
        IDENTITY.merge("scope" => scope, "status" => status, "confidence" => "high",
          "evidence" => evidence, "ambiguities" => status == "ambiguous" ? evidence : [], "incompatible_evidence" => [])
      end
    PROVIDER
  end
end
