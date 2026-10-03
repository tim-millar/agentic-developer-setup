# frozen_string_literal: true

require "digest"
require "date"
require "pathname"

module AgenticDeveloperSetup
  module Adoption
    class Validator
      COMPONENT_KEYS = %w[id status ownership update_policy source_path target_path adopted_revision adopted_source_digest rationale local_ownership equivalent].freeze
      FRAMEWORK_KEYS = %w[source version revision adopted_at updated_at].freeze
      SCOPE_KEYS = %w[type path].freeze

      attr_reader :root, :framework_root, :catalogue, :diagnostics

      def initialize(root:, framework_root:)
        @root = Pathname.new(root).expand_path.realpath
        @framework_root = Pathname.new(framework_root).expand_path.realpath
        @diagnostics = []
        @schema = Schema.load(@framework_root.join("schemas/framework-adoption-v1.schema.json"))
        @catalogue = load_catalogue
      rescue Errno::ENOENT, Errno::EACCES => e
        raise Assessment::InvocationError, "adoption root is not readable: #{e.message}"
      end

      def validate(document)
        @diagnostics = []
        return sorted unless mapping(document, "document")

        @schema.validate(document).each do |message|
          error("schema_violation", nil, schema_location(message), message)
        end
        validate_top_level(document)
        return sorted unless document["schema_version"] == 1

        validate_framework(document["framework"])
        scope = validate_scope(document["scope"])
        components = validate_components(document["components"])
        validate_component_semantics(components, scope)
        sorted
      end

      def component_ids
        catalogue.to_h { |item| [item["name"], item] }
      end

      def catalogue_revision
        revision = capture_revision(@framework_root)
        revision if revision.match?(REVISION_PATTERN)
      end

      private

      def load_catalogue
        data = YAML.safe_load(
          @framework_root.join("framework.yml").read,
          permitted_classes: [],
          permitted_symbols: [],
          aliases: false
        )
        baseline = data.is_a?(Hash) ? data["baseline"] : nil
        unless data.is_a?(Hash) && data["schema_version"] == 2 && baseline.is_a?(Hash) && baseline["required"].is_a?(Array) && baseline["recommended"].is_a?(Array)
          raise Assessment::SchemaError, "framework metadata must be schema version 2 with a baseline catalogue"
        end
        entries = data["baseline"].values_at("required", "recommended").flatten
        unless entries.all? { |item| item.is_a?(Hash) && item["name"].is_a?(String) && item["source_path"].is_a?(String) }
          raise Assessment::SchemaError, "framework metadata contains malformed baseline components"
        end
        entries.sort_by { |item| item.fetch("name") }
      rescue Psych::Exception, SystemCallError, KeyError, TypeError => e
        raise Assessment::SchemaError, "framework catalogue could not be loaded: #{e.message.lines.first.strip}"
      end

      def validate_top_level(document)
        expected = %w[schema_version framework scope components]
        missing = expected - document.keys
        extra = document.keys - expected
        error("invalid_shape", nil, nil, "metadata missing fields: #{missing.join(", ")}") unless missing.empty?
        error("unknown_field", nil, nil, "metadata has unknown fields: #{extra.join(", ")}") unless extra.empty?
        error("unsupported_schema_version", nil, nil, "schema_version must be 1") unless document["schema_version"] == 1
      end

      def validate_framework(value)
        return unless mapping(value, "framework")

        exact_object(value, FRAMEWORK_KEYS, "framework")
        string(value["source"], "framework.source")
        error("invalid_framework_source", nil, "framework.source", "framework.source must be #{SOURCE}") unless value["source"] == SOURCE
        string(value["version"], "framework.version", non_empty: true)
        revision(value["revision"], "framework.revision")
        date(value["adopted_at"], "framework.adopted_at")
        date(value["updated_at"], "framework.updated_at")
        if value["adopted_at"].is_a?(String) && value["updated_at"].is_a?(String) && value["updated_at"] < value["adopted_at"]
          error("invalid_date_order", nil, "framework.updated_at", "updated_at must not be earlier than adopted_at")
        end
      end

      def validate_scope(value)
        return {} unless mapping(value, "scope")

        exact_object(value, SCOPE_KEYS, "scope")
        type = value["type"]
        path = value["path"]
        unless %w[repository workspace].include?(type)
          error("invalid_scope_type", nil, "scope.type", "scope.type must be repository or workspace")
        end
        if type == "repository"
          error("invalid_scope_path", nil, "scope.path", "repository scope path must be .") unless path == "."
          {"type" => type, "path" => "."}
        elsif type == "workspace"
          safe_path(path, "scope.path", allow_dot: false)
          check_existing_path(path, "scope.path", directory: true) if safe_path_value?(path, allow_dot: false)
          {"type" => type, "path" => path}
        else
          {}
        end
      end

      def validate_components(value)
        return [] unless array(value, "components")

        ids = []
        value.each_with_index do |component, index|
          location = "components[#{index}]"
          next unless mapping(component, location)

          extra = component.keys - COMPONENT_KEYS
          extra.each { |key| error("unknown_field", component["id"], "#{location}.#{key}", "component has unknown field #{key}") }
          id = component["id"]
          id_value(id, location)
          if ids.include?(id)
            error("duplicate_component_id", id, "#{location}.id", "component ID is not unique")
          else
            ids << id
          end
          status = component["status"]
          unless STATUSES.include?(status)
            error("invalid_status", id, "#{location}.status", "unsupported component status")
          end
          validate_component_shape(component, location, status) if STATUSES.include?(status)
        end
        value
      end

      def validate_component_shape(component, location, status)
        if status == "active"
          ownership = component["ownership"]
          unless OWNERSHIPS.include?(ownership)
            error("active_ownership_required", component["id"], "#{location}.ownership", "active components require a supported ownership")
            return
          end
          case ownership
          when "inherited"
            required(component, %w[update_policy source_path target_path adopted_revision adopted_source_digest], location)
            forbidden(component, %w[local_ownership equivalent], location)
          when "specialised"
            required(component, %w[update_policy source_path target_path adopted_revision adopted_source_digest local_ownership], location)
            forbidden(component, ["equivalent"], location)
            string_array(component["local_ownership"], "#{location}.local_ownership", non_empty: true, unique: true)
          when "repository_owned"
            required(component, %w[update_policy equivalent rationale], location)
            forbidden(component, %w[source_path target_path adopted_revision adopted_source_digest local_ownership], location)
            validate_equivalent(component["equivalent"], "#{location}.equivalent")
            rationale(component, location) if component.key?("rationale")
          end
          validate_active_policy(component)
          if component["update_policy"] == "pinned"
            required(component, ["rationale"], location)
            rationale(component, location) if component.key?("rationale")
          end
          validate_managed_fields(component, location) if %w[inherited specialised].include?(ownership)
        else
          required(component, ["rationale"], location)
          rationale(component, location) if component.key?("rationale")
          forbidden(component, %w[ownership update_policy source_path target_path adopted_revision adopted_source_digest local_ownership equivalent], location)
        end
        rationale(component, location) if component.key?("rationale") && status == "active" && component["ownership"] != "repository_owned" && component["update_policy"] != "pinned"
      end

      def validate_active_policy(component)
        allowed = {
          "inherited" => %w[review_required pinned],
          "specialised" => %w[manual_merge pinned],
          "repository_owned" => ["repository_managed"]
        }
        unless allowed.fetch(component["ownership"], []).include?(component["update_policy"])
          error("invalid_ownership_policy", component["id"], "update_policy", "ownership and update_policy combination is not supported")
        end
      end

      def validate_managed_fields(component, location)
        safe_path(component["source_path"], "#{location}.source_path", framework: true)
        safe_path(component["target_path"], "#{location}.target_path")
        revision(component["adopted_revision"], "#{location}.adopted_revision")
        digest(component["adopted_source_digest"], "#{location}.adopted_source_digest")
      end

      def validate_component_semantics(components, scope)
        return unless components.is_a?(Array)

        ids = component_ids
        managed_targets = Hash.new { |hash, key| hash[key] = [] }
        components.each do |component|
          next unless component.is_a?(Hash) && component["status"] == "active" && %w[inherited specialised].include?(component["ownership"])
          target_path = component["target_path"]
          managed_targets[target_path] << component["id"] if target_path.is_a?(String)
        end
        duplicate_targets = managed_targets.select { |_path, owners| owners.length > 1 }.keys
        components.each do |component|
          next unless component.is_a?(Hash)
          id = component["id"]
          status = component["status"]
          unless ids.key?(id)
            error("unknown_component_id", id, "components", "component ID is not present in the framework catalogue")
            next
          end

          if status == "active"
            ownership = component["ownership"]
            if ownership.nil?
              next
            elsif %w[inherited specialised].include?(ownership)
              source_path = component["source_path"]
              target_path = component["target_path"]
              unless inside_scope?(target_path, scope["path"])
                error("path_outside_scope", id, target_path, "target path is outside the declared scope")
              end
              if target_path.is_a?(String)
                error("duplicate_target_ownership", id, target_path, "target path is claimed by multiple framework-managed components") if duplicate_targets.include?(target_path)
                inspect_target(component, scope)
              end
              validate_catalogue_identity(component, ids.fetch(id), id, source_path)
            elsif ownership == "repository_owned"
              validate_equivalent_paths(component, scope)
            end
          end
        end
      end

      def validate_catalogue_identity(component, catalogue_item, id, source_path)
        return unless component["adopted_revision"] == catalogue_revision
        expected = catalogue_item["source_path"]
        error("source_path_mismatch", id, "source_path", "source_path does not match the current framework catalogue") unless source_path == expected
        source = safe_existing(@framework_root, source_path)
        if source == :unsafe
          error("unsafe_source_path", id, source_path, "framework source path is unsafe")
        elsif source.nil?
          error("source_missing", id, source_path, "framework source path does not exist")
        elsif !source.file?
          error("source_not_regular_file", id, source_path, "framework source path is not a regular file")
        elsif digest_for(source) != component["adopted_source_digest"].to_s.delete_prefix("sha256:")
          error("source_digest_mismatch", id, source_path, "framework source digest differs from adopted_source_digest")
        end
      end

      def inspect_target(component, scope)
        target_path = component["target_path"]
        target = safe_existing(@root, target_path)
        if target == :unsafe
          error("unsafe_target_path", component["id"], target_path, "target path contains a symlink or unsafe path component")
        elsif target.nil?
          error("target_missing", component["id"], target_path, "active framework-managed target is missing")
        elsif !target.file?
          error("target_not_regular_file", component["id"], target_path, "active framework-managed target is not a regular file")
        elsif component["ownership"] == "inherited" && digest_for(target) != component["adopted_source_digest"].to_s.delete_prefix("sha256:")
          error("inherited_digest_mismatch", component["id"], target_path, "inherited target content differs from adopted_source_digest")
        end
      end

      def validate_equivalent_paths(component, scope)
        equivalent = component["equivalent"]
        Array(equivalent.is_a?(Hash) ? equivalent["paths"] : nil).each do |path|
          unless inside_scope?(path, scope["path"])
            error("path_outside_scope", component["id"], path, "repository-owned equivalent path is outside the declared scope")
          end
          existing = safe_existing(@root, path)
          if existing == :unsafe
            error("unsafe_equivalent_path", component["id"], path, "equivalent path is unsafe")
          elsif existing.nil?
            error("equivalent_path_missing", component["id"], path, "repository-owned equivalent path does not exist")
          elsif !(existing.file? || existing.directory?)
            error("equivalent_path_invalid", component["id"], path, "repository-owned equivalent path is not a file or directory")
          end
        end
      end

      def validate_equivalent(value, location)
        unless mapping(value, location)
          return
        end
        exact_object(value, %w[paths commands], location)
        string_array(value["paths"], "#{location}.paths", non_empty: true, unique: true) if value.key?("paths")
        string_array(value["commands"], "#{location}.commands", non_empty: true, unique: true) if value.key?("commands")
        paths = value["paths"].is_a?(Array) ? value["paths"] : []
        commands = value["commands"].is_a?(Array) ? value["commands"] : []
        error("empty_equivalent", nil, location, "equivalent must contain at least one path or command") if paths.empty? && commands.empty?
      end

      def check_existing_path(path, location, directory: false)
        existing = safe_existing(@root, path)
        return if existing.nil?
        error("unsafe_path", nil, location, "path contains a symlink") if existing == :unsafe
        error("scope_not_directory", nil, location, "workspace scope path is not a directory") if directory && existing != :unsafe && !existing.directory?
      end

      def safe_existing(base, relative)
        PathSafety.existing(base, relative, allow_dot: relative == ".")
      end

      def inside_scope?(path, scope_path)
        return false unless path.is_a?(String) && scope_path.is_a?(String)
        return true if scope_path == "."

        path == scope_path || path.start_with?("#{scope_path}/")
      end

      def safe_path(value, location, framework: false, allow_dot: false)
        unless safe_path_value?(value, allow_dot: allow_dot)
          error("unsafe_path", nil, location, "path must be a safe repository-relative POSIX path")
          return false
        end
        true
      end

      def safe_path_value?(value, allow_dot: false)
        return false unless value.is_a?(String) && !value.empty?
        return true if allow_dot && value == "."
        return false if value == "." || value.start_with?("/") || value.include?("\\") || value.include?("\0") || value.match?(/\A[A-Za-z]:/)

        parts = value.split("/")
        !parts.any? { |part| part.empty? || part == "." || part == ".." || part == ".git" }
      end

      def mapping(value, location)
        return true if value.is_a?(Hash)

        error("invalid_type", nil, location, "expected a mapping")
        false
      end

      def array(value, location)
        return true if value.is_a?(Array)

        error("invalid_type", nil, location, "expected an array")
        false
      end

      def exact_object(value, keys, location)
        extra = value.keys - keys
        extra.each { |key| error("unknown_field", nil, "#{location}.#{key}", "unknown field #{key}") }
      end

      def required(value, keys, location)
        (keys - value.keys).each { |key| error("required_field_missing", value["id"], "#{location}.#{key}", "required field is missing") }
      end

      def forbidden(value, keys, location)
        keys.each { |key| error("forbidden_field", value["id"], "#{location}.#{key}", "field is not permitted for this component state") if value.key?(key) }
      end

      def id_value(value, location)
        string(value, "#{location}.id")
        error("invalid_component_id", value, "#{location}.id", "component ID must match [a-z][a-z0-9_]*") if value.is_a?(String) && !value.match?(ID_PATTERN)
      end

      def string(value, location, non_empty: false)
        error("invalid_type", nil, location, "expected a string") unless value.is_a?(String)
        error("empty_string", nil, location, "value must not be empty") if non_empty && value.is_a?(String) && value.empty?
      end

      def string_array(value, location, non_empty: false, unique: false)
        unless value.is_a?(Array)
          error("invalid_type", nil, location, "expected an array")
          return
        end
        value.each { |item| string(item, location, non_empty: non_empty) }
        error("duplicate_value", nil, location, "values must be unique") if unique && value.uniq.length != value.length
        error("empty_collection", nil, location, "collection must not be empty") if non_empty && value.empty?
      end

      def rationale(component, location)
        string(component["rationale"], "#{location}.rationale", non_empty: true)
      end

      def date(value, location)
        string(value, location)
        if value.is_a?(String) && (!value.match?(DATE_PATTERN) || invalid_calendar_date?(value))
          error("invalid_date", nil, location, "date must use YYYY-MM-DD")
        end
      end

      def invalid_calendar_date?(value)
        Date.iso8601(value).iso8601 != value
      rescue Date::Error
        true
      end

      def revision(value, location)
        string(value, location)
        error("invalid_revision", nil, location, "revision must be 40 lowercase hexadecimal characters") if value.is_a?(String) && !value.match?(REVISION_PATTERN)
      end

      def digest(value, location)
        string(value, location)
        error("invalid_digest", nil, location, "digest must use sha256:<64 lowercase hexadecimal characters>") if value.is_a?(String) && !value.match?(DIGEST_PATTERN)
      end

      def error(code, component_id, path, message)
        @diagnostics << Diagnostic.new(severity: "error", code: code, component_id: component_id, path: path, message: message)
      end

      def sorted
        @diagnostics.sort_by { |item| [item.path.to_s, item.code.to_s, item.component_id.to_s, item.message] }
      end

      def schema_location(message)
        location = message[/\A(\$[^:]*):/, 1]
        return nil unless location

        location.delete_prefix("$").gsub(/\[\d+\]/) { |index| index }.delete_prefix(".")
      end

      def digest_for(path)
        Digest::SHA256.file(path.to_s).hexdigest
      end

      def capture_revision(root)
        require "open3"
        stdout, _stderr, status = Open3.capture3({"GIT_OPTIONAL_LOCKS" => "0"}, "git", "-C", root.to_s, "rev-parse", "--verify", "HEAD^{commit}")
        status.success? ? stdout.strip : "unknown"
      rescue SystemCallError
        "unknown"
      end
    end
  end
end
