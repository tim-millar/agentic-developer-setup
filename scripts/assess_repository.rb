#!/usr/bin/env ruby
# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "agentic_developer_setup/assessment"

exit AgenticDeveloperSetup::Assessment::CLI.run(ARGV)
