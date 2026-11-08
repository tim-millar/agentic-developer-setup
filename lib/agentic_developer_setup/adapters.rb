# frozen_string_literal: true

require_relative "assessment"
require_relative "adoption/schema"
require_relative "framework_catalogue"
require "rubygems"
require "shellwords"

module AgenticDeveloperSetup
  module Adapters
    class Error < Assessment::Error; end

    def self.provider_call(definition, phase)
      yield
    rescue LoadError, SyntaxError, StandardError
      raise Error, "adapter #{definition.category}/#{definition.id} failed during #{phase}", cause: nil
    end

    CATEGORIES = {
      "ecosystem" => "adapters/ecosystems/<name>",
      "framework" => "adapters/frameworks/<name>",
      "runtime" => "adapters/runtimes/<name>",
      "app-shape" => "adapters/app-shapes/<name>"
    }.freeze
    DOMAINS = %w[findings commands command_wrappers validation_profiles paths services requirements inputs component_recommendations documentation_requirements].freeze
    AUTHORITY = {
      "ecosystem" => DOMAINS - %w[command_wrappers requirements],
      "framework" => DOMAINS - %w[command_wrappers requirements],
      "runtime" => DOMAINS - %w[validation_profiles component_recommendations],
      "app-shape" => %w[findings validation_profiles requirements component_recommendations documentation_requirements]
    }.freeze
    module Providers; end
  end
end

require_relative "adapters/contracts"
require_relative "adapters/registry"
require_relative "adapters/context"
require_relative "adapters/selection"
require_relative "adapters/contributions"
require_relative "adapters/composer"
require_relative "adapters/assessor"
require_relative "adapters/cli"
