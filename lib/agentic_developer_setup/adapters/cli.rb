# frozen_string_literal: true

module AgenticDeveloperSetup
  module Adapters
    class CLI
      def self.run(argv, stdout: $stdout, stderr: $stderr, framework_root: File.expand_path("../../..", __dir__))
        options = {}
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: ruby scripts/assess_adapters.rb TARGET [--selection PATH] [--output PATH]"
          opts.on("--selection PATH") { |path| options[:selection] = path }
          opts.on("--output PATH") { |path| options[:output] = path }
        end
        parser.parse!(argv)
        target = argv.shift
        raise Error, "TARGET is required" unless target
        raise Error, "unexpected arguments: #{argv.join(" ")}" unless argv.empty?
        destination = options[:output] && Assessment::PathSafety.validate_output!(options[:output], target)
        selection = options[:selection] && Contracts.load_yaml(options[:selection])
        result = Assessor.new(target: target, framework_root: framework_root, selection: selection).assess
        yaml = YAML.dump(Contracts.copy(result))
        if destination
          # Use the generic assessor's existing revalidation and atomic writer.
          Assessment::CLI.send(:write, destination, yaml, target)
        else
          stdout.write(yaml)
        end
        0
      rescue OptionParser::ParseError, Assessment::Error, SystemCallError => e
        stderr.puts "ERROR: #{e.message}"
        1
      end
    end
  end
end
