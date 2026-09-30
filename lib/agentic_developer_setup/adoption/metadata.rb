# frozen_string_literal: true

require "pathname"
require "date"
require "yaml"

module AgenticDeveloperSetup
  module Adoption
    SOURCE = "https://github.com/tim-millar/agentic-developer-setup"
    METADATA_PATH = ".agent-framework/adoption.yml"
    STATUSES = %w[active deferred declined removed blocked].freeze
    OWNERSHIPS = %w[inherited specialised repository_owned].freeze
    UPDATE_POLICIES = %w[review_required manual_merge pinned repository_managed].freeze
    LOCAL_STATES = %w[in_sync locally_modified specialised_as_expected missing repository_equivalent inactive metadata_inconsistent].freeze
    UPDATE_STATES = %w[not_checked unchanged candidate_available manual_review pinned source_unavailable not_applicable].freeze
    ID_PATTERN = /\A[a-z][a-z0-9_]*\z/
    REVISION_PATTERN = /\A[0-9a-f]{40}\z/
    DIGEST_PATTERN = /\Asha256:[0-9a-f]{64}\z/
    DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/

    # standard:disable Style/RedundantStructKeywordInit
    Diagnostic = Struct.new(:severity, :code, :component_id, :path, :message, keyword_init: true) do
      def to_h
        {
          "severity" => severity,
          "code" => code,
          "component_id" => component_id,
          "path" => path,
          "message" => message
        }
      end
    end
    # standard:enable Style/RedundantStructKeywordInit

    class Metadata
      attr_reader :status, :document, :diagnostics

      def initialize(status:, document: nil, diagnostics: [])
        @status = status
        @document = document
        @diagnostics = diagnostics
      end

      def self.load(root)
        path = Pathname.new(root).expand_path.join(METADATA_PATH)
        unless path.file? && !path.symlink?
          return new(
            status: "missing",
            diagnostics: [Diagnostic.new(severity: "error", code: "metadata_missing", path: METADATA_PATH, message: "adoption metadata is missing")]
          )
        end

        document = YAML.safe_load(
          path.read,
          permitted_classes: [Date],
          permitted_symbols: [],
          aliases: false,
          filename: path.to_s
        )
        new(status: "loaded", document: normalise_dates(document))
      rescue Psych::Exception => e
        new(
          status: "invalid",
          diagnostics: [Diagnostic.new(severity: "error", code: "malformed_yaml", path: METADATA_PATH, message: "adoption metadata could not be parsed: #{e.message.lines.first.strip}")]
        )
      rescue SystemCallError => e
        new(
          status: "invalid",
          diagnostics: [Diagnostic.new(severity: "error", code: "metadata_unreadable", path: METADATA_PATH, message: "adoption metadata could not be read: #{e.message}")]
        )
      end

      def self.normalise_dates(value)
        case value
        when Date then value.iso8601
        when Hash then value.transform_values { |item| normalise_dates(item) }
        when Array then value.map { |item| normalise_dates(item) }
        else value
        end
      end

      private_class_method :normalise_dates
    end
  end
end
