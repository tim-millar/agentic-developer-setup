# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "rbconfig"
require "yaml"
require "digest"

# These demonstrations deliberately create and commit disposable local fixture
# repositories. The adoption CLI itself never performs those Git mutations.
class AdoptionDemo
  ROOT = File.expand_path("../..", __dir__)

  def initialize
    @directory = Dir.mktmpdir("ads-adoption-demo-")
    @source = File.join(@directory, "framework")
    @target = File.join(@directory, "application")
    FileUtils.mkdir_p([@source, @target])
    FileUtils.cp(File.join(ROOT, "framework.yml"), @source)
    FileUtils.cp_r(File.join(ROOT, "baseline"), @source)
    FileUtils.mkdir_p(File.join(@source, "schemas"))
    FileUtils.cp(File.join(ROOT, "schemas/framework-adoption-v1.schema.json"), File.join(@source, "schemas"))
    File.write(File.join(@target, "README.md"), "Disposable public adoption demonstration.\n")
    File.write(File.join(@target, "Makefile"), "verify:\n\t@echo native-validation-passed\n")
    [@source, @target].each do |root|
      git(root, "init", "-q")
      git(root, "config", "user.name", "Public adoption example")
      git(root, "config", "user.email", "example@example.invalid")
      git(root, "config", "core.hooksPath", File::NULL)
      commit(root)
    end
  end

  def initial_adoption
    native = File.binread(File.join(@target, "Makefile"))
    run("assess_repository.rb", @target, "--output", external("assessment.yml"), "--no-report")
    reviewed = external("reviewed-AGENTS.md")
    File.write(reviewed, "# Disposable application contract\n\nUse make verify. Review all changes with a developer.\n")
    decisions = {
      "schema_version" => 1,
      "components" => [
        {"id" => "issue_template_config", "disposition" => "inherited"},
        {"id" => "agent_instructions", "disposition" => "specialised", "content_path" => reviewed, "local_ownership" => ["native commands", "local review policy"], "reviewed" => true},
        {"id" => "command_interface", "disposition" => "repository_owned", "equivalent" => {"paths" => ["Makefile"]}, "rationale" => "Native Makefile remains authoritative."}
      ]
    }
    File.write(external("decisions.yml"), YAML.dump(decisions))
    File.write(external("validation.yml"), YAML.dump({"schema_version" => 1, "commands" => [{"id" => "verify", "argv" => ["make", "verify"], "cwd" => "repository", "env" => {}, "expected_exit_code" => 0}]}))
    plan("initial_adoption", decisions["components"].map { |item| item["id"] }, "initial", ["--assessment", external("assessment.yml"), "--validation-spec", external("validation.yml")])
    review_apply("initial")
    raise "native file overwritten" unless File.binread(File.join(@target, "Makefile")) == native
    puts File.read(File.join(@target, ".agent-framework/adoption.yml"))
    run("manage_adoption.rb", "validate", external("initial-plan.yml"), "--application-result", external("initial-result.yml"), "--output", external("initial-validation.yml"))
    puts git(@target, "diff", "--stat")
    puts git(@target, "status", "--short")
    # Show created files as a normal developer would; the CLI did not stage them.
    puts File.read(File.join(@target, "AGENTS.md"))
    puts "PASS initial_adoption: inherited + specialised + native equivalent; approved validation passed."
  end

  def update_inherited
    initial_adoption
    commit(@target)
    original = metadata
    specialised = File.binread(File.join(@target, "AGENTS.md"))
    native = File.binread(File.join(@target, "Makefile"))
    path = File.join(@source, "baseline/.github/ISSUE_TEMPLATE/config.yml")
    File.write(path, File.read(path) + "# explicit local candidate revision\n")
    commit(@source)
    decisions = {"schema_version" => 1, "components" => [{"id" => "issue_template_config", "disposition" => "update_inherited"}]}
    File.write(external("decisions.yml"), YAML.dump(decisions))
    plan("update_inherited", ["issue_template_config"], "update")
    review_apply("update")
    after = metadata
    record = after["components"].find { |item| item["id"] == "issue_template_config" }
    raise "bytes differ" unless File.binread(path) == File.binread(File.join(@target, record["target_path"]))
    raise "revision not advanced" unless record["adopted_revision"] == git(@source, "rev-parse", "HEAD").strip
    raise "digest not advanced" unless record["adopted_source_digest"] == "sha256:#{Digest::SHA256.file(path).hexdigest}"
    raise "specialisation changed" unless File.binread(File.join(@target, "AGENTS.md")) == specialised
    raise "native file changed" unless File.binread(File.join(@target, "Makefile")) == native
    raise "unrelated provenance changed" unless original["components"].reject { |item| item["id"] == "issue_template_config" } == after["components"].reject { |item| item["id"] == "issue_template_config" }
    puts git(@target, "diff")
    puts "PASS update_inherited: exact candidate bytes and provenance advanced; unrelated records and files preserved."
  end

  def close
    FileUtils.remove_entry_secure(@directory)
  end

  private

  def external(name)
    File.join(File.realpath(@directory), name)
  end

  def metadata
    YAML.safe_load_file(File.join(@target, ".agent-framework/adoption.yml"))
  end

  def plan(operation, ids, prefix, extra = [])
    args = ["plan", @target, "--operation", operation, "--framework-source", @source, "--scope", ".", "--decisions", external("decisions.yml"), "--effective-date", "2026-10-29", "--output", external("#{prefix}-plan.yml")]
    ids.each { |id| args.concat(["--component", id]) }
    run("manage_adoption.rb", *args, *extra)
  end

  def review_apply(prefix)
    plan = external("#{prefix}-plan.yml")
    run("manage_adoption.rb", "preview", plan)
    run("manage_adoption.rb", "check", plan)
    run("manage_adoption.rb", "apply", plan, "--dry-run")
    id = YAML.safe_load_file(plan)["plan_id"]
    # Explicit approval for these fixed, disposable demonstration inputs only.
    run("manage_adoption.rb", "apply", plan, "--accept-plan-id", id, "--result", external("#{prefix}-result.yml"))
  end

  def run(script, *arguments)
    puts "$ ruby scripts/#{script} #{arguments.join(" ")}"
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, File.join(ROOT, "scripts", script), *arguments)
    puts stdout
    raise stderr unless status.success?
  end

  def git(root, *arguments)
    environment = ENV.keys.grep(/\AGIT_/).to_h { |key| [key, nil] }
    stdout, stderr, status = Open3.capture3(environment, "git", *arguments, chdir: root)
    raise stderr unless status.success?
    stdout
  end

  def commit(root)
    git(root, "add", "--all")
    git(root, "commit", "-qm", "Disposable demonstration snapshot")
  end
end
