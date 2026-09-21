# Agent run implementation outcomes

Supported framework runtimes can opportunistically correlate immutable execution records with objective GitHub pull-request lifecycle evidence. The execution record remains the schema-v1 `run.json` owned by run telemetry; reconciliation writes a separate mutable sidecar beside it:

```text
<telemetry-root>/<run_id>/
  run.json
  task.txt       # when captured by execution telemetry
  outcome.json  # implementation-outcome evidence
```

`outcome.json` uses schema version 1, repeats the exact canonical `run_id`, and records `source_run_schema_version: 1`. It is permission-restricted to `0600` and replaced atomically in the run directory. The reconciler never rewrites a terminal `run.json`, creates a global mutable index, uploads evidence, prunes records, or mutates a GitHub object. Outcome evidence follows the underlying run's local retention: it remains until the user removes that run directory.

> Outcome telemetry records objective implementation-lifecycle evidence that the framework can reliably observe. It does not prove implementation quality, human RTM judgement, causal responsibility, or reviewer intent.

## Repository scope and correlation

An invocation only considers telemetry records for the current GitHub repository. A selected run for another repository is rejected. A matching local `path_digest` record is represented as `not_applicable`; it is not queried against GitHub.

Correlation is deliberately conservative. In descending order, the evidence that can establish an association is:

1. the run's finish HEAD equals a PR head (`finish_head_equals_pr_head`);
2. the finish HEAD appears in GitHub's PR association/commit evidence (`finish_head_in_pr_commits`);
3. when exact commit evidence is unavailable, exactly one same-repository PR has the run's attached finish branch and is temporally compatible (`unique_head_branch`).

Structured task-to-issue linkage and temporal compatibility are corroborating or disambiguating facts only. Task linkage comes from the task issue's structured cross-reference timeline when its source is the candidate PR in the same repository; PR titles, bodies, comments, and semantic text similarity are never used. Branch-only correlation accepts a PR that overlapped the run or was created no more than 30 days after it; a PR whose relevant lifecycle ended before the run is incompatible unless observable reopening evidence makes it relevant. If the timeline needed to determine reopening is unavailable, that missing evidence remains uncertainty and cannot become a definitive negative match.

Correlation states are `matched`, `unmatched`, `ambiguous`, `unavailable`, and `not_applicable`. Confirmed associations persist after rebases or force pushes, together with their first/last observation and establishing evidence. Many runs can associate with one PR, and one run can retain multiple confirmed PR associations. There is no primary-run, primary-PR, amendment-run, ownership, credit, or blame classification.

> `unmatched` means that no unambiguous associated pull request was observed at the reconciliation time. It does not mean that the run failed or produced no useful work.

## Evidence preserved

For every confirmed PR, the sidecar keeps a current snapshot and merge-preserved historical collections:

- repository, PR number, node identity, head/base refs and SHAs, draft state, lifecycle, timestamps, and merge commit SHA;
- observed PR commit and head SHAs;
- structured lifecycle events such as ready/draft transitions, review requests, dismissal, force pushes, ref deletion/restoration, base changes, close/reopen, and merge;
- submitted GitHub reviews, including reviewer identity/type, GitHub state, reviewed commit, submission time, and observable dismissal evidence;
- GitHub check-run attempts and traditional commit statuses for each exact SHA.

Collections merge by stable GitHub identity or a deterministic composite when GitHub supplies no stable ID. A later omission cannot silently erase a previously observed association, commit, event, submitted review, check attempt, or status. Current snapshot fields may advance. The sidecar deliberately excludes PR/review/comment bodies, inline comments, check annotations and logs, patches, diffs, raw API responses, credentials, and arbitrary environment data.

Submitted reviews with a real `submitted_at` are the passive review primitive. Pending drafts are excluded. `reviewed_revision_count` is the count of distinct reliable review `commit_id` values, so several bot or human reviews of one SHA are one reviewed revision. PR comments and inline review comments do not create review rounds. Reviews missing a reliable commit remain preserved but do not receive a fabricated revision.

For each exact SHA, the reconciler completely paginates both GitHub Checks and the individual traditional-status collection before deriving `observed_check_rollup`:

- `unobserved` when checks and statuses were both queried successfully and neither has a context;
- `pending` when a current context is non-terminal and none is failing;
- `passing` when at least one context exists and all current contexts are terminal and non-failing;
- `failing` when any current context has a failing check conclusion or traditional status;
- `incomplete` when either evidence class was unavailable or the observations cannot support a complete result.

The rollup uses the latest observed attempt for each stable logical context while retaining prior attempts. It is not named `ci_pass` because the framework does not invent which checks GitHub requires for merge.

## Revision proxies

`first_reviewed_revision` is the commit attached to the earliest qualifying submitted review. `post_first_review_change_observed` is `yes`, `no`, `unavailable`, or `not_applicable` based only on objective head observations and structured head-transition or force-push evidence after that review. The identity-sorted commit collection is not treated as chronological evidence. The proxy does not claim that review caused a change.

