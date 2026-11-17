# frozen_string_literal: true

# Manual, bounded reproduction of an environmental pause. The inner test is
# expected to fail its unchanged ten-second assertion; this driver succeeds only
# when that failure and complete probe cleanup are observed.
require "fileutils"
require "open3"
require "json"
require "rbconfig"
require "timeout"
require "tmpdir"

root = File.expand_path("../..", __dir__)
Dir.mktmpdir("issue-102-pause-") do |control|
  marker = File.join(control, "root")
  output = File.join(control, "output")
  cleanup = File.join(control, "cleanup.json")
  code = <<~CODE
    require_relative "test/support/launcher_harness"
    LauncherHarness.prepend(Module.new do
      def initialize(...)
        super
        File.write(#{marker.dump}, root)
      end
      def close
        File.write(#{cleanup.dump}, JSON.generate({probe_paths: codex_version_probe_temporary_paths}))
        super
      end
    end)
    require_relative "test/support/check_timing"
    require_relative "test/run_telemetry_test"
  CODE
  pid = Process.spawn({"ADS_TEST_TIMING" => "1"}, RbConfig.ruby, "-Ilib", "-Itest", "-e", code, "--",
    "--name", "/CodexRunTelemetryTest#test_hanging_version_probe_times_out_without_blocking_the_workload/", "--seed", "31468",
    chdir: root, pgroup: true, out: output, err: [:child, :out])
  group_pid = pid
  probe = nil
  fixture = nil
  begin
    Timeout.timeout(12) do
      loop do
        fixture = File.read(marker) if File.exist?(marker)
        path = fixture && File.join(fixture, "codex-version-probe.pid")
        if path && File.file?(path) && !File.read(path).empty?
          probe = Integer(File.read(path))
          break
        end
        sleep 0.01
      end
    end
    Process.kill("STOP", -pid)
    puts "controlled condition: entire synthetic test process group stopped after probe-created marker"
    launcher = Integer(Open3.capture2("ps", "-p", probe.to_s, "-o", "ppid=").first.strip)
    children = Open3.capture2("pgrep", "-P", launcher.to_s).first.split.map(&:to_i)
    states = Open3.capture2("ps", "-p", ([pid, launcher] + children).uniq.join(","), "-o", "pid=,ppid=,state=,comm=").first
    puts states.lines.map { |line|
      fields = line.split
      [*fields[0..2], File.basename(fields.last)].join(" ")
    }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 11
    puts "controller pause=#{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(3)}s"
    Process.kill("CONT", -pid)
    _, status = Timeout.timeout(15) { Process.wait2(pid) }
    pid = nil
    text = File.read(output)
    puts text
    alive = begin
      Process.kill(0, probe)
      true
    rescue Errno::ESRCH
      false
    end
    paths = JSON.parse(File.read(cleanup)).fetch("probe_paths")
    survivors = children.select do |child|
      Process.kill(0, child)
      true
    rescue Errno::ESRCH
      false
    end
    puts "probe_alive_after_completion=#{alive} owned_children_alive=#{survivors.length} probe_resources_remaining=#{paths.length}"
    expected_failure = text.match?(/1 runs, \d+ assertions, 1 failures, 0 errors, 0 skips/)
    abort "unexpected reproduction result" unless status.exitstatus == 1 && expected_failure && text.include?("to be < 10") && !alive && survivors.empty? && paths.empty?
  ensure
    # Keep ownership of the group after its parent exits, so a regression that
    # leaves an orphan is still cleaned up when the diagnostic rejects it.
    begin
      Process.kill("CONT", -group_pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.kill("KILL", -group_pid)
    rescue Errno::ESRCH
      nil
    end
    begin
      Process.wait(pid) if pid
    rescue Errno::ECHILD
      nil
    end
    FileUtils.remove_entry_secure(fixture) if fixture && File.directory?(fixture)
  end
end
