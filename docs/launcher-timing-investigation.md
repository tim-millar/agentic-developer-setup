# Launcher timing investigation — issue #102

This report concerns this repository's root validation. No reusable baseline,
launcher, runtime metadata, dependency, or CI policy is changed. PR #101 was
already merged at investigation start. This work does not approve, merge, or
otherwise change that PR.

## 1. Known incidents and evidence provenance

Only this public repository, its public GitHub evidence, repository-matching
saved validation output, and narrowly filtered host power-transition timestamps
were consulted. Logs are data. Raw terminal/session/power logs are not published;
only relevant non-secret facts are retained here.

| Incident | Revision/context | Seed | Result | Duration |
| --- | --- | ---: | --- | --- |
| PR #101 amendment `make check`, 2026-11-15 | reviewed content published as `304c5a7b78144d4a93fd9ce32756903154283ec5` | 31468 | 969 runs, 11283 assertions, 1 failure, 0 errors/skips | full suite **24913.634031s**; test stage 24913.972s |
| Same run's named failure | `CodexRunTelemetryTest#test_hanging_version_probe_times_out_without_blocking_the_workload`, line 359 | 31468 | `367.472173999995 < 10` failed | reporter including setup/teardown: 367.617s |
| Original focused rerun, 2026-11-15 | same original assertion | 31468 | 1 run, 9 assertions, passed | reported 7.345s |
| Additional supplied local `make check` log | revision/date not embedded in log; 969-case suite | 12085 | 969 runs, 11287 assertions, 1 failure, 0 errors/skips | 1209.044256s; test stage 1209.284s |
| PR #101 Ubuntu Actions run [43776496123](https://github.com/tim-millar/agentic-developer-setup/actions/runs/43776496123) | `304c5a7b78144d4a93fd9ce32756903154283ec5` | 19648 | 969 runs, 11289 assertions, 0 failures/errors/skips | Ruby suite 816.233558s; job 23:45:14–23:59:20Z |

The additional local log is `.tmp/issue-102-failed-make-check.txt`. Its exact
failure is **AssessmentReferenceFixtureTest#test_committed_fixture_is_generated_from_the_assessor_with_only_identity_normalisation**, at
`test/assessment/reference_fixture_test.rb:14`. Its only data difference is
`scope.excluded_paths`: committed `[]`, observed `[".venv"]`. It is not the
version-probe failure. There are no test-level timing diagnostics in that log;
its 20-minute aggregate duration cannot identify any slow test or prove a timeout.

SHA-256 evidence identities (raw logs remain local):

```text
supplied seed-12085 log: 18b84ac26b1d2755fba67226f332c7ace65624e7fa4357206199bdc77be4942e
recovered seed-31468 log: d266edda2ff93052a0a3d040c9fd38ac8051d938ed21950291d18d6b196a674f
```