`merged_on_first_reviewed_revision` is `yes` only when the PR merged, the first reviewed commit and final PR head are reliably known and equal, and no contrary post-review rewrite evidence exists. It is `no` when reliable evidence proves that the merged PR head differed, `not_applicable` for an unmerged or unreviewed PR, and `unavailable` when required evidence is incomplete. Squash merge is handled by comparing the final PR head—not the base-branch merge commit—to the reviewed revision.

> `merged_on_first_reviewed_revision` is a revision-history proxy only. It must not be interpreted as equivalent to first-pass RTM.

Authoritative run, PR, review, event, and merge timestamps support later interval calculation without inventing one implementation duration for a multi-run lifecycle.

## Command surface and scheduling

From the repository being reconciled:

```sh
scripts/agent_run_outcomes.sh
scripts/agent_run_outcomes.sh --automatic
scripts/agent_run_outcomes.sh --run <run_id>
scripts/agent_run_outcomes.sh --all
```

The default visits due active records. `--automatic` is the launcher hook and visits at most three due historical records, oldest due first, excluding the current invocation. `--run` revisits one eligible current-repository run regardless of schedule. `--all` revisits every eligible current-repository run, including dormant and quiescent sidecars. Unknown or combined flags exit 2.

Terminal execution states are eligible immediately. A `started` record becomes eligible after 24 hours. Open matched PRs, unmatched results, and ambiguous results become due after 24 hours. Temporarily unavailable evidence retries after at least one hour. Unresolved records become `dormant` 30 days after the run finishes; complete merged or closed-unmerged records and `not_applicable` records become `quiescent`. `active`, `quiescent`, and `dormant` control automatic work only—explicit reconciliation can refresh any eligible record. If that refresh observes a formerly terminal PR open again, scheduling is recomputed and the record becomes active.

Two reconcilers coordinate with a mode-`0700` per-run `.outcome.lock` directory. Automatic work skips a busy or disappeared run; explicit selected work reports it. Locks and recovery markers older than ten minutes are recoverable through atomic displacement. Different runs do not share a global lock.

Existing schema-v1 execution records can be backfilled with `--all`. The reconciler does not synthesize IDs or reconstruct executions from before common run telemetry.

Set `AGENT_TELEMETRY=0` to disable both execution and outcome telemetry. The reconciler uses the same `AGENT_TELEMETRY_DIR`, `XDG_DATA_HOME`, and `HOME` root selection as execution telemetry and provides no opt-out bypass.

## Runtime authority and failure behaviour

Reconciliation is trusted host-side and observational. It prefers the launcher's freshness-aware token helper, then trusted host `GH_TOKEN`/`GITHUB_TOKEN`, then host GitHub CLI authentication, and finally available unauthenticated public reads. A clear helper-token authentication failure permits the existing single forced-refresh retry; other failures do not. No competing token-minting mechanism exists.

The Codex launcher validates and snapshots its fixed optional adopted sibling before the coding child starts; ambient environment variables cannot select another reconciler. It also resolves and validates optional `gh`, Ruby, Git, and copy tooling before launch, rejects workspace-controlled selections, and uses the pinned paths afterward. Historical and post-run calls use only that snapshot and toolchain, so child edits cannot cause later execution with launcher-owned GitHub authority.

Claude Explore installs the common reconciler only from within its trusted runtime source tree and never executes a repository's reconciler outside the sandbox. Before the child starts, it searches the original host path for ownership- and mode-safe tools, skips repository-controlled candidates, and pins the accepted absolute paths. Captured host GitHub authority, including a host `GH_CONFIG_DIR` where present, is available only to trusted reconciliation. The Claude child receives neither that host config nor the captured token/token-helper path; it receives the runtime's empty private session GitHub config directory instead.

GitHub CLI and Ruby are optional reconciliation prerequisites, not mandatory coding-runtime preflight dependencies. Missing tools, API/authentication/permission/rate-limit/network/timeout/parse failures, and local write failures remain fail-open for the coding workload. Automatic calls emit at most one concise `AGENT_OUTCOME_WARNING:` and never include response bodies or credential values. Useful prior or partial evidence remains intact where it can be written safely.

The checked-in semantic validator is kept in schema-v1 parity for required fields, nullability, bounds, collection uniqueness, and malformed member handling; invalid adversarial JSON is reported rather than raising. Normal repository tests use synthetic run records and deterministic fake GitHub commands. They do not contact GitHub or invoke a live coding model.

## Related evidence layers and limitations

Human-readable PR provenance from #52 is not parsed for machine correlation. Provider usage/cost from #56 remains a separate sidecar joinable through `run_id`. Controlled evaluation and human adjudication remain owned by #6. Future non-interactive execution from #16 must reuse the same #53 execution identity and can be correlated without special outcome semantics.

GitHub evidence is eventually consistent and limited by API retention, permissions, pagination, object availability, and the observations made while evidence existed. A quiescent record is not a claim that GitHub can never change. Missing historical events or review commit identities produce explicit `unavailable` or incomplete derived evidence rather than a guess.
