# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    class Context
      class InventoryView
        attr_reader :files

        def initialize(inventory, scope, root)
          @inventory, @scope, @root = inventory, scope, root
          @mapping = inventory.files.keys.to_h do |path|
            relative = (scope["path"] == ".") ? path : "#{scope["path"]}/#{path}"
            [relative, path]
          end
          @files = @mapping.keys.sort.freeze
          freeze
        end

        def read(path)
          local = @mapping[path]
          return nil unless local
          Contracts.contained!(@root, path, exists: true)
          @inventory.read(local)
        rescue Error
          nil
        end

        def exists?(path)
          files.include?(path) && !read(path).nil?
        end
      end

      attr_reader :scope, :inventory, :selected, :inputs

      def initialize(scope:, inventory:, root:, evidence:, selected: [], inputs: {})
        @scope = Contracts.freeze_tree(Contracts.copy(scope))
        @inventory = InventoryView.new(inventory, scope, root)
        @evidence = evidence
        @selected = Contracts.freeze_tree(Contracts.copy(selected))
        @inputs = Contracts.freeze_tree(Contracts.copy(inputs))
      end

      def generic_evidence
        records = @evidence.materialize.map do |record|
          record.merge("id" => self.class.evidence_id(record))
        end
        Contracts.freeze_tree(Contracts.copy(records))
      end

      def self.evidence_id(record)
        "E-#{Digest::SHA256.hexdigest([record["type"], record["path"], record["method"], record["summary"]].join("\0"))}"
      end

      def add_evidence(type:, method:, summary:, path: nil)
        Contracts.scoped_path!(path, scope) if path
        if path && !inventory.files.include?(path)
          raise Error, "evidence path is outside bounded inventory: #{path}"
        end
        "E-#{@evidence.add(type: type, method: method, summary: summary, path: path)}"
      end
    end
  end
end
