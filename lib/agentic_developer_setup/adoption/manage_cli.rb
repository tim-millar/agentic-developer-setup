# frozen_string_literal: true

require "optparse"
require_relative "application"
require_relative "preview"
require_relative "transaction_validation"

module AgenticDeveloperSetup
  module Adoption
    class ManageCLI
      include TransactionSupport

      def self.run(argv)
        new.run(argv)
      end

      def run(argv)
        argv = argv.dup
        command = argv.shift
        fail!("invalid_invocation", "expected plan, preview, check, apply or validate", 2) unless %w[plan preview check apply validate].include?(command)
        options = parse_options(command, argv)
        path = argv.shift
        fail!("invalid_invocation", "exactly one target or plan path is required", 2) unless path && argv.empty?
        if command == "plan"
          %i[operation framework_source effective_date output].each { |key| fail!("invalid_invocation", "--#{key.to_s.tr("_", "-")} is required", 2) unless options[key] }
          output = options.delete(:output)
          options[:source] = options.delete(:framework_source)
          plan = Planner.new(target: path, **options).write(output)
          puts "#{plan["plan_id"]} #{output}"
          return (plan["diagnostics"].any? { |item| item["severity"] == "error" }) ? 4 : 0
        end
        validator = PlanValidator.load(path)
        plan_path = external(path, validator.roots, present: true)
        identities_distinct!([plan_path, *validator.input_paths])
        case command
        when "preview"
          text, code = Preview.new(validator).render
          puts text
          code
        when "check"
          validator.check!
          puts "#{validator.plan["plan_id"]} applicable"
          0
        when "apply"
          if options[:dry_run]
            fail!("invalid_invocation", "dry-run does not accept approval or result options", 2) if options[:accept_plan_id] || options[:result]
            validator.check!
            puts "#{validator.plan["plan_id"]} applicable (dry run)"
            0
          else
            fail!("invalid_invocation", "apply requires --accept-plan-id and --result", 2) unless options[:accept_plan_id] && options[:result]
            result, code = Application.new(validator).apply(**options, plan_path: plan_path)
            puts "#{result["status"]} #{options[:result]}"
            code
          end
        when "validate"
          fail!("invalid_invocation", "validate requires --application-result and --output", 2) unless options[:application_result] && options[:output]
          result, code = TransactionValidation.new(validator).run(**options, plan_path: plan_path)
          puts "#{result["status"]} #{options[:output]}"
          code
        end
      rescue OptionParser::ParseError => e
        warn "error invalid_invocation: #{e.message}"
        2
      rescue TransactionError => e
        warn "error #{e.code}: #{e.message}"
        e.exit_code
      rescue Assessment::Error, KeyError, TypeError, ArgumentError => e
        warn "error invalid_document: #{e.message.lines.first.strip}"
        2
      rescue SystemCallError, IOError => e
        warn "error application_failed: #{e.message}"
        5
      end

      private

      def parse_options(command, argv)
        options = (command == "plan") ? {components: [], exclusions: []} : {}
        parser = OptionParser.new do |opts|
          if command == "plan"
            %w[operation framework-source scope decisions assessment validation-spec effective-date output tier].each do |key|
              opts.on("--#{key} VALUE") { |value| options[key.tr("-", "_").to_sym] = value }
            end
            opts.on("--component ID") { |value| options[:components] << value }
            opts.on("--exclude ID") { |value| options[:exclusions] << value }
          elsif command == "apply"
            opts.on("--accept-plan-id ID") { |value| options[:accept_plan_id] = value }
            opts.on("--result PATH") { |value| options[:result] = value }
            opts.on("--dry-run") { options[:dry_run] = true }
          elsif command == "validate"
            opts.on("--application-result PATH") { |value| options[:application_result] = value }
            opts.on("--output PATH") { |value| options[:output] = value }
          end
        end
        parser.parse!(argv)
        options
      end
    end
  end
end
