# Agent run usage evidence

Supported framework launchers automatically attempt to preserve provider-native model-request usage evidence beside ordinary execution telemetry. The three evidence layers answer different questions and remain separate:

```text
runs/<run-id>/
  run.json       # immutable launcher execution evidence
  task.txt       # optional pre-run task evidence
  usage.json     # immutable terminal model-usage and runtime-cost evidence
  outcome.json   # evolving implementation-outcome evidence, when available
```

`run_id` is the canonical join key. `usage.json` does not modify `run.json`, determine whether an implementation succeeded, or replace `outcome.json`. A controlled evaluation can later join all three without treating usage, engineering outcome, or quality as interchangeable.

## Accounting boundary

One launcher invocation is one usage run. A fresh invocation and a resumed invocation receive different framework run IDs even if the provider session or conversation ID is the same. Collection includes only qualifying events emitted while that invocation's coding child is running; it never scans private provider transcripts, imports cumulative session totals, or subtracts a previous run.

A run can contain multiple provider session IDs, including a Claude session change after `/clear`, and multiple exact model IDs. `provider_sessions` is the sorted, deduplicated set derived from accepted measurements. Provider session identity remains supporting evidence; it never replaces the framework run ID.

The measurement unit is a runtime-emitted successful model-response usage record. Runtime work such as compaction, fallback, subagent requests, prewarm work, and retries that reach a successful completed response remains visible when the selected provider interface emits a qualifying event. The framework does not guess which request was user-facing, billable, or attributable to a particular engineering role. A failed or interrupted coding child can therefore retain valid measurements completed before failure.

## Collection transport and lifecycle

For a telemetry-bearing workload, the trusted host launcher starts an invocation-local OTLP HTTP/JSON collector before the coding child. The collector:

- binds an ephemeral port on `127.0.0.1` only;
- exposes only `/v1/logs`;
- generates a random per-run nonce and requires it in `x-agent-run-usage-token`;
- runs the pinned Ruby process with an empty environment because all required paths and operational inputs are explicit arguments;
- parses request bodies in memory and never archives raw OTLP payloads;
- immediately ignores events and attributes outside the provider whitelist;
- writes only normalized evidence and a permission-restricted normalized recovery checkpoint beneath the run directory;
- never forwards data or remains as an intentional daemon after the run.

The provider performs its normal exporter shutdown when the coding child exits. The launcher then stops the collector with bounded waiting, finalizes `run.json`, atomically links the terminal candidate as mode-`0600` `usage.json`, and proceeds independently to outcome reconciliation. If execution telemetry can no longer mutate an already-retained run, usage publication still proceeds against that validated run identity. When fallback evidence cannot observe a new terminal timestamp, it uses the run's already-validated start timestamp solely to remain schema-valid; that value does not claim the actual finalization instant. Existing terminal `usage.json` files are never silently replaced.

This is local same-user process isolation, not hostile same-user containment. Loopback binding, a nonce, restrictive paths, trusted executable selection, and the Claude sandbox reduce accidental or repository-controlled interference. They do not stop a deliberately hostile process running as the same operating-system user.

## Exporter ownership and opt-out

Usage capture owns the provider's logs/events exporter for the managed invocation so routing is deterministic. It does not introduce exporter fan-out or forward a user's existing exporter credentials. Provider metrics and trace exporters remain untouched where the runtime exposes separate controls.

| Controls | Result |
| --- | --- |
| `AGENT_TELEMETRY=0` | No execution run is allocated, so there is no usage sidecar. |
| Execution telemetry enabled and `AGENT_USAGE_TELEMETRY=0` | Provider OTel routing is left untouched and `usage.json` records `collection.state: "disabled"`. |
| Both enabled or unset | Local collection is attempted and always fails open. |

While local Codex collection is active, forwarded `otel` and `otel.*` configuration is rejected rather than allowed to override launcher-owned routing. If collection is disabled or cannot become active, that restriction does not apply and forwarded provider routing remains untouched. Users who need their own provider log exporter for a framework-managed invocation should set `AGENT_USAGE_TELEMETRY=0`. Arbitrary direct `codex` or `claude` invocation is outside this contract.

## Provider interfaces

### Claude Code Explore

Claude uses the supported OTel logs/events interface with per-signal HTTP/JSON endpoint and headers. The launcher keeps unrelated metrics and traces routing intact and explicitly keeps content-bearing telemetry off:

```text
OTEL_LOG_USER_PROMPTS=0
OTEL_LOG_ASSISTANT_RESPONSES=0
OTEL_LOG_TOOL_DETAILS=0
OTEL_LOG_TOOL_CONTENT=0
OTEL_LOG_RAW_API_BODIES unset
```

