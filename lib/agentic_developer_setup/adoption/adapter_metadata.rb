# frozen_string_literal: true

require_relative "../adapters"

module AgenticDeveloperSetup
  module Adoption
    # Historical metadata is validated without loading its former providers.
    class AdapterMetadata
      def self.validate!(document)
        new(document).validate!
      end

      def initialize(document)
        @document = document
        @state = document.fetch("adapters")
        @scope = document.fetch("scope")
      end

      def validate!
        Adapters::Contracts.plain!(@document)
        check!(@state.dig("source", "revision").match?(REVISION_PATTERN), "source revision")
        check!(@state.dig("source", "catalogue_digest").match?(DIGEST_PATTERN), "catalogue digest")
        check!(@state["composition_digest"].match?(DIGEST_PATTERN), "composition digest")
        selected = @state.fetch("selected")
        categories = selected.map { |item| item["category"] }
        check!(categories.uniq == categories && categories.count("ecosystem") == 1, "adapter category cardinality")
        check!(selected == selected.sort_by { |item| [item["category"], item["id"]] }, "adapter identity ordering")
        identity = {"scope" => @scope, "selected" => selected.map { |item| item.except("selection_source") }}
        check!(Adapters::Contracts.digest(identity) == @state["adapter_set_digest"], "adapter-set digest")
        %w[adopted_at updated_at].each do |key|
          value = @state[key]
          check!(value.match?(DATE_PATTERN) && Date.iso8601(value).iso8601 == value, "adapter calendar date")
        end
        check!(@state["updated_at"] >= @state["adopted_at"], "adapter date order")
        unique!(@state["inputs"], "key")
        @state["inputs"].each do |input|
          Adapters::InputValues.validate_supplied!({input["key"] => input["value"]})
          check!(selected.any? { |item| input["key"].start_with?("#{item["category"]}/#{item["id"]}.") }, "input namespace")
        end
        unique!(@state["resolutions"], "conflict_id")
        unique!(@state["command_bindings"], "command_id")
        @state["command_bindings"].each do |binding|
          Adapters::Contributions.command!(binding, @scope)
          check!(binding["env"].keys.none? { |key| key.match?(/TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|PRIVATE_?KEY|AUTH|COOKIE|(?:API|ACCESS|SIGNING|ENCRYPTION|HMAC|CLIENT|SSH)_?KEY|ASKPASS|(?:\A|_)KEY(?:\z|_)/i) }, "credential-like binding environment")
          binding["provenance"].each do |origin|
            check!(origin["scope"] == @scope && selected.any? { |item| item.values_at("category", "id", "version") == origin.values_at("category", "adapter_id", "adapter_version") }, "binding provenance")
          end
        end
        unique!(@state["reviewed_files"], "component_id")
        unique!(@state["reviewed_files"], "target_path")
        bindings = @state["command_bindings"].map { |item| item["command_id"] }
        @state["reviewed_files"].each do |review|
          check!(review["approved_content_digest"].match?(DIGEST_PATTERN), "reviewed content digest")
          component = @document["components"].find { |item| item["id"] == review["component_id"] }
          check!(component && component["status"] == "active" && component["ownership"] == "specialised" && component["target_path"] == review["target_path"], "reviewed component ownership/mapping")
          check!((review["approved_command_ids"] - bindings).empty?, "reviewed command reference")
          review["source_adapter_provenance"].each do |origin|
            check!(origin["scope"] == @scope, "reviewed provenance scope")
            if review["review_state"] == "current"
              check!(selected.any? { |item| item.values_at("category", "id", "version") == origin.values_at("category", "adapter_id", "adapter_version") }, "current reviewed provenance")
            end
          end
        end
        true
      rescue Date::Error
        raise Adapters::Error, "invalid adapter calendar date"
      end

      private

      def check!(condition, message)
        raise Adapters::Error, "invalid adopted #{message}" unless condition
      end

      def unique!(records, key)
        values = records.map { |item| item[key] }
        check!(values.uniq == values, "duplicate #{key}")
      end
    end
  end
end
