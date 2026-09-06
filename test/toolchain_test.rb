# frozen_string_literal: true

require "fileutils"
require "minitest/autorun"
require "open3"
require "shellwords"
require "yaml"

class ToolchainTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  MAKEFILE = File.join(ROOT, "Makefile")
  WORKFLOW = File.join(ROOT, ".github", "workflows", "validate.yml")

  def test_declared_bundle_loads_minitest_and_library_without_rubylib
    stdout, stderr, status = capture_bundle_ruby(
      "-e", 'require "minitest"; require "agentic_developer_setup/assessment"; puts Minitest::VERSION'
    )

    assert status.success?, stderr
    refute_empty stdout.strip
  end

  def test_makefile_uses_bundle_for_ruby_commands_and_explicit_load_paths
    makefile = File.read(MAKEFILE)

    assert_includes makefile, "bundle exec ruby -Ilib -Itest"
    assert_includes makefile, "bundle exec ruby scripts/validate_framework.rb"
    assert_includes makefile, "bundle exec standardrb lib scripts test"
    assert_includes makefile, "bundle exec standardrb --fix lib scripts test"
    refute_match(/^\s*ruby\s+/, makefile)
  end

  def test_setup_is_the_only_dependency_install_target
    makefile = File.read(MAKEFILE)
    setup = makefile[/\.PHONY: setup.*?(?=\.PHONY: lint)/m]
    validation = makefile[/\.PHONY: lint.*\z/m]

    assert_includes setup, "bundle install"
    assert_includes setup, "bundle exec lefthook install"
    refute_match(/bundle install/, validation.sub(/\.PHONY: assess.*\z/m, ""))
  end

  def test_check_and_hooks_delegate_to_make_targets
    makefile = File.read(MAKEFILE)

    check = makefile[/\.PHONY: check.*?(?=\.PHONY: hook-pre-commit)/m]
    pre_commit = makefile[/\.PHONY: hook-pre-commit.*?(?=\.PHONY: hook-pre-push)/m]
    pre_push = makefile[/\.PHONY: hook-pre-push.*?(?=\.PHONY: assess)/m]

    assert_equal ["$(MAKE) lint", "$(MAKE) test", "$(MAKE) validate"], check.lines.grep(/\$\(MAKE\)/).map(&:strip)
    assert_includes pre_commit, "$(MAKE) lint"
    refute_includes pre_commit, "$(MAKE) test"
    assert_includes pre_push, "$(MAKE) check"
  end

  def test_lint_does_not_modify_the_worktree
    before = worktree_state
    _stdout, stderr, status = Open3.capture3({"RUBYLIB" => nil}, "make", "lint", chdir: ROOT)

    assert status.success?, stderr
    assert_equal before, worktree_state
  end

  def test_lefthook_delegates_to_make_hooks
    hooks = YAML.safe_load_file(File.join(ROOT, "lefthook.yml"))

    assert_equal "make hook-pre-commit", hooks.dig("pre-commit", "commands", "repo-pre-commit", "run")
    assert_equal "make hook-pre-push", hooks.dig("pre-push", "commands", "repo-pre-push", "run")
  end

  def test_ci_uses_bundle_cache_and_make_check_without_duplicate_ruby_commands
    workflow = File.read(WORKFLOW)

    assert_includes workflow, 'ruby-version: ".ruby-version"'
    assert_includes workflow, "bundler-cache: true"
    assert_includes workflow, "run: make check"
    assert_includes workflow, "setup-python"
    assert_includes workflow, "setup-uv"
    assert_includes workflow, "make check-reference-service"
    refute_match(/standardrb|validate_framework\.rb|test\/\*\//, workflow)
  end

  def test_root_toolchain_files_are_present
    %w[.ruby-version Gemfile Gemfile.lock lefthook.yml].each do |path|
      assert File.file?(File.join(ROOT, path)), "expected #{path}"
    end
  end

  private

  def capture_bundle_ruby(*arguments)
    Open3.capture3({"RUBYLIB" => nil}, "bundle", "exec", "ruby", "-Ilib", *arguments, chdir: ROOT)
  end

  def worktree_state
    tracked = `git -C #{Shellwords.escape(ROOT)} diff --name-status`
    untracked = `git -C #{Shellwords.escape(ROOT)} ls-files --others --exclude-standard`
    [tracked, untracked]
  end
end
