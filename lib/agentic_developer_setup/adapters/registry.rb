# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    class Definition
      FIELDS = %w[id category version status source_path manifest_digest provider_digest capabilities contribution_domains compatibility input_definitions].freeze
      attr_reader :manifest
      FIELDS.each { |field| define_method(field) { @data[field] } }

      def initialize(data, manifest: nil)
        @data = Contracts.freeze_tree(data)
        @manifest = Contracts.freeze_tree(manifest)
        freeze
      end

      def to_h
        Contracts.copy(@data)
      end

      def identity
        {"category" => category, "id" => id}
      end

      def provenance(contribution_id, scope)
        {"category" => category, "adapter_id" => id, "adapter_version" => version,
         "contribution_id" => contribution_id, "scope" => scope}
      end
    end

    class Registry
      attr_reader :entries, :catalogue

      def self.load(framework_root:)
        new(framework_root)
      end

      def initialize(root)
        @root = Pathname.new(root).realpath
        Contracts.contained!(@root, "framework.yml", exists: true)
        @catalogue = Assessment::Catalogue.new(@root)
        errors = FrameworkCatalogue.document_errors(@root, @catalogue.data)
        raise Error, errors.sort.join("; ") unless errors.empty?
        taxonomy = @catalogue.data.fetch("adapters").fetch("taxonomy")
        unless taxonomy.all? { |item| CATEGORIES[item["type"]] == item["path_pattern"] }
          raise Error, "adapter taxonomy must use canonical categories and paths"
        end
        @entries = @catalogue.data.fetch("adapters").fetch("available").map { |entry| definition(entry) }
          .sort_by { |entry| [entry.category, entry.id] }.freeze
        validate_dependencies!
      rescue SystemCallError => e
        raise Error, "cannot load adapter registry: #{e.message.lines.first.strip}"
      end

      def fetch(category:, id:)
        entries.find { |entry| entry.category == category && entry.id == id }
      end

      def supported
        entries.select { |entry| entry.status == "supported" }.freeze
      end

      def provider(definition)
        raise Error, "unsupported adapter: #{definition.id}" unless supported.include?(definition)
        path = Contracts.contained!(@root, "#{definition.source_path}/adapter.rb", exists: true)
        source = File.binread(path)
        unless "sha256:#{Digest::SHA256.hexdigest(source)}" == definition.provider_digest
          raise Error, "provider changed after registry validation: #{definition.id}"
        end
        # A private namespace prevents fixture or independently loaded registry
        # constants from replacing another registry's provider. This is not a sandbox.
        namespace = Module.new
        outer = Module.new
        adapters = Module.new
        outer.define_singleton_method(:const_missing) { |name| ::AgenticDeveloperSetup.const_get(name, false) }
        adapters.define_singleton_method(:const_missing) { |name| ::AgenticDeveloperSetup::Adapters.const_get(name, false) }
        namespace.const_set(:AgenticDeveloperSetup, outer)
        outer.const_set(:Adapters, adapters)
        adapters.const_set(:Providers, Module.new)
        namespace.module_eval(source, path.to_s, 1)
        provider_class = definition.manifest.fetch("provider").fetch("constant").split("::").reduce(namespace) do |parent, name|
          parent.const_get(name, false)
        end
        instance = provider_class.new
        unless instance.respond_to?(:detect) && instance.respond_to?(:contribute) && instance.method(:detect).arity == 1 &&
            instance.method(:contribute).parameters.include?([:keyreq, :inputs]) && instance.method(:contribute).parameters.count { |type, _| [:req, :opt].include?(type) } == 1
          raise Error, "provider must implement detect(context) and contribute(context, inputs:)"
        end
        instance
      rescue NameError, TypeError, ArgumentError, SyntaxError => e
        raise Error, "invalid provider #{definition.id}: #{e.message.lines.first.strip}"
      end

      # Pure comparison against this already validated local registry.
      def compare(record)
        required = %w[category id version manifest_digest provider_digest]
        unless record.is_a?(Hash) && required.all? { |key| record[key].is_a?(String) }
          raise Error, "recorded adapter identity is malformed"
        end
        Contracts.validate!("assessment", record.slice(*required), fragment: "recorded_identity")
        entry = fetch(category: record["category"], id: record["id"])
        return "missing" unless entry && entry.status == "supported"
        (required.all? { |key| entry.to_h[key] == record[key] }) ? "unchanged" : "changed"
      end

      def self.version(value)
        Gem::Version.new(value.split("+", 2).first)
      end

      def self.requirement(value)
        Gem::Requirement.new(*(value || ">= 0").split(",").map(&:strip))
      rescue ArgumentError => e
        raise Error, "invalid adapter version requirement: #{e.message}"
      end

      # A requirement is a conjunction of RubyGems comparisons. Check ranges
      # algebraically, including pessimistic bounds and exact exclusions.
      def self.atoms(requirement)
        requirement.requirements.flat_map do |operator, version|
          (operator == "~>") ? [[">=", version], ["<", version.bump]] : [[operator, version]]
        end
      end

      def self.satisfiable?(comparisons)
        lower = [Gem::Version.new("0"), true]
        upper = nil
        exact = comparisons.filter_map { |operator, version| version if operator == "=" }.uniq
        return false if exact.size > 1
        if exact.one?
          return comparisons.all? { |operator, version| Gem::Requirement.new("#{operator} #{version}").satisfied_by?(exact.first) }
        end
        comparisons.each do |operator, version|
          if %w[> >=].include?(operator)
            inclusive = operator == ">="
            lower = [version, inclusive] if version > lower[0] || (version == lower[0] && !inclusive)
          elsif %w[< <=].include?(operator)
            inclusive = operator == "<="
            upper = [version, inclusive] if upper.nil? || version < upper[0] || (version == upper[0] && !inclusive)
          end
        end
        return true unless upper
        return false if lower[0] > upper[0]
        return true if lower[0] < upper[0]
        lower[1] && upper[1] && comparisons.none? { |operator, version| operator == "!=" && version == lower[0] }
      end

      def self.compatible_ranges?(required, forbidden)
        ranges = [required.flat_map { |item| atoms(requirement(item["version"])) }]
        inverse = {">" => "<=", ">=" => "<", "<" => ">=", "<=" => ">", "=" => "!=", "!=" => "="}
        forbidden.each do |item|
          alternatives = atoms(requirement(item["version"])).map { |operator, version| [inverse.fetch(operator), version] }
          ranges = ranges.flat_map { |range| alternatives.map { |atom| range + [atom] } }.select { |range| satisfiable?(range) }
          return false if ranges.empty?
        end
        ranges.any? { |range| satisfiable?(range) }
      end

      private

      def definition(entry)
        id, category, source, status = entry.values_at("name", "type", "path", "status")
        raise Error, "invalid adapter ID: #{id}" unless /\A[a-z][a-z0-9-]*\z/.match?(id)
        Contracts.relative!(source)
        base = {"id" => id, "category" => category, "status" => status, "source_path" => source}
        return Definition.new(base) if status == "planned"

        Contracts.contained!(@root, source, directory: true)
        manifest_path = Contracts.contained!(@root, "#{source}/adapter.yml", exists: true)
        provider_path = Contracts.contained!(@root, "#{source}/adapter.rb", exists: true)
        bytes = File.binread(manifest_path)
        manifest = Contracts.load_yaml(manifest_path)
        Contracts.validate!("manifest", manifest)
        unless manifest["id"] == id && manifest["category"] == category
          raise Error, "manifest/catalogue identity mismatch: #{category}/#{id}"
        end
        declarations = manifest.fetch("inputs")
        validate_inputs!(declarations, category, id)
        Definition.new(base.merge("version" => manifest["version"],
          "manifest_digest" => "sha256:#{Digest::SHA256.hexdigest(bytes)}",
          "provider_digest" => "sha256:#{Digest::SHA256.file(provider_path).hexdigest}",
          "capabilities" => manifest["capabilities"], "contribution_domains" => manifest["contribution_domains"],
          "compatibility" => manifest["compatibility"], "input_definitions" => declarations), manifest: manifest)
      end

      def validate_inputs!(declarations, category, id)
        keys = declarations.map { |item| item["key"] }
        raise Error, "duplicate adapter input declaration" unless keys.uniq == keys
        declarations.each do |item|
          raise Error, "input key must belong to #{category}/#{id}" unless item["key"].start_with?("#{category}/#{id}.")
          InputValues.validate_declaration!(item)
        end
      end

      def validate_dependencies!
        supported.each do |entry|
          requires = entry.compatibility.fetch("requires")
          incompatible = entry.compatibility.fetch("incompatible")
          (requires + incompatible).each do |constraint|
            parsed = self.class.requirement(constraint["version"])
            unless self.class.satisfiable?(self.class.atoms(parsed))
              raise Error, "contradictory adapter version requirement: #{entry.id}"
            end
            constraint["one_of"].each do |id|
              raise Error, "missing compatibility reference: #{constraint["category"]}/#{id}" unless fetch(category: constraint["category"], id: id)
              if constraint["category"] == entry.category && id == entry.id
                raise Error, "invalid adapter self-dependency: #{entry.id}"
              end
            end
          end
          requires.group_by { |constraint| constraint["category"] }.each do |category, constraints|
            options = constraints.map { |constraint| constraint["one_of"] }.reduce(:&)
            options = options.reject do |id|
              forbidden = incompatible.select { |item| item["category"] == category && item["one_of"].include?(id) }
              !self.class.compatible_ranges?(constraints, forbidden)
            end
            raise Error, "contradictory compatibility constraints: #{entry.id}" if options.empty?
          end
        end
        # Resolve alternatives rather than rejecting a satisfiable OR dependency
        # merely because one of its alternatives contains a cycle.
        pending = supported.dup
        resolved = entries.select { |entry| entry.status == "planned" }.map(&:identity)
        loop do
          ready = pending.select do |entry|
            entry.compatibility["requires"].all? do |constraint|
              constraint["one_of"].any? { |id| resolved.include?({"category" => constraint["category"], "id" => id}) }
            end
          end
          break if ready.empty?
          resolved.concat(ready.map(&:identity))
          pending -= ready
        end
        raise Error, "invalid adapter dependency cycle: #{pending.map(&:id).sort.join(", ")}" unless pending.empty?
      end
    end
  end
end
