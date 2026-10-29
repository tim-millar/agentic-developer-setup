# frozen_string_literal: true

require "tempfile"
require "time"
require_relative "../adoption"

module AgenticDeveloperSetup
  module Adoption
    class TransactionError < StandardError
      attr_reader :code, :exit_code

      def initialize(code, message, exit_code = 4)
        @code = code
        @exit_code = exit_code
        super(message)
      end
    end

    module TransactionSupport
      ROOT = Pathname.new(__dir__).join("../../..").realpath
      OPERATIONS = %w[initial_adoption add_components update_inherited reconcile_inherited].freeze
      WRITES = %w[create_inherited create_specialised update_inherited].freeze

      module_function

      def fail!(code, message, exit_code = 4)
        raise TransactionError.new(code, message, exit_code)
      end

      def digest(bytes)
        "sha256:#{Digest::SHA256.hexdigest(bytes)}"
      end

      def canonical(value)
        case value
        when Hash
          fail!("invalid_document", "mapping keys must be strings", 2) unless value.keys.all? { |key| key.is_a?(String) }
          value.keys.sort_by(&:b).to_h { |key| [key, canonical(value[key])] }
        when Array then value.map { |item| canonical(item) }
        when String, Integer, TrueClass, FalseClass, NilClass then value
        else fail!("invalid_document", "only JSON-compatible primitive values are supported", 2)
        end
      end

      def plan_id(plan)
        digest(JSON.generate(canonical(plan.except("plan_id", "created_at"))))
      end

      def metadata_bytes(document)
        YAML.dump(canonical(document))
      end

      def load_yaml(path)
        # Inspect the AST before safe_load: Psych otherwise silently accepts duplicate keys.
        raw = File.binread(path)
        ast = Psych.parse_stream(raw)
        walk_yaml(ast)
        data = YAML.safe_load(raw, permitted_classes: [], permitted_symbols: [], aliases: false)
        canonical(data)
        data
      rescue Psych::Exception, ArgumentError => e
        fail!("invalid_document", "invalid YAML: #{e.message.lines.first.strip}", 2)
      end

      def walk_yaml(node)
        if node.is_a?(Psych::Nodes::Mapping)
          keys = node.children.each_slice(2).map(&:first)
          fail!("invalid_document", "YAML mapping keys must be scalar strings", 2) unless keys.all? { |key| key.is_a?(Psych::Nodes::Scalar) }
          fail!("invalid_document", "duplicate YAML mapping key", 2) unless keys.map(&:value).uniq.length == keys.length
        end
        Array(node.children).each { |child| walk_yaml(child) } if node.respond_to?(:children)
      end

      def schema!(kind, document)
        errors = Schema.load(ROOT.join("schemas/framework-adoption-#{kind}-v1.schema.json")).validate(document)
        fail!("invalid_document", errors.join("; "), 2) unless errors.empty?
        document
      end

      def diagnostic(code, message, component_id: nil, path: nil, severity: "error")
        {"severity" => severity, "code" => code, "component_id" => component_id, "path" => path, "message" => message}
      end

      def sorted_diagnostics(items)
        items.uniq.sort_by { |d| [d["component_id"].to_s, d["path"].to_s, d["code"], d["severity"], d["message"]] }
      end

      def now
        Time.now.utc.iso8601
      end

      def inside?(path, root)
        path == root || path.to_s.start_with?("#{root}/")
      end

      def external(path, roots, present: false, new_file: false)
        fail!("unsafe_path", "external path is required", 2) unless path.is_a?(String) && !path.empty? && !path.include?("\0")
        path = Pathname.new(path).expand_path
        fail!("unsafe_path", "external parent must already exist", 2) unless path.parent.directory?
        roots.each { |root| Assessment::PathSafety.validate_output!(path, root) }
        fail!("unsafe_path", "external final path must not be a symlink", 2) if path.symlink?
        path = path.parent.realpath.join(path.basename)
        fail!("unsafe_path", "external file must be regular", 2) if path.exist? && !path.lstat.file?
        fail!("unsafe_path", "hard-linked external file is an unsafe alias", 2) if path.exist? && path.lstat.nlink > 1
        fail!("invalid_document", "required external file is missing: #{path}", 2) if present && !path.file?
        fail!("target_conflict", "result destination must be new: #{path}") if new_file && path.exist?
        path
      rescue Assessment::InvocationError, SystemCallError => e
        fail!("unsafe_path", e.message, 2)
      end

      def identities_distinct!(paths)
        paths = paths.compact.map { |path| Pathname.new(path) }
        paths.combination(2) do |a, b|
          fail!("unsafe_path", "input/output destinations must not alias") if a == b || (a.exist? && b.exist? && File.identical?(a, b))
        end
      end

      # fsync both bytes and containing directory. Each replacement is on the same filesystem.
      def atomic_write(path, bytes, mode: "0644", create: false)
        path = Pathname.new(path)
        fail!("unsafe_path", "write destination is a symlink") if path.symlink?
        Tempfile.create([".ads-", ".tmp"], path.parent.to_s) do |file|
          file.binmode
          file.write(bytes)
          file.chmod(mode.to_i(8))
          file.flush
          file.fsync
          if create
            # Hard-link installation provides no-clobber creation; rename would replace a raced-in file.
            File.link(file.path, path.to_s)
          else
            File.rename(file.path, path.to_s)
          end
          yield if block_given?
          sync_directory(path.parent)
        end
      end

      def sync_directory(path)
        File.open(path.to_s, File::RDONLY) { |directory| directory.fsync }
      end

      def snapshot(path)
        return {"content" => nil, "size" => nil} unless path
        bytes = File.binread(path)
        {"content" => [bytes].pack("m0"), "size" => bytes.bytesize}
      end

      def bytes(state)
        state.fetch("content").unpack1("m0")
      rescue ArgumentError, TypeError
        fail!("invalid_document", "invalid embedded file content", 2)
      end

      def mode(path)
        format("%04o", path.lstat.mode & 0o7777)
      end

      def safe_path(root, relative)
        fail!("unsafe_path", "invalid repository-relative path: #{relative.inspect}") unless PathSafety.safe_relative?(relative, allow_dot: relative == ".") && !relative.end_with?("/") && relative.split("/").none? { |part| part.downcase == ".git" }
        gitlinks = git!(root, "ls-files", "--stage", "-z").split("\0").filter_map do |entry|
          entry.split("\t", 2).last if entry.start_with?("160000 ")
        end
        if gitlinks.any? { |path| relative.downcase == path.downcase || relative.downcase.start_with?("#{path.downcase}/") }
          fail!("unsafe_path", "submodule content is outside the transaction boundary")
        end
        current = Pathname.new(root)
        parts = (relative == ".") ? [] : relative.split("/")
        parts.each_with_index do |part, index|
          # Case-fold checks are deliberately conservative, including on case-sensitive hosts.
          if current.directory?
            matches = current.children.select { |child| child.basename.to_s.downcase == part.downcase }
            fail!("unsafe_path", "case-folding path collision: #{relative}") if matches.any? { |child| child.basename.to_s != part }
          end
          current = current.join(part)
          if current.exist? || current.symlink?
            stat = current.lstat
            fail!("unsafe_path", "symlink path: #{relative}") if stat.symlink?
            fail!("unsafe_path", "non-directory parent: #{relative}") if index < parts.length - 1 && !stat.directory?
            fail!("unsafe_path", "nested Git worktree: #{relative}") if stat.directory? && (current.join(".git").exist? || current.join(".git").symlink?)
          end
        end
        current
      end

      def repository(path, role, clean: true)
        root = Pathname.new(path).expand_path.realpath
        head = GitCommand.revision(root)
        fail!("invalid_#{role}", "#{role} must be a Git worktree root with a commit", 3) unless root.directory? && head
        status = git!(root, "status", "--porcelain=v1", "--untracked-files=all", "--ignore-submodules=none")
        fail!("dirty_#{role}", "#{role} worktree must be clean", 3) if clean && !status.empty?
        [root, head]
      rescue SystemCallError, TypeError => e
        fail!("invalid_#{role}", e.message, 3)
      end

      def git!(root, *arguments)
        result = GitCommand.capture(root, *arguments)
        fail!("preflight_failed", "Git inspection failed: #{arguments.first}", 3) unless result.success?
        result.stdout
      end

      # Compare tree/index object identities, independently of status and index flags.
      # Paths are read from NUL-delimited Git output, never interpreted as pathspecs.
      def git_tree(root, revision = "HEAD")
        git!(root, "ls-tree", "-r", "--full-tree", "-z", revision).split("\0").to_h do |entry|
          attributes, path = entry.split("\t", 2)
          git_mode, _type, object = attributes.split(" ")
          [path, [git_mode, object]]
        end
      end

      def git_index(root)
        git!(root, "ls-files", "--stage", "-z").split("\0").each_with_object({}) do |entry, index|
          attributes, path = entry.split("\t", 2)
          git_mode, object, stage = attributes.split(" ")
          fail!("plan_stale", "index must contain one stage-zero entry per path: #{path}") unless stage == "0" && !index.key?(path)
          index[path] = [git_mode, object]
        end
      end

      def committed_regular_file!(root, relative)
        path = safe_path(root, relative)
        fail!("local_modification", "reconciliation requires an existing regular target: #{relative}") unless path.file?
        committed = git_tree(root)[relative]
        supported = committed && {"100644" => "0644", "100755" => "0755"}[committed.first]
        fail!("provenance_unavailable", "reconciliation target must be a regular file committed in target HEAD: #{relative}") unless supported
        fail!("plan_stale", "reconciliation target index differs from HEAD: #{relative}") unless git_index(root)[relative] == committed
        blob = git!(root, "cat-file", "blob", committed.last).b
        unless File.binread(path) == blob && mode(path) == supported
          fail!("local_modification", "reconciliation target bytes/mode differ from committed HEAD; commit or discard local changes: #{relative}")
        end
        {"digest" => digest(blob), "mode" => supported}
      end

      def git_state(root)
        git!(root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none")
      end
    end
  end
end
