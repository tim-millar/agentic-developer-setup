# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentReferenceFixtureTest < Minitest::Test
  include AssessmentTestSupport

  def test_committed_fixture_is_generated_from_the_assessor_with_only_identity_normalisation
    actual = normalize_reference_assessment(assess(FIXTURE))
    committed = YAML.safe_load(
      File.read(File.join(FIXTURE, "assessment", "assessment.yml")),
      permitted_classes: [],
      permitted_symbols: [],
      aliases: false
    )

    assert_equal committed, actual
    assert_schema(actual)
    assert_equal AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(actual),
                 File.read(File.join(FIXTURE, "assessment", "assessment.md"))
  end
end
