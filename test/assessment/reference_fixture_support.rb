# frozen_string_literal: true

module ReferenceAssessmentSupport
  module_function

  def normalize(result)
    normalized = Marshal.load(Marshal.dump(result))
    normalized["repository"]["root"] = "examples/reference-service"
    normalized["repository"]["git"].update(
      "commit" => "normalised-for-fixture",
      "branch" => "main",
      "working_tree" => "clean"
    )
    normalized["framework"]["source_revision"] = "normalised-for-fixture"
    normalized
  end
end
