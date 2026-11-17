# frozen_string_literal: true

require "minitest"
require "time"

module CheckTiming
  class Reporter < Minitest::AbstractReporter
    def initialize(io = $stderr)
      @io = io
      @results = []
      @current = nil
      @last_watchdog_tick = nil
      @max_watchdog_gap = 0.0
    end

    def start
      @last_watchdog_tick = now
      @io.puts "TEST TIMING started_at=#{Time.now.utc.iso8601(3)}"
      @io.flush
      @watchdog = Thread.new do
        loop do
          sleep 1
          report_stalled_test
        end
      end
    end

    def prerecord(klass, name)
      started = now
      @last_watchdog_tick ||= started
      @current = {klass: klass.name, name: name, started: started, started_at: Time.now.utc.iso8601(3), reported: false}
    end

    def record(result)
      observe_watchdog_gap(now)
      current = @current
      @current = nil
      @results << [result.klass, result.name, current ? now - current[:started] : result.time]
    end

    def report
      @watchdog&.kill
      @watchdog&.join
      observe_watchdog_gap(now)
      @io.puts format("TEST TIMING watchdog max_gap=%.1fs", @max_watchdog_gap)
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

    def report_stalled_test
      observed = now
      gap = observe_watchdog_gap(observed)
      @last_watchdog_tick = observed
      current = @current
      return unless current && !current[:reported]

      elapsed = observed - current[:started]
      return if elapsed < 30

      current[:reported] = true
      @io.puts format("TEST TIMING still running %s#%s elapsed=%.1fs watchdog_gap=%.1fs started_at=%s observed_at=%s",
        current[:klass], current[:name], elapsed, gap, current[:started_at], Time.now.utc.iso8601(3))
      @io.flush
    end

    # A gap records absent watchdog observations. It cannot on its own tell
    # host suspension, process suspension, scheduler delay, or GVL contention apart.
    def observe_watchdog_gap(observed)
      gap = @last_watchdog_tick ? observed - @last_watchdog_tick : 0.0
      @max_watchdog_gap = [@max_watchdog_gap, gap].max
      gap
    end

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
