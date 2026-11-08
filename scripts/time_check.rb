# frozen_string_literal: true

# Print only the caller-owned stage label, elapsed time, and exit status.
# Child output and failure semantics remain unchanged.
label = ARGV.shift
abort "usage: time_check.rb LABEL COMMAND [ARG ...]" unless label && !ARGV.empty?
started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
pid = Process.spawn(*ARGV)
_, status = Process.wait2(pid)
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
code = status.exitstatus || 128 + status.termsig
warn format("CHECK TIMING %s elapsed=%.3fs exit=%d", label, elapsed, code)
exit code
