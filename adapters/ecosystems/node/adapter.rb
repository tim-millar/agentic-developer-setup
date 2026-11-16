# frozen_string_literal: true

# Framework-owned static interpretation only. Target configuration is data;
# executable configuration and package scripts are never loaded or executed.
module AgenticDeveloperSetup
  module Adapters
    module Providers
      class Node
        LOCKFILES = {"package-lock.json" => "npm", "npm-shrinkwrap.json" => "npm", "yarn.lock" => "yarn", "pnpm-lock.yaml" => "pnpm"}.freeze
        SCRIPTS = {
          "test" => ["test", %w[standard]], "test:unit" => ["test_unit", %w[standard]],
          "test:e2e" => ["test_e2e", %w[extended]], "lint" => ["lint", %w[fast standard]],
          "format:check" => ["format_check", %w[fast standard]], "typecheck" => ["typecheck", %w[standard]],
          "type-check" => ["typecheck", %w[standard]], "build" => ["build", %w[extended]], "verify" => ["verify", []]
        }.freeze
        LIFECYCLE = %w[preinstall install postinstall prepare prepack postpack].freeze
        TOOLS = %w[typescript eslint prettier jest vitest playwright @playwright/test cypress mocha next vite webpack rollup esbuild turbo nx].freeze

        # JSON's default last-key-wins interpretation cannot establish authority.
        class UniqueObject
          attr_reader :values

          def initialize
            @values = {}
          end

          def []=(key, value)
            raise JSON::ParserError, "duplicate key" if @values.key?(key)
            @values[key] = value
          end
        end

        def detect(context)
          manifests = context.inventory.files.select { |path| File.basename(path) == "package.json" }
          roots = (manifests.map { |path| File.dirname(path) } + [context.scope["path"]]).uniq.sort
          roots.filter_map do |root|
            inspection = Inspection.new(context, root)
            next if root != context.scope["path"] && !manifests.include?(inspection.path("package.json"))
            inspection.candidate
          end
        end

        def contribute(context, inputs:)
          Inspection.new(context, context.scope["path"]).contributions(inputs)
        end

        class Inspection
          def initialize(context, root)
            @context, @root = context, root
            @contents = {}
            @files = context.inventory.files.select { |file| File.dirname(file) == root }.sort
            @output = {"findings" => [], "commands" => [], "validation_profiles" => [], "paths" => [], "documentation_requirements" => []}
            @manifest_path = path("package.json")
            @package = json(@manifest_path) if @files.include?(@manifest_path)
            @manifest_evidence = observe(@manifest_path, "package_manifest", @package ? "Node package manifest is a JSON object" : "Package manifest cannot be interpreted as a unique-key JSON object") if @files.include?(@manifest_path)
          end

          def path(name)
            (@root == ".") ? name : "#{@root}/#{name}"
          end

          def candidate
            signals = @files.select { |file| File.basename(file).match?(/\A(?:tsconfig.*\.json|\.nvmrc|\.node-version|pnpm-workspace\.yaml)\z/) || LOCKFILES.key?(File.basename(file)) }
            ids = signals.map { |file| observe(file, "node_configuration", "Static Node toolchain configuration detected; operational support is unverified") }
            ids << @manifest_evidence if @manifest_evidence
            status = if @package
              "detected"
            else
              (ids.empty? ? "not_detected" : "ambiguous")
            end
            {"category" => "ecosystem", "id" => "node",
             "scope" => (@root == @context.scope["path"]) ? @context.scope : {"type" => "workspace", "path" => @root},
             "status" => status, "confidence" => @package ? "high" : "low", "evidence" => ids.compact.uniq.sort,
             "ambiguities" => (status == "ambiguous") ? ids.compact.uniq.sort : [], "incompatible_evidence" => []}
          end

          def contributions(inputs)
            finding("manifest-invalid", "metadata", "Package manifest is unreadable, oversized, malformed, non-object or has duplicate keys; dependent recommendations withheld.", [@manifest_evidence]) if @manifest_evidence && !@package
            scripts = script_mapping
            manager = package_manager(inputs)
            classify_language(scripts)
            tools(scripts)
            workspaces
            versions
            lifecycle(scripts)
            commands(scripts, manager)
            ci(scripts, manager)
            profiles
            generated_path("dependencies", "node_modules", "cache_owned") if @package
            @output["documentation_requirements"] << {"id" => "node-operator-review", "description" => "Document the reviewed package manager, Node version policy, script scope/cost, setup lifecycle hooks and independent execution approval. Static recommendations and adopted bindings are not executable validation specifications."}
            @output.transform_values { |items| items.sort_by { |item| item["id"] } }
          end

          private

          def read(file)
            return @contents[file] if @contents.key?(file)
            @contents[file] = @context.inventory.read(file)
          end

          def observe(file, method, summary)
            content = read(file)
            summary += content ? "; content SHA-256 #{Digest::SHA256.hexdigest(content)}" : "; bounded content unavailable"
            @context.add_evidence(type: "configuration", method: "node_#{method}", summary: summary, path: file)
          end

          def finding(id, category, summary, evidence = [], severity: "review_required", confidence: "high")
            @output["findings"] << {"id" => "node-#{id}", "category" => category, "severity" => severity,
                                    "confidence" => confidence, "summary" => summary, "evidence_ids" => evidence.compact.uniq.sort, "related_finding_ids" => []}
          end

          def json(file)
            raw = read(file)
            return nil unless raw
            # Older standard-library JSON accepts comments and trailing commas
            # even when newer parser options request strictness. Mask strings
            # before rejecting those syntax forms; target text is never evaluated.
            structure = raw.gsub(/"(?:\\.|[^"\\])*"/m, '""')
            return nil if structure.match?(%r!//|/\*|,\s*[}\]]!)
            data = JSON.parse(raw, object_class: UniqueObject, max_nesting: 80, allow_comments: false, allow_trailing_comma: false, allow_duplicate_key: false)
            plain_json(data) if data.is_a?(UniqueObject)
          rescue JSON::ParserError, ArgumentError
            nil
          end

          def plain_json(value)
            case value
            when UniqueObject then value.values.transform_values { |item| plain_json(item) }
            when Array then value.map { |item| plain_json(item) }
            else value
            end
          end

          def yaml(file)
            raw = read(file)
            return nil unless raw
            # Bound AST depth before recursive duplicate-key validation and safe
            # construction. Aliases, tags and executable objects are not loaded.
            stream = Psych.parse_stream(raw)
            raise Error, "multiple YAML documents" unless stream.children.size == 1
            pending = [[stream, 0]]
            until pending.empty?
              node, depth = pending.pop
              raise Error, "deep YAML" if depth > 80
              pending.concat(Array(node.children).map { |child| [child, depth + 1] }) if node.respond_to?(:children)
            end
            Contracts.validate_yaml_keys!(stream)
            data = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
            data if data.is_a?(Hash)
          rescue Psych::Exception, Error, ArgumentError
            nil
          end

          def script_mapping
            return {} unless @package
            scripts = @package.fetch("scripts", {})
            unless scripts.is_a?(Hash)
              finding("scripts-invalid", "metadata", "Scripts must be a mapping; script recommendations withheld.", [@manifest_evidence])
              return {}
            end
            finding("scripts-incomplete", "metadata", "Some script definitions are not non-empty strings; those candidates are withheld.", [@manifest_evidence]) if scripts.values.any? { |value| !value.is_a?(String) || value.strip.empty? }
            scripts.select { |_, value| value.is_a?(String) && !value.strip.empty? }
          end

          def package_manager(inputs)
            locks = @files.select { |file| LOCKFILES.key?(File.basename(file)) }
            ids = locks.map { |file| observe(file, "lockfile", "#{LOCKFILES.fetch(File.basename(file))} lockfile present; freshness and dependency installation unverified") }
            families = locks.map { |file| LOCKFILES.fetch(File.basename(file)) }.uniq
            if locks.count { |file| LOCKFILES[File.basename(file)] == "npm" } > 1
              finding("npm-lockfile-coexistence", "package_manager", "Both npm lockfile forms are present. Effective precedence depends on npm version; dependency resolution and currency are not assessed.", ids)
            end
            declaration = @package && @package["packageManager"]
            declared = nil
            unsupported = false
            if @package&.key?("packageManager")
              # Numeric versions/ranges and simple distribution tags, optionally
              # Corepack hashes. URLs and remote resolution are unsupported.
              match = parse_manager(declaration)
              if match && safe_value?(match[2])
                declared = match[1]
                ids << observe(@manifest_path, "package_manager_declaration", "Package manager #{declared} declared; version text #{match[2]}; installed version unverified")
              else
                unsupported = true
                ids << @manifest_evidence
                finding("manager-unsupported", "package_manager", "Explicit packageManager declaration is unsupported, malformed or not safely representable; commands withheld without falling back to npm.", ids)
              end
            end
            choice = inputs["ecosystem/node.package_manager"]
            conflict = families.size > 1 || (declared && families.any? { |family| family != declared }) ||
              (choice && ([declared].compact + families).any? { |family| family != choice })
            if conflict
              finding("manager-conflict", "package_manager", "Package-manager declaration, lockfile families or explicit input contradict one another; manager-backed commands withheld.", ids, severity: "blocking")
              return nil
            end
            return nil if unsupported || (@manifest_evidence && !@package)
            manager = declared || families.first || choice
            unless manager
              finding("manager-missing", "package_manager", "No authoritative supported package manager in this scope. Review ecosystem/node.package_manager before requesting native commands.", [@manifest_evidence], confidence: "medium")
              return nil
            end
            origin = if declared
              "packageManager declaration"
            else
              (families.any? ? "single lockfile family" : "explicit reviewed selection input")
            end
            finding("manager-selected", "package_manager", "#{manager} selected from #{origin}; package-manager version, installed dependencies and lockfile currency are unverified.", ids, severity: "informational", confidence: declared ? "high" : "medium")
            finding("manager-input", "package_manager", "Explicit #{choice} input #{(declared || families.any?) ? "corroborates repository evidence" : "establishes an operator choice without repository manager evidence"}; it does not approve execution.", ids, severity: "informational") if choice
            finding("lockfile-missing", "package_manager", "No recognised lockfile is visible in the selected scope.", [@manifest_evidence], confidence: "medium") if locks.empty?
            manager
          end

          def parse_manager(declaration)
            return nil unless safe_value?(declaration)
            match = declaration.match(/\A(npm|yarn|pnpm)@(.+)\z/)
            return nil unless match
            spec, metadata = match[2].split("+", 2)
            if metadata
              hash = metadata.match(/\Asha(224|256|384|512)\.([a-fA-F0-9]+)\z/)
              if metadata.start_with?("sha")
                return nil unless hash && hash[2].size == hash[1].to_i / 4
              else
                return nil unless metadata.match?(/\A[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*\z/)
              end
            end
            version = /v?(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*|[xX*])){0,2}(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?/
            term = /(?:[~^]|<=|>=|<|>|=)?\s*#{version}/
            range = /\A#{term}(?:\s+#{term}|\s*\|\|\s*#{term})*\z/
            tag = /\A[A-Za-z][A-Za-z0-9._-]*\z/
            hyphen_range = /\A#{version} - #{version}\z/
            match if spec.match?(range) || spec.match?(tag) || spec.match?(hyphen_range)
          end

          def safe_value?(value)
            return false unless value.is_a?(String) && value.bytesize <= 160 && !value.match?(/[\x00-\x1f\x7f]/)
            InputValues.validate_non_secret!(value)
            true
          rescue Error
            false
          end

          def classify_language(scripts)
            configs = @files.grep(/(?:\A|\/)tsconfig[^\/]*\.json\z/)
            ids = configs.map { |file| observe(file, "typescript_configuration", "TypeScript configuration detected; extends and source files are not resolved") }
            js = @package && @package["main"].is_a?(String) && @package["main"].match?(/\.(?:js|cjs|mjs)\z/)
            js ||= scripts.values.any? { |script| script.match?(/\bnode\s+(?:\.\/)?[A-Za-z0-9_\/.-]+\.(?:js|cjs|mjs)(?:\s|\z)/) }
            ids << @manifest_evidence if js
            summary = if configs.any? && js
              "Both JavaScript entrypoint/script and TypeScript configuration evidence observed. Source composition is not verified."
            elsif configs.any?
              "TypeScript configuration detected alongside Node tooling; source composition is not verified."
            elsif js
              "JavaScript entrypoint/script evidence observed; no TypeScript configuration observed in the supported inventory. This does not establish JavaScript-only sources."
            else
              "No TypeScript configuration observed in the supported inventory. Source extensions are not indexed; JavaScript-only or mixed-source composition cannot be established."
            end
            finding("language-evidence", "language", summary, ids + [@manifest_evidence], severity: "informational", confidence: "medium")
            if @package&.key?("type")
              value = @package["type"]
              finding("module-type", "configuration", %w[module commonjs].include?(value) ? "Package type declares #{value}; incomplete configuration does not establish runtime behaviour." : "Package type has an unsupported value; runtime module behaviour is unresolved.", [@manifest_evidence], severity: "informational")
            end
          end

          def tools(scripts)
            dependencies = %w[dependencies devDependencies peerDependencies optionalDependencies].flat_map do |group|
              values = @package && @package[group]
              if @package&.key?(group) && (!values.is_a?(Hash) || values.values.any? { |value| !value.is_a?(String) })
                finding("#{group.downcase}-invalid", "metadata", "A dependency group has invalid field types; its tooling interpretation is withheld.", [@manifest_evidence])
                []
              else
                values.is_a?(Hash) ? values.keys : []
              end
            end.uniq
            TOOLS.each do |tool|
              next unless dependencies.include?(tool)
              observe(@manifest_path, "tool_dependency", "#{tool} dependency declared; installation and execution unverified")
            end
            {"typescript" => [@files.grep(/(?:\A|\/)tsconfig[^\/]*\.json\z/), %w[typecheck type-check]],
             "eslint" => [@files.select { |file| File.basename(file).match?(/\A(?:eslint\.config\..+|\.eslintrc(?:\..*)?)\z/) }, %w[lint]],
             "prettier" => [@files.select { |file| File.basename(file).match?(/\A(?:prettier\.config\..+|\.prettierrc(?:\..*)?)\z/) }, %w[format:check]]}.each do |tool, (configs, names)|
              ids = configs.map { |file| observe(file, "tool_configuration", "#{tool} configuration detected; executable configuration is not evaluated") }
              finding("#{tool}-script-missing", "tooling", "#{tool} configuration detected without a corresponding supported script; no command is fabricated.", ids, confidence: "medium") if configs.any? && (names & scripts.keys).empty?
              configs.each { |file| typescript_config(file) } if tool == "typescript"
            end
            {"jest" => /\bjest\b/, "vitest" => /\bvitest\b/, "node_test_runner" => /\bnode\s+--test\b/}.each do |tool, pattern|
              observe(@manifest_path, "tool_script", "#{tool} referenced by a script; execution unverified") if scripts.values.any? { |script| script.match?(pattern) }
            end
          end

          def typescript_config(file)
            data = json(file)
            id = observe(file, "typescript_options", "TypeScript configuration inspected as strict JSON only; comments, trailing commas and extends resolution are unsupported")
            unless data
              finding("tsconfig-#{Digest::SHA256.hexdigest(file)[0, 16]}-incomplete", "configuration", "TypeScript configuration could not be safely parsed as unique-key JSON; options and output paths withheld.", [id])
              return
            end
            options = data["compilerOptions"]
            return unless data.key?("compilerOptions")
            unless options.is_a?(Hash)
              finding("tsconfig-#{Digest::SHA256.hexdigest(file)[0, 16]}-options", "configuration", "TypeScript compilerOptions is not an object; option interpretation withheld.", [id])
              return
            end
            %w[module moduleResolution noEmit outDir].each do |key|
              next unless options.key?(key)
              value = options[key]
              valid = (key == "noEmit") ? [true, false].include?(value) : (safe_value?(value) && value.match?(/\A[A-Za-z0-9_.\/-]+\z/))
              observe(file, "typescript_option", valid ? "TypeScript #{key} declares #{value}; advisory only, without extends resolution" : "TypeScript #{key} cannot be represented safely")
            end
            generated_path("typescript-#{Digest::SHA256.hexdigest(file)[0, 16]}", options["outDir"], "generated", base: File.dirname(file)) if options["outDir"].is_a?(String) && (!options.key?("noEmit") || options["noEmit"] == false)
          end

          def workspaces
            ids = []
            if @package&.key?("workspaces")
              value = @package["workspaces"]
              patterns = value.is_a?(Hash) ? value["packages"] : value
              valid = patterns.is_a?(Array) && patterns.all? { |item| item.is_a?(String) && !item.empty? }
              ids << @manifest_evidence
              finding("workspaces-declared", "scope", valid ? "Package workspace patterns declared; membership, task graphs and inherited manager policy are not resolved." : "Workspace declaration has unsupported field types; membership is unresolved.", ids)
            end
            file = path("pnpm-workspace.yaml")
            if @files.include?(file)
              data = yaml(file)
              patterns = data && data["packages"]
              valid = patterns.is_a?(Array) && patterns.all? { |item| item.is_a?(String) && !item.empty? }
              ids << observe(file, "pnpm_workspace", "pnpm workspace declaration detected; patterns are not expanded")
              finding("pnpm-workspaces", "scope", valid ? "pnpm package patterns declared; complete workspace policy is not reconstructed." : "pnpm workspace declaration is incomplete or unsupported; membership unresolved.", ids)
            end
            nested = @context.inventory.files.select { |file| File.basename(file) == "package.json" && file != @manifest_path }
            if nested.any?
              nested.each { |file| ids << observe(file, "nested_package", "Nested package manifest visible; its scripts are not imported") }
              finding("nested-packages", "scope", "Nested package manifests are visible. Generic scope-conflict rules remain authoritative; packages are not composed automatically.", ids)
            end
            finding("workspace-isolation", "scope", "Selected workspace inventory excludes parent policy. Parent manager/lockfile declarations are not inherited; a reviewed manager input may be necessary.", [@manifest_evidence]) if @context.scope["type"] == "workspace"
          end

          def version_value(file, kind, value)
            if value.is_a?(Integer) && kind == "setup-node node-version"
              value = value.to_s
            end
            valid = safe_value?(value) && value.match?(%r{\A(?:v?\d[0-9A-Za-z.*^~<>=| /+-]*|[~^<>=]+\s*\d[0-9A-Za-z.*^~<>=| /+-]*|lts/[A-Za-z*]+|node|stable|system)\z})
            summary = if valid
              "Node #{kind} declares #{value}; #{value.match?(/\Av?\d+\.\d+\.\d+\z/) ? "exact version" : "constraint or selector, not directly compared"}; installation unverified"
            else
              "Node #{kind} declaration is non-literal, unsupported or not safely representable"
            end
            id = observe(file, "node_version", summary)
            @versions << [valid ? value : nil, id]
          end

          def versions
            @versions = []
            %w[engines volta].each do |key|
              value = @package && @package[key]
              if value.is_a?(Hash)
                version_value(@manifest_path, "#{key}.node", value["node"]) if value.key?("node")
              elsif @package&.key?(key)
                version_value(@manifest_path, "#{key}.node", nil)
              end
            end
            %w[.nvmrc .node-version].each do |name|
              file = path(name)
              version_value(file, name, read(file)&.strip) if @files.include?(file)
            end
          end

          def lifecycle(scripts)
            hooks = LIFECYCLE & scripts.keys
            finding("lifecycle-hooks", "setup", "Recognised lifecycle hooks declared (#{hooks.join(", ")}); setup or packaging may execute repository-owned code. Hook safety is not established.", [@manifest_evidence]) if hooks.any?
          end

          def eligible?(name, script)
            return false unless name.match?(/\A[a-z][a-z0-9:-]*\z/)
            evidence = observe(@manifest_path, "script_declaration", "Supported script #{name} declared; implementation, dependencies, scope, cost and success unverified")
            finding("native-script-#{name.tr(":", "-")}", "validation", "Native #{name} script declared; command eligibility is assessed separately and execution is unverified.", [evidence], severity: "informational")
            reason = if script.match?(/\A\s*(?:(?:echo|printf)\b|(?:exit\s+[01]|true|false|:)\s*\z)/) || script.match?(/no test specified|not implemented|TODO|placeholder/i)
              "placeholder"
            elsif script.match?(/(?:\A|\s)--(?:fix(?:-dry-run)?|write)(?:[=\s]|\z)|\b(?:lint:fix|format:write)\b/)
              "mutating"
            elsif !safe_script?(script)
              "indeterminate"
            end
            if reason
              finding("script-#{name.tr(":", "-")}-#{reason}", "validation", "Supported script candidate #{name} is #{reason}; command recommendation withheld.", [@manifest_evidence])
              return false
            end
            true
          end

          def safe_script?(script)
            # Shared recognised-secret policy only; never echo script contents.
            InputValues.validate_non_secret!(script)
            !script.include?("\0")
          rescue Error
            false
          end

          def commands(scripts, manager)
            SCRIPTS.each do |name, (capability, profiles)|
              next unless scripts.key?(name)
              next if name == "type-check" && scripts.key?("typecheck")
              next unless eligible?(name, scripts[name]) && manager && @package
              id = "node-#{capability.tr("_", "-")}"
              argv = [manager, "run", name]
              Contributions.tokens!(argv)
              @output["commands"] << {"id" => id, "kind" => "base", "capability" => capability, "scope" => @root, "cwd" => @root,
                                       "argv" => argv, "env" => {}, "profiles" => profiles,
                                       "preconditions" => ["Independently review execution, script implementation and lifecycle hooks", "Confirm the declared toolchain, dependencies and any required services are available"],
                                       "classification" => ["unexecuted_native_script"]}
            end
            finding("typecheck-alternative", "validation", "Both typecheck and type-check declared; typecheck is the single preferred capability proposal.", [@manifest_evidence], severity: "informational") if scripts.key?("typecheck") && scripts.key?("type-check")
            finding("unclassified-scripts", "validation", "Additional script names are declared outside the supported validation vocabulary; no validation commands inferred from them.", [@manifest_evidence], severity: "informational") if (scripts.keys - SCRIPTS.keys - LIFECYCLE).any?
          end

          def profiles
            %w[fast standard extended].each do |profile|
              ids = @output["commands"].select { |command| command["profiles"].include?(profile) }.map { |command| command["id"] }.sort
              next if ids.empty?
              @output["validation_profiles"] << {"id" => "node-profile-#{profile}", "profile" => profile, "command_ids" => ids,
                                                "emphasis" => "Recommended script-name grouping; cost and coverage are unmeasured and execution needs independent approval"}
            end
          end

          def generated_path(id, relative, classification, base: @root)
            return unless safe_value?(relative) && relative.match?(%r{\A[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z}) && !relative.split("/").include?("..") && relative != "."
            full = (base == ".") ? relative : "#{base}/#{relative}"
            Contracts.scoped_path!(full, @context.scope)
            @output["paths"] << {"id" => "node-path-#{id}", "path" => full, "recursive" => true, "classifications" => [classification]}
          rescue Error
            # Unsafe declarations remain observations, never path claims.
            nil
          end

          def ci(scripts, manager)
            workflow_paths = @context.inventory.files.grep(%r{(?:\A|/)\.github/workflows/[^/]+\.ya?ml\z}).sort
            observed = []
            workflow_paths.each do |file|
              id = observe(file, "ci_workflow", "GitHub Actions workflow statically inspected; dynamic execution is not resolved")
              data = yaml(file)
              jobs = data && data["jobs"]
              unless jobs.is_a?(Hash)
                finding("ci-#{Digest::SHA256.hexdigest(file)[0, 16]}-incomplete", "ci", "Workflow is unreadable, malformed or unsupported; CI validation is unresolved.", [id])
                next
              end
              jobs.sort_by { |key, _| key.to_s }.each do |_, job|
                next unless job.is_a?(Hash)
                steps = job["steps"]
                ci_indeterminate(id) if job.key?("uses") || job.key?("strategy")
                next unless steps.is_a?(Array)
                steps.each do |step|
                  next unless step.is_a?(Hash)
                  if step["uses"].is_a?(String) && step["uses"].match?(/\Aactions\/setup-node@[^\s]+\z/)
                    settings = step["with"]
                    version_value(file, "setup-node node-version", settings["node-version"]) if settings.is_a?(Hash) && settings.key?("node-version")
                    ci_indeterminate(id) if settings.is_a?(Hash) && settings.key?("node-version-file")
                  elsif step.key?("uses")
                    ci_indeterminate(id)
                  end
                  next unless step.key?("run")
                  run = step["run"]
                  cwd = step.fetch("working-directory", default_directory(job) || default_directory(data) || ".")
                  if !run.is_a?(String) || cwd != @root
                    ci_indeterminate(id)
                    next
                  end
                  run.lines.each do |line|
                    line = line.strip
                    next if line.empty? || line.start_with?("#")
                    match = line.match(/\A(npm|yarn|pnpm)\s+(?:(run)\s+)?([a-z][a-z0-9:-]*)(?:\s+(.+))?\z/)
                    unless match && !line.include?("${{") && !line.match?(/[;&|`$<>]/)
                      ci_indeterminate(id)
                      next
                    end
                    ci_manager, run_keyword, name, arguments = match.captures
                    # npm only has a test shorthand among this vocabulary.
                    # Keep other literal operations as manager observations,
                    # without treating e.g. npm build as npm run build.
                    name = nil if ci_manager == "npm" && !run_keyword && name != "test"
                    invocation_id = observe(file, "ci_invocation", "Literal #{ci_manager} invocation observed; script implementation and CI semantics unverified")
                    observed << [ci_manager, name, arguments, invocation_id]
                  end
                end
              end
            end
            compare_ci(scripts, manager, observed, workflow_paths)
            version_findings
          end

          def default_directory(document)
            defaults = document["defaults"]
            return nil unless defaults.is_a?(Hash) && defaults["run"].is_a?(Hash)
            defaults["run"]["working-directory"]
          end

          def ci_indeterminate(id)
            # Several unsupported steps in one workflow share one stable finding.
            return if @output["findings"].any? { |item| item["id"] == "node-ci-indeterminate-#{id}" }
            finding("ci-indeterminate-#{id}", "ci", "CI uses dynamic, non-literal or unsupported execution, scope or matrix/reusable-workflow semantics; comparison is incomplete.", [id], confidence: "medium")
          end

          def compare_ci(scripts, manager, observed, workflows)
            observed.each_with_index do |(ci_manager, name, arguments, id), index|
              if manager && manager != ci_manager
                finding("ci-manager-#{index}", "ci", "CI invokes #{ci_manager} while primary selected-scope manager remains #{manager}; primary evidence is not overridden.", [id, @manifest_evidence])
              end
              if SCRIPTS.key?(name)
                state = if !scripts.key?(name)
                  "missing-local"
                else
                  (arguments ? "arguments-differ" : "matching")
                end
                finding("ci-script-#{index}-#{state}", "ci", "CI #{name} invocation: #{state}; matching names alone do not prove semantic equivalence or verified execution.", [id, @manifest_evidence], severity: (state == "matching") ? "informational" : "review_required")
              else
                finding("ci-only-#{index}", "ci", "A CI-only or unsupported invocation was observed; no supported local validation capability is inferred.", [id])
              end
            end
            (scripts.keys & SCRIPTS.keys).sort.each do |name|
              next if observed.any? { |ci_manager, ci_name, args, _| ci_name == name && ci_manager == manager && !args }
              finding("ci-absent-#{name.tr(":", "-")}", "ci", "Local supported #{name} script has no matching literal invocation in inspected workflows; CI coverage may be indirect or indeterminate.", [@manifest_evidence], confidence: "low") if workflows.any?
            end
          end

          def version_findings
            if @versions.empty?
              finding("node-version-missing", "toolchain", "No supported Node runtime declaration is visible; runtime compatibility and installation cannot be assessed.", [@manifest_evidence], confidence: "low")
              return
            end
            exact = @versions.filter_map { |value, _| value&.match?(/\Av?\d+\.\d+\.\d+\z/) ? value.delete_prefix("v") : nil }.uniq
            ids = @versions.map(&:last)
            if exact.size > 1
              finding("node-version-disagreement", "toolchain", "Exact Node version declarations disagree; installed runtime and range compatibility are unverified.", ids)
            end
            if @versions.any? { |value, _| !value || !value.match?(/\Av?\d+\.\d+\.\d+\z/) }
              finding("node-version-uncertain", "toolchain", "Node constraints, selectors or unsupported declarations are not directly comparable. Different ranges are not treated as definite conflicts; no SemVer solver or installed-version check is performed.", ids, confidence: "medium")
            end
          end
        end
      end
    end
  end
end
