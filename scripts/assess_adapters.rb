#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative "../lib/agentic_developer_setup/adapters"

exit AgenticDeveloperSetup::Adapters::CLI.run(ARGV)
