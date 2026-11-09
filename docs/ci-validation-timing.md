# Root validation timing (issue #87)

This report concerns this framework repository's required validation. It does
not change reusable baseline commands, launcher behavior, or adopter policy.
PR #85 was already merged before this work began.

## Revisions and historical evidence

Investigation began at clean `main` commit
`44bde0de1756b240c0a8faf753634ae887271376` (merged PR #85). Its workflow blob
was `39a3468a2e6f671fff2594690f722d171de201fc`.
The diagnostic-only commit was
`10f8d5684669adcf8e1e0db418c4e645b3e9f987`, workflow blob
`1d275323957cc546d36980eb44e957113dd6dd51`.

All runs below used `ubuntu-24.04`, image `20261101.360.1`, and Ruby 3.3.12.
The workflow sets up Python 3.14 and uv 0.12.7 after the root checks.

| Actions run | Head revision | Outcome | Seed | Ruby tests/assertions | Ruby duration |
| --- | --- | --- | ---: | --- | ---: |
| [42483459409](https://github.com/tim-millar/agentic-developer-setup/actions/runs/42483459409) | `29518b8c5f2e8a842a350623fa411e89a7fb58ad` | pass | 65024 | 844 / 9443 | 707.451s |
| [42493282005](https://github.com/tim-millar/agentic-developer-setup/actions/runs/42493282005) | `7196344435755a2a0c4047e9d5628d53dbc5c4ed` | pass | 64904 | 854 / 9563 | 889.187s |
| [42502779562](https://github.com/tim-millar/agentic-developer-setup/actions/runs/42502779562) | `44bde0de1756b240c0a8faf753634ae887271376` | pass | 44383 | 854 / 9563 | 772.249s |
| [42538743439](https://github.com/tim-millar/agentic-developer-setup/actions/runs/42538743439) | `10f8d5684669adcf8e1e0db418c4e645b3e9f987` | pass | 41188 | 857 / 9588 | 799.875s |
| [42386800352](https://github.com/tim-millar/agentic-developer-setup/actions/runs/42386800352) | `911dd5cecea7b3e147ca87dfb3f1432251f738f2` | cancelled | 50611 | no completion count | entered Ruby at 15:32:00Z; run ended 15:46:54Z |

The cancelled run has no test-level evidence; it cannot establish a stalled
case or a lifecycle cause. The successful runs' differing test counts and
seeds prevent treating their entire duration difference as a code effect.

For current main, runner scheduling/startup took about 2 seconds from run
creation to job start. The job lasted 799 seconds: checkout 1 second, Ruby
setup 4 seconds, framework checks 782 seconds, Python setup below one second,
uv setup 2 seconds, reference verification/setup 5 seconds, and final cleanup.
The root Ruby suite accounts for 772 seconds of that job. Queue/setup and the
reference service do not explain the 12–15 minute execution time.

## Instrumented baseline

Run `42538743439` lasted 828 seconds, with about 2 seconds between run creation
and job start. Timed stages: lint 9.488s; test command 800.282s (Minitest
799.875s); framework validation 0.403s; locked reference setup 0.541s; offline
reference verification 5.310s. All passed, including the 20 Python tests.

| Main Ruby family | Cases | Elapsed including setup/teardown |
| --- | ---: | ---: |
| LauncherTest | 98 | 214.107s |
| ClaudeExploreMigrationTest | 28 | 174.783s |
| ClaudeExploreRuntimeTest | 41 | 137.836s |
| ManageAdoptionTest | 85 | 103.652s |
| CodexRunTelemetryTest | 26 | 83.683s |
| ClaudeExploreRunTelemetryTest | 11 | 28.620s |
| FrameworkValidationTest | 101 | 19.903s |
| AgentRunOutcomesTest | 33 | 15.217s |
| RunUsageTest | 19 | 9.042s |

The slowest cases were migration's ambiguous-layout matrix (41.356s),
runtime's blocked-executable matrix (36.595s), migration rollback matrix
(18.521s), transaction-slot collision matrix (18.106s), and the startup
argument matrix (17.677s). These are many subprocess invocations over finite input matrices,
not individual waits lasting their complete test duration.

Issue #50's report identified a renewal-worker shutdown race and handed its
fix to #59, which is already present in this baseline. Neither the instrumented
successful CI run nor the local baseline reproduced that shutdown hang.
The 30-second notices named policy/migration matrix cases that subsequently
completed successfully. This establishes substantial ordinary serial work;
it does not prove that all historical nontermination has disappeared.

## Measured remediation

Two test-only costs were reproduced locally on macOS arm64, Ruby 3.3.12:

- A fresh Claude fixture installation took 2.008s, before a runtime-info call
  taking 0.640s. Runtime and migration prerequisites repeatedly performed that
  same fresh installation, although their assertions exercise later runtime,
  upgrade, rollback, or ownership behavior.
- Forty dependency-free fake Git calls took 1.660s with ordinary Ruby startup
  and 0.687s with unused RubyGems initialization disabled. An earlier comparison
  of 20 calls took 1.020s through the fake versus 0.207s directly through Git.
  These microbenchmarks isolate startup costs; they are not whole-CI forecasts.

The test harness now builds an independent installed prerequisite directly
from current runtime source. A regression compares every installed path,
file-content SHA-256, permission mode, metadata byte digest, and literal link
target with a real fresh installation. It then mutates/removes one fixture
and verifies a second fixture is unchanged and works through the real runtime.
There is no shared mutable template or cache. Fresh install, idempotence,
source syntax/permissions, transactional activation, migration, rollback,
uninstall, and security assertions continue to invoke the real installer
where that operation is under test. Prerequisite-success guards instead check
that the fixture's launcher link exists. No test case or behavior assertion
is removed.

Only the dependency-free Git/chmod/mv/date/sleep and controlled wait/gate
fakes disable RubyGems startup. Their code and delegated commands are otherwise
unchanged. Fakes requiring libraries retain ordinary initialization.
Production runtimes, credentials, permissions, timing constants, dependencies,
and all baseline artifacts are unchanged. No concurrency or retries are added.

## Reproduction and limitations

Use `make check ADS_TEST_TIMING=1 SEED=41188` for the full root command, or
`make test ADS_TEST_TIMING=1 SEED=44383` for a second recorded seed. CI keeps
running `make check` and independent `make check-reference-service` for PRs
and main pushes. Logs include stage exit statuses, family counts/durations,
the slowest 20 cases, and at most one still-running notice per case after
30 seconds. The reporter does not change seeds, discovery, assertion results,
or test exit statuses. Its diagnostics contain static test identifiers and
elapsed time, not subprocess arguments or environment contents.

The local checkout initially contained an untracked reference-service `.venv`.
The reference-assessment snapshot consequently reported `.venv` as an excluded
path, while its committed clean-tree snapshot has no such directory. This is
an environmental discrepancy, not a fixture-performance regression. CI runs
Ruby before Python setup and the instrumented baseline passed that assertion.
Local clean comparisons must keep the environment outside the assessed tree,
preserving the developer's existing environment for restoration. Local results
are supporting evidence; hosted-runner before/after measurements are the main
comparison. Focused diagnostic and verification commands ran during the first local
baseline, so it is not a strict isolated hardware benchmark.

The 30-minute timeout remains an outer failure bound. Historical normal runs
already vary by several minutes; one or two faster runs are insufficient
reason to shorten that bound while claiming tail behavior is established.
Neither a timeout change nor the absence of a timeout is the performance fix.

The PR validation handoff records final revision, exact commands, test counts,
seeds, durations, run links, and remaining variance for two final-code CI runs.
Those measurements should be assessed against the under-eight-minute initial
goal and aspirational five-minute target without treating either as permission
to skip validation. Further optimization of production lifecycle or adoption
transactions requires its own reproduced evidence and bounded scope.
