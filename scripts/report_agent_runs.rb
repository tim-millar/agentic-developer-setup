#!/usr/bin/env ruby
# frozen_string_literal: true

require "optparse"
require "tempfile"
require_relative "../lib/agent_run_reporting/markdown"

module AgentRunReporting
  class Command
    def run(arguments)
      options = {generated_at: Time.now.utc}
      parser = OptionParser.new do |cli|
        cli.banner = "Usage: ruby scripts/report_agent_runs.rb [options]"
        cli.require_exact = true
        cli.on("--telemetry-dir ABSOLUTE_PATH", "Select an existing telemetry root") { |value| options[:root] = absolute(value) }
        cli.on("--repository OWNER/REPOSITORY", "Filter by GitHub repository identity") do |value|
          unless AgentRunTelemetry::Validator::GITHUB_REPOSITORY.match?(value)
            raise OptionParser::InvalidArgument, "expected OWNER/REPOSITORY"
          end
          options[:repository] = value.downcase
        end
        cli.on("--output ABSOLUTE_PATH", "Write Markdown atomically outside the telemetry root") { |value| options[:output] = absolute(value) }
        cli.on("--as-of YYYY-MM-DDTHH:MM:SSZ", "Set the report timestamp in UTC") do |value|
          options[:generated_at] = AgentRunReporting.utc_timestamp(value, precision: 0) ||
            raise(OptionParser::InvalidArgument, "expected a valid UTC timestamp (YYYY-MM-DDTHH:MM:SSZ)")
        end
        cli.on("-h", "--help", "Show usage") do
          puts cli
          return 0
        end
      end
      parser.parse!(arguments)
      raise OptionParser::InvalidArgument, "unexpected positional arguments" unless arguments.empty?

      explicit_root = options.key?(:root)
      corpus = Corpus.new(options[:root] || Corpus.default_root, explicit: explicit_root, repository: options[:repository])
      report = Markdown.new(corpus, generated_at: options.fetch(:generated_at), repository: options[:repository], explicit_root: explicit_root).render
      if options[:output]
        write_output(options.fetch(:output), corpus.root, report)
      else
        $stdout.write(report)
      end
      0
    rescue OptionParser::ParseError => error
      warn error.message, parser
      2
    rescue InputError => error
      warn error.message
      1
    rescue SystemCallError
      warn "Could not write the Markdown report"
      1
    end

    private

    def absolute(value)
      raise OptionParser::InvalidArgument, "path must be absolute" unless value.start_with?("/")

      value
    end

    def write_output(path, root, report)
      directory = File.realpath(File.dirname(path))
      name = File.basename(path)
      destination = File.join(directory, name)
      if destination == root || destination.start_with?(root.end_with?("/") ? root : "#{root}/") ||
          %w[run.json usage.json outcome.json task.txt].include?(name)
        raise InputError, "Report output must be outside telemetry storage and use a non-telemetry filename"
      end

      existing = begin
        File.lstat(destination)
      rescue Errno::ENOENT
        nil
      end
      if existing && (!existing.file? || existing.nlink > 1)
        raise InputError, "Report output must be a regular file without links"
      end

      Tempfile.create([".ads-report-", ".md"], directory) do |file|
        file.binmode
        file.write(report)
        file.close
        File.rename(file.path, destination)
      end
    end
  end
end

exit AgentRunReporting::Command.new.run(ARGV) if $PROGRAM_NAME == __FILE__
