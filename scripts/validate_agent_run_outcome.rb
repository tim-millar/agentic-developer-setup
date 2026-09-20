#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/agent_run_outcomes/validator"

if ARGV.length != 1 || File.absolute_path(ARGV.first) != ARGV.first
  warn "usage: ruby scripts/validate_agent_run_outcome.rb /absolute/path/to/outcome.json"
  exit 2
end

begin
  record = JSON.parse(File.binread(ARGV.first))
rescue Errno::ENOENT, Errno::EACCES => error
  warn "outcome: #{error.message}"
  exit 1
rescue JSON::ParserError => error
  warn "outcome: invalid JSON (#{error.message})"
  exit 1
end

validator = AgentRunOutcomes::Validator.new(record)
if validator.validate
  puts "valid agent run outcome v1: #{record["run_id"]}"
  exit 0
end

validator.errors.each { |error| warn error }
exit 1
