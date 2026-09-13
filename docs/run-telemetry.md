# Agent run telemetry

Supported framework launchers automatically preserve a local, runtime-neutral record of each accepted agent workload invocation. One telemetry run is one launcher invocation: a fresh launch and every resume launch receive distinct framework-generated `run_id` values even when they refer to the same underlying runtime session. Help, runtime-information, command-classification, and malformed launcher invocations are not workloads and do not create records.

The supported v1 boundaries are the adopted `scripts/run_codex.sh` launcher and the globally installed `claude-explore` runtime. The repository-root Codex wrapper only supplies repository defaults before delegating to the baseline launcher, so it is not a separate harness. Direct invocation of arbitrary `codex` or `claude` clients is outside the telemetry guarantee.

> Telemetry records what the framework can reliably observe about an execution. It does not prove that the implementation is correct, complete, publishable, or ready to merge.

## Storage and control

Telemetry is enabled by default. Set `AGENT_TELEMETRY=0` to disable it without changing workload behaviour or producing an opt-out warning.

The default run root is:

```text
${XDG_DATA_HOME:-$HOME/.local/share}/agent-development-framework/telemetry/runs/
```

`AGENT_TELEMETRY_DIR` may specify an absolute run root directly, which is useful for deterministic tests and controlled environments. Relative overrides are rejected fail-open, as is an effective run root at or beneath the current repository. An empty `XDG_DATA_HOME` is treated as unset and uses the `HOME` fallback; an explicitly relative non-empty value is rejected instead of being resolved beneath the current repository.

Each run owns an independent directory:

```text
runs/
  <run-id>/
    run.json
    task.txt        # only when pre-run task-specific text is available
```

Framework-created directories use mode `0700` and files use mode `0600`. Updates stage a sibling temporary file and atomically replace `run.json`; independently generated run directories avoid a shared append lock or mutable global index. A terminal v1 `run.json` is immutable. Later enrichment associates sidecar evidence by `run_id` rather than rewriting the base record.

Records remain until the user removes them. The framework performs no automatic pruning, upload, synchronisation, or central ingestion.

## Common schema

`run.json` is UTF-8 JSON with `schema_version: 1`. The repository-owned contract is [`schemas/agent-run-telemetry-v1.schema.json`](../schemas/agent-run-telemetry-v1.schema.json), and a record can be checked with:

```sh
ruby scripts/validate_run_telemetry.rb /absolute/path/to/run.json
```

The common record separates these concepts:

| Evidence | Meaning |
| --- | --- |
| `runtime.client` | The selected vendor coding-agent client (`codex-cli` or `claude-code`) and its observed version when available. |
| `runtime.harness` | The framework execution surface, its `framework.yml` runtime version, and a SHA-256 revision of the launcher artefact that owns the invocation. |
| `runtime.session` | A resume/session identifier only when the launcher directly possesses one. It is not the framework `run_id`. |
| `configuration.*.requested` | An explicit model or reasoning-effort value observed in launcher-owned arguments or configuration. |
| `configuration.*.initial_effective` | The initial value only when a supported runtime observation or guaranteed invocation contract establishes it authoritatively. |
| `repository` | A normalized `owner/repository` identity when suitable, otherwise a SHA-256 digest of the canonical repository root, plus minimal start/finish Git state. |
| `task` | Identity, exact snapshot digest, and `task.txt` reference when the harness already possesses task-specific text before launch. |
| `timing` | UTC launcher-envelope timestamps and calendar elapsed milliseconds. |
| `termination` | The child exit code, handled signal, and a stable terminal reason where available. |

Observation objects use `launcher_requested`, `runtime_observed`, `launcher_guaranteed`, `unavailable`, or `not_applicable` evidence kinds. Unavailable and not-applicable observations have JSON `null` values; strings such as `unknown` or `n/a` are not missing-value sentinels.

Requested configuration is not proof of effective configuration. The v1 effective fields mean *initial effective* only, and `configuration_stability` records `unchanged`, `changed`, or `unknown`. Both current interactive runtimes use `unknown` because they do not expose complete configuration-change observation to these launchers.

