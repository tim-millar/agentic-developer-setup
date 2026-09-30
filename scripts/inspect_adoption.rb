#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "optparse"
require "yaml"
require "agentic_developer_setup/adoption"

options = {no_report: false}
parser = OptionParser.new do |opts|
  opts.banner = "Usage: ruby scripts/inspect_adoption.rb TARGET [options]"
  opts.on("--framework-source PATH", "Compare with an explicit local framework source") { |value| options[:framework_source] = value }
  opts.on("--output PATH", "Write structured YAML to PATH") { |value| options[:output] = value }
  opts.on("--report PATH", "Write Markdown report to PATH") { |value| options[:report] = value }
  opts.on("--no-report", "Suppress Markdown generation") { options[:no_report] = true }
end

begin
  parser.parse!(ARGV)
  target = ARGV.shift
  raise AgenticDeveloperSetup::Assessment::InvocationError, "TARGET is required" unless target
  raise AgenticDeveloperSetup::Assessment::InvocationError, "unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
  raise AgenticDeveloperSetup::Assessment::InvocationError, "--report cannot be combined with --no-report" if options[:report] && options[:no_report]

  result = AgenticDeveloperSetup::Adoption::Inspector.new(target).inspect(framework_source: options[:framework_source])
  yaml = YAML.dump(result)
  output = options[:output] && AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(options[:output], target)
  report = options[:report] && AgenticDeveloperSetup::Assessment::PathSafety.validate_output!(options[:report], target)
  raise AgenticDeveloperSetup::Assessment::InvocationError, "--output and --report must be different paths" if output && report && output.identity == report.identity
  AgenticDeveloperSetup::Assessment::CLI.send(:write, output, yaml, target) if output
  $stdout.write(yaml) unless options[:output]
  if report && !options[:no_report]
    AgenticDeveloperSetup::Assessment::CLI.send(:write, report, AgenticDeveloperSetup::Adoption::Renderer.render(result), target)
  end
  exit(result.dig("summary", "error_count").to_i.zero? ? 0 : 1)
rescue OptionParser::ParseError, AgenticDeveloperSetup::Assessment::Error => e
  warn "ERROR: #{e.message}"
  exit 1
rescue SystemCallError => e
  warn "ERROR: cannot write adoption inspection output: #{e.message}"
  exit 1
end
