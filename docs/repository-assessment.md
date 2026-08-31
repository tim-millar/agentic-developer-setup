# Repository assessment

The read-only assessor is a deterministic entry point for an unfamiliar
repository:

```text
assess -> review findings -> decide adoption scope -> plan implementation
```

It recommends an incremental adoption strategy from repository evidence. An
assessment recommends an adoption strategy. It does not authorise repository
changes and does not replace repository-owner, architecture, security, or
operational review.

## Commands and boundaries

Use the direct Ruby entrypoint or the root Make wrapper:

```sh
ruby scripts/assess_repository.rb TARGET
make assess REPO=/path/to/repository
```

The direct command supports `--output PATH`, `--report PATH`, `--context PATH`,
and `--no-report`. YAML is written to stdout when `--output` is omitted. A
Markdown report is written only when `--report` is supplied; this keeps the
default stdout stream machine-readable. Explicit YAML and report paths inside
the assessed repository are rejected. Output destinations must already have
an appropriate parent directory. Output and report destinations are compared
by their resolved destination identity, including symlink and dangling-symlink
aliases, before assessment or writing begins. Each write creates the complete
content in a new temporary file in the resolved external destination directory
and atomically replaces the requested final directory entry. Existing regular
file modes are retained; a final safe symlink is replaced rather than followed.
The destination is revalidated immediately before replacement. This protects
normal operation from hard links and unsafe aliases, but is not a hostile
multi-process filesystem-containment guarantee.

The assessor never installs dependencies, runs project commands, invokes
tests, builds, linters, formatters, migrations, deployments, agents, LLMs, or
network services. It does not create branches, change Git configuration, or
write target files. Git commands are limited to read-only identity, status,
tracked-file, and ignore inspection. Each Git subprocess disables optional
locks and fsmonitor execution locally (`GIT_OPTIONAL_LOCKS=0` and
`core.fsmonitor=false`); persistent Git configuration is not changed.

`--no-report` suppresses Markdown rendering as well as report writing. When an
explicit output or report path is supplied, every existing and not-yet-created
path component is checked with `lstat`/`readlink`. Direct paths, symlinked
parents, existing symlinks, and dangling symlinks that resolve into the target
are rejected. A symlink resolving wholly outside the target is permitted by
the current policy, and output parent directories are not created.

## What is inspected

Traversal is allowlisted. The assessor can read recognised metadata and
documentation such as `README*`, `CONTRIBUTING*`, `SECURITY*`, `AGENTS.md`,
`CLAUDE.md`, `Makefile`, package manifests and lockfiles, Python and Node/TypeScript
configuration, recognised test/lint/format/type-check configuration, hooks,
workspace metadata, `.gitignore`, GitHub Actions workflows, and recognised
architecture, development, domain, testing, and operations documents.

It does not recursively read arbitrary source code. Dependency, generated,
build, and cache areas are excluded, including `.git`, `node_modules`,
`.venv`, `venv`, `vendor`, `coverage`, `dist`, `build`, `target`, `tmp`, and
cache directories. Git-ignored files are not inspected by default. `.env`,
credential, private-key, token, and secret-store files are excluded. Example
environment metadata is not treated as live credentials. Symlinks are not
followed; a symlink escaping the target root is reported as an excluded
boundary when it is in a recognised traversal area.

The first detector scope is generic Git, GitHub Actions, Make, Python, and
Node.js/TypeScript. Python signals include `pyproject.toml`, requirements
files, uv, pip, pytest, Ruff, and mypy. Node/TypeScript signals include
`package.json`, npm, yarn, pnpm, ESLint, Prettier, the TypeScript compiler,
and common package scripts. Unsupported ecosystems still receive Git,
documentation, generic command, recognised CI, framework-capability, gap,
risk, and readiness findings where evidence permits. Ruby-project assessment
is not inferred from this framework's own implementation language.

For a repository with multiple candidate roots, the result lists
`scope.project_roots` and assesses shared surfaces. It does not recursively
run independent assessments for each workspace.

Package-manager evidence uses this precedence: an explicit supported
`packageManager` declaration, then a recognised lockfile, then npm as the
fallback for a bare `package.json`. A declaration that disagrees with a
lockfile is retained as a conflict. Multiple supported lockfiles are also
reported as a conflict; no manager is silently preferred.

GitHub Actions command evidence comes only from scalar or multiline `run`
values under job steps. Comments, step names, `env`, `with`, and arbitrary
workflow text do not establish an invocation. Local and CI commands are
compared using normalized command identity (for example, `make test` matches
`make test`, but not `make test-destructive`; package script syntax may be
normalized across npm, Yarn, and pnpm when the script identity is the same).

