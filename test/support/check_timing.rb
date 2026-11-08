# frozen_string_literal: true

require "minitest"

module CheckTiming
  class Reporter < Minitest::AbstractReporter
    def initialize(io = $stderr)
      @io = io
      @results = []
      @current = nil
    end

    def start
      @watchdog = Thread.new do
        loop do
          sleep 1
          current = @current
          next unless current && !current[:reported]

          elapsed = now - current[:started]
          next if elapsed < 30

          current[:reported] = true
          @io.puts format("TEST TIMING still running %s#%s elapsed=%.1fs", current[:klass], current[:name], elapsed)
          @io.flush
        end
      end
    end

    def prerecord(klass, name)
      @current = {klass: klass.name, name: name, started: now, reported: false}
    end

    def record(result)
      current = @current
      @current = nil
      @results << [result.klass, result.name, current ? now - current[:started] : result.time]
    end

    def report
      @watchdog&.kill
      @watchdog&.join
      @io.puts "TEST TIMING families (includes setup and teardown):"
      @results.group_by(&:first).sort_by { |_, rows| -rows.sum(&:last) }.each do |klass, rows|
        @io.puts format("  %s tests=%d elapsed=%.3fs", klass, rows.length, rows.sum(&:last))
      end
      @io.puts "TEST TIMING slowest 20 cases:"
      @results.sort_by { |row| -row.last }.first(20).each do |klass, name, elapsed|
        @io.puts format("  %s#%s elapsed=%.3fs", klass, name, elapsed)
      end
      @io.flush
    end

    private

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

module Minitest
  def self.plugin_check_timing_init(_options)
    reporter << CheckTiming::Reporter.new
  end
end

Minitest.extensions << "check_timing" if ENV["ADS_TEST_TIMING"] == "1"
