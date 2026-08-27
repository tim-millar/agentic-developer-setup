#!/usr/bin/env ruby
# frozen_string_literal: true

require "pathname"
require "yaml"

class FrameworkValidator
  LOAD_FAILED = Object.new.freeze
  TOP_LEVEL_KEYS = %w[
    schema_version framework usage_modes prompts path_conventions baseline
    agent_runtimes adoption_tiers adapters issue_templates conventions
  ].freeze
  ACCESS_MODES = %w[disabled app].freeze
  ADAPTER_STATUSES = %w[supported planned].freeze
  RUNTIME_DISTRIBUTIONS = %w[repository global-user].freeze
  RUNTIME_ARTEFACT_ROLES = %w[launcher prompt installer policy].freeze
  RUNTIME_PLATFORMS = %w[macos linux].freeze

  def initialize(root)
    @root = Pathname.new(root).expand_path
    @root_real = @root.realpath
    @metadata_path = @root.join("framework.yml")
    @errors = []
  end

  attr_reader :errors

  def validate
    metadata = load_metadata
    return false if metadata.equal?(LOAD_FAILED)

    validate_schema(metadata)
    validate_semantics(metadata)
    validate_metadata_paths(metadata)
    validate_repository_structure
    errors.empty?
  end

  private

  def load_metadata
    unless @metadata_path.file?
      error("framework.yml", "file does not exist: framework.yml")
      return LOAD_FAILED
    end

    YAML.safe_load(
      @metadata_path.read,
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false,
      filename: @metadata_path.to_s
    )
  rescue Psych::Exception => e
    error("framework.yml", "could not parse YAML: #{e.message.lines.first.strip}")
    LOAD_FAILED
  rescue SystemCallError => e
    error("framework.yml", "could not read file: #{e.message}")
    LOAD_FAILED
  end

  # Schema and type validation deliberately precedes semantic validation.
  def validate_schema(metadata)
    unless controlled_mapping(metadata, "framework.yml", TOP_LEVEL_KEYS)
      return
    end

    validate_schema_version(metadata["schema_version"])
    validate_framework(metadata["framework"])
    validate_usage_modes(metadata["usage_modes"])
    validate_prompts(metadata["prompts"])
    validate_path_conventions(metadata["path_conventions"])
    validate_baseline(metadata["baseline"])
    validate_agent_runtimes(metadata["agent_runtimes"])
    validate_adoption_tiers(metadata["adoption_tiers"])
    validate_adapters(metadata["adapters"])
    validate_issue_templates(metadata["issue_templates"])
    validate_conventions(metadata["conventions"])
  end

  def validate_schema_version(value)
    location = "framework.yml: schema_version"
    return unless integer(value, location)

    error(location, "unsupported schema version: #{value.inspect}; expected: 2") unless value == 2
  end

  def validate_framework(value)
    location = "framework.yml: framework"
    return unless controlled_mapping(value, location, %w[name framework_version description intended_for primary_goals])

    %w[name framework_version description].each { |field| string(value[field], "#{location}.#{field}") }
    string_sequence(value["intended_for"], "#{location}.intended_for", non_empty: true)
    string_sequence(value["primary_goals"], "#{location}.primary_goals", non_empty: true)
  end

  def validate_usage_modes(value)
    location = "framework.yml: usage_modes"
    return unless sequence(value, location, non_empty: true)

    entries = []
    value.each_with_index do |entry, index|
      item_location = collection_location("usage_modes", entry, index)
      next unless controlled_mapping(entry, "framework.yml: #{item_location}", %w[id name description])

      %w[id name description].each { |field| string(entry[field], "framework.yml: #{item_location}.#{field}") }
      entries << [entry["id"], "framework.yml: #{item_location}.id"]
    end
    validate_unique(entries)
  end

  def validate_prompts(value)
    location = "framework.yml: prompts"
    return unless sequence(value, location, non_empty: true)

    entries = []
    value.each_with_index do |entry, index|
      item_location = collection_location("prompts", entry, index)
      next unless controlled_mapping(entry, "framework.yml: #{item_location}", %w[id path purpose])

      %w[id path purpose].each { |field| string(entry[field], "framework.yml: #{item_location}.#{field}") }
      entries << [entry["id"], "framework.yml: #{item_location}.id"]
    end
    validate_unique(entries)
  end

  def validate_path_conventions(value)
    location = "framework.yml: path_conventions"
    return unless controlled_mapping(value, location, %w[baseline agent_runtimes adapters prompts])

    validate_leaf_mapping(value["baseline"], "#{location}.baseline", %w[source_path target_path])

    validate_leaf_mapping(value["agent_runtimes"], "#{location}.agent_runtimes", %w[source_path target_path])
    validate_leaf_mapping(value["adapters"], "#{location}.adapters", ["path"])
    validate_leaf_mapping(value["prompts"], "#{location}.prompts", ["path"])
  end

  def validate_leaf_mapping(value, location, keys)
    return unless controlled_mapping(value, location, keys)

    keys.each { |field| string(value[field], "#{location}.#{field}") }
  end

  def validate_baseline(value)
    location = "framework.yml: baseline"
    return unless controlled_mapping(value, location, %w[description path_semantics required recommended])

    string(value["description"], "#{location}.description")
    validate_leaf_mapping(value["path_semantics"], "#{location}.path_semantics", %w[source_path target_path])

    required = value["required"]
    recommended = value["recommended"]
    required_valid = sequence(required, "#{location}.required")
    recommended_valid = sequence(recommended, "#{location}.recommended")
    if required_valid && recommended_valid && required.empty? && recommended.empty?
      error(location, "required and recommended must not both be empty")
    end

    identities = []
    targets = []
    [["required", required], ["recommended", recommended]].each do |collection, entries|
      next unless entries.is_a?(Array)

      entries.each_with_index do |entry, index|
        item_location = baseline_location(collection, entry, index)
        next unless controlled_mapping(entry, "framework.yml: #{item_location}", %w[name category source_path target_path description])

        %w[name category source_path target_path description].each do |field|
          string(entry[field], "framework.yml: #{item_location}.#{field}")
        end
        identities << [entry["name"], "framework.yml: #{item_location}.name"]
        targets << [entry["target_path"], "framework.yml: #{item_location}.target_path"]
      end
    end
    validate_unique(identities)
    validate_unique(targets)
  end

  def validate_agent_runtimes(value)
    location = "framework.yml: agent_runtimes"
    return unless controlled_mapping(value, location, %w[philosophy supported planned])

    string(value["philosophy"], "#{location}.philosophy")
    supported_valid = sequence(value["supported"], "#{location}.supported")
    planned_valid = sequence(value["planned"], "#{location}.planned")
    ids = []

    if supported_valid
      value["supported"].each_with_index do |runtime, index|
        item_location = runtime_location("supported", runtime, index)
        validate_supported_runtime(runtime, item_location)
        ids << [runtime["id"], "framework.yml: #{item_location}.id"] if runtime.is_a?(Hash)
      end
    end
    if planned_valid
      value["planned"].each_with_index do |runtime, index|
        item_location = runtime_location("planned", runtime, index)
        validate_planned_runtime(runtime, item_location)
        ids << [runtime["id"], "framework.yml: #{item_location}.id"] if runtime.is_a?(Hash)
      end
    end
    validate_unique(ids)
  end

  def validate_supported_runtime(runtime, item_location)
    fields = %w[id display_name status runtime_version distribution description artefacts supported_platforms required_executables capabilities limitations configuration]
    location = "framework.yml: #{item_location}"
    return unless controlled_mapping(runtime, location, fields)

    %w[id display_name status distribution description].each { |field| string(runtime[field], "#{location}.#{field}") }
    integer(runtime["runtime_version"], "#{location}.runtime_version")
    if runtime["runtime_version"].is_a?(Integer) && runtime["runtime_version"] < 1
      error("#{location}.runtime_version", "expected a positive integer")
    end
    if runtime["status"].is_a?(String) && runtime["status"] != "supported"
      error("#{location}.status", "unsupported runtime status: #{runtime['status'].inspect}; expected: supported")
    end
    if runtime["distribution"].is_a?(String) && !RUNTIME_DISTRIBUTIONS.include?(runtime["distribution"])
      error("#{location}.distribution", "unsupported distribution: #{runtime['distribution'].inspect}; expected one of: #{RUNTIME_DISTRIBUTIONS.join(', ')}")
    end
    validate_runtime_artefacts(runtime["artefacts"], "#{location}.artefacts", runtime["distribution"], runtime.dig("configuration", "type"))
    string_sequence(runtime["supported_platforms"], "#{location}.supported_platforms", non_empty: true, allowed: RUNTIME_PLATFORMS)
    validate_required_executables(runtime["required_executables"], "#{location}.required_executables")
    string_sequence(runtime["capabilities"], "#{location}.capabilities", non_empty: true)
    string_sequence(runtime["limitations"], "#{location}.limitations", non_empty: true)
    validate_runtime_configuration(runtime["configuration"], "#{location}.configuration")
  end

  def validate_planned_runtime(runtime, item_location)
    location = "framework.yml: #{item_location}"
    return unless controlled_mapping(runtime, location, %w[id display_name status description])

    %w[id display_name status description].each { |field| string(runtime[field], "#{location}.#{field}") }
    if runtime["status"].is_a?(String) && runtime["status"] != "planned"
      error("#{location}.status", "unsupported runtime status: #{runtime['status'].inspect}; expected: planned")
    end
  end

  def validate_runtime_artefacts(value, location, distribution, configuration_type)
    return unless sequence(value, location, non_empty: true)

    roles = []
    value.each_with_index do |artefact, index|
      item_location = "#{location}[#{index}]"
      next unless mapping(artefact, item_location)

      valid_shape =
        if distribution == "global-user"
          controlled_mapping(artefact, item_location, %w[role source_path])
        else
          controlled_mapping_with_optional(artefact, item_location, %w[role source_path], %w[target_path])
        end
      next unless valid_shape

      string(artefact["role"], "#{item_location}.role")
      string(artefact["source_path"], "#{item_location}.source_path")
      string(artefact["target_path"], "#{item_location}.target_path") if artefact.key?("target_path")
      if artefact["role"].is_a?(String) && !RUNTIME_ARTEFACT_ROLES.include?(artefact["role"])
        error("#{item_location}.role", "unsupported artefact role: #{artefact['role'].inspect}; expected one of: #{RUNTIME_ARTEFACT_ROLES.join(', ')}")
      end
      roles << [artefact["role"], "#{item_location}.role"]
    end
    validate_unique(roles, label: "role")
    role_values = roles.map(&:first)
    error(location, "supported runtime requires exactly one launcher artefact") unless role_values.count("launcher") == 1
    if configuration_type == "claude-explore"
      %w[installer policy].each do |role|
        error(location, "claude-explore requires exactly one #{role} artefact") unless role_values.count(role) == 1
      end
    elsif configuration_type == "codex"
      error(location, "codex requires exactly one prompt artefact") unless role_values.count("prompt") == 1
    end
  end

  def validate_required_executables(value, location)
    return unless sequence(value, location, non_empty: true)

    names = []
    value.each_with_index do |entry, index|
      item_location = "#{location}[#{index}]"
      next unless controlled_mapping_with_optional(entry, item_location, ["name"], ["minimum_version"])

      string(entry["name"], "#{item_location}.name")
      string(entry["minimum_version"], "#{item_location}.minimum_version") if entry.key?("minimum_version")
      names << [entry["name"], "#{item_location}.name"]
    end
    validate_unique(names)
  end

  def validate_runtime_configuration(value, location)
    return unless mapping(value, location)

    type = value["type"]
    case type
    when "codex"
      return unless controlled_mapping(value, location, %w[type access_modes repository_identity])
      string(type, "#{location}.type")
      string_sequence(value["access_modes"], "#{location}.access_modes", non_empty: true, allowed: ACCESS_MODES)
      validate_repository_identity(value["repository_identity"], "#{location}.repository_identity")
    when "claude-explore"
      return unless controlled_mapping(value, location, %w[type policy_schema_version minimum_client_version])
      string(type, "#{location}.type")
      integer(value["policy_schema_version"], "#{location}.policy_schema_version")
      string(value["minimum_client_version"], "#{location}.minimum_client_version")
      error("#{location}.policy_schema_version", "unsupported policy schema version; expected: 1") if value["policy_schema_version"].is_a?(Integer) && value["policy_schema_version"] != 1
      if value["minimum_client_version"].is_a?(String) && value["minimum_client_version"] != "2.1.224"
        error("#{location}.minimum_client_version", "unsupported minimum client version; expected: 2.1.224")
      end
    else
      controlled_mapping(value, location, ["type"])
      string(type, "#{location}.type")
      error("#{location}.type", "unsupported configuration type: #{type.inspect}") if type.is_a?(String)
    end
  end

  def validate_repository_identity(value, location)
    fields = %w[
      origin_remote_required origin_remote_scheme expected_owner_env
      expected_owner_default expected_repo_env expected_repo_default
    ]
    return unless controlled_mapping(value, location, fields)

    boolean(value["origin_remote_required"], "#{location}.origin_remote_required")
    %w[origin_remote_scheme expected_owner_env expected_owner_default expected_repo_env expected_repo_default].each do |field|
      string(value[field], "#{location}.#{field}")
    end
    if value["origin_remote_scheme"].is_a?(String) && value["origin_remote_scheme"] != "https"
      error("#{location}.origin_remote_scheme", "unsupported origin scheme: #{value['origin_remote_scheme'].inspect}; expected: https")
    end
  end

  def validate_adoption_tiers(value)
    location = "framework.yml: adoption_tiers"
    return unless sequence(value, location, non_empty: true)

    identities = []
    value.each_with_index do |tier, index|
      item_location = collection_location("adoption_tiers", tier, index)
      next unless controlled_mapping(tier, "framework.yml: #{item_location}", %w[id name description includes])

      %w[id name description].each { |field| string(tier[field], "framework.yml: #{item_location}.#{field}") }
      string_sequence(tier["includes"], "framework.yml: #{item_location}.includes", non_empty: true)
      identities << [tier["id"], "framework.yml: #{item_location}.id"]
    end
    validate_unique(identities)
  end

  def validate_adapters(value)
    location = "framework.yml: adapters"
    return unless controlled_mapping(value, location, %w[taxonomy available])

    taxonomy_valid = sequence(value["taxonomy"], "#{location}.taxonomy")
    available_valid = sequence(value["available"], "#{location}.available")
    types = []
    identities = []

    if taxonomy_valid
      value["taxonomy"].each_with_index do |entry, index|
        item_location = adapter_location("taxonomy", entry, index, "type")
        next unless controlled_mapping(entry, "framework.yml: #{item_location}", %w[type description path_pattern])

        %w[type description path_pattern].each { |field| string(entry[field], "framework.yml: #{item_location}.#{field}") }
        validate_path_pattern(entry["path_pattern"], "framework.yml: #{item_location}.path_pattern")
        types << [entry["type"], "framework.yml: #{item_location}.type"]
      end
    end
    if available_valid
      value["available"].each_with_index do |entry, index|
        item_location = adapter_location("available", entry, index, "name")
        next unless controlled_mapping(entry, "framework.yml: #{item_location}", %w[name type path status])

        %w[name type path status].each { |field| string(entry[field], "framework.yml: #{item_location}.#{field}") }
        if entry["status"].is_a?(String) && !ADAPTER_STATUSES.include?(entry["status"])
          error("framework.yml: #{item_location}.status", "unsupported adapter status: #{entry['status'].inspect}")
        end
        if entry["name"].is_a?(String) && entry["type"].is_a?(String)
          identities << [[entry["type"], entry["name"]], "framework.yml: #{item_location}"]
        end
      end
    end
    validate_unique(types)
    validate_unique(identities, label: "adapter identity")
  end

  def validate_path_pattern(value, location)
    return unless value.is_a?(String) && !value.empty?

    validate_relative_syntax(value, location)
    count = value.scan("<name>").length
    error(location, "expected exactly one literal <name> placeholder, got: #{count}") unless count == 1
    error(location, "must not end with a slash: #{value.inspect}") if value.end_with?("/")
  end

  def validate_issue_templates(value)
    location = "framework.yml: issue_templates"
    return unless controlled_mapping(value, location, %w[primary additional])

    identities = []
    primary = value["primary"]
    if validate_issue_template(primary, "issue_templates.primary")
      identities << [primary["id"], "framework.yml: issue_templates.primary.id"]
    end
    if sequence(value["additional"], "#{location}.additional")
      value["additional"].each_with_index do |entry, index|
        item_location = collection_location("issue_templates.additional", entry, index)
        if validate_issue_template(entry, item_location)
          identities << [entry["id"], "framework.yml: #{item_location}.id"]
        end
      end
    end
    validate_unique(identities)
  end

  def validate_issue_template(entry, item_location)
    location = "framework.yml: #{item_location}"
    return false unless controlled_mapping(entry, location, %w[id source_path target_path purpose])

    %w[id source_path target_path purpose].each { |field| string(entry[field], "#{location}.#{field}") }
    true
  end

  def validate_conventions(value)
    location = "framework.yml: conventions"
    fields = %w[issue_workflow command_surface hooks ci commit_metadata]
    return unless controlled_mapping(value, location, fields)

    validate_boolean_mapping(
      value["issue_workflow"], "#{location}.issue_workflow",
      %w[implementation_ready_issues_are_primary discovery_work_should_be_explicit issue_execution_readiness_is_part_of_scope_control]
    )
    validate_boolean_mapping(
      value["command_surface"], "#{location}.command_surface",
      %w[makefile_is_primary_interface local_and_ci_commands_share_conceptual_surface ci_specific_overlays_supported]
    )
    validate_hooks(value["hooks"], "#{location}.hooks")
    validate_ci(value["ci"], "#{location}.ci")
    validate_commit_metadata(value["commit_metadata"], "#{location}.commit_metadata")
  end

  def validate_boolean_mapping(value, location, keys)
    return unless controlled_mapping(value, location, keys)

    keys.each { |field| boolean(value[field], "#{location}.#{field}") }
  end

  def validate_hooks(value, location)
    return unless controlled_mapping(value, location, %w[standard_runner hook_targets])

    string(value["standard_runner"], "#{location}.standard_runner")
    string_sequence(value["hook_targets"], "#{location}.hook_targets", non_empty: true)
  end

  def validate_ci(value, location)
    return unless controlled_mapping(value, location, %w[semantically_grouped_jobs_preferred typical_targets])

    boolean(value["semantically_grouped_jobs_preferred"], "#{location}.semantically_grouped_jobs_preferred")
    string_sequence(value["typical_targets"], "#{location}.typical_targets", non_empty: true)
  end

  def validate_commit_metadata(value, location)
    fields = %w[documented_in default_authorship_model agent_metadata_recorded_in_trailers]
    return unless controlled_mapping(value, location, fields)

    string(value["documented_in"], "#{location}.documented_in")
    string(value["default_authorship_model"], "#{location}.default_authorship_model")
    boolean(value["agent_metadata_recorded_in_trailers"], "#{location}.agent_metadata_recorded_in_trailers")
  end

  # Semantic checks use only objects whose relevant fields have usable types.
  def validate_semantics(metadata)
    return unless metadata.is_a?(Hash)

    baseline = baseline_entries(metadata)
    validate_runtime_references(metadata, baseline)
    validate_issue_template_references(metadata, baseline)
    validate_adoption_references(metadata, baseline)
    validate_adapter_references(metadata)
  end

  def validate_runtime_references(metadata, baseline)
    runtimes = dig_array(metadata, "agent_runtimes", "supported")
    runtimes.each_with_index do |runtime, index|
      next unless runtime.is_a?(Hash)

      item_location = runtime_location("supported", runtime, index)
      next unless runtime["distribution"] == "repository" && runtime["artefacts"].is_a?(Array)

      runtime["artefacts"].each_with_index do |artefact, artefact_index|
        next unless artefact.is_a?(Hash)
        expected_category = {"launcher" => "agent-launcher", "prompt" => "agent-session-brief"}[artefact["role"]]
        next unless expected_category

        validate_baseline_pair_reference(artefact, baseline, "framework.yml: #{item_location}.artefacts[#{artefact_index}]", expected_category)
      end
    end
  end

  def validate_issue_template_references(metadata, baseline)
    issue_templates = metadata["issue_templates"]
    return unless issue_templates.is_a?(Hash)

    entries = [["issue_templates.primary", issue_templates["primary"]]]
    additional = issue_templates["additional"]
    if additional.is_a?(Array)
      additional.each_with_index do |entry, index|
        entries << [collection_location("issue_templates.additional", entry, index), entry]
      end
    end
    entries.each do |location, entry|
      validate_baseline_pair_reference(entry, baseline, "framework.yml: #{location}", "issue-template")
    end
  end

  def validate_baseline_pair_reference(pair, baseline, location, expected_category)
    return unless path_pair_strings?(pair)

    matches = baseline.select do |entry|
      entry["source_path"] == pair["source_path"] && entry["target_path"] == pair["target_path"]
    end
    if matches.empty?
      error(location, "source_path/target_path pair does not match a baseline artefact: #{pair['source_path'].inspect} -> #{pair['target_path'].inspect}")
    elsif matches.length > 1
      error(location, "source_path/target_path pair matches multiple baseline artefacts")
    elsif matches.first["category"] != expected_category
      error("#{location}.category", "matching baseline artefact has category #{matches.first['category'].inspect}; expected: #{expected_category}")
    end
  end

  def validate_adoption_references(metadata, baseline)
    tiers = metadata["adoption_tiers"]
    return unless tiers.is_a?(Array)

    tiers.each_with_index do |tier, tier_index|
      next unless tier.is_a?(Hash) && tier["includes"].is_a?(Array)

      tier_location = collection_location("adoption_tiers", tier, tier_index)
      tier["includes"].each_with_index do |target, index|
        next unless target.is_a?(String) && !target.empty?

        matches = baseline.count { |entry| entry["target_path"] == target }
        location = "framework.yml: #{tier_location}.includes[#{index}]"
        if matches.zero?
          error(location, "unknown baseline target path: #{target}")
        elsif matches > 1
          error(location, "ambiguous baseline target path: #{target}")
        end
      end
    end
  end

  def validate_adapter_references(metadata)
    adapters = metadata["adapters"]
    return unless adapters.is_a?(Hash)

    taxonomy = adapters["taxonomy"].is_a?(Array) ? adapters["taxonomy"].select { |entry| entry.is_a?(Hash) } : []
    available = adapters["available"]
    return unless available.is_a?(Array)

    available.each_with_index do |adapter, index|
      next unless adapter.is_a?(Hash)
      next unless adapter["type"].is_a?(String) && adapter["name"].is_a?(String) && adapter["path"].is_a?(String)

      item_location = adapter_location("available", adapter, index, "name")
      matches = taxonomy.select { |entry| entry["type"] == adapter["type"] }
      if matches.empty?
        error("framework.yml: #{item_location}.type", "unknown adapter taxonomy type: #{adapter['type']}")
        next
      elsif matches.length > 1
        error("framework.yml: #{item_location}.type", "ambiguous adapter taxonomy type: #{adapter['type']}")
        next
      end

      pattern = matches.first["path_pattern"]
      next unless pattern.is_a?(String) && pattern.scan("<name>").length == 1

      expected = pattern.sub("<name>", adapter["name"])
      if adapter["path"] != expected
        error("framework.yml: #{item_location}.path", "path does not match taxonomy pattern; expected: #{expected}, got: #{adapter['path']}")
      end
    end
  end

  # Filesystem checks are role-specific; descriptive path fields are never resolved.
  def validate_metadata_paths(metadata)
    return unless metadata.is_a?(Hash)

    prompts = metadata["prompts"]
    if prompts.is_a?(Array)
      prompts.each_with_index do |entry, index|
        next unless entry.is_a?(Hash)

        location = collection_location("prompts", entry, index)
        validate_source_file(entry["path"], "framework.yml: #{location}.path")
      end
    end

    baseline_entries_with_locations(metadata).each do |entry, location|
      validate_source_file(entry["source_path"], "framework.yml: #{location}.source_path")
      validate_target_path(entry["target_path"], "framework.yml: #{location}.target_path")
    end

    runtimes = dig_array(metadata, "agent_runtimes", "supported")
    runtimes.each_with_index do |runtime, index|
      next unless runtime.is_a?(Hash)

      item_location = runtime_location("supported", runtime, index)
      next unless runtime["artefacts"].is_a?(Array)
      runtime["artefacts"].each_with_index do |artefact, artefact_index|
        next unless artefact.is_a?(Hash)

        artefact_location = "framework.yml: #{item_location}.artefacts[#{artefact_index}]"
        validate_source_file(artefact["source_path"], "#{artefact_location}.source_path")
        validate_target_path(artefact["target_path"], "#{artefact_location}.target_path") if artefact.key?("target_path")
      end
    end

    tiers = metadata["adoption_tiers"]
    if tiers.is_a?(Array)
      tiers.each_with_index do |tier, tier_index|
        next unless tier.is_a?(Hash) && tier["includes"].is_a?(Array)

        tier_location = collection_location("adoption_tiers", tier, tier_index)
        tier["includes"].each_with_index do |target, index|
          validate_target_path(target, "framework.yml: #{tier_location}.includes[#{index}]")
        end
      end
    end

    validate_adapter_paths(metadata)
    validate_issue_template_paths(metadata)
    validate_convention_paths(metadata)
  end

  def validate_adapter_paths(metadata)
    available = dig_array(metadata, "adapters", "available")
    available.each_with_index do |adapter, index|
      next unless adapter.is_a?(Hash)

      location = adapter_location("available", adapter, index, "name")
      path = adapter["path"]
      syntax_valid = validate_source_syntax(path, "framework.yml: #{location}.path")
      next unless syntax_valid && adapter["status"] == "supported"

      validate_existing_source(path, "framework.yml: #{location}.path", :directory)
    end
  end

  def validate_issue_template_paths(metadata)
    issue_templates = metadata["issue_templates"]
    return unless issue_templates.is_a?(Hash)

    entries = [["issue_templates.primary", issue_templates["primary"]]]
    if issue_templates["additional"].is_a?(Array)
      issue_templates["additional"].each_with_index do |entry, index|
        entries << [collection_location("issue_templates.additional", entry, index), entry]
      end
    end
    entries.each do |location, entry|
      next unless entry.is_a?(Hash)

      validate_source_file(entry["source_path"], "framework.yml: #{location}.source_path")
      validate_target_path(entry["target_path"], "framework.yml: #{location}.target_path")
    end
  end

  def validate_convention_paths(metadata)
    commit_metadata = metadata.dig("conventions", "commit_metadata") if metadata["conventions"].is_a?(Hash)
    return unless commit_metadata.is_a?(Hash)

    validate_target_path(commit_metadata["documented_in"], "framework.yml: conventions.commit_metadata.documented_in")
  end

  def validate_repository_structure
    required_files = %w[AGENTS.md README.md framework.yml docs/AGENT_PROMPT.txt scripts/run_codex.sh .github/PULL_REQUEST_TEMPLATE.md]
    required_directories = %w[docs scripts baseline prompts adapters]
    required_files.each { |path| validate_existing_source(path, "repository structure: #{path}", :file) }
    required_directories.each { |path| validate_existing_source(path, "repository structure: #{path}", :directory) }
  end

  def validate_source_file(value, location)
    return unless validate_source_syntax(value, location)

    validate_existing_source(value, location, :file)
  end

  def validate_target_path(value, location)
    return false unless value.is_a?(String) && !value.empty?

    validate_relative_syntax(value, location)
  end

  def validate_source_syntax(value, location)
    return false unless value.is_a?(String) && !value.empty?

    validate_relative_syntax(value, location)
  end

  def validate_relative_syntax(value, location)
    valid = true
    if value.include?("\0")
      error(location, "path must not contain NUL bytes")
      valid = false
    end
    if value.start_with?("/", "~") || value.match?(/\A[A-Za-z]:/)
      error(location, "expected a relative path, got: #{value}")
      valid = false
    end
    if value.include?("\\")
      error(location, "path must use forward slashes: #{value}")
      valid = false
    end
    segments = value.split("/", -1)
    if segments.include?("")
      error(location, "path must not contain empty segments: #{value}")
      valid = false
    end
    if segments.include?(".") || segments.include?("..")
      error(location, "path must not contain '.' or '..' segments: #{value}")
      valid = false
    end
    valid
  end

  def validate_existing_source(value, location, expected_type)
    return false unless value.is_a?(String) && !value.empty?

    path = @root.join(value)
    begin
      resolved = path.realpath
      unless inside_root?(resolved)
        error(location, "path resolves outside repository: #{value}")
        return false
      end
    rescue Errno::ENOENT
      error(location, "#{expected_type == :file ? 'file' : 'directory'} does not exist: #{value}")
      return false
    rescue SystemCallError => e
      kind = expected_type == :file ? "file" : "directory"
      error(location, "could not resolve #{kind}: #{value} (#{e.class.name})")
      return false
    end

    if expected_type == :file && !resolved.file?
      error(location, "expected a regular file: #{value}")
      false
    elsif expected_type == :directory && !resolved.directory?
      error(location, "expected a directory: #{value}")
      false
    else
      true
    end
  end

  def inside_root?(path)
    path_string = path.to_s
    root_string = @root_real.to_s
    path_string == root_string || path_string.start_with?(root_string + File::SEPARATOR)
  end

  def controlled_mapping(value, location, expected_keys)
    return false unless mapping(value, location)

    expected_keys.each do |key|
      error("#{location}.#{key}", "missing required field") unless value.key?(key)
    end
    (value.keys - expected_keys).map(&:to_s).sort.each do |key|
      error("#{location}.#{key}", "unknown field")
    end
    true
  end

  def controlled_mapping_with_optional(value, location, required_keys, optional_keys)
    return false unless mapping(value, location)

    required_keys.each { |key| error("#{location}.#{key}", "missing required field") unless value.key?(key) }
    allowed = required_keys + optional_keys
    (value.keys - allowed).map(&:to_s).sort.each { |key| error("#{location}.#{key}", "unknown field") }
    true
  end

  def mapping(value, location)
    return true if value.is_a?(Hash)

    error(location, "expected a mapping, got: #{yaml_type(value)}")
    false
  end

  def sequence(value, location, non_empty: false)
    unless value.is_a?(Array)
      error(location, "expected a sequence, got: #{yaml_type(value)}")
      return false
    end
    error(location, "expected a non-empty sequence") if non_empty && value.empty?
    true
  end

  def string(value, location)
    unless value.is_a?(String)
      error(location, "expected a string, got: #{yaml_type(value)}")
      return false
    end
    if value.empty?
      error(location, "expected a non-empty string")
      return false
    end
    true
  end

  def boolean(value, location)
    return true if value == true || value == false

    error(location, "expected a boolean, got: #{yaml_type(value)}")
    false
  end

  def integer(value, location)
    return true if value.is_a?(Integer)

    error(location, "expected an integer, got: #{yaml_type(value)}")
    false
  end

  def string_sequence(value, location, non_empty:, allowed: nil)
    return false unless sequence(value, location, non_empty: non_empty)

    identities = []
    value.each_with_index do |entry, index|
      entry_location = "#{location}[#{index}]"
      if string(entry, entry_location)
        identities << [entry, entry_location]
        if allowed && !allowed.include?(entry)
          error(entry_location, "unsupported value: #{entry.inspect}; expected one of: #{allowed.join(', ')}")
        end
      end
    end
    validate_unique(identities)
    true
  end

  def validate_unique(entries, label: "value")
    seen = {}
    entries.each do |value, location|
      next if value.nil? || (value.respond_to?(:empty?) && value.empty?)

      if seen.key?(value)
        printable = value.is_a?(Array) ? value.join("/") : value
        error(location, "duplicate #{label}: #{printable}")
      else
        seen[value] = location
      end
    end
  end

  def baseline_entries(metadata)
    baseline_entries_with_locations(metadata).map(&:first)
  end

  def baseline_entries_with_locations(metadata)
    baseline = metadata["baseline"]
    return [] unless baseline.is_a?(Hash)

    %w[required recommended].flat_map do |collection|
      entries = baseline[collection]
      next [] unless entries.is_a?(Array)

      entries.each_with_index.each_with_object([]) do |(entry, index), result|
        next unless entry.is_a?(Hash)

        result << [entry, baseline_location(collection, entry, index)]
      end
    end
  end

  def dig_array(metadata, *keys)
    value = keys.reduce(metadata) { |current, key| current.is_a?(Hash) ? current[key] : nil }
    value.is_a?(Array) ? value : []
  end

  def path_pair_strings?(value)
    value.is_a?(Hash) && value["source_path"].is_a?(String) && value["target_path"].is_a?(String)
  end

  def collection_location(collection, entry, index)
    identity = entry.is_a?(Hash) && entry["id"].is_a?(String) && !entry["id"].empty? ? entry["id"] : index
    "#{collection}[#{identity}]"
  end

  def baseline_location(collection, entry, index)
    identity = entry.is_a?(Hash) && entry["name"].is_a?(String) && !entry["name"].empty? ? entry["name"] : index
    "baseline.#{collection}[#{identity}]"
  end

  def runtime_location(collection, entry, index)
    identity = entry.is_a?(Hash) && entry["id"].is_a?(String) && !entry["id"].empty? ? entry["id"] : index
    "agent_runtimes.#{collection}[#{identity}]"
  end

  def adapter_location(collection, entry, index, identity_key)
    identity = entry.is_a?(Hash) && entry[identity_key].is_a?(String) && !entry[identity_key].empty? ? entry[identity_key] : index
    "adapters.#{collection}[#{identity}]"
  end

  def yaml_type(value)
    case value
    when Hash then "mapping"
    when Array then "sequence"
    when String then "string"
    when Integer then "integer"
    when TrueClass, FalseClass then "boolean"
    when NilClass then "null"
    else value.class.name
    end
  end

  def error(location, message)
    @errors << "ERROR: #{location}: #{message}"
  end
end

if $PROGRAM_NAME == __FILE__
  repository_root = File.expand_path("..", __dir__)
  validator = FrameworkValidator.new(repository_root)
  if validator.validate
    puts "Framework validation passed."
    exit 0
  end

  validator.errors.sort.each { |diagnostic| warn diagnostic }
  exit 1
end
