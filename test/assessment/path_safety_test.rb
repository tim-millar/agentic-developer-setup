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

    destination = AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(output, @target)

    assert_equal Pathname.new(output).expand_path, destination.path
    assert_equal Pathname.new(output).realpath, destination.resolved
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

    destination = AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(link, @target)

    assert_equal Pathname.new(link).expand_path, destination.path
    assert_equal Pathname.new(File.join(outside, "assessment.yml")).realpath, destination.resolved
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

  def test_output_and_report_same_lexical_destination_is_rejected
    output = File.join(@temporary_root, "assessment.yml")
    status = cli_status("--output", output, "--report", output)

    assert_equal 1, status
    refute File.exist?(output)
  end

  def test_output_and_report_path_aliases_are_rejected
    output = File.join(@temporary_root, "nested", "..", "assessment.yml")
    report = File.join(@temporary_root, "assessment.yml")

    assert_equal 1, cli_status("--output", output, "--report", report)
  end

  def test_output_and_report_symlink_aliases_are_rejected
    destination = File.join(@temporary_root, "future", "assessment.yml")
    first = File.join(@temporary_root, "first.yml")
    second = File.join(@temporary_root, "second.yml")
    File.symlink(destination, first)
    File.symlink(destination, second)

    assert_equal 1, cli_status("--output", first, "--report", second)
    refute File.exist?(File.join(@target, "future", "assessment.yml"))
  end

  def test_distinct_external_destinations_are_accepted
    output = File.join(@temporary_root, "assessment.yml")
    report = File.join(@temporary_root, "assessment.md")

    assert_equal 0, cli_status("--output", output, "--report", report)
    assert_includes File.read(output), "schema_version"
    assert_includes File.read(report), "# Repository assessment"
  end

  def test_hard_linked_external_output_is_replaced_without_mutating_target
    target_file = File.join(@target, "README.md")
    original = "target bytes must remain unchanged\n"
    File.write(target_file, original)
    outside_link = File.join(@temporary_root, "result.yml")
    File.link(target_file, outside_link)
    target_inode = File.stat(target_file).ino

    assert_equal 0, cli_status("--output", outside_link)

    assert_equal original, File.read(target_file)
    assert_includes File.read(outside_link), "schema_version"
    refute_equal target_inode, File.stat(outside_link).ino
  end

  def test_safe_external_symlink_is_replaced_at_the_requested_entry
    outside = File.join(@temporary_root, "outside")
    FileUtils.mkdir_p(outside)
    linked_target = File.join(outside, "linked-result.yml")
    File.write(linked_target, "external bytes\n")
    link = File.join(@temporary_root, "result.yml")
    File.symlink(linked_target, link)

    assert_equal 0, cli_status("--output", link)

    assert File.file?(link)
    assert_equal "external bytes\n", File.read(linked_target)
  end

  def test_temporary_output_file_is_created_beside_requested_entry
    outside = File.join(@temporary_root, "outside")
    FileUtils.mkdir_p(outside)
    target = File.join(outside, "result.yml")
    link = File.join(@temporary_root, "result.yml")
    File.symlink(target, link)
    destination = AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(link, @target)

    directory = AgenticDeveloperSetup::Assessment::CLI.send(:temporary_directory, destination)

    assert_equal Pathname.new(link).expand_path.dirname.to_s, directory
    refute_equal destination.resolved.dirname.to_s, directory
  end

  def test_containment_uses_canonical_existing_ancestry
    existing = File.join(@temporary_root, "Repository")
    FileUtils.mkdir_p(existing)
    requested = File.join(existing, "nested", "result.yml")
    canonical = AgenticDeveloperSetup::Assessment::PathSafety.send(:canonical_path, Pathname.new(requested))

    assert_equal Pathname.new(existing).realpath, canonical.parent.parent
  end

  private

  def cli_status(*arguments)
    AgenticDeveloperSetup::Assessment::CLI.run(
      [@target, *arguments],
      stdout: StringIO.new,
      stderr: StringIO.new
    )
  end
end
