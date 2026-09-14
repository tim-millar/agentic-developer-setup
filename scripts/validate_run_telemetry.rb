#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/agent_run_telemetry/validator"

if ARGV.length != 1
  warn "Usage: scripts/validate_run_telemetry.rb RUN_JSON"
  exit 2
end

begin
  record = JSON.parse(File.binread(ARGV.fetch(0)))
rescue JSON::ParserError, SystemCallError => e
  warn "run.json: #{e.message}"
  exit 1
end

validator = AgentRunTelemetry::Validator.new(record)
if validator.validate
  puts "Run telemetry validation passed."
else
  validator.errors.each { |error| warn error }
  exit 1
end
