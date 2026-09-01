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

  def test_git_inspection_clears_inherited_repository_routing_environment
    init_git
    write(".gitignore", "ignored.txt\n")
    Open3.capture3("git", "-C", @target, "add", ".gitignore")
    Open3.capture3("git", "-C", @target, "commit", "-m", "target metadata")
    write("ignored.txt", "ignored\n")

    decoy = File.join(@temporary_root, "decoy")
    init_git(decoy)
    write_absolute(File.join(decoy, "decoy-only.md"), "decoy\n")
    Open3.capture3("git", "-C", decoy, "add", "decoy-only.md")
    Open3.capture3("git", "-C", decoy, "commit", "-m", "decoy metadata")
    target_commit = Open3.capture3("git", "-C", @target, "rev-parse", "HEAD").first.strip

    original = %w[GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE].to_h { |name| [name, ENV[name]] }
    begin
      ENV["GIT_DIR"] = File.join(decoy, ".git")
      ENV["GIT_WORK_TREE"] = decoy
      ENV["GIT_INDEX_FILE"] = File.join(decoy, ".git", "index")

      inspector = AgenticDeveloperSetup::Assessment::GitInspector.new(Pathname.new(@target))

      assert_equal target_commit, inspector.source_revision
      assert_includes inspector.tracked_files, ".gitignore"
      refute_includes inspector.tracked_files, "decoy-only.md"
      assert inspector.ignored?("ignored.txt")
    ensure
      original.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    end
  end
end
