# frozen_string_literal: true

require "digest"
require "json"
require "yaml"

module AgenticDeveloperSetup
  module Adapters
    module Contracts
      SCHEMA_ROOT = File.expand_path("../../../schemas", __dir__)

      module_function

      def canonical(value)
        case value
        when Hash
          value.keys.sort.to_h { |key| [key, canonical(value.fetch(key))] }
        when Array
          value.map { |item| canonical(item) }
        else
          value
        end
      end

      def digest(value)
        "sha256:#{Digest::SHA256.hexdigest(JSON.generate(canonical(value)))}"
      end

      def order(values)
        values.sort_by { |value| JSON.generate(canonical(value)) }
      end

      def copy(value)
        plain!(value)
        JSON.parse(JSON.generate(value))
      end

      def plain!(value)
        case value
        when Hash
          raise Error, "structured object keys must be strings" unless value.keys.all? { |key| key.is_a?(String) }
          value.each_value { |item| plain!(item) }
        when Array then value.each { |item| plain!(item) }
        when String, Integer, TrueClass, FalseClass, NilClass
          # Plain serialisable contract values.
        else raise Error, "unsupported structured value type: #{value.class}"
        end
      end

      def freeze_tree(value)
        case value
        when Hash then value.each { |key, item|
          freeze_tree(key)
          freeze_tree(item)
        }
        when Array then value.each { |item| freeze_tree(item) }
        end
        value.freeze
      end

      def load_yaml(path)
        YAML.safe_load_file(path, permitted_classes: [], permitted_symbols: [], aliases: false)
      rescue Psych::Exception, SystemCallError => e
        raise Error, "cannot read YAML: #{e.message.lines.first.strip}"
      end

      def validate!(name, value, fragment: nil)
        document = SCHEMAS[name]
        raise Error, "adapter #{name} schema is unavailable" unless document
        schema = fragment ? {"$defs" => document.fetch("$defs"), "$ref" => "#/$defs/#{fragment}"} : document
        errors = Adoption::Schema.new(schema).validate(value)
        raise Error, "invalid adapter #{name}: #{errors.sort.join("; ")}" unless errors.empty?
        value
      end

      def relative!(path)
        valid = path.is_a?(String) && !path.empty? && !path.include?("\0") && !path.include?("\\") &&
          !Pathname.new(path).absolute? && Pathname.new(path).cleanpath.to_s == path &&
          path.split("/").none? { |part| part == ".." || part.empty? }
        raise Error, "unsafe or non-normalised relative path: #{path.inspect}" unless valid
        path
      end

      def contained!(root, relative, directory: false, exists: false)
        relative!(relative)
        path = Pathname.new(root)
        relative.split("/").each do |part|
          path = path.join(part)
          raise Error, "symlink traversal is forbidden: #{relative}" if path.symlink?
        end
        raise Error, "directory does not exist: #{relative}" if directory && !path.directory?
        raise Error, "source file does not exist: #{relative}" if exists && !path.file?
        path
      end

      def scope!(scope, root: nil)
        validate!("selection", scope, fragment: "scope")
        relative!(scope.fetch("path"))
        raise Error, "repository scope path must be ." if scope["type"] == "repository" && scope["path"] != "."
        raise Error, "workspace scope must name a directory" if scope["type"] == "workspace" && scope["path"] == "."
        if scope["path"].split("/").any? { |part| Assessment::Inventory::EXCLUDED_DIRECTORIES.include?(part.downcase) }
          raise Error, "selected scope is excluded from bounded inventory"
        end
        contained!(root, scope["path"], directory: true) if root
        scope
      end

      def scoped_path!(path, scope)
        relative!(path)
        prefix = scope.fetch("path")
        unless prefix == "." || path == prefix || path.start_with?("#{prefix}/")
          raise Error, "path is outside selected scope: #{path}"
        end
        path
      end

      # Load immutable framework-owned contracts once. Pure composition never
      # performs filesystem I/O; partial catalogue-only fixtures need no schemas.
      SCHEMAS = freeze_tree(%w[manifest selection assessment].filter_map do |name|
        path = File.join(SCHEMA_ROOT, "adapter-#{name}-v1.schema.json")
        [name, JSON.parse(File.binread(path))] if File.file?(path)
      end.to_h)
    end
  end
end
