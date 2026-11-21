# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    module Providers
      class Python
        LOCKS = {"uv.lock" => "uv", "poetry.lock" => "poetry", "pdm.lock" => "pdm"}.freeze
        CONFIGS = {
          "pytest" => [%w[pytest.ini], [%w[pytest ini_options]]],
          "unittest" => [[], []],
          "tox" => [%w[tox.ini], [%w[tox]]],
          "nox" => [%w[noxfile.py], []],
          "ruff" => [%w[ruff.toml .ruff.toml], [%w[ruff]]],
          "black" => [[], [%w[black]]],
          "isort" => [%w[.isort.cfg], [%w[isort]]],
          "flake8" => [%w[.flake8], []],
          "pylint" => [%w[.pylintrc pylintrc], [%w[pylint]]],
          "mypy" => [%w[mypy.ini .mypy.ini], [%w[mypy]]],
          "pyright" => [%w[pyrightconfig.json], [%w[pyright]]],
          "basedpyright" => [[], [%w[basedpyright]]],
          "build" => [[], []]
        }.freeze
        TASKS = {
          "test" => "test", "tests" => "test", "lint" => "lint", "format-check" => "format_check",
          "format:check" => "format_check", "typecheck" => "typecheck", "type-check" => "typecheck",
          "build" => "build", "verify" => "verify", "check" => "verify"
        }.freeze
        MANAGED = %w[uv poetry pdm hatch].freeze
        MARKER = /\A(?:pyproject\.toml|setup\.(?:cfg|py)|requirements[^\/]*\.(?:txt|in)|uv\.lock|poetry\.lock|pdm\.lock|\.python-version|tox\.ini|noxfile\.py)\z/
        REQUIREMENTS = /\Arequirements[^\/]*\.(?:txt|in)\z/
        VERSION = /\d{1,2}\.\d{1,3}(?:\.\d{1,4})?/
        VERSION_PIN = /\A\d{1,2}\.\d{1,3}\.\d{1,4}\z/
        VERSION_CLAUSE = /(?:===|==|!=|~=|>=|<=|>|<|\^|~)?[ \t]*#{VERSION}(?:\.\*|[a-z]+\d+)?/
        TASK_NAME = /\A[a-z][a-z0-9:_-]{0,47}\z/

        def detect(context)
          files = context.inventory.files.group_by { |file| File.dirname(file) }
          roots = files.keys.select { |root| files[root].any? { |file| MARKER.match?(File.basename(file)) } }
          (roots << context.scope.fetch("path")).uniq.sort.map { |root| Scan.new(context, root, files.fetch(root, [])).candidate }
        end

        def contribute(context, inputs:)
          Scan.new(context, context.scope.fetch("path")).contribute(inputs["ecosystem/python.package_manager"])
        end

        # Parse TOML as TOML. The pinned parser uses an iterative stack; bound the
        # resulting tree before consumers interpret nested fields.
        module StaticConfiguration
          module_function

          def toml(raw)
            return unless raw
            require "tomlrb"
            data = Tomlrb.parse(raw, version: "1.0")
            pending = [[data, 0]]
            until pending.empty?
              value, depth = pending.pop
              return if depth > 48
              children = (value.is_a?(Hash) ? value.values : value)
              children.each { |item| pending << [item, depth + 1] } if children.is_a?(Array)
            end
            data
          rescue Tomlrb::ParseError, ArgumentError, RangeError
            nil
          end

          # Bounded ConfigParser subset. Whole-line comments and indented
          # continuations are accepted; interpolation and includes are absent.
          def ini(raw)
            return unless raw
            data = {}
            section = key = nil
            raw.each_line do |line|
              value = line.strip
              next if value.empty? || value.start_with?("#", ";")
              if (match = /\A\[([a-zA-Z0-9:_.-]+)\]\z/.match(value))
                section = match[1].downcase
                return nil if data.key?(section)
                data[section] = {}
                key = nil
              elsif section && key && line.match?(/\A[ \t]/)
                data[section][key] << "\n" << value
              elsif section && (match = /\A([a-zA-Z0-9_.-]+)[ \t]*[=:][ \t]*(.*)\z/.match(value))
                key = match[1].downcase
                return nil if data[section].key?(key)
                data[section][key] = match[2]
              else
                return nil
              end
            end
            data
          end

          def yaml(raw)
            return unless raw
            tree = Psych.parse_stream(raw)
            return unless tree.children.size == 1
            pending = [[tree, 0]]
            until pending.empty?
              node, depth = pending.pop
              return if depth > 48 || node.is_a?(Psych::Nodes::Alias)
              Array(node.children).each { |item| pending << [item, depth + 1] } if node.respond_to?(:children)
            end
            Contracts.validate_yaml_keys!(tree)
            data = YAML.safe_load(raw, aliases: false)
            data if data.is_a?(Hash)
          rescue Psych::Exception, Error, ArgumentError
            nil
          end
        end

        class Scan
          def initialize(context, root, files = nil)
            @context, @root = context, root
            files ||= context.inventory.files.select { |file| File.dirname(file) == root }
            @files = files.to_h { |file| [File.basename(file), file] }
            @contents = {}
            @content_digests = {}
            @findings = []
            @versions = []
            @risk = {}
            @native = {}
            @commands = []
            @paths = []
            @manifest = config("pyproject.toml", :toml)
            @setup = config("setup.cfg", :ini)
            @tox = config("tox.ini", :ini)
            @requirements = @files.keys.grep(REQUIREMENTS).to_h { |name| [name, requirements(name)] }
          end

          def candidate
            markers = @files.keys.grep(MARKER)
            ids = markers.map do |name|
              summary = case name
              when "pyproject.toml"
                @manifest ? "Python project configuration parsed as unique-key TOML" : "Python project configuration present with unresolved content"
              when "setup.cfg"
                @setup ? "Static INI configuration parsed" : "Static INI configuration present with unresolved content"
              when "setup.py", "noxfile.py"
                "Executable Python configuration present"
              else
                "Python project or toolchain marker present"
              end
              evidence(name, "project_marker", summary)
            end
            invalid = @uninterpreted.to_a + @requirements.select { |_, value| value.nil? }.keys
            invalid << "pyproject.toml" if invalid_manifest_shape?
            invalid_ids = invalid.map { |name| evidence(name, "configuration_limit", "Bounded static configuration unavailable or unsupported") }
            status = if strong_project?
              "detected"
            elsif ids.any?
              "ambiguous"
            else
              "not_detected"
            end
            scope = (@root == @context.scope["path"]) ? @context.scope : {"type" => "workspace", "path" => @root}
            {"category" => "ecosystem", "id" => "python", "scope" => scope, "status" => status,
             "confidence" => confidence_for(status, invalid_ids),
             "evidence" => ids.sort, "ambiguities" => ((status == "ambiguous") ? ids + invalid_ids : invalid_ids).uniq.sort,
             "incompatible_evidence" => []}
          end

          def contribute(input)
            report_configuration
            report_layout
            report_versions
            manager = manager_policy(input)
            tools = tool_configuration
            report_risks
            discover_local
            workflows = inspect_ci
            compare_versions
            @native.each_value { |entry| recommend(entry, manager) }
            compare_ci(workflows)
            report_tools(tools)
            report_paths
            report_unavailable
            {"findings" => @findings, "commands" => @commands, "paths" => @paths, "validation_profiles" => profiles}
          end

          private

          def path(name)
            (@root == ".") ? name : "#{@root}/#{name}"
          end

          def read(name)
            @contents.fetch(name) do
              @contents[name] = @context.inventory.read(path(name), strict_encoding: true)&.then { |raw| raw unless raw.include?("\0") }
            end
          end

          def evidence(name, method, summary, content: false)
            full_path = name && path(name)
            if content
              digest = @content_digests.fetch(name) { @content_digests[name] = read(name)&.then { |raw| Digest::SHA256.hexdigest(raw) } }
              summary += digest ? ". Content SHA-256 #{digest}" : ". Bounded UTF-8 content unavailable"
            end
            @context.add_evidence(type: "configuration", method: "python_#{method}", summary: summary, path: full_path)
          end

          def finding(id, category, summary, ids = [], severity: "review_required", confidence: "high")
            @findings << {"id" => "python-#{id}", "category" => category, "severity" => severity, "confidence" => confidence,
                          "summary" => summary, "evidence_ids" => ids.compact.uniq.sort, "related_finding_ids" => []}
          end

          def info(id, category, summary, ids = [])
            finding(id, category, summary, ids, severity: "informational")
          end

          def digest(value)
            Digest::SHA256.hexdigest(value)[0, 16]
          end

          def config(name, format)
            return unless @files.key?(name)
            parsed = StaticConfiguration.public_send(format, read(name))
            (@uninterpreted ||= []) << name unless parsed
            parsed
          end

          def table(data, *keys)
            keys.reduce(data) do |value, key|
              return nil unless value.is_a?(Hash)
              value[key]
            end.then { |value| value if value.is_a?(Hash) }
          end

          def project
            table(@manifest, "project")
          end

          def tool(*keys)
            table(@manifest, "tool", *keys)
          end

          def poetry
            tool("poetry")
          end

          def confidence_for(status, ambiguities)
            return "low" unless status == "detected"
            (manifest_backed? && ambiguities.empty?) ? "high" : "medium"
          end

          def manifest_backed?
            project_name?(project&.dig("name")) || project_name?(poetry&.dig("name")) ||
              valid_backend? || project_name?(table(@setup, "metadata")&.dig("name"))
          end

          def strong_project?
            manifest_backed? || @files.key?("setup.py") || @requirements.values.compact.any? { |entry| entry[:packages].any? } ||
              LOCKS.keys.any? { |name| @files.key?(name) } && @manifest && MANAGED.any? { |name| tool(name) }
          end

          def valid_backend?
            name = table(@manifest, "build-system")&.dig("build-backend")
            name.is_a?(String) && name.match?(/\A[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*(?::[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)?\z/)
          end

          def project_name?(value)
            value.is_a?(String) && value.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9_.-]*[A-Za-z0-9])?\z/)
          end

          def python_name(value)
            return unless value.is_a?(String)
            value[/\A([A-Za-z0-9][A-Za-z0-9_.-]*)(?=[ \t\[<>=!~;@]|\z)/, 1]&.downcase&.gsub(/[_.-]+/, "-")
          end

          def requirements(name)
            raw = read(name)
            return unless raw
            packages = []
            risky = []
            unsupported = false
            raw.each_line do |line|
              line = line.strip
              next if line.empty? || line.start_with?("#")
              token = line.split(/[ \t]/, 2).first
              if line.match?(/\A(?:-e(?:\s|$)|--editable(?:[=\s]|$))/)
                risky << :editable
              elsif line.match?(/\A(?:-i(?:\s|$)|--(?:extra-)?index-url(?:[=\s]|$)|--find-links(?:[=\s]|$))/)
                risky << :index
              elsif token.start_with?("-") || line.match?(%r{\A(?:https?:|git|file:|\.|/)})
                unsupported = true
              elsif line.match?(/\A[A-Za-z0-9][A-Za-z0-9_.-]*(?:\[[\w.,-]+\])?(?:[ \t]*(?:[<>=!~;@#].*)?)\z/) && (package = python_name(line))
                packages << package
                risky << :platform if line.match?(/;\s*(?:sys_platform|platform_machine|os_name)\b/)
                risky << :index if line.match?(/@\s*(?:https?:|git|\$\{)/)
              else
                unsupported = true
              end
            end
            {packages: packages.uniq, compiled: raw.match?(/^#.*(?:pip-compile|autogenerated by pip-tools)/i),
             risks: risky.uniq, unsupported: unsupported}
          end

          def report_configuration
            @uninterpreted.to_a.each do |name|
              finding("config-#{digest(name)}", "configuration", "#{name} is unreadable, oversized, invalid UTF-8, malformed, duplicate or unsupported. Dependent evidence is unresolved.",
                [evidence(name, "configuration_limit", "Static interpretation unavailable", content: true)])
            end
            @policy_invalid = @uninterpreted.to_a.intersect?(%w[pyproject.toml setup.cfg]) || invalid_manifest_shape?
            if @policy_invalid && @manifest
              finding("manifest-policy-shape", "configuration", "A Python policy table or field has an unsupported type. Native recommendations are withheld until it is reviewed.",
                [evidence("pyproject.toml", "configuration_limit", "Unsupported Python policy structure", content: true)])
            end
          end

          def invalid_manifest_shape?
            return false unless @manifest
            return true if %w[project build-system tool].any? { |key| @manifest.key?(key) && !@manifest[key].is_a?(Hash) }
            return true if MANAGED.any? { |key| tool&.key?(key) && !tool(key) }
            return true if project&.key?("requires-python") && !project["requires-python"].is_a?(String)
            return true if project&.key?("dependencies") && !string_list?(project["dependencies"])
            if project&.key?("optional-dependencies")
              extras = table(project, "optional-dependencies")
              return true unless extras&.values&.all? { |group| string_list?(group) }
            end
            return true if poetry&.key?("dependencies") && !table(poetry, "dependencies")
            return true if table(poetry, "dependencies")&.key?("python") && !poetry["dependencies"]["python"].is_a?(String)
            return true if poetry&.key?("package-mode") && ![true, false].include?(poetry["package-mode"])
            return true if tool("pdm")&.key?("distribution") && ![true, false].include?(tool("pdm")["distribution"])
            return true if %w[managed package].any? { |key| tool("uv")&.key?(key) && ![true, false].include?(tool("uv")[key]) }
            return true if tool("pdm")&.key?("scripts") && !table(tool("pdm"), "scripts")
            return true if tool("hatch")&.key?("envs") && !table(tool("hatch"), "envs")
            return true if table(@manifest, "build-system")&.key?("build-backend") && !valid_backend?
            PINNED_MANAGER_FIELDS.any? do |manager, field|
              tool(manager)&.key?(field) && !safe_version?(tool(manager)[field], constraint: true)
            end
          end

          PINNED_MANAGER_FIELDS = {"uv" => "required-version", "poetry" => "requires-poetry"}.freeze

          def string_list?(value)
            value.is_a?(Array) && value.all? { |item| item.is_a?(String) }
          end

          def report_layout
            manifest_id = evidence("pyproject.toml", "layout", "Static packaging and layout evidence", content: true) if @files.key?("pyproject.toml")
            setup_id = evidence("setup.cfg", "layout", "Static setuptools options and metadata", content: true) if @files.key?("setup.cfg")
            setuptools = tool("setuptools")
            options = table(@setup, "options")
            if valid_backend? || setuptools || options || (manifest_backed? && poetry && poetry["package-mode"] != false)
              info("distribution", "layout", "Static packaging or build-backend metadata indicates distribution intent. Dynamic metadata and build outcomes are unverified.", [manifest_id, setup_id])
            end
            if poetry&.dig("package-mode") == false || tool("uv")&.dig("package") == false || tool("pdm")&.dig("distribution") == false
              info("application-layout", "layout", "A tool explicitly disables packaging. This suggests an application or dependency-only workflow without establishing architecture.", [manifest_id])
            elsif @requirements.any? && !manifest_backed?
              info("unclassified-layout", "layout", "Requirements-based project evidence establishes neither a distribution nor an application architecture.")
            end
            mappings = table(setuptools, "package-dir")
            mapping = mappings&.dig("")
            src = @context.inventory.directory?(path("src"))
            if mapping == "src" || table(@setup, "options.packages.find")&.dig("where") == "src" || src
              info("src-layout", "layout", "A bounded src directory or package search configuration suggests a src layout. Exact package membership is unresolved.", [manifest_id, setup_id])
            elsif mapping == "." || options&.dig("package_dir")&.match?(/\A=\s*\.\z/) || table(@setup, "options.packages.find")&.dig("where") == "."
              info("flat-layout", "layout", "Static packaging configuration indicates a project-root search layout. Import names are unresolved.", [manifest_id, setup_id])
            end
            modules = setuptools&.dig("py-modules")
            if (modules.is_a?(Array) && modules.size == 1 && python_name(modules.first)) || options&.dig("py_modules")&.match?(/\A[A-Za-z_]\w*\z/)
              info("single-module", "layout", "A single module is explicitly declared for packaging. Module contents and importability are unverified.", [manifest_id, setup_id])
            end
            if table(setuptools, "packages", "find")&.dig("namespaces") == true || options&.dig("packages") == "find_namespace:"
              info("namespace-layout", "layout", "Namespace discovery is explicitly enabled. Namespace membership is unresolved.", [manifest_id, setup_id])
            end
            script_tables = [table(project, "scripts"), table(poetry, "scripts"), table(@setup, "options.entry_points")]
            if script_tables.compact.any? { |entries| entries.values.any? { |value| value.is_a?(String) && !value.empty? } }
              info("entrypoints", "layout", "Static entrypoint declarations indicate a possible CLI. These declarations describe installed entrypoints.", [manifest_id, setup_id])
            end
            if [project, poetry].compact.any? { |metadata| metadata.key?("dynamic") } || @files.key?("setup.py")
              finding("dynamic-metadata", "layout", "Dynamic or executable packaging metadata needs independent review before use. Exact metadata and imports remain unresolved.",
                [manifest_id, @files.key?("setup.py") && evidence("setup.py", "presence", "Executable setup file present") || nil])
            end
            markers = @files.keys & %w[package.json Gemfile mix.exs Cargo.toml go.mod composer.json pom.xml]
            if markers.any?
              info("mixed-ecosystem", "scope", "Other ecosystem markers are present in this scope. The generic assessor determines scope compatibility.",
                markers.map { |name| evidence(name, "other_ecosystem", "Other ecosystem marker present") })
            end
          end

          def safe_version?(value, constraint:)
            return false unless value.is_a?(String) && value.bytesize <= 120
            if constraint
              value.match?(/\A#{VERSION_CLAUSE}(?:[ \t]*(?:,|\|\|)[ \t]*#{VERSION_CLAUSE})*\z|\A\*\z/o)
            else
              value.match?(/\A(?:python|cpython-|pypy-)?#{VERSION}(?:\.[x*]|[a-z]+\d+)?\z|\A(?:system|pypy3)\z/o)
            end
          end

          def version(name, label, value, role)
            constraint = role == :policy
            value = value.strip if value.is_a?(String)
            accepted = safe_version?(value, constraint: constraint)
            pin = accepted && value.delete_prefix("==").strip
            pin = nil unless pin && VERSION_PIN.match?(pin)
            kind = if pin
              "exact pin"
            elsif accepted
              constraint ? "constraint or selector" : "selector"
            else
              "unsupported or non-literal declaration"
            end
            text = accepted ? "#{label} declares #{value} (#{kind})" : "#{label} has an #{kind}"
            @versions << [role, pin, evidence(name, "interpreter_version", "#{text}. Installed interpreter unverified", content: true)]
          end

          def report_versions
            if project&.key?("requires-python")
              version("pyproject.toml", "Project compatibility", project["requires-python"], :policy)
            end
            deps = table(poetry, "dependencies")
            version("pyproject.toml", "Poetry compatibility", deps["python"], :policy) if deps&.key?("python")
            options = table(@setup, "options")
            version("setup.cfg", "Setuptools compatibility", options["python_requires"], :policy) if options&.key?("python_requires")
            version(".python-version", "Local interpreter selection", read(".python-version"), :local) if @files.key?(".python-version")
            @tox.to_h.each do |section, options|
              next unless section == "testenv" || section.start_with?("testenv:")
              %w[basepython base_python].each do |key|
                version("tox.ini", "Tox base interpreter", options[key], :environment) if options.key?(key)
              end
            end
            table(tool("hatch"), "envs").to_h.each_value do |environment|
              version("pyproject.toml", "Hatch environment interpreter", environment["python"], :environment) if environment.is_a?(Hash) && environment.key?("python")
            end
          end

          def compare_versions
            declared = @versions.select { |role, _, _| role == :policy }
            local = @versions.find { |role, _, _| role == :local }
            ci = @versions.select { |role, _, _| %i[ci ci_axis].include?(role) }
            if declared.empty?
              finding("compatibility-missing", "toolchain", "No supported Python compatibility declaration was found. Installed interpreter versions are unverified.", [], confidence: "low")
            else
              info("compatibility", "toolchain", "Python compatibility declarations are distinct from local, environment and CI selection.", declared.map(&:last))
            end
            if !local
              info("local-version-missing", "toolchain", "No bounded local interpreter selection was found. The installed interpreter remains unverified.")
            end
            policy_pins = declared.filter_map { |_, pin, _| pin }.uniq
            environments = @versions.select { |role, pin, _| role == :environment && pin && policy_pins.any? && !policy_pins.include?(pin) }
            if environments.any?
              finding("environment-pin-difference", "toolchain", "An explicit environment pin differs from the declared exact compatibility pins.", (environments + declared).map(&:last))
            end
            @interpreter_conflict = policy_pins.size > 1 || (local&.[](1) && policy_pins.any? { |pin| pin != local[1] })
            if @interpreter_conflict
              finding("pin-disagreement", "toolchain", "Exact compatibility pins or the exact local selection disagree. Review interpreter policy before execution.", (declared + [local].compact).map(&:last))
            end
            if local&.[](1) && ci.any? { |_, pin, _| pin && pin != local[1] }
              finding("ci-version-difference", "ci", "Configured exact CI interpreter coverage differs from the exact local selection. CI success and installed interpreters are unverified.", [local.last] + ci.map(&:last))
            end
            unresolved = @versions.reject { |_, pin, _| pin }
            if unresolved.any?
              finding("version-unresolved", "toolchain", "Ranges, selectors and unsupported interpreter settings require review. Their compatibility remains unresolved.", unresolved.map(&:last), confidence: "medium")
            end
          end

          def manager_policy(input)
            evidence_by_manager = Hash.new { |hash, key| hash[key] = [] }
            LOCKS.each do |name, manager|
              next unless @files.key?(name)
              evidence_by_manager[manager] << evidence(name, "manager_lock", "#{manager} lockfile present. Lock validity, freshness and installation are unverified")
            end
            # Task tables and generic settings can coexist with another manager.
            # Poetry's legacy dependency policy is primary only when it supplies
            # the project identity or explicitly disables package mode.
            if table(poetry, "dependencies")&.any? && (project_name?(poetry["name"]) || poetry["package-mode"] == false)
              evidence_by_manager["poetry"] << evidence("pyproject.toml", "manager_policy", "Poetry project dependency policy declared", content: true)
            end
            MANAGED.each do |name|
              next unless (settings = tool(name))
              ids = [evidence("pyproject.toml", "manager_configuration", "#{name} configuration detected", content: true)]
              info("manager-config-#{name}", "dependencies", "#{name} configuration is visible. Managed environments and installations are unverified.", ids)
              field = PINNED_MANAGER_FIELDS[name]
              if field && safe_version?(settings[field], constraint: true)
                evidence_by_manager[name].concat(ids)
                info("manager-version-#{name}", "toolchain", "#{name} declares tool version policy #{settings[field]}. The installed manager version is unverified.", ids)
              end
            end
            dep_ids = report_requirements
            primary = evidence_by_manager.keys
            ids = evidence_by_manager.values.flatten
            unmanaged_uv = tool("uv")&.dig("managed") == false && ([input] + primary).include?("uv")
            if primary.size > 1 || (input && primary.any? && input != primary.first) || unmanaged_uv
              finding("manager-conflict", "dependencies", "Competing primary manager evidence or a contradictory reviewed choice needs resolution. Native recommendations are withheld.", ids)
              @manager_conflict = true
              return
            end
            manager = primary.first || input
            if manager.nil?
              configured = []
              configured << "pdm" if table(tool("pdm"), "scripts")&.any?
              configured << "hatch" if table(tool("hatch"), "envs")&.any? { |_, env| table(env, "scripts")&.any? }
              manager = configured.first if configured.one?
              if configured.size > 1
                finding("manager-task-ambiguity", "dependencies", "Multiple explicit managed task surfaces are visible without primary manager authority. Review the intended manager.",
                  [evidence("pyproject.toml", "manager_configuration", "Multiple task runners configured", content: true)])
                @manager_conflict = true
              end
              manager ||= requirements_manager unless @manager_conflict || managed_workflow_unresolved?
            end
            if manager
              ids += dep_ids if %w[pip pip-tools].include?(manager)
              info("manager-#{manager}", "dependencies", "Selected-scope evidence or reviewed input identifies #{manager}. Dependency state and manager installation are unverified.", ids)
            elsif !@manager_conflict
              finding("manager-unresolved", "dependencies", "Primary dependency-manager authority remains unresolved. Managed invocations require primary evidence or a reviewed choice.", dep_ids, confidence: "medium")
            end
            manager
          end

          def managed_workflow_unresolved?
            MANAGED.any? { |name| tool(name)&.any? }
          end

          def requirements_manager
            entries = @requirements.values.compact
            return "pip-tools" if entries.any? { |item| item[:compiled] }
            return "pip" if @requirements.any? { |name, item| name.end_with?(".txt") && item && item[:packages].any? }
            nil
          end

          def report_requirements
            @requirements.map do |name, data|
              id = evidence(name, "requirements_file", "Requirements convention observed", content: true)
              if !data || data[:unsupported]
                finding("requirements-limit-#{digest(name)}", "dependencies", "Some or all requirements content could not be interpreted. Includes, options and dependency resolution remain outside static authority.", [id])
              end
              if data
                if name.end_with?(".in") || data[:compiled]
                  info("pip-tools-#{digest(name)}", "dependencies", data[:compiled] ? "A generated pip-tools header indicates compiled requirements." : "A requirements input file suggests an input/compiled workflow.", [id])
                end
                data[:risks].each { |risk| add_risk(risk, id) }
              end
              id
            end
          end

          def dependency_sources
            return @dependency_sources if @dependency_sources
            result = Hash.new { |hash, name| hash[name] = [] }
            names = []
            names.concat(dependency_list(project&.dig("dependencies")))
            groups = [table(project, "optional-dependencies"), table(@manifest, "dependency-groups")]
            groups.compact.each { |group| group.each_value { |value| names.concat(dependency_list(value)) } }
            names.concat(table(poetry, "dependencies").to_h.keys.filter_map { |name| python_name(name) unless name == "python" })
            table(poetry, "group").to_h.each_value do |group|
              names.concat(table(group, "dependencies").to_h.keys.filter_map { |name| python_name(name) })
            end
            names.concat(dependency_list(tool("pdm")&.dig("dev-dependencies")&.then { |value| value.values.flatten if value.is_a?(Hash) }))
            if names.any?
              id = evidence("pyproject.toml", "dependency_declarations", "Supported dependency groups contain static dependency names", content: true)
              names.uniq.each { |name| result[name] << id }
            end
            dependencies = table(@setup, "options")&.dig("install_requires")
            if dependencies
              dependency_list(dependencies.lines.map(&:strip)).uniq.each do |name|
                result[name] << evidence("setup.cfg", "dependency_declarations", "Static install_requires declarations", content: true)
              end
            end
            @requirements.each do |name, entry|
              next unless entry&.dig(:packages)&.any?
              id = evidence(name, "dependency_declarations", "Requirements declare static dependency names", content: true)
              entry[:packages].each { |package| result[package] << id }
            end
            @dependency_sources = result
          end

          def dependency_list(value)
            return [] unless value.is_a?(Array)
            value.filter_map do |entry|
              if entry.is_a?(String) && entry.match?(/;\s*(?:sys_platform|platform_machine|os_name)\b/)
                add_risk(:platform, evidence("pyproject.toml", "platform_dependencies", "A platform-dependent requirements marker is declared", content: true)) if @manifest
              end
              python_name(entry)
            end
          end

          def tool_configuration
            deps = dependency_sources
            CONFIGS.to_h do |name, (files, tables)|
              ids = files.filter_map do |file|
                evidence(file, "tool_configuration", "#{name} configuration or executable declaration present") if @files.key?(file)
              end
              ids << evidence("pyproject.toml", "tool_configuration", "#{name} configuration table declared", content: true) if tables.any? { |keys| tool(*keys) }
              ids << evidence("setup.cfg", "tool_configuration", "Flake8 configuration declared", content: true) if name == "flake8" && table(@setup, "flake8")
              ids << evidence("pyproject.toml", "tool_configuration", "PEP 517 build backend declared", content: true) if name == "build" && valid_backend?
              [name, [deps[name], ids]]
            end
          end

          def add_risk(risk, id)
            (@risk[risk] ||= []) << id
          end

          RISKS = {
            setup: "Build backends, setup hooks or executable task definitions may run project-controlled code. Review prerequisites and side effects independently.",
            editable: "Editable installation evidence requires review of environment mutation and build hooks.",
            platform: "Native or platform-dependent dependency evidence requires platform and compiler review.",
            index: "Repository evidence identifies an alternate or potentially credential-dependent package source. Review connectivity and credential requirements independently.",
            services: "External service requirements are visible. Review isolation and state before authorising validation.",
            credentials: "A workflow or task declares credential-dependent behaviour. Review the requirement independently; credential values are excluded from the report.",
            stateful: "Stateful setup, generation or migration evidence requires independent review. No operational command is proposed."
          }.freeze

          def report_risks
            files = @files.keys & %w[setup.py noxfile.py]
            files.each { |name| add_risk(:setup, evidence(name, "executable_configuration", "Executable configuration present")) }
            backend = table(@manifest, "build-system")
            if valid_backend?
              id = evidence("pyproject.toml", "build_backend", "Static build-backend declaration present", content: true)
              add_risk(:setup, id)
              if %w[maturin scikit_build_core.build mesonpy].include?(backend["build-backend"]) || tool("setuptools")&.key?("ext-modules")
                add_risk(:platform, id)
              end
              if backend["build-backend"].start_with?("setuptools.") || tool("setuptools")
                info("setuptools-backend", "dependencies", "Static setuptools backend or packaging evidence is visible. Backend and installer are separate roles.", [id])
              end
            end
            indexed = tool("uv")&.key?("index") || poetry&.key?("source") || tool("pdm")&.key?("source")
            add_risk(:index, evidence("pyproject.toml", "package_source", "Explicit package source declared", content: true)) if indexed
            deps = dependency_sources
            %w[alembic grpcio-tools datamodel-code-generator].each do |name|
              deps[name].each { |id| add_risk(:stateful, id) }
            end
            deps["uvicorn"].concat(deps["gunicorn"]).uniq.each do |id|
              info("service-signal-#{digest(id)}", "layout", "A recognized server dependency is declared. Service architecture and runtime requirements remain unresolved.", [id])
            end
          end

          def operational_tokens(line, id)
            if line.match?(/\b(?:pip(?:3)? install|uv pip install|uv sync|poetry install|pdm sync|hatch env create|pip-compile|pip-sync)\b/)
              add_risk(:setup, id)
            end
            if line.match?(/(?:\A|\s)(?:-e|--editable)(?:\s|=)/) && line.match?(/\binstall\b/)
              add_risk(:editable, id)
            end
            add_risk(:index, id) if line.match?(/(?:--(?:extra-)?index-url|--find-links)(?:\s|=)/)
            add_risk(:stateful, id) if line.match?(/\b(?:alembic|protoc|datamodel-codegen|manage\.py\s+migrate)\b/)
            add_risk(:services, id) if line.match?(/\b(?:docker\s+compose|docker-compose|service\s+\S+\s+start)\b/)
            InputValues.validate_non_secret!(line)
          rescue Error
            add_risk(:credentials, id)
          end

          # Closed shell-free token grammar. The tool-specific grammar below
          # separately determines semantics for the subset this adapter knows.
          def tokens(line)
            return unless line.is_a?(String) && line.bytesize <= 400 && line.match?(/\A[A-Za-z0-9_.\/:+-]+(?:[ \t]+[A-Za-z0-9_.\/:=+-]+)*\z/)
            argv = line.split
            return if argv.any? { |token| token.split("/").include?("..") || token.start_with?("/") }
            Contributions.tokens!(argv)
            argv
          rescue Error
            nil
          end

          def literal_invocation(argv)
            return unless argv
            executable, subcommand, task = argv
            if argv.size == 2 && %w[make task].include?(executable) && TASKS.key?(subcommand)
              return [TASKS[subcommand], nil, nil]
            end
            if executable == "tox" && subcommand == "-e" && argv.size == 3 && TASK_NAME.match?(task) && TASKS.key?(task)
              return [TASKS[task], nil, "tox"]
            end
            if argv.size == 1 && (match = %r{\A\./scripts/([a-z-]+)\.sh\z}.match(executable)) && TASKS.key?(match[1])
              return [TASKS[match[1]], nil, nil]
            end
            if MANAGED.include?(executable) && subcommand == "build" && argv.size == 2
              return ["build", executable, "build"]
            end
            if MANAGED.include?(executable) && subcommand == "run"
              body = argv.drop(2)
              body = body.drop_while { |arg| %w[--locked --frozen --no-sync].include?(arg) } if executable == "uv"
              if %w[pdm hatch].include?(executable) && body.size == 1
                name = body.first.split(":", 2).last
                return [TASKS[name], executable, nil] if TASKS.key?(name)
              end
              capability, tool = validation_tool(body)
              return [capability, executable, tool] if capability
            else
              capability, tool = validation_tool(argv)
              return [capability, nil, tool] if capability
            end
            nil
          end

          def validation_tool(argv)
            name, action = argv
            rest = argv.drop(1)
            paths_and = ->(items, flags) { items.all? { |token| flags.include?(token) || token.match?(/\A(?:\.|\.\/)?[A-Za-z0-9_.][A-Za-z0-9_.\/-]*\z/) } }
            case name
            when "pytest"
              ["test", name] if paths_and.call(rest, %w[-q -v -vv -x --strict-markers --strict-config])
            when "python", "python3"
              if argv[1, 2] == %w[-m unittest] && (argv.size == 3 || (argv[3] == "discover" && paths_and.call(argv.drop(4), %w[-s -t -v])))
                ["test", "unittest"]
              elsif argv[1, 2] == %w[-m pytest] && paths_and.call(argv.drop(3), %w[-q -v -vv -x --strict-markers --strict-config])
                ["test", "pytest"]
              elsif argv[1, 2] == %w[-m build] && paths_and.call(argv.drop(3), %w[--sdist --wheel --no-isolation])
                ["build", "build"]
              end
            when "ruff"
              configured_fix = tool("ruff")&.dig("fix") == true && !argv.include?("--no-fix")
              if action == "check" && !configured_fix && paths_and.call(argv.drop(2), %w[--no-fix])
                ["lint", name]
              elsif action == "format" && argv.include?("--check") && paths_and.call(argv.drop(2), %w[--check --diff])
                ["format_check", name]
              end
            when "black", "isort"
              flag = (name == "black") ? "--check" : "--check-only"
              ["format_check", name] if argv.include?(flag) && paths_and.call(rest, [flag, "--diff"])
            when "flake8", "pylint"
              ["lint", name] if paths_and.call(rest, [])
            when "mypy", "pyright", "basedpyright"
              ["typecheck", name] if paths_and.call(rest, %w[--strict])
            end
          end

          def record_native(argv, capability, id, tool: nil, manager: nil, delegated: [], source: nil)
            return unless argv && capability
            entry = (@native[argv] ||= {argv: argv, capability: capability, ids: [], tools: [], managers: [], delegated: [], sources: []})
            entry[:ids] << id
            entry[:tools] << tool if tool
            entry[:managers] << manager if manager
            entry[:delegated].concat(delegated)
            entry[:sources] << source if source
          end

          def discover_local
            discover_make
            discover_taskfile
            discover_tox
            discover_manager_tasks
            discover_docs
          end

          def local_recipe(line, id, managed_runner: false)
            operational_tokens(line, id)
            argv = tokens(line)
            capability, manager, tool = literal_invocation(argv)
            return unless capability
            return if %w[make task tox].include?(argv.first)
            return if argv.first.start_with?("./") && !@context.inventory.files.include?(path(argv.first.delete_prefix("./")))
            {capability: capability, manager: manager, tool: tool, managed_runner: managed_runner, argv: argv}
          end

          def discover_make
            names = %w[GNUmakefile makefile Makefile] & @files.keys
            return if names.empty?
            name = names.first
            id = evidence(name, "make_surface", "Make command surface detected", content: true)
            raw = read(name)
            unless raw && names.one?
              finding("make-unsupported", "validation", "Makefile precedence or bounded content is unresolved. Make recommendations are withheld.", [id])
              return
            end
            targets = {}
            current = nil
            supported = raw.each_line.all? do |line|
              value = line.rstrip
              if value.match?(/\A\s*(?:#.*)?\z/)
                true
              elsif value.start_with?("\t") && current
                targets[current][1] << value.delete_prefix("\t").sub(/\A@/, "").strip
                true
              elsif (match = /\A([A-Za-z][A-Za-z0-9_-]*):[ \t]*([A-Za-z0-9_ \t-]*)\z/.match(value)) && !targets.key?(match[1])
                current = match[1]
                targets[current] = [match[2].split, []]
                true
              elsif value.match?(/\A\.PHONY:[ \t]+[A-Za-z0-9_ \t-]+\z/)
                current = nil
                true
              else
                false
              end
            end
            unless supported
              finding("make-unsupported", "validation", "Make definitions use unsupported directives, substitutions, syntax or repeated targets. Review the Make command surface manually.", [id])
              return
            end
            eligible = {}
            targets.each do |task, (prerequisites, lines)|
              next unless TASKS.key?(task) && prerequisites.empty? && lines.any?
              delegates = lines.map { |line| local_recipe(line, id) }
              if !delegates.include?(nil) && delegates.all? { |record| record[:capability] == TASKS[task] }
                eligible[task] = delegates
              else
                finding("make-target-#{digest(task)}", "validation", "The declared Make target has opaque or unsupported recipe semantics. Its recommendation is withheld.", [id])
              end
            end
            targets.each do |task, (prerequisites, lines)|
              next unless TASKS[task] == "verify" && lines.empty? && prerequisites.any? && prerequisites.all? { |dependency| eligible.key?(dependency) && TASKS[dependency] != "verify" }
              eligible[task] = prerequisites.flat_map { |dependency| eligible.fetch(dependency) }
            end
            eligible.each do |task, delegates|
              record_native(["make", task], TASKS[task], id, delegated: delegates, source: :declared)
            end
          end

          def discover_taskfile
            files = %w[Taskfile.yml Taskfile.yaml taskfile.yml taskfile.yaml] & @files.keys
            return if files.empty?
            name = files.first
            id = evidence(name, "taskfile", "Task command surface detected", content: true)
            data = config(name, :yaml)
            tasks = table(data, "tasks")
            unless files.one? && tasks && %w[3 3.0].include?(data["version"].to_s) && (data.keys - %w[version tasks]).empty?
              finding("taskfile-unsupported", "validation", "Taskfile syntax, precedence or global settings need independent review. Task recommendations are withheld.", [id])
              return
            end
            tasks.each do |task, settings|
              next unless TASKS.key?(task)
              lines = table(settings)&.dig("cmds")
              delegates = lines.is_a?(Array) ? lines.map { |line| line.is_a?(String) && local_recipe(line, id) } : []
              if delegates.any? && delegates.all? { |record| record && (record[:capability] == TASKS[task] || TASKS[task] == "verify") } && (settings.keys - %w[cmds desc silent]).empty?
                record_native(["task", task], TASKS[task], id, delegated: delegates, source: :declared)
              else
                finding("taskfile-task-#{digest(task)}", "validation", "The explicit Taskfile task has unsupported settings or commands. Its recommendation is withheld.", [id])
              end
            end
          end

          def discover_tox
            if @files.key?("noxfile.py")
              info("nox-presence", "validation", "Nox executable configuration is present. Session identities and execution semantics are unresolved.",
                [evidence("noxfile.py", "nox_presence", "Executable Nox configuration present")])
            end
            return unless @tox
            id = evidence("tox.ini", "tox_environments", "Tox INI configuration inspected", content: true)
            if tool("tox")
              finding("tox-precedence", "validation", "Multiple Tox configuration surfaces are visible. Tox environment recommendations are withheld.", [id])
              return
            end
            global = table(@tox, "tox").to_h
            if (global.keys - %w[envlist env_list minversion min_version]).any?
              finding("tox-global-options", "validation", "Tox global options exceed the supported static subset. Tox environment recommendations are withheld.", [id])
              return
            end
            base = table(@tox, "testenv").to_h
            @tox.each do |section, environment|
              next unless section.start_with?("testenv:")
              name = section.delete_prefix("testenv:")
              capability = TASKS[name] || ("test" if name.match?(/\Apy(?:3\d{1,2})?\z/))
              next unless capability
              options = base.merge(environment)
              lines = options.fetch("commands", "").lines.map(&:strip).reject(&:empty?)
              delegated = lines.map { |line| local_recipe(line, id, managed_runner: true) }
              if (options.keys - %w[basepython base_python commands deps description package skip_install]).empty? &&
                  delegated.any? && delegated.all? { |record| record && record[:capability] == capability && record[:manager].nil? }
                record_native(["tox", "-e", name], capability, id, tool: "tox", delegated: delegated, source: :environment)
              else
                finding("tox-environment-#{digest(name)}", "validation", "The explicit Tox environment has opaque settings, substitution or commands. Its recommendation is withheld.", [id])
              end
            end
          end

          def discover_manager_tasks
            return unless @manifest
            id = evidence("pyproject.toml", "managed_tasks", "Static task runner declarations inspected", content: true)
            scripts = table(tool("pdm"), "scripts").to_h
            scripts.each do |name, body|
              next unless TASKS.key?(name)
              if body.is_a?(Hash)
                body = body["cmd"] if (body.keys - %w[cmd help]).empty?
              end
              body = body.join(" ") if string_list?(body) && body.none? { |item| item.match?(/\s/) }
              hooks = ["_", "pre_run", "post_run", "pre_#{name}", "post_#{name}"]
              body = nil if hooks.any? { |hook| scripts.key?(hook) }
              register_task("pdm", name, name, body, id)
            end
            table(tool("hatch"), "envs").to_h.each do |environment, settings|
              next unless TASK_NAME.match?(environment) && !environment.include?(":")
              table(settings, "scripts").to_h.each do |name, body|
                next unless TASKS.key?(name) && !name.include?(":")
                eligible = (settings.keys & %w[template matrix env-vars env-include env-exclude pre-install-commands post-install-commands]).empty?
                register_task("hatch", name, "#{environment}:#{name}", eligible ? body : nil, id)
              end
            end
          end

          def register_task(manager, name, invocation, body, id)
            lines = body.is_a?(Array) ? body : [body]
            delegates = lines.map { |line| line.is_a?(String) && local_recipe(line, id, managed_runner: true) }
            if delegates.any? && delegates.all? { |record| record && record[:manager].nil? && (record[:capability] == TASKS[name] || TASKS[name] == "verify") }
              record_native([manager, "run", invocation], TASKS[name], id, manager: manager, delegated: delegates, source: :declared)
            else
              finding("managed-task-#{digest("#{manager}:#{invocation}")}", "validation", "An explicit managed task has opaque or unsupported settings or task contents. Its recommendation is withheld.", [id])
            end
          end

          def docs_paths
            prefix = (@root == ".") ? "" : "#{@root}/"
            @context.inventory.files.filter_map do |file|
              next unless file.start_with?(prefix)
              name = file.delete_prefix(prefix)
              name if name.match?(%r{\A(?:(?:README|CONTRIBUTING|DEVELOPMENT|TESTING)(?:\.[^/]+)?|docs/(?:TESTING|DEVELOPMENT|CONTRIBUTING)[^/]*)\z}i)
            end
          end

          def discover_docs
            docs_paths.each do |name|
              raw = read(name)
              next unless raw
              prose = raw.gsub(/<!--.*?(?:-->|\z)/m, "")
              lines = documentation_invocations(prose)
              next if lines.empty?
              id = evidence(name, "documented_invocation", "Documented commands inspected as literal text", content: true)
              lines.each do |line|
                operational_tokens(line, id)
                argv = tokens(line)
                capability, manager, tool_name = literal_invocation(argv)
                next unless capability
                # A documented task-runner name cannot create a missing target.
                if argv.first.start_with?("./")
                  next unless @context.inventory.files.include?(path(argv.first.delete_prefix("./")))
                elsif %w[make task tox].include?(argv.first) || (%w[pdm hatch].include?(manager) && !tool_name)
                  next unless @native.key?(argv)
                end
                record_native(argv, capability, id, tool: tool_name, manager: manager, source: :documented)
              end
            end
          end

          def documentation_invocations(text)
            fenced = nil
            text.each_line.filter_map do |line|
              # Ignore examples from other language fences, and quoted prose.
              if (match = /\A[ \t]*(\x60{3,}|~{3,})([a-zA-Z0-9_-]*)[ \t]*\z/.match(line.rstrip))
                if fenced
                  fenced = nil if match[1] == fenced[0] && match[2].empty?
                else
                  fenced = [match[1], %w[sh bash shell console].include?(match[2])]
                end
                next
              end
              if fenced&.last
                line.strip.delete_prefix("$ ")
              elsif !fenced
                line.rstrip[/\A[ \t]*(?:[-*][ \t]+)?\x60([^\x60]+)\x60[ \t]*\z/, 1]
              end
            end.reject { |line| line.empty? || line.start_with?("#") }
          end

          def recommend(entry, manager)
            argv = entry.fetch(:argv)
            capability = entry.fetch(:capability)
            missing_policy = manager.nil? && managed_workflow_unresolved?
            mismatched_manager = entry[:managers].any? { |name| name != manager }
            unsafe_delegate = entry[:delegated].any? do |delegate|
              if delegate[:manager]
                delegate[:manager] != manager
              else
                !delegate[:managed_runner] && MANAGED.include?(manager) && delegate[:tool]
              end
            end
            bare_managed_tool = MANAGED.include?(manager) && entry[:tools].any? && entry[:sources].uniq == [:documented] && entry[:managers].empty?
            if !strong_project? || @policy_invalid || @manager_conflict || @interpreter_conflict || mismatched_manager || unsafe_delegate || bare_managed_tool || missing_policy
              finding("command-withheld-#{digest(argv.join("\0"))}", "validation", "An explicit native validation invocation is visible. Its manager, interpreter, environment or configuration authority needs review before a recommendation can be made.", entry[:ids])
              return
            end
            entry[:delegated].each { |delegate| entry[:tools] << delegate[:tool] if delegate[:tool] }
            id = "python-#{capability.tr("_", "-")}-#{digest(argv.join("\0"))}"
            entry[:command_id] = id
            review = ["Review the repository-controlled invocation, inputs and hooks before independent execution approval",
              "Verify the toolchain, environment, dependencies and all relevant services before execution"]
            review << "Review service isolation, credentials and side effects before authorising execution" if restricted_profiles?
            @commands << {"id" => id, "kind" => "base", "capability" => capability,
                          "scope" => @root, "cwd" => @root, "argv" => argv, "env" => {},
                          "profiles" => profile_members(capability, entry), "preconditions" => review,
                          "classification" => ["unexecuted_native_command"]}
            finding("native-#{digest(argv.join("\0"))}", "validation", "An explicit #{capability.tr("_", " ")} invocation is eligible for individual review. Execution and coverage are unverified.", entry[:ids], severity: "informational")
          end

          def restricted_profiles?
            (@risk.keys & %i[services credentials stateful]).any?
          end

          def profile_members(capability, entry)
            return [] if restricted_profiles? || entry[:sources].include?(:environment)
            case capability
            when "lint", "format_check" then %w[fast standard]
            when "test", "typecheck" then %w[standard]
            when "build" then %w[extended]
            else []
            end
          end

          def profiles
            %w[fast standard extended].filter_map do |profile|
              ids = @commands.select { |item| item["profiles"].include?(profile) }.map { |item| item["id"] }.sort
              next if ids.empty?
              {"id" => "python-profile-#{profile}", "profile" => profile, "command_ids" => ids,
               "emphasis" => "Advisory native capability grouping. Cost, coverage and execution approval are unverified."}
            end
          end

          def inspect_ci
            @ci = {}
            prefix = (@root == ".") ? "" : "#{@root}/"
            workflows = @context.inventory.files.grep(/\A#{Regexp.escape(prefix)}\.github\/workflows\/[^\/]+\.ya?ml\z/).map { |file| file.delete_prefix(prefix) }
            workflows.each do |name|
              id = evidence(name, "ci_configuration", "GitHub Actions workflow detected", content: true)
              data = StaticConfiguration.yaml(read(name))
              jobs = table(data, "jobs")
              unless jobs
                finding("ci-config-#{digest(name)}", "ci", "Workflow is unreadable, malformed, duplicate or unsupported. CI evidence is incomplete.", [id])
                next
              end
              indeterminate = jobs.values.map { |job| inspect_job(name, data, job, id) }
              if indeterminate.any?
                finding("ci-dynamic-#{digest(name)}", "ci", "Some CI jobs, matrices, action references, shell settings or expressions require independent review. Comparison is incomplete.", [id], confidence: "medium")
              end
            end
            workflows
          end

          def inspect_job(name, workflow, job, id)
            return true unless job.is_a?(Hash)
            add_risk(:services, id) if job["services"].is_a?(Hash) && job["services"].any?
            add_risk(:credentials, id) if credential_expression?(job) || credential_expression?(workflow["env"])
            strategy = table(job, "strategy", "matrix")
            axis = strategy&.dig("python-version")
            if axis.is_a?(Array)
              axis.each { |value| version(name, "Configured CI python-version matrix axis", ci_version(value), :ci_axis) }
            end
            dynamic = %w[uses strategy container if].any? { |key| job.key?(key) } ||
              [workflow["env"], job["env"]].any? { |env| contains_expression?(env, /\$\{\{/) }
            return true unless job["steps"].is_a?(Array)
            states = job["steps"].map { |step| inspect_step(name, workflow, job, step, id, dynamic: dynamic) }
            dynamic || states.any?
          end

          def credential_expression?(object)
            contains_expression?(object, /\$\{\{[^}\n]*\bsecrets\s*(?:\.|\[)/i)
          end

          def contains_expression?(object, pattern)
            pending = [object]
            until pending.empty?
              item = pending.pop
              case item
              when String
                return true if item.match?(pattern)
              when Hash then pending.concat(item.values)
              when Array then pending.concat(item)
              end
            end
            false
          end

          def ci_version(value)
            # YAML numeric values lose the spelling of the minor version (3.10
            # becomes 3.1). Require quoted version strings for authoritative use.
            value if value.is_a?(String)
          end

          def inspect_step(name, workflow, job, step, id, dynamic:)
            return true unless step.is_a?(Hash)
            action = step["uses"]
            if action.is_a?(String) && action.match?(%r{\Aactions/setup-python@[A-Za-z0-9_./-]+\z})
              setup = table(step, "with").to_h
              if setup.key?("python-version")
                version(name, "Configured CI setup-python version", ci_version(setup["python-version"]), :ci)
              end
              return setup.key?("python-version-file") || (setup.key?("python-version") && !safe_version?(setup["python-version"], constraint: false))
            elsif action
              return true
            end
            return true unless step["run"].is_a?(String)
            line = step["run"].strip
            operational_tokens(line, id)
            defaults = [step, table(job, "defaults", "run"), table(workflow, "defaults", "run")].compact
            cwd = defaults.find { |data| data.key?("working-directory") }&.dig("working-directory") || "."
            return true if dynamic || cwd != @root || step.key?("if") || defaults.any? { |data| data.key?("shell") } ||
              contains_expression?(step["env"], /\$\{\{/)
            argv = tokens(line)
            capability, manager, tool = literal_invocation(argv)
            return true unless capability
            observed = (@ci[argv] ||= {capability: capability, manager: manager, tool: tool, ids: []})
            observed[:ids] << id
            false
          end

          def compare_ci(workflows)
            @ci.each do |argv, data|
              local = @native[argv]
              id = digest(argv.join("\0"))
              if local&.key?(:command_id)
                info("ci-alignment-#{id}", "ci", "CI and local evidence share a literal invocation and working directory. Environment and execution equivalence remain unverified.", data[:ids] + local[:ids])
              else
                finding("ci-only-#{id}", "ci", "A supported literal CI invocation lacks an equivalent eligible local command. CI remains corroborating evidence.", data[:ids])
              end
            end
            return if workflows.empty?
            @native.each do |argv, data|
              next if !data[:command_id] || @ci.key?(argv)
              finding("ci-missing-#{digest(argv.join("\0"))}", "ci", "An eligible local invocation has no literal equivalent in inspected CI. Coverage may be indirect.", data[:ids], confidence: "low")
            end
          end

          def report_tools(tools)
            tests = @context.inventory.directory?(path("tests")) || @context.inventory.directory?(path("test"))
            source = @context.inventory.directory?(path("src"))
            tools.each do |name, (deps, configs)|
              local = @native.values.select { |item| item[:command_id] && item[:tools].include?(name) }.flat_map { |item| item[:ids] }
              ci = @ci.values.select { |item| item[:tool] == name }.flat_map { |item| item[:ids] }
              next if (deps + configs + local + ci).empty?
              states = [deps.any? ? "dependency declared" : "no supported dependency declaration",
                configs.any? ? "configuration detected" : "no supported configuration",
                local.any? ? "native invocation eligible" : "no eligible native invocation",
                ci.any? ? "literal CI invocation visible" : "no supported literal CI invocation"]
              if %w[pytest unittest tox nox].include?(name) && tests
                states << "conventional test directory present"
              elsif source
                states << "conventional source directory present"
              end
              info("tool-#{name}", "tooling", "#{name} evidence includes #{states.join(", ")}. Execution and coverage are unverified.", deps + configs + local + ci)
            end
          end

          def report_paths
            return unless strong_project?
            caches = %w[.venv venv __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .nox]
            generated = []
            generated.concat(%w[build dist]) if valid_backend? || tool("setuptools")
            generated.concat(%w[coverage htmlcov]) if tool("coverage")
            @context.inventory.excluded_directories.each do |full|
              next unless File.dirname(full) == @root
              name = File.basename(full)
              classification = if caches.include?(name)
                "cache_owned"
              elsif generated.include?(name)
                "generated"
              end
              classify_path(name, classification, recursive: true) if classification
            end
            if tool("coverage")
              %w[.coverage coverage.xml].each do |name|
                classify_path(name, "generated", recursive: false) if @files.key?(name)
              end
            end
          end

          def classify_path(name, classification, recursive:)
            @paths << {"id" => "python-path-#{digest(name)}", "path" => path(name), "recursive" => recursive, "classifications" => [classification]}
          end

          def report_unavailable
            @risk.each { |kind, ids| finding("risk-#{kind}", "risk", RISKS.fetch(kind), ids) }
            missing = TASKS.values.uniq - @commands.map { |item| item["capability"] }
            if missing.any?
              finding("unsupported-capabilities", "validation", "No eligible native recommendation for #{missing.sort.map { |name| name.tr("_", " ") }.join(", ")}. Review repository-defined tooling and prerequisites.", [], confidence: "medium")
            end
          end
        end
      end
    end
  end
end
