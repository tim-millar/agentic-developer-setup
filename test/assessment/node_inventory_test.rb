# frozen_string_literal: true

require_relative "../assessment_test_helper"

class NodeMetadataInventoryTest < Minitest::Test
  include AssessmentTestSupport

  I = AgenticDeveloperSetup::Assessment::Inventory

  def inventory
    I.new(Pathname.new(@target)).discover
  end

  def test_new_metadata_is_bounded_at_root_and_nested_packages
    %w[.nvmrc .node-version npm-shrinkwrap.json].each do |file|
      write(file, "20.1.0")
      write("packages/web/#{file}", "20.1.0")
      write("node_modules/hidden/#{file}", "private")
      write("dist/#{file}", "generated")
      write("docs/examples/#{file}", "documentation sample")
      write("arbitrary/deep/#{file}", "not traversed")
    end
    write(".npmrc", "private configuration")
    result = inventory
    %w[.nvmrc .node-version npm-shrinkwrap.json].each do |file|
      assert_equal "20.1.0", result.read(file)
      assert_equal "20.1.0", result.read("packages/web/#{file}")
      %w[node_modules/hidden dist docs/examples arbitrary/deep].each { |prefix| assert_nil result.read("#{prefix}/#{file}") }
    end
    assert_nil result.read(".npmrc")
    assert_nil result.read("../outside")
  end

  def test_ignored_unsafe_oversized_and_tracked_excluded_metadata_stays_inaccessible
    init_git
    write(".gitignore", ".nvmrc\npackages/ignored/\n")
    write(".nvmrc", "private ignored value")
    write("packages/ignored/.node-version", "private")
    write("npm-shrinkwrap.json", "x" * (I::MAX_READ_BYTES + 1))
    outside = File.join(@temporary_root, "outside-version")
    File.write(outside, "private")
    File.symlink(outside, File.join(@target, ".node-version"))
    write("node_modules/package/npm-shrinkwrap.json", "private dependency")
    write("build/.nvmrc", "private generated metadata")
    _, err, status = Open3.capture3("git", "-C", @target, "add", "-f", "node_modules", "build")
    assert status.success?, err
    result = inventory
    %w[.nvmrc packages/ignored/.node-version npm-shrinkwrap.json .node-version node_modules/package/npm-shrinkwrap.json build/.nvmrc].each do |file|
      assert_nil result.read(file), file
    end
    assert_includes result.ignored_paths, ".nvmrc"
    assert_includes result.symlink_boundaries, ".node-version"
    assert_equal 256 * 1024, I::MAX_READ_BYTES
  end

  def test_generic_detector_handles_nonobject_and_invalid_script_fields
    %w[null false 1 []].each do |raw|
      write("package.json", raw)
      assert_schema assess
    end
    write("package.json", '{"scripts":{"test":{"command":"jest"},"lint":null,"build":3}}')
    assert_schema assess
  end
end
