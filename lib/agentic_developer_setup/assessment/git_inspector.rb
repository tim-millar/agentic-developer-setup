# frozen_string_literal: true

require "open3"

module AgenticDeveloperSetup
  module Assessment
    class GitInspector
      def initialize(root)
        @root = root
      end

      def info
        top_level = capture("rev-parse", "--show-toplevel")
        unless top_level.success?
          return {
            "detected" => false,
            "commit" => "unknown",
            "branch" => "unknown",
            "working_tree" => "unknown"
          }
        end

        status = capture("status", "--porcelain", "--untracked-files=normal")
        {
          "detected" => true,
          "commit" => value_or_unknown(capture("rev-parse", "--verify", "HEAD^{commit}")),
          "branch" => value_or_unknown(capture("symbolic-ref", "--quiet", "--short", "HEAD")),
          "working_tree" => if status.success?
                              status.stdout.empty? ? "clean" : "dirty"
                            else
                              "unknown"
                            end
        }
      end

      def tracked_files
        result = capture("ls-files", "-z")
        return [] unless result.success?

        result.stdout.split("\0").reject(&:empty?).sort
      end

      def ignored?(relative_path)
        result = capture("check-ignore", "--quiet", "--no-index", "--", relative_path)
        result.success?
      end

      def ignored_files(relative_paths)
        paths = relative_paths.uniq.sort
        return [] if paths.empty?

        result = capture("check-ignore", "--no-index", "-z", "--stdin", stdin_data: paths.join("\0"))
        result.stdout.split("\0").reject(&:empty?).sort
      end

      def source_revision
        value_or_unknown(capture("rev-parse", "--verify", "HEAD^{commit}"))
      end

      private

      def capture(*arguments, stdin_data: nil)
        options = { chdir: @root.to_s }
        options[:stdin_data] = stdin_data if stdin_data
        environment = {
          "GIT_OPTIONAL_LOCKS" => "0",
          "GIT_DIR" => nil,
          "GIT_WORK_TREE" => nil,
          "GIT_INDEX_FILE" => nil,
          "GIT_COMMON_DIR" => nil
        }
        stdout, stderr, status = Open3.capture3(environment, "git", "--no-optional-locks", "-c", "core.fsmonitor=false", *arguments, **options)
        Struct.new(:stdout, :stderr, :success?).new(stdout, stderr, status.success?)
      rescue SystemCallError
        Struct.new(:stdout, :stderr, :success?).new("", "", false)
      end

      def value_or_unknown(result)
        result.success? && !result.stdout.strip.empty? ? result.stdout.strip : "unknown"
      end
    end
  end
end
