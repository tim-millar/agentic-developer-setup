# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "tmpdir"
require "yaml"

require "agentic_developer_setup/assessment"
require_relative "assessment/reference_fixture_support"

module AssessmentTestSupport
  ROOT = File.expand_path("..", __dir__)
  FIXTURE = File.join(ROOT, "examples", "reference-service")

  def setup
    super
    @temporary_root = Dir.mktmpdir("assessment-amendment-")
    @target = File.join(@temporary_root, "target")
    FileUtils.mkdir_p(@target)
  end

  def teardown
    FileUtils.remove_entry_secure(@temporary_root) if @temporary_root && File.exist?(@temporary_root)
    super
  end

  def assess(target = @target, context_path: nil)
    AgenticDeveloperSetup::Assessment::Assessor.new(target, clock: fixed_clock).assess(context_path: context_path)
  end

  def fixed_clock
    -> { Time.utc(2026, 1, 2, 3, 4, 5) }
  end

  def assert_schema(result)
    assert AgenticDeveloperSetup::Assessment::Schema.validate!(result)
  end

  def write(relative_path, content)
    write_absolute(File.join(@target, relative_path), content)
  end

  def write_absolute(path, content)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content)
  end

  def init_git(path = @target)
    _out, err, status = Open3.capture3("git", "init", path)
    raise err unless status.success?

    Open3.capture3("git", "-C", path, "config", "user.name", "Assessment Test")
    Open3.capture3("git", "-C", path, "config", "user.email", "assessment@example.invalid")
    File.write(File.join(path, "README.md"), "# initial\n")
    Open3.capture3("git", "-C", path, "add", "README.md")
    Open3.capture3("git", "-C", path, "commit", "-m", "initial")
  end

  def self.normalize_reference_assessment(result)
    ReferenceAssessmentSupport.normalize(result)
  end

  def normalize_reference_assessment(result)
    AssessmentTestSupport.normalize_reference_assessment(result)
  end
end
