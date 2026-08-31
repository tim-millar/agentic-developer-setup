# frozen_string_literal: true

require "optparse"
require "tempfile"
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

        output_destination = options[:output] && PathSafety.validate_output!(options[:output], target)
        report_destination = options[:report] && PathSafety.validate_output!(options[:report], target)
        if output_destination && report_destination && output_destination.identity == report_destination.identity
          raise InvocationError, "--output and --report must be different paths"
        end

        result = Assessor.new(target).assess(context_path: options[:context])
        yaml = YAML.dump(deep_copy(result))
        report = if options[:report] && !options[:no_report]
                   MarkdownRenderer.render(result)
                 end
        write(output_destination, yaml, target) if output_destination
        stdout.write(yaml) unless options[:output]
        write(report_destination, report, target) if report
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

      def self.write(destination, content, target_root)
        validated = PathSafety.validate_output!(destination.path, target_root)
        unless validated.identity == destination.identity
          raise InvocationError, "output destination changed after validation"
        end

        mode = existing_mode(validated.path)
        Tempfile.create([".assessment-", ".tmp"], temporary_directory(validated)) do |temporary|
          temporary.binmode
          temporary.write(content)
          temporary.flush
          temporary.fsync
          temporary.chmod(mode) if mode
          temporary.close
          File.rename(temporary.path, validated.path.to_s)
        end
      end

      def self.existing_mode(path)
        stat = File.lstat(path.to_s)
        stat.mode & 0o7777 if stat.file? && !stat.symlink?
      rescue Errno::ENOENT
        nil
      end

      def self.temporary_directory(destination)
        destination.path.dirname.to_s
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

      private_class_method :parse_options, :write, :existing_mode, :temporary_directory, :deep_copy
    end
  end
end