## Evidence and confidence

Every non-trivial finding points to the top-level `evidence` collection.
Evidence has a stable `E###` ID, type, detection method, summary, and a
relative path where applicable. Evidence collection uses internal keys while
the result is assembled. After collection is complete, one deterministic
sorted evidence order is frozen, `E###` IDs are assigned, and every reference
is resolved in one pass. Internal keys never appear in YAML or Markdown.
Supported types are `git`, `file`, `directory`,
`configuration`, `documented_command`, `ci_invocation`, `assessor_context`,
and `framework_metadata`. IDs are assigned after deterministic sorting; no
raw arbitrary file bodies or secret-bearing values are emitted.

Confidence is exactly one of:

* `high` — direct machine-readable, exact-path, Git, command, CI, or exact
  framework evidence. A single manifest, lockfile, explicit package-manager
  declaration, tool configuration, dependency declaration, or tool-bearing
  package script is sufficient for high confidence when it is not conflicting;
* `medium` — corroborated weaker signals or a documented command supported by
  compatible configuration. The npm manager inferred from a bare `package.json`
  with no package-manager declaration or lockfile remains medium confidence;
* `low` — one weak structural signal or an ambiguous conventional signal.

Conflicting repository and context evidence remains visible and cannot yield a
high-confidence affected conclusion. Absence is represented as `unknown` when
static inspection cannot safely establish a negative fact.

## YAML schema version 1

The canonical result is a versioned YAML document. `schema_version: 1` is the
assessment result schema. `framework.metadata_schema_version: 2` is the
schema of the framework catalogue being consumed. `framework.version` is the
framework release. `framework.source_revision` identifies the local source
revision when available. These are separate identities.

The stable top-level shape is:

```yaml
schema_version: 1
framework: {metadata_schema_version: 2, version: 0.1.0, source_revision: ...}
assessment: {generated_at: ...}
repository: {root: ..., git: {...}}
scope: {type: repository, project_roots: []}
ecosystem: []
tooling: {}
validation: {}
documentation: {}
framework_adoption: {}
readiness: {}
tier_recommendation: {}
component_recommendations: []
gaps: []
risks: []
roadmap: []
assessor_context: {}
assumptions: []
unknowns: []
evidence: []
```

The Ruby schema validator checks the complete emitted v1 structures: ecosystem
entries; all tooling sections and nested command entries; validation
capabilities, command collections, and CI alignment; every documentation
category; and the adoption, readiness, recommendation, gap, risk, roadmap,
context, and evidence objects. Stable objects are closed to unknown nested
fields. It also checks required fields, types, closed status values, safe
relative paths, stable IDs, unique IDs, evidence references, gap and roadmap
prerequisites, and internal consistency. Schema/type checks are kept separate
from semantic checks. YAML and Markdown are rendered from the same in-memory
result.

## Readiness dimensions

There is no aggregate readiness score. Exactly these dimensions are emitted:

`repository_context`, `task_boundary`, `command_surface`,
`deterministic_validation`, `ci_alignment`, `sensitive_area_guidance`,
`runtime_access`, `review_handoff`, and `local_setup_reproducibility`.

Each has `status`, `confidence`, `evidence_ids`, `consequence`, and
`recommended_action`. Status is exactly one of `ready`, `partial`, `missing`,
`blocked`, `not_applicable`, or `unknown`.

The dimensions mean:

* `repository_context`: discoverable purpose, roots, architecture, and
  boundaries;
* `task_boundary`: evidence of scope, acceptance criteria, non-goals, and
  implementation boundaries in the repository's task workflow;
* `command_surface`: stable commands discoverable without executing them;
* `deterministic_validation`: static evidence of tests and validation tools;
* `ci_alignment`: conceptual overlap between local and recognised CI checks;
* `sensitive_area_guidance`: discoverable restricted/high-risk area guidance;
* `runtime_access`: explicit runtime/access expectations where relevant;
* `review_handoff`: a place to record scope and validation evidence for human
  review;
* `local_setup_reproducibility`: documented prerequisites and dependency or
  runtime identity.

## Tier recommendation

The outcome is the highest currently supportable framework tier, not a quality,
maturity, security, or agent-readiness score. The current catalogue is read
from `framework.yml`:

* Tier 1 / `tier-1` / agent-aware: repository context is sufficiently
  established to review standing instructions and workflow/documentation
  artefacts without a material unresolved boundary;
* Tier 2 / `tier-2` / agent-operable: Tier 1 is supportable and a clear
  executable command and validation surface exists, with no unresolved
  runtime, CI, hook, or access blocker for selected Tier-2 components;
