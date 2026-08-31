# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentEvidenceTest < Minitest::Test
  include AssessmentTestSupport

  def test_final_ids_are_resolved_after_late_evidence_changes_sort_order
    evidence = AgenticDeveloperSetup::Assessment::Evidence.new
    evidence_a = evidence.add(type: "file", path: "z.yml", method: "test", summary: "Evidence A")
    finding = { "evidence_ids" => evidence.references([evidence_a]) }
    evidence_b = evidence.add(type: "file", path: "a.yml", method: "test", summary: "Evidence B")

    evidence.resolve_references!(finding)

    assert_equal ["E002"], finding["evidence_ids"]
    assert_equal ["E001", "E002"], evidence.materialize.map { |item| item["id"] }
    assert_equal "Evidence A", evidence.materialize.fetch(1).fetch("summary")
    refute_includes finding["evidence_ids"], evidence_b
  end

  def test_duplicate_evidence_is_deduplicated_and_shared_references_resolve_once
    evidence = AgenticDeveloperSetup::Assessment::Evidence.new
    first = evidence.add(type: "file", path: "same.yml", method: "test", summary: "Same")
    duplicate = evidence.add(type: "file", path: "same.yml", method: "test", summary: "Same")
    result = {
      "first" => { "evidence_ids" => evidence.references([first, duplicate]) },
      "second" => { "evidence_ids" => evidence.references([duplicate]) }
    }

    evidence.resolve_references!(result)

    assert_equal first, duplicate
    assert_equal ["E001"], result.dig("first", "evidence_ids")
    assert_equal ["E001"], result.dig("second", "evidence_ids")
    assert_equal 1, evidence.materialize.length
  end

  def test_assessment_output_is_stable_over_repeated_runs
    write("README.md", "# Stable\n\nmake verify\n")
    write("Makefile", "verify:\n\t@echo verify\n")

    assert_equal YAML.dump(assess), YAML.dump(assess)
  end
end