> An unavailable model or reasoning-effort observation is preferable to an inferred value that the runtime did not authoritatively expose.

The framework does not infer configuration from vendor defaults, subscription tier, remembered behaviour, aliases, profiles, or private runtime state.

## Git, task, and timing semantics

Git observations contain the attached branch or detached state, full HEAD SHA, dirty flag, and staged, unstaged, and untracked porcelain-entry counts. Status parsing is NUL-safe. The common record deliberately excludes file names, diffs, patches, line counts, quality judgements, and acceptance conclusions. Git state is `null` when the repository cannot be inspected reliably.

Codex snapshots fetched issue context and explicit extra task instructions already supplied to the workload. A composite preserves their semantic order and boundaries. The generic base session prompt is excluded. Claude Explore snapshots an explicit positional initial prompt as a local task; an interactive launch without one remains unavailable. It does not include generic runtime guidance or scrape transcripts, shell history, or private session files. A stored snapshot is historical: later edits to its issue or source prompt do not alter it.

`calendar_elapsed_ms` spans `run_started_at` through `run_finished_at`. It intentionally includes interactive pauses, idle time, developer wait time, and machine sleep within the launcher invocation. It is not provider-active time, API compute time, token-generation time, or productivity time.

## Lifecycle and failure behaviour

The lifecycle states are:

| State | Execution meaning |
| --- | --- |
| `started` | The workload was accepted and the initial record persisted, but no terminal finalisation is present. |
| `completed` | The child returned success at the execution layer only. |
| `preflight_failed` | Valid workload parsing completed, but repository/runtime/framework preflight rejected the launch. |
| `launch_failed` | The harness reached launch intent but could not start the selected runtime. |
| `runtime_failed` | A started runtime returned a normal non-zero failure. |
| `launcher_failed` | The launcher failed outside the ordinary preflight or child-result cases. |
| `interrupted` | The harness handled a supported interruption or termination signal. |

An ungraceful process death, `SIGKILL`, host crash, or power loss may leave a valid stale `started` record. It must not be interpreted as success, and v1 has no background reconciler.

Telemetry is observational and fail-open. Unexpected failures emit a concise `AGENT_TELEMETRY_WARNING:` diagnostic without task content or credentials, then preserve the meaningful workload exit status. Failure to create, observe, or finalise telemetry never turns an otherwise successful workload into a failed one and never replaces a runtime failure.

## Privacy and runtime limitations

The common record deliberately avoids complete child argv, environment dumps, credentials, authentication headers, shell history, hidden reasoning, runtime authentication state, provider usage, and unrelated local files. Task text is the one deliberate potentially private snapshot; it is local-only, permission-restricted, covered by the global opt-out, and never uploaded automatically. These controls do not claim comprehensive secret detection or make telemetry a security, billing, or audit authority.

Codex records explicit supported model/config arguments as requested configuration; a selected profile does not manufacture an effective value. The selected Codex executable is queried for its version, but no private session files or undocumented state are parsed. Codex remains in its existing interactive mode.

Claude Explore records supported explicit model, effort, and resume/session arguments. Its existing client validation supplies the selected Claude version. The runtime does not enable hooks, broaden permissions, weaken its sandbox, change settings ownership, or scrape Claude state to improve observability. If client version validation itself fails, the valid workload is represented as a preflight failure with unavailable version evidence.

## Downstream contracts

This record is the machine-readable counterpart to the human-readable PR provenance introduced by #52, but telemetry does not select a primary implementation run or mutate pull requests. Future provider usage and cost evidence from #56 and PR/outcome evidence from #57 join to the immutable record by `run_id`; they do not add those fields to schema v1. Controlled evaluations from #6 retain their separate `evaluation_run_id` and may reference one or more ordinary run IDs.

Issue #53 owns the canonical common execution `run_id`. Future non-interactive execution artefacts from #16 must reuse or reference that identity instead of creating a competing execution-run identifier. This implementation does not add provider accounting, outcome correlation, controlled evaluation, model routing, or non-interactive execution.