Only `claude_code.api_request` is accepted. The persisted whitelist is `session.id`, `event.sequence`, `model`, `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `cost_usd_micros`, `duration_ms`, `speed`, `query_source`, and `effort`. Framework-local `sequence`, not provider process sequence, orders accepted measurements.

Normalization is:

```text
input_uncached    = input_tokens
input_cache_read  = cache_read_tokens
input_cache_write = cache_creation_tokens
input_total       = input_tokens + cache_read_tokens + cache_creation_tokens
output_total      = output_tokens
output_reasoning  = null
```

The selected interface does not expose a reasoning-token dimension. That `null` does not by itself make collection partial. Source token fields are retained in the closed `claude_code_api_request` native-usage variant.

When integer `cost_usd_micros` is present, the exact value is stored as `runtime_estimated`, `USD` evidence. It is Claude Code's estimate, not an invoice, actual billed cost, or subscription charge. The framework does not recalculate it from the floating-point `cost_usd` field.

### Codex

Codex remains interactive; the launcher does not switch to `codex exec --json`, scrape the TUI, or inspect rollout/session files. It injects invocation-local `[otel]` equivalents for a JSON OTLP logs exporter, the nonce header, and `otel.log_user_prompt=false`. Current official Codex configuration exposes no supported tool-result-byte limit, so no undocumented configuration key is injected; the collector nevertheless persists only the accepted completed-response event and its usage whitelist.

Only `codex.sse_event` with `event.kind: "response.completed"` and token evidence is accepted. The whitelist is `conversation.id`, `model`, `input_token_count`, `output_token_count`, `cached_token_count`, `cache_write_token_count`, `reasoning_token_count`, `service_tier`, and `model_reasoning_effort`.

Normalization is:

```text
input_total       = input_token_count
input_cache_read  = cached_token_count
input_cache_write = cache_write_token_count
input_uncached    = input_token_count - cached_token_count
output_total      = output_token_count
output_reasoning  = reasoning_token_count
```

Cache-write input remains a separately preserved dimension and is not subtracted from total input when deriving uncached input. Reasoning tokens are detail within output and are never added to `output_total`. If cached input exceeds total input, native counts remain unchanged, `input_uncached` becomes `null`, and collection records a normalization warning rather than clamping or inventing a value. Missing cached-input evidence likewise leaves `input_uncached` as `null`.

The selected Codex OTel source does not report a runtime-estimated dollar amount equivalent to Claude's integer micros. Usage-bearing Codex runs therefore use `cost_summary.state: "unavailable"` and `reason: "source_does_not_report_cost"`. The framework does not infer API-list-price or subscription cost.

## Schema, missing values, and aggregation

The closed v1 contract is [`schemas/agent-run-usage-v1.schema.json`](../schemas/agent-run-usage-v1.schema.json). Validate a sidecar with:

```sh
ruby scripts/validate_run_usage.rb /absolute/path/to/usage.json
```

The validator applies the JSON Schema and cross-field semantics: provider/native variants, non-negative integers, normalized token relationships, sequential ordering, provider-session derivation, aggregate reproduction, cost counts, and legal state combinations. Invalid evidence is rejected rather than repaired.

For scalar evidence, `0` is an observed zero and `null` means the source did not establish the value. Missing evidence is never converted to zero. `observed_totals` is reproduced from stored measurements: a dimension is summed only when every accepted measurement establishes it; otherwise its aggregate is `null`. With zero measurements, known countable dimensions are zero, while dimensions the selected source does not expose remain null. Unavailable or disabled collection does not pretend zero usage.

## Collection states

| State | Meaning |
| --- | --- |
| `complete` | The collector was ready before child launch, remained usable, accepted every relevant well-formed event it received, and finalized cleanly. Zero qualifying measurements is valid. |
| `partial` | Valid measurements were retained but parsing, normalization, availability, or shutdown integrity was incomplete. |
| `unavailable` | No trustworthy measurement can be asserted because setup, source, parsing, availability, or finalization failed. |
| `disabled` | Normal execution telemetry exists, but `AGENT_USAGE_TELEMETRY=0` was explicit. |

Reasons and warnings use closed codes rather than provider error prose. Setup, parsing, collector, and finalization failures never block the coding workload, replace its exit status, prevent independent `run.json` finalization, or prevent independent outcome reconciliation.

The decoded OTLP envelope and each traversed `resourceLogs`, `scopeLogs`, and `logRecords` container/member must have the expected object or array shape. Structurally valid empty containers can therefore produce complete zero-measurement evidence, while malformed structure records `collector_parse_failed`; valid measurements accepted before the malformed input remain as partial evidence.

## Cost summary states

Cost state is independent of collection state:

| State | Meaning |
| --- | --- |
| `complete` | Collection is complete and every accepted measurement has runtime-reported cost with the same semantics and currency. |
| `partial` | Some runtime cost is preserved, but not all model usage has an amount or collection itself is partial. |
| `unavailable` | Model usage exists, but the selected source supplies no usable dollar-cost evidence. |
| `not_applicable` | No qualifying model-usage measurements were observed. |

Partial sums include only priced measurements; `priced_measurement_count` and `measurement_count` expose the gap. Versioned downstream analysis may later apply a pricing catalogue to request-level usage, but v1 deliberately includes no hard-coded prices, scraper, live pricing lookup, currency conversion, historical repricing, or subscription amortization.

## Privacy and retention

The final sidecar never persists prompts, assistant or reasoning text, tool arguments or output, diffs, patches, raw request or response bodies, raw OTLP payloads, provider or GitHub credentials, account IDs, email, organization metadata, arbitrary resource attributes, or arbitrary environment variables. Adversarial fixture tests exercise those exclusions.

Records remain local until the user removes their run directories. There is no global usage index, database, daemon, webhook, hosted backend, automatic upload, or retention policy. A historical run created before this layer can legitimately have no `usage.json`; absence means only that usage evidence was not collected then, never zero usage. New telemetry-bearing runs write a terminal sidecar even when collection is disabled or unavailable.

## Controlled evaluation boundary

Later controlled evaluation can join execution facts from `run.json`, request-level usage and runtime cost evidence from `usage.json`, and evolving engineering outcomes from `outcome.json` through `run_id`. This layer does not decide which model is better, whether the agent succeeded, whether a pull request is good, whether a run was efficient, or whether a provider estimate equals money actually billed.
