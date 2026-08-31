# frozen_string_literal: true

require "optparse"
require "yaml"

module AgenticDeveloperSetup
  module Assessment
    class CLI
      def self.run(argv, stdout: $stdout, stderr: $stderr)
        options = parse_options(argv)
        target = argv.shift
        raise InvocationError, "TARGET is required" unless target
        raise InvocationError, "unexpected arguments: #{argv.join(' ')}" unless argv.empty?
        raise InvocationError, "--report cannot be combined with --no-report" if options[:report] && options[:no_report]

        PathSafety.validate_output!(options[:output], target) if options[:output]
        PathSafety.validate_output!(options[:report], target) if options[:report]
        if options[:output] && options[:report] && Pathname.new(options[:output]).expand_path == Pathname.new(options[:report]).expand_path
          raise InvocationError, "--output and --report must be different paths"
        end

        result = Assessor.new(target).assess(context_path: options[:context])
        yaml = YAML.dump(deep_copy(result))
        report = if options[:report] && !options[:no_report]
                   MarkdownRenderer.render(result)
                 end
        write(options[:output], yaml) if options[:output]
        stdout.write(yaml) unless options[:output]
        write(options[:report], report) if report
        0
      rescue OptionParser::ParseError, Error => e
        stderr.puts "ERROR: #{e.message}"
        1
      rescue SystemCallError => e
        stderr.puts "ERROR: cannot write assessment output: #{e.message}"
        1
      end

      def self.parse_options(argv)
        options = { no_report: false }
        parser = OptionParser.new do |opts|
          opts.banner = "Usage: ruby scripts/assess_repository.rb TARGET [options]"
          opts.on("--output PATH", "Write YAML assessment to PATH") { |value| options[:output] = value }
          opts.on("--report PATH", "Write Markdown report to PATH") { |value| options[:report] = value }
          opts.on("--context PATH", "Read assessor context from PATH") { |value| options[:context] = value }
          opts.on("--no-report", "Suppress Markdown generation") { options[:no_report] = true }
        end
        parser.parse!(argv)
        options
      end

      def self.write(path, content)
        File.binwrite(path, content)
      end

      def self.deep_copy(value)
        case value
        when Hash
          value.each_with_object({}) { |(key, item), copy| copy[key] = deep_copy(item) }
        when Array
          value.map { |item| deep_copy(item) }
        else
          value
        end
      end

      private_class_method :parse_options, :write, :deep_copy
    end
  end
end
