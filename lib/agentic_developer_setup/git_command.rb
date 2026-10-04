# frozen_string_literal: true

require "open3"
require "pathname"

module AgenticDeveloperSetup
  module GitCommand
    Result = Struct.new(:stdout, :stderr, :success?)

    module_function

    def revision(root)
      supplied_root = Pathname.new(root).expand_path.realpath
      return nil unless worktree_root(root) == supplied_root

      result = capture(root, "rev-parse", "--verify", "HEAD^{commit}")
      revision = result.stdout.strip
      revision if result.success? && revision.match?(/\A[0-9a-f]{40}\z/)
    rescue SystemCallError
      nil
    end

    def worktree_root(root)
      result = capture(root, "rev-parse", "--show-toplevel")
      return nil unless result.success?

      top_level = result.stdout.strip
      return nil if top_level.empty?

      Pathname.new(top_level).expand_path.realpath
    rescue SystemCallError
      nil
    end

    def capture(root, *arguments, stdin_data: nil)
      options = {chdir: root.to_s}
      options[:stdin_data] = stdin_data if stdin_data
      environment = {
        "GIT_OPTIONAL_LOCKS" => "0",
        "GIT_DIR" => nil,
        "GIT_WORK_TREE" => nil,
        "GIT_INDEX_FILE" => nil,
        "GIT_COMMON_DIR" => nil
      }
      stdout, stderr, status = Open3.capture3(
        environment,
        "git",
        "--no-optional-locks",
        "-c",
        "core.fsmonitor=false",
        *arguments,
        **options
      )
      Result.new(stdout, stderr, status.success?)
    rescue SystemCallError
      Result.new("", "", false)
    end
  end
end
