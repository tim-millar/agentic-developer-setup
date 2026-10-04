# frozen_string_literal: true

require "digest"
require "pathname"

require_relative "../git_command"
require_relative "../framework_catalogue"

module AgenticDeveloperSetup
  module Adoption
    class Inspector
      attr_reader :root, :framework_root

      def initialize(target, framework_root: default_framework_root)
        @root = Pathname.new(target).expand_path.realpath
        @framework_root = Pathname.new(framework_root).expand_path.realpath
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Assessment::InvocationError, "inspection target is not readable: #{e.message}"
      end

      def inspect(framework_source: nil)
        metadata = Metadata.load(@root)
        validator = Validator.new(root: @root, framework_root: @framework_root)
        validation = (metadata.status == "loaded") ? validator.validate(metadata.document) : metadata.diagnostics
        candidate = load_candidate(framework_source)
        diagnostics = metadata.diagnostics + validation + candidate[:diagnostics]
        document = metadata.document if metadata.status == "loaded"
        components = (document.is_a?(Hash) && document["components"].is_a?(Array)) ? document["components"] : []
        results = components.filter_map { |component| inspect_component(component, validator, candidate, diagnostics) }.sort_by { |item| item["id"].to_s }
        diagnostics += local_diagnostics(results)
        diagnostics = normalize_diagnostics(diagnostics)
        {
          "schema_version" => 1,
          "repository" => {"root" => @root.to_s},
          "metadata" => {
            "path" => METADATA_PATH,
            "status" => metadata_status(metadata, validation),
            "schema_version" => document.is_a?(Hash) ? document["schema_version"] : nil
          },
          "framework" => framework_identity(document),
          "candidate" => candidate_result(candidate, framework_source),
          "scope" => (document.is_a?(Hash) && document["scope"].is_a?(Hash)) ? document["scope"] : {"type" => nil, "path" => nil},
          "components" => results,
          "diagnostics" => diagnostics.map(&:to_h),
          "summary" => summary(diagnostics)
        }
      end

      private

      def default_framework_root
        Pathname.new(__dir__).join("../../..").to_s
      end

      def inspect_component(component, validator, candidate, diagnostics)
        return nil unless component.is_a?(Hash) && component["id"].is_a?(String)

        id = component["id"]
        status = component["status"]
        ownership = component["ownership"]
        item = {
          "id" => id,
          "status" => status,
          "ownership" => ownership,
          "update_policy" => component["update_policy"],
          "target_path" => %w[inherited specialised].include?(ownership) ? component["target_path"] : nil,
          "local_state" => local_state(component, validator, diagnostics),
          "update_state" => update_state(component, candidate, diagnostics)
        }
        if item["local_state"] == "locally_modified"
          diagnostics << diagnostic("error", "inherited_digest_mismatch", id, component["target_path"], "inherited target content differs from adopted_source_digest")
        end
        item
      end

      def local_state(component, validator, diagnostics)
        status = component["status"]
        return "inactive" if STATUSES[1..].include?(status)
        return "metadata_inconsistent" unless status == "active" && OWNERSHIPS.include?(component["ownership"])
        if component["ownership"] == "repository_owned"
          return repository_equivalent_state(component, validator, diagnostics)
        end

        target = validator.send(:safe_existing, root, component["target_path"])
        return "metadata_inconsistent" if target == :unsafe
        return "missing" if target.nil?
        return "metadata_inconsistent" unless target.file?
        return "specialised_as_expected" if component["ownership"] == "specialised"

        digest = Digest::SHA256.file(target.to_s).hexdigest
        (digest == component["adopted_source_digest"].to_s.delete_prefix("sha256:")) ? "in_sync" : "locally_modified"
      rescue SystemCallError
        "metadata_inconsistent"
      end

      def repository_equivalent_state(component, validator, diagnostics)
        equivalent = component["equivalent"].is_a?(Hash) ? component["equivalent"] : {}
        paths = equivalent["paths"].is_a?(Array) ? equivalent["paths"] : []
        missing = paths.any? do |path|
          existing = validator.send(:safe_existing, root, path)
          existing.nil? || existing == :unsafe
        end
        diagnostics << diagnostic("review_required", "repository_command_not_executed", component["id"], nil, "declared repository-owned commands were not executed") if equivalent["commands"].is_a?(Array) && !equivalent["commands"].empty?
        missing ? "metadata_inconsistent" : "repository_equivalent"
      end

      def update_state(component, candidate, diagnostics)
        return "not_applicable" unless component["status"] == "active" && %w[inherited specialised].include?(component["ownership"])
        return "not_checked" unless candidate[:status] == "available"

        item = candidate[:catalogue].find { |entry| entry["name"] == component["id"] }
        return "source_unavailable" unless item
        source = candidate_source(candidate[:root], item["source_path"])
        return "source_unavailable" unless source&.file?

        digest = Digest::SHA256.file(source.to_s).hexdigest
        return "unchanged" if digest == component["adopted_source_digest"].to_s.delete_prefix("sha256:")

        if component["update_policy"] == "pinned"
          "pinned"
        elsif component["ownership"] == "specialised"
          diagnostics << diagnostic("review_required", "candidate_change_requires_manual_review", component["id"], item["source_path"], "candidate framework content differs for a specialised component")
          "manual_review"
        else
          diagnostics << diagnostic("review_required", "candidate_available", component["id"], item["source_path"], "candidate framework content differs from adopted source content")
          "candidate_available"
        end
      rescue SystemCallError
        "source_unavailable"
      end

      def load_candidate(path)
        return {status: "not_checked", diagnostics: [], catalogue: [], root: nil, version: nil, revision: nil} unless path
        candidate_root = Pathname.new(path).expand_path.realpath
        unless candidate_root.directory?
          return invalid_candidate("candidate_source_invalid", "candidate framework source is not a directory")
        end
        catalogue_path = PathSafety.existing(candidate_root, "framework.yml")
        return invalid_candidate("candidate_source_unsafe_path", "candidate framework catalogue path is unsafe") unless catalogue_path&.is_a?(Pathname) && catalogue_path.lstat.file?
        catalogue = YAML.safe_load(catalogue_path.read, permitted_classes: [], permitted_symbols: [], aliases: false)
        unless catalogue.is_a?(Hash)
          return invalid_candidate("candidate_catalogue_invalid", "candidate framework source does not contain a valid framework catalogue")
        end
        return invalid_candidate("candidate_catalogue_invalid", "candidate framework source does not contain schema version 2") unless catalogue["schema_version"] == 2

        baseline = catalogue["baseline"]
        unless baseline.is_a?(Hash)
          return invalid_candidate("candidate_catalogue_invalid", "candidate framework source baseline must be a mapping")
        end
        required = baseline["required"]
        recommended = baseline["recommended"]
        unless required.is_a?(Array) && recommended.is_a?(Array)
          return invalid_candidate("candidate_catalogue_invalid", "candidate framework source baseline collections must be arrays")
        end

        framework = catalogue["framework"]
        unless framework.is_a?(Hash) && framework["framework_version"].is_a?(String) && !framework["framework_version"].empty?
          return invalid_candidate("candidate_catalogue_invalid", "candidate framework source framework identity is malformed")
        end

        entries = required + recommended
        unless entries.all? { |entry| valid_candidate_baseline_entry?(entry) }
          return invalid_candidate("candidate_catalogue_invalid", "candidate framework source contains malformed baseline components")
        end
        names = entries.map { |entry| entry["name"] }
        return invalid_candidate("candidate_catalogue_invalid", "candidate framework source contains duplicate component IDs") unless names.uniq.length == names.length
        targets = entries.map { |entry| entry["target_path"] }
        return invalid_candidate("candidate_catalogue_invalid", "candidate framework source contains duplicate target paths") unless targets.uniq.length == targets.length
        unsafe_source = entries.find { |entry| PathSafety.existing(candidate_root, entry["source_path"]) == :unsafe }
        return invalid_candidate("candidate_source_unsafe_path", "candidate framework source contains an unsafe component source path") if unsafe_source
        revision = capture_revision(candidate_root)
        {
          status: "available",
          diagnostics: (revision == "unknown") ? [diagnostic("warning", "candidate_revision_unavailable", nil, nil, "candidate source has no usable Git revision; digest comparison remains available")] : [],
          catalogue: entries.sort_by { |entry| entry["name"] },
          root: candidate_root,
          version: framework["framework_version"],
          revision: (revision == "unknown") ? nil : revision
        }
      rescue Psych::Exception, SystemCallError => e
        invalid_candidate("candidate_source_invalid", "candidate framework source could not be read: #{e.message.lines.first.strip}")
      end

      def invalid_candidate(code, message)
        {status: "invalid", diagnostics: [diagnostic("error", code, nil, nil, message)], catalogue: [], root: nil, version: nil, revision: nil}
      end

      def valid_candidate_baseline_entry?(entry)
        FrameworkCatalogue.baseline_entry_shape_valid?(entry) &&
          entry["name"].match?(FrameworkCatalogue::COMPONENT_ID_PATTERN) &&
          PathSafety.safe_relative?(entry["source_path"]) &&
          PathSafety.safe_relative?(entry["target_path"])
      end

      def candidate_source(root, path)
        return nil unless root && path.is_a?(String)

        source = PathSafety.existing(root, path)
        source unless source == :unsafe || source.nil?
      end

      def framework_identity(document)
        framework = (document.is_a?(Hash) && document["framework"].is_a?(Hash)) ? document["framework"] : {}
        {"source" => framework["source"], "version" => framework["version"], "revision" => framework["revision"]}
      end

      def candidate_result(candidate, path)
        {
          "status" => candidate[:status],
          "path" => (path && candidate[:root]) ? candidate[:root].to_s : nil,
          "version" => candidate[:version],
          "revision" => candidate[:revision]
        }
      end

      def metadata_status(metadata, validation)
        return metadata.status if %w[missing invalid].include?(metadata.status)
        (validation.any? { |item| item.severity == "error" }) ? "invalid" : "valid"
      end

      def local_diagnostics(results)
        []
      end

      def normalize_diagnostics(items)
        items.sort_by { |item| [item.path.to_s, item.code.to_s, item.component_id.to_s, item.message] }.uniq { |item| [item.severity, item.code, item.component_id, item.path, item.message] }
      end

      def summary(diagnostics)
        {
          "error_count" => diagnostics.count { |item| item.severity == "error" },
          "warning_count" => diagnostics.count { |item| item.severity == "warning" },
          "review_required_count" => diagnostics.count { |item| item.severity == "review_required" }
        }
      end

      def diagnostic(severity, code, component_id, path, message)
        Diagnostic.new(severity: severity, code: code, component_id: component_id, path: path, message: message)
      end

      def capture_revision(root)
        result = GitCommand.capture(root, "rev-parse", "--verify", "HEAD^{commit}")
        (result.success? && !result.stdout.strip.empty?) ? result.stdout.strip : "unknown"
      end
    end
  end
end
