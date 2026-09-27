#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require_relative "../lib/agent_run_usage/validator"

unless ARGV.length == 1
  warn "Usage: scripts/validate_run_usage.rb USAGE_JSON"
  exit 2
end

begin
  record = JSON.parse(File.binread(ARGV.fetch(0)))
rescue Errno::ENOENT, Errno::EACCES, JSON::ParserError => e
  warn "usage.json: #{e.message}"
  exit 1
end

validator = AgentRunUsage::Validator.new(record)
unless validator.validate
  validator.errors.sort.each { |error| warn "usage.json: #{error}" }
  exit 1
end

puts "Run usage validation passed."
