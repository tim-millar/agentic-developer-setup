# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    module InputValues
      module_function

      # This recognises credential channels and high-confidence formats, not
      # every possible secret. No environment, private file or entropy scan.
      def credential_name?(name)
        words = name.gsub(/([A-Z]+)([A-Z][a-z])/, '\\1_\\2')
          .gsub(/([a-z0-9])([A-Z])/, '\\1_\\2').downcase.split(/[^a-z0-9]+/)
        return true if (words & %w[password passwords passphrase passphrases token tokens secret secrets credential credentials apikey apikeys accesskey accesskeys clientsecret privatekey privatekeys signingkey encryptionkey sessioncookie sessioncookies]).any?
        return true if %w[cookie cookies].include?(words.last)
        pairs = words.map { |word| (word == "keys") ? "key" : word }.each_cons(2).map { |pair| pair.join("_") }
        return true if (pairs & %w[api_key access_key private_key signing_key encryption_key session_key auth_key authentication_key authorization_key authorisation_key auth_header authorization_header authorisation_header]).any?
        %w[auth authentication authorization authorisation jwt bearer].include?(words.last)
      end

      def validate_name!(key)
        unless key.is_a?(String) && !credential_name?(key.split(".", 2).last)
          raise Error, "credential-bearing input names are forbidden; use a value-free secret requirement"
        end
      end

      def validate_namespace!(key, category:, id:)
        unless key.is_a?(String) && key.start_with?("#{category}/#{id}.")
          raise Error, "input key must belong to its originating adapter namespace"
        end
      end

      def jwt?(value)
        parts = value.split(".", -1)
        return false unless parts.size == 3 && parts.all? { |part| part.match?(/\A[A-Za-z0-9_-]+\z/) } && parts.last.length >= 16
        header, payload = parts.first(2).map do |part|
          encoded = part.tr("-_", "+/")
          encoded += "=" * ((4 - encoded.length % 4) % 4)
          JSON.parse(encoded.unpack1("m0"))
        end
        header.is_a?(Hash) && header["alg"].is_a?(String) && !header["alg"].empty? && payload.is_a?(Hash)
      rescue ArgumentError, JSON::ParserError
        false
      end

      def validate_non_secret!(value)
        return unless value.is_a?(String)
        credential = value.match?(/-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----/) ||
          value.strip.match?(/\A(?:Authorization:[ \t]*)?Bearer[ \t]+[A-Za-z0-9._~+\/=-]{8,}\z/i) ||
          value.match?(/(?:\A|[^A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|sk-(?:proj-|svcacct-)?[A-Za-z0-9_-]{20,}|(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|(?:AKIA|ASIA)[A-Z0-9]{16}|AIza[A-Za-z0-9_-]{35})(?![A-Za-z0-9])/) ||
          value.match?(%r{\b[a-z][a-z0-9+.-]*://[^/\s?#@]+:[^/\s?#@]*@}i) || jwt?(value)
        assignments = value.scan(/^[ \t]*(?:export[ \t]+)?([A-Za-z_][A-Za-z0-9_.-]*)[ \t]*=/).flatten
        credential ||= assignments.any? { |name| credential_name?(name) }
        raise Error, "recognised credential material is forbidden in adapter inputs" if credential
      end

      def validate_supplied!(inputs)
        raise Error, "explicit inputs must be a mapping" unless inputs.is_a?(Hash)
        inputs.each do |key, value|
          validate_name!(key)
          validate_non_secret!(value)
          unless value.is_a?(String) || value.is_a?(Integer) || value == true || value == false
            raise Error, "malformed adapter input value"
          end
        end
      end

      def validate_value!(definition, value)
        validate_name!(definition["key"])
        validate_non_secret!(value)
        valid = case definition.fetch("type")
        when "string", "relative_path" then value.is_a?(String) && !value.empty? && !value.include?("\0")
        when "boolean" then value == true || value == false
        when "integer" then value.is_a?(Integer)
        end
        raise Error, "malformed adapter input value" unless valid
        Contracts.relative!(value) if definition["type"] == "relative_path"
        if definition["allowed_values"] && !definition["allowed_values"].include?(value)
          raise Error, "adapter input value is not allowed"
        end
        value
      end

      def validate_declaration!(definition)
        validate_name!(definition["key"])
        fields = %w[key type required description allowed_values default]
        Contracts.validate!("assessment", definition.slice(*fields), fragment: "input_definition")
        definition["allowed_values"]&.each { |value| validate_value!(definition, value) }
        validate_value!(definition, definition["default"]) if definition.key?("default")
      end
    end

    class Selection
      attr_reader :document, :definitions, :inputs

      def initialize(document, registry:, root: nil)
        if document.is_a?(Hash) && document["inputs"].is_a?(Array)
          document["inputs"].each do |item|
            next unless item.is_a?(Hash)
            InputValues.validate_name!(item["key"])
            InputValues.validate_non_secret!(item["value"])
          end
        end
        @document = Contracts.copy(document)
        Contracts.validate!("selection", @document)
        Contracts.scope!(@document["scope"], root: root)
        selected = @document["selected"]
        categories = selected.map { |item| item["category"] }
        raise Error, "multiple selections in one category" unless categories == categories.uniq
        raise Error, "selected adapter set requires exactly one ecosystem" unless categories.include?("ecosystem")
        @definitions = selected.map do |item|
          entry = registry.fetch(category: item["category"], id: item["id"])
          raise Error, "unknown adapter: #{item["category"]}/#{item["id"]}" unless entry
          raise Error, "unsupported adapter: #{item["id"]} (#{entry.status})" unless entry.status == "supported"
          entry
        end.sort_by { |entry| [entry.category, entry.id] }.freeze
        @inputs = @document["inputs"].to_h { |item| [item["key"], item["value"]] }
        raise Error, "duplicate explicit input" unless @inputs.length == @document["inputs"].length
        known = @definitions.flat_map(&:input_definitions).to_h { |item| [item["key"], item] }
        @inputs.each do |key, value|
          raise Error, "unknown explicit input" unless known[key]
          InputValues.validate_value!(known.fetch(key), value)
        end
        ids = @document["resolutions"].map { |item| item["conflict_id"] }
        raise Error, "duplicate conflict resolution" unless ids.uniq == ids
        Contracts.freeze_tree(@document)
        Contracts.freeze_tree(@inputs)
      end

      def scope
        document.fetch("scope")
      end

      def validate_candidates!(candidates)
        document["selected"].each do |item|
          next unless item["source"] == "accepted_detection"
          unless candidates.any? { |candidate| candidate.values_at("category", "id", "scope") == [item["category"], item["id"], scope] }
            raise Error, "accepted_detection requires a current matching candidate: #{item["id"]}"
          end
        end
      end
    end
  end
end
