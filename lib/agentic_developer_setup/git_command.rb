# frozen_string_literal: true

require "open3"

module AgenticDeveloperSetup
  module GitCommand
    Result = Struct.new(:stdout, :stderr, :success?)

    module_function

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
