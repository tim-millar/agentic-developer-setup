# frozen_string_literal: true

require "digest"

require_relative "../assessment_test_helper"

class AssessmentGitInspectorTest < Minitest::Test
  include AssessmentTestSupport

  def test_git_inspection_preserves_index_and_configuration_and_skips_fsmonitor
    init_git
    write(".gitignore", "ignored.txt\n")
    write("tracked.md", "tracked\n")
    Open3.capture3("git", "-C", @target, "add", ".gitignore", "tracked.md")
    Open3.capture3("git", "-C", @target, "commit", "-m", "metadata")
    write("ignored.txt", "ignored\n")
    write("dirty.md", "dirty\n")

    sentinel = File.join(@temporary_root, "fsmonitor-ran")
    hook = File.join(@temporary_root, "fsmonitor-hook")
    write_absolute(hook, "#!/bin/sh\ntouch #{sentinel}\n")
    File.chmod(0o755, hook)
    Open3.capture3("git", "-C", @target, "config", "core.fsmonitor", hook)

    index = File.join(@target, ".git", "index")
    config = File.join(@target, ".git", "config")
    index_digest = Digest::SHA256.file(index).hexdigest
    config_digest = Digest::SHA256.file(config).hexdigest

    inspector = AgenticDeveloperSetup::Assessment::GitInspector.new(Pathname.new(@target))
    info = inspector.info
    tracked = inspector.tracked_files
    ignored = inspector.ignored?("ignored.txt")
    result = assess

    assert_equal "dirty", info["working_tree"]
    assert_includes tracked, ".gitignore"
    assert_includes tracked, "tracked.md"
    assert ignored
    assert_equal index_digest, Digest::SHA256.file(index).hexdigest
    assert_equal config_digest, Digest::SHA256.file(config).hexdigest
    refute File.exist?(sentinel)
    assert_equal "dirty", result.dig("repository", "git", "working_tree")
  end
end