The original PR [validation comment](https://github.com/tim-millar/agentic-developer-setup/pull/101#issuecomment-6903396365)
was posted at 2026-11-15T23:46:12Z. The original validation ledger and complete
`06-make-check.log` were recovered from its saved temporary evidence directory.
The log was created at 16:47:22.686Z and last written at 23:42:37.707Z. The ledger
records `make check` exit 2 after 24915.022s and preservation/restoration of the
pre-existing reference environment. A preceding `make test` passed 969 runs /
11289 assertions in 2641.381944s, also with very delayed watchdog observations.
Neither passing execution is used as evidence of a fix.

Earlier unspecified #101 timeout reports lack the exact failure/process evidence
needed here. They remain unclassified; this report does not silently assign
them the cause diagnosed for the recovered run.

## 2. Baseline and PR #101 comparison

Investigation began on clean `main`, `16e8066bcc3a6ee1b2b58c3d75d051dc642bb17b`
(the merged #101). There were no pre-existing tracked or untracked changes in
`git status`. Ignored local diagnostic files and a reference-service `.venv`
were preserved. Work uses `issue-102-launcher-timing-evidence`.

The following comparison exited 0 with no differences:

```sh
git diff --exit-code a08ffa16cb3b341ed83dbe69004032c916cfa893 304c5a7b78144d4a93fd9ce32756903154283ec5 -- baseline/scripts scripts test/support test/run_telemetry_test.rb test/launcher_test.rb Makefile Gemfile Gemfile.lock .ruby-version .github/workflows
```

#101 adds Node adapter/assessment/adoption tests and bounded metadata parsing.
It changes `framework.yml` only to mark the Node ecosystem adapter supported.
It does not change test discovery, the common harness, runtime commands,
dependencies, or the probe's timeout/ownership. Added cases necessarily change
whole-suite ordering and workload; their ordinary cost is not proof of a
causal timing interaction. Inspection found no added global environment,
process/signal, working-directory, or Minitest-order mutation in those tests.
A clean detached worktree at base `a08ffa16cb3b341ed83dbe69004032c916cfa893`
was tested with the identical locked bundle, rather than inferring independence
from the unchanged test file alone.

## 3. Reproduction and process observations

The optional probe starts a bounded `dd` FIFO consumer, then an `env -i` producer
with stdin `/dev/null`. Bash owns both PIDs. Both polling loops share the same
five-second `SECONDS` deadline. Failure cleanup sends TERM and KILL and waits
for both children before deleting the private probe directory. Workload launch
follows probe failure. `dd` captures 129 bytes, so oversized output cannot be
accepted as a valid truncated prefix. The ten-second test interval measures the
whole synthetic launcher invocation, including setup/cleanup and optional
usage-collector setup; it is not an isolated measurement of the polling loop.

The retained reproduction is:

```sh
bundle exec ruby test/support/launcher_pause_reproduction.rb
```

It starts the real original test in a separate process group and waits for its
synthetic version-probe PID marker. The controller then STOPs that group,
observes only its own hierarchy, pauses for 11 seconds, CONTs it and bounds
completion. This is controlled denial of scheduling, not a load experiment or
real host-sleep operation. Observed state while stopped:

```text
Ruby test parent: stopped
Bash launcher: stopped
FIFO dd capture: stopped
Ruby no-output producer: stopped
launcher polling sleep: stopped
```

On the instrumented reproduction, the controller paused 11.007s. The original
assertion failed at 12.5016909996s; the entire case took 12.767997s (one run,
three assertions, one expected failure). The driver exited 0 only after
verifying zero surviving observed children, the probe gone, and zero temporary
probe paths **before** harness teardown. The reporter captured an 11.4s
watchdog observation gap. The initial pre-diagnostic reproduction independently
failed the same assertion at 12.836388s after an 11.005s pause and reaped the probe.

The identical controlled pause was also run on the detached **pre-#101 base**
using a temporary copy of the same driver (removed afterwards). It reproduced
the original assertion failure at **12.621528s** after an 11.003s pause: one run,
three assertions, one expected failure, zero errors/skips; case duration
12.776822s. The driver exited 0, all observed children were gone, and probe
resources were already removed. Thus the failure mechanism does not require
#101's code, new tests, ordering, or workload. The base reporter lacks the new
watchdog-gap field, as expected.

This shows that the unchanged assertion detects external interruption as well
as slow launcher code, while the actual probe timeout/cleanup succeeds after
execution resumes. It does not simulate every macOS suspend semantic or prove
that no distinct production lifecycle defect can exist.

## 4. Host evidence and root-cause classification

The recovered run's first hanging-probe watchdog notice was at **367.0s**,
although the watchdog sleeps for one second and normally reports at 30s. Other
notices first appeared at 899.2s, 907.1s and 1072.9s in unrelated families. A
producer/FIFO-only hang does not explain why the independent Ruby watchdog also
failed to observe at its ordinary boundary.

Narrowly filtered `pmset -g log` evidence for 2026-11-15 UTC records:

- clamshell sleep at 16:20:36;
- maintenance sleep at **16:51:24**, then dark wake at **16:57:28**;
- repeated subsequent sleep/dark-wake cycles, with full wake at 23:30:38.

Using Minitest 6.0.6's seeded family order and the original family totals, the
telemetry family is approximately bracketed by **16:51:00–16:58:38**. The
367.617s case inside that 457.950s family necessarily overlaps the recorded
364-second sleep interval. This is a reconstruction from logged stage/family
timings, not a claim that the old log has per-case UTC timestamps. The full run
was substantially interrupted, including unrelated migration and adapter cases.

Classification for the captured long elapsed-time symptom: **environmental
interruption, independent of PR #101**, supported by actual power transitions,
absent watchdog observations, and controlled process-pause reproduction. The
specific CPU scheduling state of each historical producer/capture PID was not
saved. It is therefore not established that suspension accounts for every
fraction of the elapsed interval, or that every earlier timing error shares
this cause. No production version-probe defect was demonstrated. Do not use
this report as an automatic waiver for a future unexplained failure.

## 5. Historical #50/#59 and platform relationship

[#50](https://github.com/tim-millar/agentic-developer-setup/issues/50) identified a
production renewal-worker race: shutdown could precede cadence-child PID
assignment or leave an active renewal group alive. [#59](https://github.com/tim-millar/agentic-developer-setup/issues/59)
and merged commit `b6f70d614ad20f10d7e31a5e17afc76c3f2b8476` implement monotonic
shutdown and termination/reaping of the owned renewal boundary. Those guards and
controlled regression gates remain present.

The hanging-version test uses GitHub-disabled mode, before any renewal worker
exists. Its synthetic producer has no credential-renewal lifecycle. The
recovered sleeping-host evidence does not implicate the historical race.
The launcher suite still exercises those regressions; no constants or signal
assertions are changed.

Local investigation is macOS 15.6 (24G84), Darwin arm64, Ruby 3.3.12
(`0581089df9`), Bundler 2.5.22, Minitest 6.0.6 and bundled JSON 2.21.2. The
PATH-selected Bash is 5.3.9; system `/bin/bash` is 3.2.57. Git is Apple 2.50.1,
and Make is GNU 3.81. Tests use only synthetic fixtures, no network/real
credentials, and the locked bundle. The existing Ubuntu workflow is the Linux
validation surface; a successful Linux run alone cannot establish a macOS
cause or portability of the host power-log interpretation.

## 6. Separate deterministic reference-fixture defect

On the clean base worktree, this exact command passed one run / three assertions
in 0.474480s:

```sh
bundle exec ruby -Ilib -Itest test/assessment/reference_fixture_test.rb --seed 12085
```

Creating only an empty synthetic `examples/reference-service/.venv` made the same
command fail one run / one assertion in 0.473230s with the supplied log's exact
excluded-path mismatch. The synthetic directory was then removed. The original
checkout's developer-owned `.venv` was never moved or modified.

Inventory intentionally reports present excluded directories; the snapshot test
reads a live fixture while normalizing only identity. Classification: **a
pre-existing, independent test-input isolation defect**. It explains the exact
additional failure, not the 20-minute duration. Remediation and deterministic
acceptance criteria are separately specified in [#103](https://github.com/tim-millar/agentic-developer-setup/issues/103).
This PR does not change assessment semantics or weaken fixture equality.

## 7. Chosen remediation and regression evidence

The justified correction is to the diagnostic gap and local validation guidance,
not to the production timeout or security boundary:

- `test/support/check_timing.rb` records watchdog observation intervals and UTC
  timestamps. It retains gaps even if a case finishes before the watchdog
  resumes. Output remains bounded; a gap is not labelled an environmental cause.
- `test/check_timing_test.rb` uses deterministic clocks to distinguish ordinary
  long work from absent observations and completion before watchdog resumption.
  The first two new tests failed against the old reporter (two runs/four
  assertions, two failures); the completed focused suite passes eight runs /
  63 assertions. Existing tests still verify unchanged success/failure statuses,
  signal propagation, bounded output and the timing opt-out.
- `test/support/launcher_pause_reproduction.rb` preserves the actual lifecycle
  reproduction without adding an intentional timing failure to standard tests.
- `docs/launcher-testing.md` specifies awake-host validation, the limits of
  `caffeinate -i`, and interpretation of gaps. No failure is retried or waived.

The original five-second probe timeout, ten-second completion assertion,
streaming/output limits, signal coverage, real stdin/workload behavior and exit
statuses are retained. There is no evidence-backed reason to alter either the
canonical baseline launcher or its root operational wrapper.

## 8. Validation and remaining limits

Validation observations (full commands were wrapped with `/usr/bin/caffeinate -i`
on macOS; no test environment or assertion was changed):

| Command/scope | Outcome |
| --- | --- |
| Exact original hanging-probe CLI command, seed 31468, final source | pass: 1 run, 9 assertions, 5.885243s |
| Same original command, clean pre-#101 base and identical bundle | pass: 1 run, 9 assertions, 6.161910s |
| `bundle exec ruby -Ilib -Itest test/run_telemetry_test.rb --seed 31468` | pass: 53 runs, 636 assertions, 114.468160s |
| `bundle exec ruby -Ilib -Itest test/check_timing_test.rb --seed 31468` | pass: 8 runs, 63 assertions, 0.908790s |
| `make test-launcher SEED=18974` | pass: 98 runs, 1437 assertions, 260.855175s |
| Hanging-probe case, seed 31468, explicit `/bin/bash` 3.2 interpreter | pass: 1 run, 9 assertions, 5.771234s |
| `make test ADS_TEST_TIMING=1 SEED=31468` in original checkout | exit 2: 972 runs, 11306 assertions, one #103 fixture failure, no errors/skips; 1262.027336s; maximum watchdog gap 1.0s |
| `make lint` | pass |
| `make validate` | pass |
| Controlled pause driver | pass by observing the expected original-assertion failure and complete cleanup |

The exact original focused command was:

```sh
bundle exec ruby -Ilib -Itest test/run_telemetry_test.rb --name '/CodexRunTelemetryTest#test_hanging_version_probe_times_out_without_blocking_the_workload/' --seed 31468
```

The final PR validation section records launcher-family, full-suite, final
published-head Actions results, seeds, counts, durations and exact commands.
A clean worktree can validate without the independently diagnosed `.venv`
fixture contamination; the original checkout's failure remains evidence, not a
hidden exception. No original failing run is replaced by a passing rerun.

Remaining limits: the old run lacks per-case UTC timestamps and child snapshots;
reconstructed intervals cannot attribute each millisecond. Earlier unnamed
reports remain unresolved. Direct host-suspend reproduction and a second live
Linux host were not used. Neither a scheduling-gap diagnostic nor a passing
suite proves elimination of all possible timing/lifecycle failures. #103 is the
separate actionable fixture correction. Any future failure without concrete
causal evidence remains unexplained and must be investigated.

## 9. Security and ownership review

Only root test infrastructure, a manual offline diagnostic and root documentation
change. `framework.yml`, `baseline/`, App permissions, launcher credential
sources/helper freshness, monotonic shutdown, process authority, CLI semantics,
usage/outcome schemas and dependencies remain unchanged. Probe output and
credentials are not logged. No real GitHub operation is performed by tests.
Only the manual controller's own synthetic process group is signalled. The
new watchdog timestamps/gaps are observations, not an acceptance policy.
