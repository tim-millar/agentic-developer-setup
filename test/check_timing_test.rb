# frozen_string_literal: true

require "minitest/autorun"
require "open3"
require "rbconfig"
require "stringio"
require_relative "support/check_timing"

class CheckTimingTest < Minitest::Test
  TIMER = File.expand_path("../scripts/time_check.rb", __dir__)

  def test_timer_preserves_success_and_failure_without_logging_arguments
    [0, 7].each do |code|
      stdout, stderr, status = Open3.capture3(RbConfig.ruby, TIMER, "fixture", RbConfig.ruby, "-e", "exit #{code}", "synthetic-secret-argument")
      assert_equal code, status.exitstatus
      assert_empty stdout
      assert_match(/CHECK TIMING fixture elapsed=\d+\.\d+s exit=#{code}/, stderr)
      refute_includes stderr, "synthetic-secret-argument"
    end
  end

  def test_timer_preserves_signal_failure
    _stdout, stderr, status = Open3.capture3(RbConfig.ruby, TIMER, "fixture", RbConfig.ruby, "-e", 'Process.kill("TERM", Process.pid)')
    assert_equal 143, status.exitstatus
    assert_includes stderr, "exit=143"
  end

  def test_reporter_emits_one_stall_notice_per_case_without_waiting
    io = StringIO.new
    reporter = CheckTiming::Reporter.new(io)
    clock = 0.0
    reporter.define_singleton_method(:now) { clock }
    reporter.prerecord(self.class, "slow_fixture")
    clock = 29.0
    reporter.send(:report_stalled_test)
    assert_empty io.string
    clock = 31.0
    reporter.send(:report_stalled_test)
    clock = 100.0
    reporter.send(:report_stalled_test)
    assert_equal 1, io.string.lines.length
    assert_includes io.string, "CheckTimingTest#slow_fixture elapsed=31.0s"
  end

  def test_timing_toggle_preserves_passing_and_failing_suite_outcomes
    [false, true].each do |failing|
      statuses = ["0", "1"].map do |enabled|
        code = <<~RUBY
          require "minitest/autorun"
          require_relative "test/support/check_timing"
          class TimingFixture < Minitest::Test
            def test_result
              assert #{!failing}
            end
          end
        RUBY
        stdout, stderr, status = Open3.capture3({"ADS_TEST_TIMING" => enabled}, RbConfig.ruby, "-e", code, chdir: File.expand_path("..", __dir__))
        assert_includes stdout, "1 runs, 1 assertions"
        assert_equal enabled == "1", stderr.include?("TEST TIMING families")
        status.exitstatus
      end
      assert_equal [failing ? 1 : 0] * 2, statuses
    end
  end

  def test_reporter_bounds_case_output_and_keeps_every_family_count
    io = StringIO.new
    reporter = CheckTiming::Reporter.new(io)
    25.times do |index|
      result = Minitest::Result.new("case_#{index}")
      result.klass = "Fixture"
      result.time = index.to_f
      reporter.record(result)
    end
    reporter.report
    assert_includes io.string, "Fixture tests=25 elapsed=300.000s"
    assert_equal 20, io.string.lines.grep(/Fixture#case_/).length
    assert_includes io.string, "Fixture#case_24"
    refute_includes io.string, "Fixture#case_0 "
    assert reporter.passed?
  end
end
