# frozen_string_literal: true

require_relative "transaction_context"
require_relative "adapter_transaction"

module AgenticDeveloperSetup
  module Adoption
    class AdapterInspection
      include AdapterSourceVerification

      def initialize(root:, document:)
        @root, @document = root, document
      end

      def inspect(candidate:, selection:)
        state = @document["adapters"]
        raise Assessment::InvocationError, "proposed selection requires an explicit candidate source" if selection && !candidate
        comparison = {"status" => candidate ? "unavailable" : "not_checked", "source" => nil, "selected" => [], "diagnostics" => []}
        proposed = nil
        if candidate
          begin
            source = Pathname.new(candidate).expand_path.realpath
            registry = Adapters::Registry.load(framework_root: source)
            comparison["status"] = "available"
            comparison["source"] = {"root" => source.to_s, "revision" => GitCommand.revision(source), "catalogue_digest" => digest(File.binread(source.join("framework.yml")))}
            comparison["selected"] = state.fetch("selected").map do |item|
              definition = registry.fetch(category: item["category"], id: item["id"])
              {"adopted" => item, "status" => registry.compare(item), "candidate" => definition&.to_h&.slice("category", "id", "version", "manifest_digest", "provider_digest"),
               "changed_fields" => definition ? %w[version manifest_digest provider_digest].select { |key| definition.to_h[key] != item[key] } : []}
            end
          rescue Adapters::Error, TransactionError, SystemCallError => e
            comparison["status"] = "unavailable"
            comparison["selected"] = []
            comparison["diagnostics"] << {"code" => "candidate_unavailable", "message" => e.message}
          end
        end
        if selection && comparison["status"] == "available"
          begin
            # Use the transaction source verifier before the public assessor can execute a provider.
            verify_adapter_sources!(source)
          rescue TransactionError => e
            raise Assessment::InvocationError, "#{e.code}: #{e.message}"
          end
          proposed = Adapters::Assessor.new(target: @root, framework_root: source, selection: Adapters::Contracts.load_yaml(selection)).assess
        end
        {"adopted" => state, "scope" => @document["scope"], "candidate" => comparison,
         "reviewed_files" => state.fetch("reviewed_files", []).map { |item| item.merge("local_state" => local_state(item)) },
         "proposed_assessment" => proposed}
      end

      private

      def local_state(item)
        path = PathSafety.existing(@root, item["target_path"])
        return "unsafe" if path == :unsafe
        return "missing" if path.nil?
        return "unsafe" unless path.file?
        return "modified" unless digest(File.binread(path)) == item["approved_content_digest"] && mode(path) == item["approved_mode"]
        (item["review_state"] == "retained_after_adapter_change") ? "historical_retained" : "in_sync"
      rescue SystemCallError
        "unsafe"
      end
    end
  end
end
