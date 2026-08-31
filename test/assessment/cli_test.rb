# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentCLITest < Minitest::Test
  include AssessmentTestSupport

  def test_no_report_does_not_invoke_markdown_renderer
    renderer = AgenticDeveloperSetup::Assessment::MarkdownRenderer
    original = renderer.method(:render)
    invoked = false
    renderer.define_singleton_method(:render) do |_result|
      invoked = true
      raise "Markdown renderer should not be called"
    end

    status = nil
    begin
      status = AgenticDeveloperSetup::Assessment::CLI.run([@target, "--no-report"], stdout: StringIO.new, stderr: StringIO.new)
    ensure
      renderer.define_singleton_method(:render, original)
    end

    assert_equal 0, status
    refute invoked
  end

  def test_make_wrapper_passes_paths_with_spaces_and_wildcards_as_one_argument
    path = File.join(@temporary_root, "target with spaces [literal]*")
    FileUtils.mkdir_p(path)

    stdout, stderr, status = Open3.capture3(
      "make", "assess", "REPO=#{path}",
      chdir: AssessmentTestSupport::ROOT
    )

    assert status.success?, stderr
    assert_includes stdout, "schema_version: 1"
  end
end
