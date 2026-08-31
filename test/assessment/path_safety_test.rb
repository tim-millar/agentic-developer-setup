# frozen_string_literal: true

require_relative "../assessment_test_helper"

class AssessmentPathSafetyTest < Minitest::Test
  include AssessmentTestSupport

  def test_direct_output_path_inside_target_is_rejected
    assert_raises(AgenticDeveloperSetup::Assessment::InvocationError) do
      AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(File.join(@target, "assessment.yml"), @target)
    end
  end

  def test_existing_external_regular_file_is_allowed
    output = File.join(@temporary_root, "output.yml")
    File.write(output, "old\n")

    assert_equal Pathname.new(output).expand_path,
                 AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(output, @target)
  end

  def test_external_symlink_pointing_inside_target_is_rejected
    link = File.join(@temporary_root, "inside-link.yml")
    File.symlink(File.join(@target, "assessment.yml"), link)

    assert_raises(AgenticDeveloperSetup::Assessment::InvocationError) do
      AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(link, @target)
    end
  end

  def test_dangling_external_symlink_pointing_inside_target_is_rejected
    link = File.join(@temporary_root, "dangling-link.yml")
    File.symlink(File.join(@target, "not-created.yml"), link)

    assert_raises(AgenticDeveloperSetup::Assessment::InvocationError) do
      AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(link, @target)
    end
  end

  def test_symlinked_parent_resolving_inside_target_is_rejected
    parent = File.join(@temporary_root, "parent-link")
    File.symlink(@target, parent)

    assert_raises(AgenticDeveloperSetup::Assessment::InvocationError) do
      AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(File.join(parent, "assessment.yml"), @target)
    end
  end

  def test_safe_external_symlink_is_allowed
    outside = File.join(@temporary_root, "outside")
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, "assessment.yml"), "old\n")
    link = File.join(@temporary_root, "outside-link.yml")
    File.symlink(File.join(outside, "assessment.yml"), link)

    assert_equal Pathname.new(link).expand_path,
                 AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(link, @target)
  end

  def test_rejected_destinations_leave_target_unchanged
    before = Dir.glob(File.join(@target, "**", "*"), File::FNM_DOTMATCH).sort.map { |path| [path, File.lstat(path).ftype] }
    link = File.join(@temporary_root, "dangling-link.yml")
    File.symlink(File.join(@target, "not-created.yml"), link)

    status = AgenticDeveloperSetup::Assessment::CLI.run([@target, "--output", link], stdout: StringIO.new, stderr: StringIO.new)
    assert_equal 1, status

    after = Dir.glob(File.join(@target, "**", "*"), File::FNM_DOTMATCH).sort.map { |path| [path, File.lstat(path).ftype] }
    assert_equal before, after
  end
end
