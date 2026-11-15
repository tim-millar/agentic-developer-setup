# frozen_string_literal: true

require_relative "support"

# Independently authored disposable fixtures: never install or execute them.
module PublicNodeFixture
  def install_node
    @metadata["adapters"]["available"] = YAML.safe_load_file(File.join(AdapterTest::ROOT, "framework.yml")).fetch("adapters").fetch("available")
    save_catalogue
    FileUtils.mkdir_p(File.join(@framework, "adapters/ecosystems"))
    FileUtils.cp_r(File.join(AdapterTest::ROOT, "adapters/ecosystems/node"), File.join(@framework, "adapters/ecosystems"))
  end

  def node_selection(manager: nil, scope: @scope)
    inputs = manager ? [{"key" => "ecosystem/node.package_manager", "value" => manager}] : []
    selected(["ecosystem", "node"], inputs: inputs, scope: scope)
  end

  def package(data = {}, prefix: "")
    write_target("#{prefix}package.json", JSON.generate(data))
  end

  def f1
    package({"name" => "public-synthetic", "packageManager" => "npm@10.9.0", "engines" => {"node" => ">=20"},
             "scripts" => {"test" => "node --test", "lint" => "eslint .", "typecheck" => "tsc --noEmit", "build" => "tsc"},
             "devDependencies" => {"typescript" => "5.0.0", "eslint" => "9.0.0"}})
    write_target("package-lock.json", '{"lockfileVersion":3}')
    write_target("tsconfig.json", '{"compilerOptions":{"outDir":"lib","module":"nodenext","moduleResolution":"nodenext","noEmit":false}}')
  end

  def node_commands(result = assess(node_selection))
    result.dig("composition", "commands")
  end

  def node_findings(result)
    result.dig("composition", "contributions", "findings")
  end

  def finding_ids(result)
    node_findings(result).map { |item| item["id"] }
  end
end
