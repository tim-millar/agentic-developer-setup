# frozen_string_literal: true

require "json"
require "yaml"

module AgenticDeveloperSetup
  module Assessment
    class Detector
      SUPPORTED_ECOSYSTEMS = %w[node typescript python].freeze
      NODE_PACKAGE_MANAGERS = %w[npm yarn pnpm].freeze
      DOCUMENT_COMMAND_PATTERN = /\b(?:make\s+[A-Za-z0-9_.-]+|(?:npm|yarn|pnpm)\s+(?:run\s+)?[A-Za-z0-9_.:-]+|uv\s+run\s+[^\s`]+|(?:pytest|ruff|mypy|tsc)\b)/
      CI_COMMAND_PATTERN = /(?:make\s+[A-Za-z0-9_.-]+|(?:npm|yarn|pnpm)\s+(?:run\s+)?[A-Za-z0-9_.:-]+|(?:uv\s+run\s+[^\s`]+|pytest|ruff|mypy|tsc)\b)/
      DIRECT_EVIDENCE_METHODS = %w[
        package_json_project_metadata package_manager_lockfile package_json_manager
        pyproject_project_metadata requirements_project_metadata requirements_file uv_lockfile
        typescript_configuration typescript_dependency typescript_package_script
        pytest_configuration ruff_configuration ruff_formatter_configuration mypy_configuration
        eslint_dependency eslint_configuration prettier_dependency prettier_configuration
        package_script_test_framework package_script_type_checker package_scripts
        package_validation_script make_validation_target verification_command verification_script
        package_build_script python_build_configuration make_command_surface make_target
      ].freeze

      def initialize(inventory, catalogue, evidence)
        @inventory = inventory
        @catalogue = catalogue
        @evidence = evidence
      end

      def analyze
        @package = parse_json("package.json")
        @pyproject = text("pyproject.toml")
        @make_targets = make_targets
        @documentation = documentation
        @ci = ci_findings
        @local_commands = local_commands
        {
          scope: scope,
          ecosystem: ecosystems,
          tooling: tooling,
          validation: validation,
          documentation: @documentation,
          facts: facts
        }
      end

      private

      def facts
        {
          make_targets: @make_targets,
          package_scripts: package_scripts.keys.sort,
          local_commands: @local_commands,
          ci_commands: @ci[:commands].sort,
          ci_validation_workflow_paths: @ci[:validation_paths].sort,
          ci_present: !@ci[:paths].empty?,
          ci_invocations: @ci[:invocation_keys],
          issue_template_components: issue_template_components,
          ecosystems: ecosystem_facts,
          framework_paths: @inventory.files.keys.sort
        }
      end

      def scope
        roots = @inventory.candidate_project_files.map { |path| File.dirname(path).sub(%r{\A\./}, "") }
        roots = roots.map { |root| root.empty? ? "." : root }.uniq.sort
        {
          "type" => "repository",
          "project_roots" => roots,
          "shape" => if roots.empty?
                       "unknown"
                     elsif roots.length == 1
                       "single_project"
                     else
                       "multiple_projects"
                     end,
          "excluded_paths" => @inventory.excluded_paths.sort,
          "ignored_paths" => @inventory.ignored_paths.sort,
          "symlink_boundaries" => @inventory.symlink_boundaries.sort
        }
      end

      def ecosystem_facts
        facts = []
        add_ecosystem_fact(facts, "python", python_evidence, "Python project metadata detected")
        add_ecosystem_fact(facts, "node", node_evidence, "Node.js project metadata detected")
        add_ecosystem_fact(facts, "typescript", typescript_evidence, "TypeScript configuration or package detected")

        unsupported = %w[Cargo.toml go.mod Gemfile composer.json pom.xml mix.exs].select { |path| @inventory.exists?(path) }
        unless unsupported.empty?
          keys = unsupported.map { |path| file(path, "unsupported_ecosystem_marker", "Unsupported ecosystem marker detected") }
          facts << { name: "unsupported", evidence: keys, paths: unsupported.sort, confidence: "low" }
        end
        facts.sort_by { |entry| entry[:name] }
      end

      def ecosystems
        facts = ecosystem_facts
        ordered = facts.sort_by { |entry| [entry[:paths].first.to_s, entry[:name]] }
        ordered.each_with_index.map do |entry, index|
          {
            "name" => entry[:name],
            "role" => index.zero? ? "primary" : "secondary",
            "status" => "detected",
            "confidence" => entry[:confidence],
            "paths" => entry[:paths].sort,
            "evidence_ids" => @evidence.ids_for(entry[:evidence]),
            "signals" => entry[:signals] || []
          }
        end
      end

      def add_ecosystem_fact(collection, name, evidence_keys, summary)
        return if evidence_keys.empty?

        paths = evidence_keys.filter_map { |key| evidence_path(key) }.uniq
        collection << {
          name: name,
          evidence: evidence_keys,
          paths: paths,
          confidence: confidence_for(evidence_keys),
          signals: [summary]
        }
      end

      def python_evidence
        keys = []
        pyprojects = @inventory.files.keys.select { |path| File.basename(path).casecmp("pyproject.toml").zero? }
        pyprojects.each { |path| keys << file(path, "pyproject_project_metadata", "Python project metadata detected") }
        requirements = @inventory.files.keys.select { |path| File.basename(path).match?(/\Arequirements[^\/]*\.txt\z/i) }
        requirements.each { |path| keys << file(path, "requirements_project_metadata", "Requirements-based Python project metadata detected") }
        @inventory.files.keys.select { |path| File.basename(path) == "uv.lock" }.each { |path| keys << file(path, "uv_lockfile", "uv lockfile detected") }
        keys
      end

      def node_evidence
        keys = []
        @inventory.files.keys.select { |path| File.basename(path) == "package.json" }.each do |path|
          keys << file(path, "package_json_project_metadata", "Node.js package manifest detected")
        end
        @inventory.files.keys.select { |path| %w[package-lock.json yarn.lock pnpm-lock.yaml].include?(File.basename(path)) }.each do |path|
          keys << file(path, "package_manager_lockfile", "Node.js package-manager lockfile detected")
        end
        keys
      end

      def typescript_evidence
        keys = @inventory.files.keys.select { |path| File.basename(path).match?(/\Atsconfig[^\/]*\.json\z/i) }.map do |path|
          file(path, "typescript_configuration", "TypeScript configuration detected")
        end
        if package_dependencies.keys.any? { |name| name == "typescript" }
          keys << file("package.json", "typescript_dependency", "TypeScript package dependency detected")
        end
        keys
      end

      def typescript_script_evidence
        package_scripts.filter_map do |name, command|
          next unless command.to_s.match?(/\btsc(?:\s|\z)/)

          file("package.json", "package_script_type_checker", "Package script #{name} invokes the TypeScript compiler")
        end
      end

      def tooling
        clean_internal({
          "package_managers" => package_managers,
          "test_frameworks" => test_frameworks,
          "linters" => linters,
          "formatters" => formatters,
          "type_checkers" => type_checkers,
          "task_runners" => task_runners,
          "command_surface" => command_surface,
          "ci" => ci_tooling,
          "hooks" => hooks,
          "workspace" => workspace_tooling,
          "containerisation" => containerisation
        })
      end

      def package_managers
        managers = Hash.new { |hash, key| hash[key] = [] }
        declaration = package_manager_declaration
        lockfiles = { "package-lock.json" => "npm", "yarn.lock" => "yarn", "pnpm-lock.yaml" => "pnpm" }.filter_map do |path, manager|
          [manager, path] if @inventory.exists?(path)
        end

        if declaration[:state] == :supported
          managers[declaration[:name]] << file("package.json", "package_json_manager", "Package manager declared in package manifest")
        elsif declaration[:state] == :unsupported
          managers[declaration[:name]] << file("package.json", "unsupported_package_manager_declaration", "Unsupported package manager declared in package manifest")
        elsif lockfiles.empty? && @inventory.exists?("package.json")
          managers["npm"] << file("package.json", "package_json_default_manager", "npm-compatible package manifest detected")
        end
        lockfiles.each do |manager, path|
          managers[manager] << file(path, "package_manager_lockfile", "#{manager} lockfile detected")
        end
        managers["uv"] << file("uv.lock", "uv_lockfile", "uv lockfile detected") if @inventory.exists?("uv.lock")
        if @inventory.files.keys.any? { |path| path.match?(/\Arequirements[^\/]*\.txt\z/i) }
          path = @inventory.files.keys.grep(/\Arequirements[^\/]*\.txt\z/i).first
          managers["pip"] << file(path, "requirements_file", "pip-compatible requirements file detected")
        end

        node_names = managers.keys.select { |name| NODE_PACKAGE_MANAGERS.include?(name) }
        unsupported_declaration = declaration[:state] == :unsupported
        conflict = node_names.length > 1 || (unsupported_declaration && lockfiles.any?)
        managers.keys.sort.map do |name|
          keys = managers.fetch(name).compact
          {
            "name" => name,
            "status" => if conflict && (NODE_PACKAGE_MANAGERS.include?(name) || name == declaration[:name])
                           "conflicting"
                         elsif declaration[:state] == :unsupported && name == declaration[:name]
                           "unknown"
                         else
                           "detected"
                         end,
            "confidence" => if conflict && (NODE_PACKAGE_MANAGERS.include?(name) || name == declaration[:name])
                              "low"
                            elsif declaration[:state] == :unsupported && name == declaration[:name]
                              "low"
                            elsif name == "npm" && declaration[:state] == :absent && lockfiles.empty?
                              "medium"
                            else
                              confidence_for(keys)
                            end,
            "evidence_ids" => @evidence.ids_for(keys),
            "_evidence_keys" => keys
          }
        end
      end

      def test_frameworks
        entries = []
        pytest_keys = python_tool_evidence("pytest", "pytest_configuration", "pytest configuration or dependency detected")
        if pytest_keys.any?
          entries << tool_entry_with_keys("pytest", "Python test framework detected", pytest_keys)
        end
        package_scripts.each do |name, command|
          next unless command.to_s.match?(/\b(?:jest|vitest|mocha)\b/i)

          entries << tool_entry_with_keys(command[/\b(?:jest|vitest|mocha)\b/i].downcase, "Node test framework referenced by package script", [file("package.json", "package_script_test_framework", "Node test framework referenced by package script")])
        end
        entries.sort_by { |entry| entry["name"] }
      end

      def linters
        entries = []
        if python_tool_evidence("ruff", "ruff_configuration", "Ruff configuration or dependency detected").any? || @inventory.exists?("ruff.toml") || @inventory.exists?(".ruff.toml")
          keys = python_tool_evidence("ruff", "ruff_configuration", "Ruff configuration or dependency detected")
          %w[ruff.toml .ruff.toml].each { |path| keys << file(path, "ruff_configuration", "Ruff configuration detected") if @inventory.exists?(path) }
          entries << tool_entry_with_keys("Ruff", "Python linting tool detected", keys)
        end
        if package_dependencies.keys.any? { |name| name == "eslint" } || eslint_config_path
          keys = [file("package.json", "eslint_dependency", "ESLint package detected")].compact
          keys << file(eslint_config_path, "eslint_configuration", "ESLint configuration detected") if eslint_config_path
          entries << tool_entry_with_keys("ESLint", "Node linting tool detected", keys)
        end
        entries.sort_by { |entry| entry["name"] }
      end

      def formatters
        entries = []
        ruff_keys = python_tool_evidence("ruff", "ruff_formatter_configuration", "Ruff formatter configuration or dependency detected", section_prefix: "tool.ruff.format")
        if ruff_keys.any?
          entries << tool_entry_with_keys("Ruff format", "Python formatter detected", ruff_keys)
        end
        if package_dependencies.keys.any? { |name| name == "prettier" } || prettier_config_path
          keys = [file("package.json", "prettier_dependency", "Prettier package detected")].compact
          keys << file(prettier_config_path, "prettier_configuration", "Prettier configuration detected") if prettier_config_path
          entries << tool_entry_with_keys("Prettier", "Node formatter detected", keys)
        end
        entries.sort_by { |entry| entry["name"] }
      end

      def type_checkers
        entries = []
        if python_tool_evidence("mypy", "mypy_configuration", "mypy configuration or dependency detected").any? || @inventory.exists?("mypy.ini")
          keys = python_tool_evidence("mypy", "mypy_configuration", "mypy configuration or dependency detected")
          keys << file("mypy.ini", "mypy_configuration", "mypy configuration detected") if @inventory.exists?("mypy.ini")
          entries << tool_entry_with_keys("mypy", "Python static type checker detected", keys)
        end
        typescript_keys = typescript_evidence + typescript_script_evidence
        if typescript_keys.any?
          entries << tool_entry_with_keys("TypeScript compiler", "TypeScript compiler detected", typescript_keys)
        end
        entries.sort_by { |entry| entry["name"] }
      end

      def task_runners
        entries = []
        entries << tool_entry_with_keys("Make", "Make command interface detected", [file("Makefile", "make_command_surface", "Makefile command interface detected")]) if @inventory.exists?("Makefile")
        entries << tool_entry_with_keys("package.json scripts", "Package scripts command interface detected", [file("package.json", "package_scripts", "package scripts detected")]) if package_scripts.any?
        entries.sort_by { |entry| entry["name"] }
      end

      def command_surface
        commands = []
        @make_targets.each do |target|
          commands << { "name" => "make #{target}", "source" => "Makefile", "evidence_ids" => @evidence.ids_for([file("Makefile", "make_target", "Make target #{target} declared")]) }
        end
        package_scripts.keys.sort.each do |name|
          commands << { "name" => "package script #{name}", "source" => "package.json", "evidence_ids" => @evidence.ids_for([file("package.json", "package_script", "Package script #{name} declared")]) }
        end
        docs_commands.each do |entry|
          commands << { "name" => entry[:command], "source" => "documentation", "evidence_ids" => @evidence.ids_for(entry[:keys]) }
        end
        commands = commands.uniq { |entry| entry["name"] }.sort_by { |entry| entry["name"] }
        {
          "status" => commands.empty? ? "not_detected" : "detected",
          "commands" => commands
        }
      end

      def ci_tooling
        {
          "provider" => @ci[:paths].empty? ? "none_detected" : "github_actions",
          "workflow_paths" => @ci[:paths].sort,
          "invocations" => @ci[:commands].sort,
          "evidence_ids" => @evidence.ids_for(@ci[:file_keys] + @ci[:invocation_keys])
        }
      end

      def hooks
        paths = @inventory.files.keys.select do |path|
          path.match?(%r{\A(?:\.pre-commit-config\.ya?ml|lefthook\.ya?ml|\.husky/)}i)
        end
        {
          "status" => paths.empty? ? "not_detected" : "detected",
          "paths" => paths.sort,
          "evidence_ids" => @evidence.ids_for(paths.map { |path| file(path, "hook_configuration", "Hook configuration detected") })
        }
      end

      def workspace_tooling
        workspaces = @package && @package["workspaces"]
        detected = workspaces.is_a?(Array) || workspaces.is_a?(Hash) || @inventory.exists?("pnpm-workspace.yaml")
        {
          "status" => detected ? "detected" : "not_detected",
          "evidence_ids" => detected ? @evidence.ids_for([file("package.json", "workspace_configuration", "Workspace configuration detected"), file("pnpm-workspace.yaml", "workspace_configuration", "pnpm workspace configuration detected")]) : []
        }
      end

      def containerisation
        paths = @inventory.files.keys.grep(/\ADockerfile[^\/]*\z/i)
        {
          "status" => paths.empty? ? "not_detected" : "detected",
          "paths" => paths.sort,
          "evidence_ids" => @evidence.ids_for(paths.map { |path| file(path, "containerisation_marker", "Containerisation metadata detected") })
        }
      end

      def validation
        test_keys = test_frameworks.flat_map { |entry| entry["_evidence_keys"] || [] } + test_directory_evidence
        test_command_keys = package_test_command_evidence + make_test_command_evidence
        lint_keys = linters.flat_map { |entry| entry["_evidence_keys"] || [] }
        lint_invocation_keys = validation_tool_invocation_evidence("linting")
        type_keys = type_checkers.flat_map { |entry| entry["_evidence_keys"] || [] }
        type_invocation_keys = validation_tool_invocation_evidence("static_type_checking")
        {
          "capabilities" => {
            "tests" => capability("tests", test_keys.any? || test_command_keys.any?, test_keys + test_command_keys),
            "linting" => capability("linting", lint_invocation_keys.any?, lint_keys + lint_invocation_keys),
            "formatting" => capability("formatting", formatters.any?, formatters.flat_map { |entry| entry["_evidence_keys"] || [] }),
            "static_type_checking" => capability("static_type_checking", type_invocation_keys.any?, type_keys + type_invocation_keys),
            "build_compile" => build_capability,
            "standard_local_verification" => standard_verification,
            "ci_execution" => ci_execution,
            "local_hooks" => hooks,
            "validation_documentation" => validation_documentation
          },
          "ci_alignment" => ci_alignment,
          "local_commands" => @local_commands,
          "ci_commands" => @ci[:commands].sort
        }
      end

      def capability(_name, implementation, keys)
        signals = []
        signals << "implementation_detected" if implementation
        signals << "configuration_detected" unless keys.empty?
        signals.concat(documented_signals_for(_name))
        signals.concat(ci_signals_for(_name))
        {
          "status" => signals.first || "not_detected",
          "signals" => signals.uniq,
          "evidence_ids" => @evidence.ids_for(keys + documentation_evidence_for(_name) + ci_evidence_for(_name))
        }
      end

      def build_capability
        keys = []
        implementation = package_scripts.keys.any? { |name| name.match?(/\A(?:build|compile)\z/i) } || pyproject_has_section?("build-system")
        keys << file("package.json", "package_build_script", "Package build script detected") if package_scripts.keys.any? { |name| name.match?(/\A(?:build|compile)\z/i) }
        keys << file("pyproject.toml", "python_build_configuration", "Python build configuration detected") if pyproject_has_section?("build-system")
        capability("build_compile", implementation, keys.compact)
      end

      def package_test_command_evidence
        package_scripts.filter_map do |name, command|
          next unless name.match?(/\Atest(?:-|:|\z)/i) || command.to_s.match?(/\b(?:pytest|jest|vitest|mocha)\b/i)

          file("package.json", "package_validation_script", "Package script #{name} provides a local test command")
        end
      end

      def make_test_command_evidence
        make_target_evidence(/\Atest(?:-|\z)/i, /\b(?:pytest|jest|vitest|mocha|npm\s+(?:run\s+)?test|yarn\s+(?:run\s+)?test|pnpm\s+(?:run\s+)?test)\b/i, "test")
      end

      def validation_tool_invocation_evidence(capability)
        case capability
        when "linting"
          package_tool_evidence(/\b(?:eslint|ruff)\b/i, "linting") + make_target_evidence(/\A(?:lint|check|verify)(?:-|\z)/i, /\b(?:eslint|ruff)\b/i, "linting")
        when "static_type_checking"
          typescript_script_evidence + package_tool_evidence(/\b(?:mypy|tsc)\b/i, "type checking") + make_target_evidence(/\A(?:typecheck|type-check|check|verify)(?:-|\z)/i, /\b(?:mypy|tsc)\b/i, "type checking")
        else
          []
        end
      end

      def package_tool_evidence(pattern, label)
        package_scripts.filter_map do |name, command|
          next unless command.to_s.match?(pattern)

          file("package.json", "package_validation_script", "Package script #{name} invokes a #{label} tool")
        end
      end

      def make_target_evidence(target_pattern, command_pattern, label)
        @make_targets.filter_map do |target|
          next unless target.match?(target_pattern) && make_target_body(target).match?(command_pattern)

          file("Makefile", "make_validation_target", "Make target #{target} invokes a #{label} tool")
        end
      end

      def make_target_body(target)
        content = text("Makefile").to_s
        body = []
        active = false
        content.lines.each do |line|
          if line.match?(/\A#{Regexp.escape(target)}\s*:/)
            active = true
          elsif active && line.match?(/\A\S/)
            break
          elsif active
            body << line
          end
        end
        body.join
      end

      def standard_verification
        candidates = @make_targets.select { |target| %w[check verify].include?(target) }
        candidates += package_scripts.keys.select { |name| name.match?(/\A(?:check|verify)\z/) }
        keys = []
        keys << file("Makefile", "verification_command", "Standard verification Make target detected") if @make_targets.any? { |target| %w[check verify].include?(target) }
        keys << file("package.json", "verification_script", "Standard verification package script detected") if package_scripts.keys.any? { |name| %w[check verify].include?(name) }
        {
          "status" => candidates.empty? ? "not_detected" : "documented_command_detected",
          "commands" => candidates.sort,
          "evidence_ids" => @evidence.ids_for(keys.compact)
        }
      end

      def ci_execution
        {
          "status" => @ci[:paths].empty? ? "not_detected" : (@ci[:commands].empty? ? "configuration_detected" : "ci_invocation_detected"),
          "evidence_ids" => @evidence.ids_for(@ci[:file_keys] + @ci[:invocation_keys])
        }
      end

      def validation_documentation
        keys = documentation_evidence_for("validation")
        {
          "status" => keys.empty? ? "not_detected" : "documented_command_detected",
          "signals" => keys.empty? ? [] : ["documented_command_detected"],
          "evidence_ids" => @evidence.ids_for(keys)
        }
      end

      def ci_alignment
        if @ci[:paths].empty?
          return {
            "status" => "not_applicable",
            "confidence" => "high",
            "evidence_ids" => [],
            "local_commands" => @local_commands,
            "ci_commands" => []
          }
        end

        local_identities = @local_commands.select { |command| validation_command?(command) }
          .map { |command| command_identity(command) }.uniq
        ci_identities = @ci[:commands].select { |command| validation_command?(command) }
          .map { |command| command_identity(command) }.uniq
        complete = !local_identities.empty? && !ci_identities.empty? &&
          (local_identities == ci_identities || coherent_verification_alignment?(local_identities, ci_identities))
        keys = @ci[:file_keys] + @ci[:invocation_keys]
        {
          "status" => complete ? "ready" : "partial",
          "confidence" => @ci[:invocation_keys].empty? ? "medium" : "high",
          "evidence_ids" => @evidence.ids_for(keys),
          "local_commands" => @local_commands.sort,
          "ci_commands" => @ci[:commands].sort
        }
      end

      def documentation
        {
          "root_readme" => doc_entry(root_paths(/\AREADME/i), "README documentation detected"),
          "development_guide" => doc_entry(paths_for(/\A(?:CONTRIBUTING|docs\/DEVELOPMENT)/i), "Development guidance detected"),
          "architecture" => doc_entry(paths_for(/\A(?:docs\/)?ARCHITECTURE/i), "Architecture documentation detected"),
          "domain" => doc_entry(paths_for(/\Adocs\/DOMAIN/i), "Domain documentation detected"),
          "testing" => doc_entry(paths_for(/\A(?:docs\/TESTING|testing)/i), "Testing guidance detected"),
          "security" => doc_entry(paths_for(/\A(?:SECURITY|docs\/SECURITY)/i), "Security guidance detected"),
          "deployment_operations" => doc_entry(paths_for(/\A(?:docs\/)?(?:DEPLOY|OPERATIONS)/i), "Deployment or operations guidance detected"),
          "adrs" => doc_entry(paths_for(%r{\Adocs/(?:adr|adrs)/}i), "Architecture decision records detected", ambiguous: false),
          "agent_instructions" => doc_entry(root_paths(/\A(?:AGENTS|CLAUDE)\.md\z/i), "Repository agent instructions detected"),
          "issue_templates" => doc_entry(@inventory.files.keys.grep(%r{\A\.github/ISSUE_TEMPLATE/}i), "Issue templates detected", ambiguous: false),
          "pull_request_template" => doc_entry(@inventory.files.keys.grep(%r{\A\.github/PULL_REQUEST_TEMPLATE(?:/.*)?\.md\z}i), "Pull request template detected", ambiguous: false),
          "ownership" => doc_entry(@inventory.files.keys.grep(%r{\A(?:CODEOWNERS|\.github/CODEOWNERS)\z}i), "Ownership metadata detected")
        }
      end

      def issue_template_components
        paths = @inventory.files.keys.grep(%r{\A\.github/ISSUE_TEMPLATE/}i).sort
        {
          "agent_ready_issue_template" => paths.select { |path| issue_template_signal?(path, /agent[-_ ]?ready|implementation|acceptance criteria|non[- ]goals?|implementation boundaries?/i) },
          "bug_report_issue_template" => paths.select { |path| issue_template_signal?(path, /bug|defect|steps to reproduce|expected behavior|actual behavior/i) },
          "discovery_or_shaping_issue_template" => paths.select { |path| issue_template_signal?(path, /discovery|shaping|problem statement|open questions|unknowns/i) },
          "issue_template_config" => paths.select { |path| File.basename(path).match?(/\Aconfig\.ya?ml\z/i) || text(path).to_s.match?(/blank_issues_enabled|contact_links/i) }
        }
      end

      def issue_template_signal?(path, pattern)
        File.basename(path).match?(pattern) || text(path).to_s.match?(pattern)
      end

      def doc_entry(paths, summary, ambiguous: paths.length > 1)
        paths = paths.sort
        keys = paths.map { |path| file(path, "documentation_presence", summary) }
        {
          "status" => paths.empty? ? "not_detected" : "present",
          "paths" => paths,
          "discoverability" => paths.empty? ? "unknown" : "obvious",
          "ambiguity" => ambiguous,
          "evidence_ids" => @evidence.ids_for(keys)
        }
      end

      def docs_commands
        @docs_commands ||= begin
          entries = @inventory.files.keys.sort.flat_map do |path|
            next unless path.start_with?("docs/") || path.match?(/\AREADME|\ACONTRIBUTING/i)

            content = text(path).to_s
            extract_commands(content, DOCUMENT_COMMAND_PATTERN).map do |command|
              { command: command, key: documented_command(path, command) }
            end
          end.compact
          entries.group_by { |entry| command_identity(entry[:command]) }.values.map do |group|
            representative = group.map { |entry| entry[:command] }.min
            { command: representative, keys: group.map { |entry| entry[:key] }.compact.uniq }
          end.sort_by { |entry| [command_identity(entry[:command]), entry[:command]] }
        end
      end

      def documentation_evidence_for(name)
        return docs_commands.select { |entry| validation_command?(entry[:command]) }.flat_map { |entry| entry[:keys] } if name == "validation"

        []
      end

      def documented_signals_for(name)
        return [] unless name == "tests" || name == "linting" || name == "formatting" || name == "static_type_checking"

        docs_commands.any? { |entry| documented_command_matches?(name, entry[:command]) } ? ["documented_command_detected"] : []
      end

      def ci_signals_for(name)
        token = { "tests" => /test|pytest/, "linting" => /lint|ruff|eslint/, "formatting" => /format|prettier/, "static_type_checking" => /type|mypy|tsc/ }[name]
        token && @ci[:commands].any? { |command| command.match?(token) } ? ["ci_invocation_detected"] : []
      end

      def ci_evidence_for(name)
        token = { "tests" => /test|pytest/, "linting" => /lint|ruff|eslint/, "formatting" => /format|prettier/, "static_type_checking" => /type|mypy|tsc/ }[name]
        token ? @ci[:invocations].filter_map { |entry| entry[:key] if entry[:command].match?(token) } : []
      end

      def validation_command?(command)
        identity = command_identity(command)
        identity.match?(/\A(?:make|package):(?:test|check|verify|lint|format|format-check|typecheck|build|compile)\z/) ||
          %w[tool:pytest tool:ruff tool:mypy tool:tsc].include?(identity)
      end

      def coherent_verification_alignment?(local_identities, ci_identities)
        verification = %w[make:check make:verify package:check package:verify]
        (local_identities & verification).any? { |identity| ci_identities.include?(identity) }
      end

      def documented_command_matches?(name, command)
        identity = command_identity(command)
        case name
        when "tests"
          identity.match?(/\A(?:make|package):test\z/) || identity == "tool:pytest"
        when "linting"
          identity.match?(/\A(?:make|package):lint\z/) || identity == "tool:ruff" || command.to_s.match?(/\A(?:npm|yarn|pnpm)\s+(?:run\s+)?lint\z/i)
        when "formatting"
          identity.match?(/\A(?:make|package):format(?:-check)?\z/) || identity == "tool:ruff" || identity == "package:prettier"
        when "static_type_checking"
          identity.match?(/\A(?:make|package):typecheck\z/) || %w[tool:mypy tool:tsc].include?(identity)
        else
          false
        end
      end

      def package_scripts
        scripts = @package.is_a?(Hash) ? @package["scripts"] : {}
        scripts.is_a?(Hash) ? scripts.transform_keys(&:to_s) : {}
      end

      def declared_package_manager
        package_manager_declaration[:name] if package_manager_declaration[:state] == :supported
      end

      def package_manager_declaration
        return { state: :absent, name: nil } unless @package.is_a?(Hash) && @package.key?("packageManager")

        declaration = @package["packageManager"].to_s
        name = declaration[/\A([A-Za-z][A-Za-z0-9_.-]*)/, 1].to_s.downcase
        name = "unknown" if name.empty?
        state = NODE_PACKAGE_MANAGERS.include?(name) ? :supported : :unsupported
        { state: state, name: name }
      end

      def test_directory_evidence
        directory_keys = %w[test tests].filter_map do |path|
          directory(path, "test_directory", "Generic test directory detected")
        end
        file_keys = @inventory.files.keys.select { |path| path.start_with?("test/") || path.start_with?("tests/") }
          .map { |path| file(path, "test_directory", "Generic test file detected") }
          .compact
        directory_keys + file_keys
      end

      def package_dependencies
        return {} unless @package.is_a?(Hash)

        %w[dependencies devDependencies peerDependencies].each_with_object({}) do |group, result|
          values = @package[group]
          result.merge!(values) if values.is_a?(Hash)
        end
      end

      def eslint_config_path
        @inventory.files.keys.find { |path| File.basename(path).match?(/\A(?:eslint\.config\..*|\.eslintrc(?:\..*)?)\z/i) }
      end

      def prettier_config_path
        @inventory.files.keys.find { |path| File.basename(path).match?(/\A(?:prettier\.config\..*|\.prettierrc(?:\..*)?)\z/i) }
      end

      def local_commands
        commands = @make_targets.map { |target| "make #{target}" }
        commands.concat(package_scripts.keys.map { |name| "package script #{name}" })
        commands.concat(docs_commands.map { |entry| entry[:command] })
        commands.uniq.sort
      end

      def make_targets
        content = text("Makefile")
        return [] unless content

        content.lines.filter_map do |line|
          match = line.match(/^([A-Za-z0-9_.-]+)\s*:(?!=)/)
          match && match[1] unless match && %w[.PHONY .DEFAULT_GOAL].include?(match[1])
        end.uniq.sort
      end

      def ci_findings
        paths = @inventory.files.keys.grep(%r{\A\.github/workflows/.*\.(?:yml|yaml)\z}i).sort
        file_keys = paths.map { |path| file(path, "github_actions_workflow", "GitHub Actions workflow detected") }
        invocations = []
        validation_paths = []
        paths.each do |path|
          path_has_validation = false
          github_actions_run_values(text(path)).each do |run_value|
            extract_commands(run_value, CI_COMMAND_PATTERN).each do |command|
              key = file(path, "ci_invocation", "GitHub Actions invokes #{command}", type: "ci_invocation")
              invocations << { command: command, key: key }
              path_has_validation = true if validation_command?(command)
            end
          end
          validation_paths << path if path_has_validation
        end
        invocations = invocations.uniq { |entry| [entry[:command], entry[:key]] }
        { paths: paths, validation_paths: validation_paths, file_keys: file_keys, invocation_keys: invocations.map { |entry| entry[:key] }, invocations: invocations, commands: invocations.map { |entry| entry[:command] }.uniq.sort }
      end

      def parse_json(path)
        content = text(path)
        return nil unless content

        JSON.parse(content)
      rescue JSON::ParserError
        nil
      end

      def extract_commands(content, pattern)
        content.to_s.lines.flat_map do |line|
          next [] if line.lstrip.start_with?("#")

          line.scan(pattern)
        end.map(&:strip).reject(&:empty?).uniq
      end

      def github_actions_run_values(content)
        parsed = YAML.safe_load(content.to_s, permitted_classes: [], permitted_symbols: [], aliases: false)
        jobs = parsed.is_a?(Hash) ? parsed["jobs"] : nil
        return [] unless jobs.is_a?(Hash)

        jobs.keys.sort.flat_map do |job_name|
          job = jobs[job_name]
          steps = job.is_a?(Hash) ? job["steps"] : nil
          next [] unless steps.is_a?(Array)

          steps.filter_map do |step|
            value = step.is_a?(Hash) ? step["run"] : nil
            value if value.is_a?(String)
          end
        end
      rescue Psych::Exception
        []
      end

      def command_identity(command)
        normalized = command.to_s.strip.gsub(/\s+/, " ")
        case normalized
        when /\Amake\s+([A-Za-z0-9_.-]+)\z/
          "make:#{$1}"
        when /\Apackage script\s+([A-Za-z0-9_.:-]+)\z/
          "package:#{$1}"
        when /\A(?:npm|yarn|pnpm)\s+(?:run\s+)?([A-Za-z0-9_.:-]+)\z/
          "package:#{$1}"
        when /\Auv\s+run\s+(.+)\z/
          command_identity(Regexp.last_match(1))
        when /\A(pytest|ruff|mypy|tsc)(?:\s|\z)/
          "tool:#{$1}"
        else
          "raw:#{normalized}"
        end
      end

      def python_tool_evidence(tool, method, summary, section_prefix: "tool.%<tool>s")
        keys = []
        normalized_tool = normalize_python_name(tool)
        keys << file("pyproject.toml", method, summary) if pyproject_dependency_names.include?(normalized_tool)
        section_prefix = format(section_prefix, tool: tool)
        keys << file("pyproject.toml", method, summary) if pyproject_has_section?(section_prefix)
        @inventory.files.keys.grep(/\Arequirements[^\/]*\.txt\z/i).each do |path|
          keys << file(path, method, summary) if requirements_dependency_names(path).include?(normalized_tool)
        end
        keys << file("mypy.ini", method, summary) if tool == "mypy" && @inventory.exists?("mypy.ini")
        keys
      end

      def python_dependency_names
        @python_dependency_names ||= (pyproject_dependency_names + requirements_dependency_names).uniq
      end

      def pyproject_dependency_names
        names = []
        pyproject_sections.each do |section, lines|
          assignments = pyproject_assignments(lines)
          if section == "project"
            assignments.each do |key, value|
              next unless key == "dependencies"

              names.concat(extract_quoted_values(value).map { |item| python_package_name(item) })
            end
          elsif section.start_with?("project.optional-dependencies", "dependency-groups")
            assignments.each_value { |value| names.concat(extract_quoted_values(value).map { |item| python_package_name(item) }) }
          elsif section == "tool.poetry.dependencies" || section.match?(/\Atool\.poetry\.group\..+\.dependencies\z/)
            assignments.each_key { |key| names << normalize_python_name(key) unless key == "python" }
          end
        end
        names.compact
      end

      def requirements_dependency_names(path = nil)
        paths = path ? [path] : @inventory.files.keys.grep(/\Arequirements[^\/]*\.txt\z/i)
        paths.flat_map do |requirement_path|
          text(requirement_path).to_s.lines.filter_map do |line|
            requirement_package_name(line)
          end
        end
      end

      def pyproject_has_section?(prefix)
        pyproject_sections.keys.any? { |section| section == prefix || section.start_with?("#{prefix}.") }
      end

      def pyproject_sections
        @pyproject_sections ||= begin
          sections = Hash.new { |hash, key| hash[key] = [] }
          current = nil
          @pyproject.to_s.lines.each do |line|
            content = strip_toml_comment(line).strip
            next if content.empty?

            header = content.match(/\A\[\s*([^\]]+)\s*\]\z/)
            if header
              current = header[1].strip
            elsif current
              sections[current] << content
            end
          end
          sections
        end
      end

      def pyproject_assignments(lines)
        assignments = {}
        current_key = nil
        lines.each do |line|
          assignment = line.match(/\A([A-Za-z0-9_.-]+)\s*=\s*(.*)\z/)
          if assignment
            current_key = assignment[1]
            assignments[current_key] = assignment[2]
          elsif current_key
            assignments[current_key] = "#{assignments[current_key]} #{line.strip}"
          end
        end
        assignments
      end

      def extract_quoted_values(value)
        value.to_s.scan(/(['"])(.*?)\1/).map { |_quote, item| item }
      end

      def python_package_name(value)
        value.to_s[/\A([A-Za-z0-9][A-Za-z0-9_.-]*)/, 1].then { |name| name && normalize_python_name(name) }
      end

      def normalize_python_name(name)
        name.to_s.downcase.tr("-_.", "")
      end

      def requirement_package_name(line)
        candidate = line.to_s.strip
        return nil if candidate.empty? || candidate.start_with?("#", "-", ".", "/", "http:", "https:", "git+")

        candidate = candidate.sub(/\s+#.*\z/, "").strip
        match = candidate.match(/\A([A-Za-z0-9][A-Za-z0-9_.-]*)(?:\[[^\]]+\])?(?:\s*(?:===|==|!=|~=|<=|>=|<|>|@)\s*\S+)?(?:\s*;.*)?\z/)
        match && normalize_python_name(match[1])
      end

      def strip_toml_comment(line)
        quote = nil
        escaped = false
        line.each_char.with_index do |character, index|
          if quote
            if quote == '"' && character == "\\" && !escaped
              escaped = true
              next
            end
            if character == quote && !escaped
              quote = nil
            end
            escaped = false
          elsif character == '"' || character == "'"
            quote = character
          elsif character == "#"
            return line[0...index]
          end
        end
        line
      end

      def text(path)
        @inventory.read(path)
      end

      def root_paths(pattern)
        @inventory.files.keys.select { |path| !path.include?("/") && File.basename(path).match?(pattern) }
      end

      def paths_for(pattern)
        @inventory.files.keys.select { |path| path.match?(pattern) }
      end

      def documented_command(path, command = nil)
        return nil unless path && @inventory.exists?(path)

        summary = command ? "Repository command documented: #{command}" : "Repository command documented"
        @evidence.add(type: "documented_command", path: path, method: "documented_command", summary: summary)
      end

      def file(path, method, summary, type: "file")
        return nil unless path && @inventory.exists?(path)

        @evidence.add(type: type, path: path, method: method, summary: summary)
      end

      def directory(path, method, summary)
        return nil unless @inventory.directory?(path)

        @evidence.add(type: "directory", path: path, method: method, summary: summary)
      end

      def tool_entry(name, method, summary, path)
        keys = [file(path, method, summary)].compact
        tool_entry_with_keys(name, summary, keys)
      end

      def tool_entry_with_keys(name, summary, keys)
        {
          "name" => name,
          "status" => "detected",
          "confidence" => confidence_for(keys),
          "evidence_ids" => @evidence.ids_for(keys),
          "_evidence_keys" => keys
        }
      end

      def confidence_for(keys, fallback: "medium")
        return fallback if keys.empty?

        keys.any? { |key| DIRECT_EVIDENCE_METHODS.include?(@evidence.item_for(key)&.fetch("method", nil)) } ? "high" : fallback
      end

      def evidence_path(key)
        @evidence.item_for(key)&.fetch("path", nil)
      end

      def evidence_summary(key)
        @evidence.item_for(key).to_h.fetch("summary", "")
      end

      def clean_internal(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, item), result|
            next if key == "_evidence_keys"

            result[key] = clean_internal(item)
          end
        when Array
          value.map { |item| clean_internal(item) }
        else
          value
        end
      end
    end
  end
end
