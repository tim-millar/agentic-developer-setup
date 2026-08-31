# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentSchemaTest < Minitest::Test
  include AssessmentTestSupport

  def setup
    super
    write("README.md", "# Schema fixture\n")
    @valid = assess
  end

  def test_unknown_ecosystem_status_is_rejected
    invalid = copy(@valid)
    invalid["ecosystem"] = [{
      "name" => "python", "role" => "primary", "status" => "maybe", "confidence" => "high",
      "paths" => [], "evidence_ids" => [], "signals" => []
    }]

    assert_schema_error(invalid, "ecosystem[0].status")
  end

  def test_malformed_ecosystem_evidence_id_is_rejected
    invalid = copy(@valid)
    invalid["ecosystem"] = [{
      "name" => "python", "role" => "primary", "status" => "detected", "confidence" => "high",
      "paths" => [], "evidence_ids" => ["sha-key"], "signals" => []
    }]

    assert_schema_error(invalid, "E###")
  end

  def test_malformed_command_surface_entry_is_rejected
    invalid = copy(@valid)
    invalid.dig("tooling", "command_surface", "commands") << { "name" => "make test", "source" => "Makefile" }

    assert_schema_error(invalid, "tooling.command_surface.commands[0]")
  end

  def test_invalid_tool_confidence_is_rejected
    invalid = copy(@valid)
    invalid["tooling"]["task_runners"] = [{
      "name" => "Make", "status" => "detected", "confidence" => "certain", "evidence_ids" => []
    }]

    assert_schema_error(invalid, "confidence")
  end

  def test_invalid_validation_capability_state_is_rejected
    invalid = copy(@valid)
    invalid.dig("validation", "capabilities", "tests")["status"] = "works"

    assert_schema_error(invalid, "validation.capabilities.tests.status")
  end

  def test_unknown_validation_capability_field_is_rejected
    invalid = copy(@valid)
    invalid.dig("validation", "capabilities", "tests")["unexpected"] = true

    assert_schema_error(invalid, "unknown fields")
  end

  def test_malformed_documentation_entry_is_rejected
    invalid = copy(@valid)
    invalid.dig("documentation", "root_readme")["paths"] = ["/absolute/path"]

    assert_schema_error(invalid, "safe relative path")
  end

  def test_malformed_ci_tooling_section_is_rejected
    invalid = copy(@valid)
    invalid.dig("tooling", "ci")["invocations"] = ["make test", 42]

    assert_schema_error(invalid, "array of strings")
  end

  private

  def copy(value)
    Marshal.load(Marshal.dump(value))
  end

  def assert_schema_error(value, message)
    error = assert_raises(AgenticDeveloperSetup::Assessment::SchemaError) do
      AgenticDeveloperSetup::Assessment::Schema.validate!(value)
    end
    assert_includes error.message, message
  end
end