* Tier 3 / `tier-3` / agent-optimised: lower-tier capability exists and the
  current catalogue's architecture, domain, testing, and commit-convention
  components can be specialised from evidence without inventing semantics.
  The assessor reads these Tier 3 component memberships from `framework.yml`;
  repository-native equivalents are valid evidence.

`manual_review_required` is returned when root/scope is materially ambiguous,
important evidence conflicts, safety-sensitive context cannot be established,
or evidence cannot justify a tier. The result records confidence, evidence,
blocking gaps, assumptions, and alternative conditions. Components remain
independent of tier membership.

## Components, gaps, risks, and roadmap

Assessment component references use the current catalogue names in
`framework.yml`. They are not the durable ownership IDs planned for Issue #9.
The detected component state distinguishes:

* `framework_exact`: exact content or explicit safe metadata proves current
  framework correspondence;
* `framework_like`: a recognised framework-style artefact exists but provenance
  is not proven;
* `repository_native`: a local mechanism satisfies the capability.

Filename equality alone never proves provenance. The recommendation state is
one of `adopt_now`, `specialise_now`, `adopt_after_prerequisite`,
`evaluate_later`, `defer`, `not_applicable`, or
`already_satisfied_by_repository_native`. A native equivalent is preserved;
an absent optional runtime or hook is not automatically a defect.

Gaps are adoption-specific and use deterministic `GAP-###` IDs, one of
`blocking`, `high`, `medium`, or `low`, a readiness dimension, evidence,
impact rationale, and prerequisite gap IDs. Risks use deterministic
`RISK-###` IDs, a relevant adoption category, severity, confidence, evidence,
impact, and mitigation. They do not constitute a vulnerability scan or code
quality judgement.

Roadmap items use deterministic `STEP-###` IDs and phases 0–3. Phase 0
clarifies or unblocks; Phase 1 establishes repository contract, context,
command, and validation foundations; Phase 2 adds justified task/review,
CI, hook, runtime, and access controls; Phase 3 is reserved for later
operationalisation. The current component mapping places
`agent_instructions`, `development_guide`, `testing_strategy`,
`architecture_scaffold`, `domain_context`, and `command_interface` in Phase 1.
Issue/review templates, `ci_workflow`, `git_hooks`, `agent_launcher`, and
`github_access_helper` are Phase 2 actions. Deferred operational work is only
emitted in Phase 3 when the current recommendation logic supplies a roadmap
item. Blocking gaps remain Phase 0. Component recommendations that are
already satisfied by repository-native mechanisms, optional evaluations, or
deferred items do not receive redundant generic roadmap steps; roadmap actions
use capability-specific titles and are skipped when an existing gap step
already provides the sequencing action.

## Assessor context

Optional human context supplements, and cannot silently replace, repository
evidence. Its file uses:

```yaml
schema_version: 1
repository:
  criticality: ...
  deployment_impact: ...
sensitive_paths: []
approved_agent_runtimes: []
review_requirements: []
known_setup_constraints: []
notes: []
```

Fields may be omitted when unknown. Malformed context is an invocation error.
Each context entry produces `assessor_context` evidence, while the supplied
values are recorded under `assessor_context` in the result. Contradictions are
reported explicitly and can force manual review.

## Markdown report

The optional report is a projection of the structured result. It includes an
executive summary, repository profile, ecosystem/tooling profile, readiness,
tier recommendation, component recommendations, gaps, risks, phased roadmap,
assumptions, unknowns, and an evidence appendix. The renderer does not inspect
the target or invent additional findings.

Volatile `assessment.generated_at`, repository root, and live Git branch/tree
state are normalised or injected in tests. Substantive ordering and IDs remain
stable for equivalent repository state and context. The committed reference
fixture is regenerated by the real assessor with a fixed clock; its test
normalizes only the volatile identity fields and compares the complete YAML
and the Markdown projection exactly.

## Current framework metadata boundary

Schema v1 reserves:

```yaml
framework_adoption:
  metadata:
    status: unsupported_in_schema_v1
```

This assessor does not invent adopted component ownership, digests, revisions,
drift semantics, or `.agent-framework.yml`. Issue #9 will define the formal
metadata contract. Issue #10 will define safe adoption/update planning and
mutation. The current assessment is a read-only input to those later workflows,
not an installer or general `framework` executable.

## Review expectations

Review the evidence and unknowns before relying on a recommendation. Confirm
repository ownership, architecture/domain boundaries, security and sensitive
areas, deployment impact, review responsibilities, runtime access, and the
actual commands that should be run. Do not treat a detected command as proof
that it works, or a passing future validation as authorisation to merge or
expand agent permissions.
