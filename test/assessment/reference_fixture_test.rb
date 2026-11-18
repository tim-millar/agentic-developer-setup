# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentReferenceFixtureTest < Minitest::Test
  include AssessmentTestSupport

  def test_committed_fixture_is_generated_from_the_assessor_with_only_identity_normalisation
    fixture = isolated_reference_fixture
    actual = normalize_reference_assessment(assess(fixture))
    committed = YAML.safe_load_file(File.join(FIXTURE, "assessment", "assessment.yml"), permitted_classes: [],
      permitted_symbols: [],
      aliases: false)

    assert_equal committed, actual
    assert_schema(actual)
    assert_equal AgenticDeveloperSetup::Assessment::MarkdownRenderer.render(actual),
      File.read(File.join(FIXTURE, "assessment", "assessment.md"))
  end

  def test_local_generated_environment_changes_the_live_assessment_but_not_the_committed_fixture_input
    clean_fixture = isolated_reference_fixture
    generated_fixture = isolated_reference_fixture
    FileUtils.mkdir_p(File.join(generated_fixture, ".venv"))

    clean = normalize_reference_assessment(assess(clean_fixture))
    generated = normalize_reference_assessment(assess(generated_fixture))
    committed = YAML.safe_load_file(File.join(FIXTURE, "assessment", "assessment.yml"), permitted_classes: [],
      permitted_symbols: [],
      aliases: false)

    assert_equal committed, clean
    assert_equal committed.dig("scope", "excluded_paths"), clean.dig("scope", "excluded_paths")
    assert_includes generated.dig("scope", "excluded_paths"), ".venv"
    refute_equal committed, generated
  end
end
