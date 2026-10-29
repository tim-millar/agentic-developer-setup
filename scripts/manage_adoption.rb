#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agentic_developer_setup/adoption/manage_cli"
exit AgenticDeveloperSetup::Adoption::ManageCLI.run(ARGV)
