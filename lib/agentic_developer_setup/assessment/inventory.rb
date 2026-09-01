# frozen_string_literal: true

require "pathname"

module AgenticDeveloperSetup
  module Assessment
    class Inventory
      EXCLUDED_DIRECTORIES = %w[
        .git
        .venv
        venv
        node_modules
        vendor
        coverage
        dist
        build
        target
        tmp
        cache
        .cache
      ].freeze
      PROJECT_CONTAINERS = %w[apps packages services projects workspaces modules].freeze
      MAX_READ_BYTES = 256 * 1024

      ROOT_FILE_PATTERNS = [
        /\AREADME(?:\..*)?\z/i,
        /\ACONTRIBUTING(?:\..*)?\z/i,
        /\ASECURITY(?:\..*)?\z/i,
        /\AAGENTS\.md\z/i,
        /\ACLAUDE\.md\z/i,
        /\AMakefile(?:\..*)?\z/i,
        /\Apackage\.json\z/i,
        /\A(?:package-lock\.json|yarn\.lock|pnpm-lock\.yaml)\z/i,
        /\A(?:pyproject\.toml|uv\.lock|requirements[^\/]*\.txt)\z/i,
        /\Atsconfig[^\/]*\.json\z/i,
        /\A(?:\.gitignore|CODEOWNERS|Dockerfile[^\/]*)\z/i,
        /\A(?:ARCHITECTURE|DEVELOPMENT|DOMAIN|TESTING|OPERATIONS|DEPLOY|COMMITS)[^\/]*\.(?:md|markdown|rst|txt)\z/i,
        /\A(?:pytest\.ini|tox\.ini|setup\.cfg|mypy\.ini|ruff\.toml|\.ruff\.toml)\z/i,
        /\A(?:eslint\.config\..*|\.eslintrc(?:\..*)?)\z/i,
        /\A(?:prettier\.config\..*|\.prettierrc(?:\..*)?)\z/i,
        /\A(?:\.pre-commit-config\.ya?ml|lefthook\.ya?ml|nx\.json|turbo\.json|pnpm-workspace\.yaml)\z/i,
        /\A(?:Cargo\.toml|go\.mod|Gemfile|composer\.json|pom\.xml|mix\.exs)\z/i
      ].freeze

      attr_reader :files, :excluded_paths, :symlink_boundaries, :ignored_paths, :git

      def initialize(root, git: GitInspector.new(root))
        @root = root
        @git = git
        @files = {}
        @excluded_paths = []
        @symlink_boundaries = []
        @ignored_paths = []
      end

      def discover
        @tracked = @git.tracked_files
        @git_detected = @git.info["detected"]
        @ignored_set = @git_detected ? @git.ignored_files(@tracked).to_h { |path| [path, true] } : {}
        @tracked.each { |path| add_if_known(path) }
        Dir.children(@root).sort.each do |name|
          path = @root.join(name)
          if excluded_directory_name?(name)
            add_excluded(name) if directory_or_symlink?(path)
            record_symlink_boundary(name, path) if symlink?(path)
          elsif symlink?(path)
            record_symlink_boundary(name, path)
          elsif PROJECT_CONTAINERS.include?(name)
            walk_project_container(name)
          elsif name == ".github"
            walk_known_tree(name, 0)
          elsif name == "docs"
            walk_documentation_tree(name, 0)
          elsif known_root_file?(name)
            add_if_known(name)
          end
        rescue SystemCallError
          next
        end
        @files.keys.sort
        self
      end

      def read(relative_path)
        return nil unless @files.key?(relative_path)

        path = @root.join(relative_path)
        return nil unless regular_non_symlink?(path)

        bytes = File.binread(path.to_s, MAX_READ_BYTES + 1)
        return nil if bytes.bytesize > MAX_READ_BYTES

        bytes.force_encoding(Encoding::UTF_8).scrub
      rescue SystemCallError
        nil
      end

      def exists?(relative_path)
        @files.key?(relative_path)
      end

      def directory?(relative_path)
        path = @root.join(relative_path)
        regular_directory?(path)
      end

      def candidate_project_files
        @files.keys.select do |path|
          basename = File.basename(path)
          basename.match?(/\A(?:package\.json|pyproject\.toml|requirements[^\/]*\.txt|uv\.lock)\z/i)
        end
      end

      private

      def walk_project_container(relative_path)
        directory = @root.join(relative_path)
        return unless regular_directory?(directory)

        Dir.children(directory).sort.each do |child|
          child_relative = File.join(relative_path, child)
          child_path = @root.join(child_relative)
          if excluded_directory_name?(child)
            add_excluded(child_relative) if directory_or_symlink?(child_path)
          elsif symlink?(child_path)
            record_symlink_boundary(child_relative, child_path)
          elsif regular_directory?(child_path)
            Dir.children(child_path).sort.each do |filename|
              add_if_known(File.join(child_relative, filename))
            end
          end
        rescue SystemCallError
          next
        end
      end

      def walk_known_tree(relative_path, depth)
        return if depth > 4

        path = @root.join(relative_path)
        return unless regular_directory?(path)

        Dir.children(path).sort.each do |child|
          child_relative = File.join(relative_path, child)
          child_path = @root.join(child_relative)
          if excluded_directory_name?(child)
            add_excluded(child_relative) if directory_or_symlink?(child_path)
          elsif symlink?(child_path)
            record_symlink_boundary(child_relative, child_path)
          elsif regular_directory?(child_path)
            walk_known_tree(child_relative, depth + 1)
          elsif known_nested_file?(child_relative)
            add_if_known(child_relative)
          end
        rescue SystemCallError
          next
        end
      end

      def walk_documentation_tree(relative_path, depth)
        return if depth > 4

        path = @root.join(relative_path)
        return unless regular_directory?(path)

        Dir.children(path).sort.each do |child|
          child_relative = File.join(relative_path, child)
          child_path = @root.join(child_relative)
          if excluded_directory_name?(child)
            add_excluded(child_relative) if directory_or_symlink?(child_path)
          elsif symlink?(child_path)
            record_symlink_boundary(child_relative, child_path)
          elsif regular_directory?(child_path)
            walk_documentation_tree(child_relative, depth + 1)
          elsif documentation_file?(child_relative)
            add_if_known(child_relative)
          end
        rescue SystemCallError
          next
        end
      end

      def add_if_known(relative_path)
        return unless safe_relative?(relative_path)
        if excluded_path?(relative_path)
          add_excluded(excluded_path_prefix(relative_path))
          return
        end

        path = @root.join(relative_path)
        if symlink?(path)
          record_symlink_boundary(relative_path, path)
          return
        end
        return unless regular_non_symlink?(path)
        if @git_detected && !@tracked.include?(relative_path) && (@ignored_set[relative_path] || @git.ignored?(relative_path))
          @ignored_paths << relative_path unless @ignored_paths.include?(relative_path)
          return
        end
        return unless known_path?(relative_path)

        @files[relative_path] = path
      end

      def known_path?(relative_path)
        # Documentation trees are an inspection surface for recognised
        # documents only. A tracked sample manifest must not become project
        # evidence merely because Git supplied it to the inventory.
        return documentation_file?(relative_path) if relative_path.start_with?("docs/")

        if !relative_path.include?(File::SEPARATOR)
          known_root_file?(relative_path)
        else
          known_nested_file?(relative_path)
        end
      end

      def known_root_file?(name)
        ROOT_FILE_PATTERNS.any? { |pattern| pattern.match?(name) }
      end

      def known_nested_file?(relative_path)
        basename = File.basename(relative_path)
        return true if relative_path.match?(%r{\Ascripts/(?:run_codex|mint_gh_app_token)\.sh\z}i)
        return true if relative_path.match?(%r{\A\.github/(?:workflows/[^/]+\.(?:yml|yaml)|ISSUE_TEMPLATE/[^/]+\.(?:md|yml|yaml)|PULL_REQUEST_TEMPLATE(?:/[^/]+)?\.md)\z}i)
        return true if relative_path.match?(%r{\Adocs/(?:adr|adrs)/.+\.(?:md|markdown|rst|txt)\z}i)
        return true if relative_path.start_with?("docs/") && basename.match?(/\A(?:README|AGENT_PROMPT|ARCHITECTURE|DEVELOPMENT|DOMAIN|TESTING|SECURITY|DEPLOY|OPERATIONS|COMMITS|FRAMEWORK_ADOPTION|ADOPTION)[^\/]*\.(?:md|markdown|rst|txt)\z/i)
        known_root_file?(basename)
      end

      def documentation_file?(relative_path)
        basename = File.basename(relative_path)
        return true if relative_path.match?(%r{\Adocs/(?:adr|adrs)/.+\.(?:md|markdown|rst|txt)\z}i)

        relative_path.start_with?("docs/") && basename.match?(
          /\A(?:README|AGENT_PROMPT|ARCHITECTURE|DEVELOPMENT|DOMAIN|TESTING|SECURITY|DEPLOY|OPERATIONS|COMMITS|FRAMEWORK_ADOPTION|ADOPTION)[^\/]*\.(?:md|markdown|rst|txt)\z/i
        )
      end

      def safe_relative?(relative_path)
        path = Pathname.new(relative_path)
        !path.absolute? && path.each_filename.none? { |part| part == ".." }
      end

      def excluded_directory_name?(name)
        EXCLUDED_DIRECTORIES.include?(name.downcase)
      end

      def excluded_path?(relative_path)
        relative_path.split(File::SEPARATOR).any? { |part| excluded_directory_name?(part) }
      end

      def excluded_path_prefix(relative_path)
        components = relative_path.split(File::SEPARATOR)
        index = components.index { |part| excluded_directory_name?(part) }
        components[0..index].join(File::SEPARATOR)
      end

      def regular_non_symlink?(path)
        path.lstat.file? && !path.lstat.symlink?
      rescue SystemCallError
        false
      end

      def regular_directory?(path)
        path.lstat.directory? && !path.lstat.symlink?
      rescue SystemCallError
        false
      end

      def directory_or_symlink?(path)
        path.lstat.directory? || path.lstat.symlink?
      rescue SystemCallError
        false
      end

      def symlink?(path)
        path.lstat.symlink?
      rescue SystemCallError
        false
      end

      def record_symlink_boundary(relative_path, path)
        return unless symlink?(path)

        target = path.realpath
        root_real = @root.realpath
        unless target == root_real || target.to_s.start_with?("#{root_real}#{File::SEPARATOR}")
          @symlink_boundaries << relative_path unless @symlink_boundaries.include?(relative_path)
        end
      rescue SystemCallError
        @symlink_boundaries << relative_path unless @symlink_boundaries.include?(relative_path)
      end

      def add_excluded(relative_path)
        @excluded_paths << relative_path unless @excluded_paths.include?(relative_path)
      end
    end
  end
end
