# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    class Contributions
      def self.empty
        DOMAINS.to_h { |domain| [domain, []] }
      end

      def self.validate!(set, definitions:, scope:, component_ids:, evidence_ids:)
        unless set.is_a?(Hash) && set.keys.sort == DOMAINS.sort
          raise Error, "provider contributions must contain exactly the declared domains"
        end
        ids = []
        set.each do |domain, records|
          raise Error, "contribution domain must be an array: #{domain}" unless records.is_a?(Array)
          records.each do |record|
            Contracts.validate!("assessment", record, fragment: domain)
            id = record.fetch("id")
            raise Error, "duplicate contribution ID: #{id}" if ids.include?(id)
            ids << id
            record.fetch("provenance").each do |origin|
              entry = definitions.find { |definition| definition.category == origin["category"] && definition.id == origin["adapter_id"] && definition.version == origin["adapter_version"] }
              raise Error, "invalid contribution provenance: #{id}" unless entry && origin["scope"] == scope && origin["contribution_id"] == id
              unless entry.contribution_domains.include?(domain) && AUTHORITY.fetch(entry.category).include?(domain)
                raise Error, "unsupported_contribution: #{entry.category}/#{entry.id} cannot contribute #{domain}"
              end
              authority!(entry.category, domain, record)
            end
            case domain
            when "commands"
              if record["kind"] == "base"
                command!(record, scope)
              end
            when "command_wrappers"
              tokens!(record["prefix_argv"] + record["suffix_argv"])
              environment!(record.fetch("env", {}))
              Contracts.scoped_path!(record["cwd"], scope) if record["cwd"]
            when "paths"
              Contracts.scoped_path!(record["path"], scope)
            when "inputs"
              InputValues.validate_declaration!(record)
            when "component_recommendations"
              raise Error, "unknown framework component: #{record["component_id"]}" unless component_ids.include?(record["component_id"])
            when "findings"
              unknown = record["evidence_ids"] - evidence_ids
              raise Error, "unknown finding evidence: #{unknown.join(", ")}" unless unknown.empty?
            end
          end
        end
        findings = set["findings"].map { |item| item["id"] }
        set["findings"].each do |item|
          raise Error, "unknown related finding" unless (item["related_finding_ids"] - findings).empty?
        end
        set
      end

      def self.authority!(category, domain, record)
        allowed = case domain
        when "commands"
          if category == "runtime"
            record["kind"] == "refinement" && record["profiles"].empty? && record["classification"].empty?
          else
            record["kind"] != "refinement" || category == "framework"
          end
        when "services" then record["kind"] == ((category == "runtime") ? "binding" : "requirement")
        when "requirements" then (category == "app-shape") ? record["kind"] == "risk" : %w[execution secret].include?(record["kind"])
        else true
        end
        raise Error, "unsupported_contribution: #{category} cannot supply these #{domain} semantics" unless allowed
      end

      def self.command!(command, scope)
        Contracts.scoped_path!(command["scope"], scope)
        Contracts.scoped_path!(command["cwd"], scope)
        tokens!(command["argv"])
        environment!(command["env"])
      end

      def self.tokens!(tokens)
        raise Error, "command argument contains NUL" if tokens.any? { |token| token.include?("\0") }
        # Reject shell-evaluation forms even when buried inside an execution
        # wrapper (for example env bash -c). No command is executed here.
        tokens.each_with_index do |token, index|
          if token.match?(/\A--?(?:password|token|secret|api[-_]key|private[-_]key)(?:=|\z)/i) ||
              token.match?(/\A[A-Z_]*(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY|API_KEY)=/i) ||
              token.match?(%r{\A[a-z][a-z0-9+.-]*://[^/\s]*:[^/\s]*@}i)
            raise Error, "credential-bearing arguments must be represented as secret requirements"
          end
          name = File.basename(token)
          if %w[sh bash dash zsh ksh fish].include?(name) && tokens.drop(index + 1).any? { |item| item.match?(/\A-[A-Za-z]*c/) }
            raise Error, "shell evaluation is not a supported structured command"
          end
        end
      end

      def self.environment!(env)
        env.each do |key, value|
          raise Error, "invalid command environment variable" unless /\A[A-Za-z_][A-Za-z0-9_]*\z/.match?(key)
          if key.match?(/(?:TOKEN|SECRET|PASSWORD|CREDENTIAL|PRIVATE_KEY|API_KEY)/i)
            raise Error, "secret values must be represented as requirements"
          end
          raise Error, "command environment contains NUL" if value.include?("\0")
        end
      end
    end
  end
end
