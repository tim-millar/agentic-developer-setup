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
end
