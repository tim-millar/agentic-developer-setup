# Safe framework adoption and updates

> Mechanical adoption safety does not establish architectural suitability, organisational approval or safe agent execution permissions.

`scripts/manage_adoption.rb` implements a local, deterministic transaction over
explicitly selected baseline components. It does not fetch releases, call models,
execute repository code during plan/apply, or change Git configuration, index,
branches, commits, remotes or GitHub state. The separate demonstrations create
and commit disposable repositories as fixture preparation.

## Operation matrix

| Operation | Preconditions | Effects |
| --- | --- | --- |
| `initial_adoption` | Canonical metadata absent; explicit scope | Create absent inherited/reviewed specialised files; record native equivalents or inactive decisions; create metadata |
| `add_components` | Valid metadata; source HEAD equals recorded framework revision | Add only previously unrecorded IDs; preserve existing records and scope |
| `update_inherited` | Active inherited, review-required, locally unchanged target | Replace changed candidate bytes at compatible paths; advance selected component provenance and framework revision/version/date |
| `reconcile_inherited` | Committed inherited content mismatch; source HEAD equals recorded framework revision | Convert explicitly selected unpinned inherited component to specialised/manual-merge; preserve file bytes, paths and original source provenance |

Every selected component needs an explicit disposition or operation decision. For
`update_inherited`, explicit operation/component selection supplies the operation
decision when no decision file is given. Unselected components stay
absent from metadata. An existing inactive record cannot be reactivated by add.
Unsupported transitions, automatic merges, automatic unpinning, removal,
restoration of missing targets, source/target path migration, adapters, dependency
installation and repository/domain generation remain deferred. Specialised,
pinned and repository-owned components are never updated by inherited update.

## Inputs and repository eligibility

Source and target must be separate, non-overlapping, readable Git worktree roots
with 40-character lowercase HEAD commit identities and no staged, unstaged or
untracked changes. Ordinary ignored caches are allowed, but ignored files cannot
be adopted source files and ignored destination collisions block creation.
Git identity commands discard inherited `GIT_*` variables and disable fsmonitor
and optional locks. No remote URL establishes source authenticity or approval.

The source is always explicit; the running CLI checkout is never an implicit
candidate. A completely validated `framework.yml` supplies stable baseline `name`
IDs and source/target mappings. Selected source files must be regular tracked
files whose exact bytes and executable mode agree with Git. Supported installed
file modes are `0644` and `0755`. No chronological ordering is inferred from
revision identity or version labels.

All plans, decisions, assessment inputs, reviewed content, validation specs and
results must be external to both worktrees. Existing parent directories are
required. Unsafe symlinks, hard-link aliases, input/output collisions and paths
resolving inside either worktree are rejected. A safe explicitly chosen plan
output may be replaced. Application and validation results require new paths.
The tool never creates external parent directories.

An optional `--assessment` must be schema v2 and match the same canonical target,
HEAD and clean Git state. Its observations remain advisory and grant no selection,
ownership, overwrite or command-execution authority.

## Decisions

Create an external YAML file, for example `/tmp/adoption/decisions.yml`:

```yaml
schema_version: 1
components:
  - id: issue_template_config
    disposition: inherited
  - id: agent_instructions
    disposition: specialised
    content_path: /tmp/adoption/reviewed-AGENTS.md
    local_ownership:
      - native development commands
      - repository operating constraints
    reviewed: true
  - id: command_interface
    disposition: repository_owned
    equivalent:
      paths: [Makefile]
      commands: [make verify]
    rationale: Native Makefile remains authoritative.
  - id: review_policy
    disposition: deferred
    rationale: Review contract will be adopted separately.
```

`inherited` copies exact framework bytes. `specialised` requires an existing
external regular content file, non-empty local ownership categories and the human
attestation `reviewed: true`. Exact content bytes and mode are bound to the plan;
apply refuses changed reviewed content. The CLI does not establish semantic
completeness. Specialised metadata records the original framework source digest,
not the reviewed file digest; the latter remains in plan/application evidence.

`repository_owned` requires a rationale and non-empty paths and/or commands using
the existing metadata equivalent shape. Paths must exist inside scope; commands
are declarations only and are never implicitly executed. Equivalent paths do not
become managed target ownership. `deferred` and `declined` require rationale and
produce inactive records without ownership or source provenance.

For update, use `disposition: update_inherited`. For reconciliation, use:

```yaml
schema_version: 1
components:
  - id: issue_template_config
    disposition: convert_to_specialised
    local_ownership: [repository-specific issue policy]
    rationale: Existing committed changes are intentional specialisation.
```

Unknown fields, duplicate IDs, unselected decisions, missing decisions and
unsupported disposition/operation combinations are rejected. Decisions are the
editable inputs; direct editing of generated plans is unsupported.

## Plan, review and approve

```sh
ruby scripts/manage_adoption.rb plan /path/to/target \
  --operation initial_adoption \
  --framework-source /path/to/clean/framework-checkout \
  --scope . \
  --component issue_template_config \
  --component agent_instructions \
  --component command_interface \
  --component review_policy \
  --decisions /tmp/adoption/decisions.yml \
  --effective-date 2026-10-29 \
  --output /tmp/adoption/plan.yml

ruby scripts/manage_adoption.rb preview /tmp/adoption/plan.yml
ruby scripts/manage_adoption.rb check /tmp/adoption/plan.yml
ruby scripts/manage_adoption.rb apply /tmp/adoption/plan.yml --dry-run

ruby scripts/manage_adoption.rb apply /tmp/adoption/plan.yml \
  --accept-plan-id sha256:REPLACE_WITH_REVIEWED_PLAN_ID \
  --result /tmp/adoption/application-result.yml
```

`--component ID` and `--exclude ID` repeat. `--tier tier-1|tier-2|tier-3`
expands cumulative catalogue tier target paths to component IDs for initial/add
operations. Exclusions apply after expansion; explicitly requested IDs cannot be
excluded. Neither tiers nor assessment recommendations establish ownership.

Initial `--scope .` uses repository scope. An existing workspace path such as
`apps/storefront` prefixes all managed catalogue targets. Canonical metadata is
always `.agent-framework/adoption.yml` at the worktree root. Existing operations
preserve the recorded scope; a supplied scope must match it.

All plan commands are non-interactive. Preview includes file actions, exact
full-context unified text diffs, binary sizes/digests/modes, original and proposed
metadata, ownership/rationale, specialisation attestations, diagnostics, approved
validation commands and current applicability. Check and dry-run use identical
preflight and write neither target files nor an application journal. A blocked
but structurally valid plan can be saved for inspection; it returns exit 4.
Malformed documents and invalid source identity cannot become executable plans.

The exact acceptance ID is required for apply. It is a checksum-backed explicit
invocation, not a signature or proof that the caller performed human review.

## Immutable plan contract

The closed Draft 2020-12 schemas live under `schemas/framework-adoption-*-v1.schema.json`.
The plan records source root/revision/version/catalogue digest, target
root/HEAD/scope, raw input digests, requested and resolved selection, ordered
actions, exact file existence/digest/mode preconditions, reviewed content,
complete proposed component records/metadata and explicit validation commands.
`before` and `after` store `record`, base64 `content`, raw byte `size` and original
base64 `metadata_content` for offline rendering. They do not authorise extra writes.
The metadata serializer recursively orders keys and produces deterministic YAML;
format normalisation is visible in preview.

Plan identity is SHA-256 over compact UTF-8 JSON with recursively byte-sorted
object keys, preserving array order, excluding only `plan_id` and informational
`created_at`. No floats, native timestamps or arbitrary YAML objects are allowed.
Equivalent substantive inputs produce the same ID. Unknown nested fields,
invalid identities and unapproved action effects are rejected independently of
the checksum. A checksum establishes integrity, not authenticity.

Existing metadata remains schema v1 with exactly the ownership, lifecycle,
policy, provenance and local/candidate inspection meanings documented in
[framework-adoption.md](framework-adoption.md). Equal candidate bytes produce
`no_change`, even if catalogue paths moved; mode-only differences produce a
review warning and preserve the file. Changed bytes with moved source/target
mappings block replacement. Unchanged component provenance and `adopted_at`
remain intact; selected updates may leave mixed component revisions.

## Application guarantees and recovery

Apply revalidates the complete plan, exact approval ID, source/target identity
and HEAD, clean worktrees, catalogue, external inputs, reviewed files, source
bytes/modes, target preconditions, scope and all intended outputs before mutation.
It does not regenerate selection or infer alternative actions. Individual
paths/preconditions are checked again before writes. Unsafe symlinks, special
files, case-folding collisions, metadata aliases, nested worktrees, submodule
contents, traversal and file/directory conflicts are refused.

Application prepares bytes, initialises an external journal, then writes selected
files in component-ID order and canonical metadata last. Regular-file writes use
same-filesystem temporary files with synchronisation and atomic replacement;
creations use atomic no-clobber installation. Journal replacements synchronise
bytes and parent directory before/after actions. Parent creation and component
installation are bounded by declared action paths.

This is **not a globally atomic transaction**, rollback engine or hostile
multi-process filesystem isolation. A partial failure can leave installed files
and old/absent metadata. Catchable errors preserve completed actions and observed
identities. Hard termination can leave an `in_progress` journal; its started
action and interruption uncertainty need manual inspection. No automatic resume,
retry, rollback, reset, checkout, clean, branch, commit or publication occurs.

Inspect the result's `actions`, `metadata`, diagnostics and `recovery` fields,
then inspect `git status`, `git diff`, and the recorded paths (including untracked
files and new directories). Decide manually which changes to retain or remove.
Git alone does not automatically undo interrupted untracked-file creation.
Restore a coherent clean worktree and generate a fresh plan before subsequent
application. Never overwrite old application evidence. Reapplying a completed
mutating plan fails its original preconditions. An applicable all-`no_change`
plan can record `no_changes` without target writes.

Application states are `in_progress`, `applied_unvalidated`, `no_changes`,
`refused`, and `partially_applied`. Actions are `pending`, `started`, `completed`,
or `failed`. A failure after any target mutation cannot claim zero-mutation
refusal. A journal-write failure may leave the last durable `in_progress` record
and is reported explicitly.

## Explicit validation authority

Provide `--validation-spec /tmp/adoption/validation.yml` while planning:

```yaml
schema_version: 1
commands:
  - id: repository_verify
    argv: [make, verify]
    cwd: repository
    env:
      UV_OFFLINE: "1"
    expected_exit_code: 0
```

Commands have unique stable IDs, literal non-empty argv arrays, `repository` or
`scope` working directories, explicit non-secret environment additions and exit
codes 0–255. Secret/credential transport names are refused. Commands are never
discovered from Make, assessment or equivalent declarations.

```sh
ruby scripts/manage_adoption.rb validate /tmp/adoption/plan.yml \
  --application-result /tmp/adoption/application-result.yml \
  --output /tmp/adoption/validation-result.yml
```

Validation requires completed matching application evidence and verifies managed
files and metadata before execution. It uses direct argv execution (no implicit
shell interpolation) in declared order and stops at the first unsuccessful
command. Children receive only host `PATH`, fixed `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`,
`TZ=UTC`, and approved additions. Inherited HOME, operational credentials,
Git variables and runtime options are not forwarded. Output capture retains at
most 65,536 raw bytes per stream per command, drains excess to avoid pipe blocking,
records truncation and replaces invalid UTF-8 for YAML output. Results record
argv, cwd, expected/actual exit, duration, stdout/stderr and status. Tracked and
untracked content, modes, index and HEAD are compared around validation; ignored
build/test artefacts need not independently fail it.

Validation executes repository-controlled code. Even `make verify` may read
files/credentials, write files or access a network. There is **no additional
guaranteed execution sandbox or network isolation**. Approving a command set
requires considering that trust boundary. Supply no secrets in specs or command
output. Planning/application stay offline; validation authority is separate.
Validation never rewrites application evidence or adoption metadata itself.

Separate immutable results use `passed`, `failed`, `skipped` or `unavailable`.
No approved commands means `skipped`, not verified completion. Successful command
execution is not human approval. Continue with ordinary developer Git review and
explicitly authorised publication after inspecting results.

## Exit and diagnostic contract

| Exit | Meaning |
| --- | --- |
| 0 | Applicable command, completed application, or passed validation |
| 2 | Invalid invocation, malformed input or unsupported schema |
| 3 | Invalid/dirty source or target; unreadable required source |
| 4 | Blocked, conflicting, stale or non-applicable plan; skipped validation |
| 5 | Filesystem/application failure, including partial application |
| 6 | Failed or unavailable validation |

Structured diagnostics contain `severity`, stable `code`, nullable `component_id`
and `path`, and explanatory `message`; severity/code are authoritative.
Diagnostics are deduplicated and deterministically ordered by component, path,
code, severity and message. Errors block application. CLI refusal messages expose
the same stable code on stderr. Codes include invalid invocation/document/source/
target/catalogue/metadata/decision, dirty source/target, unknown/duplicate
component, ambiguous selection, unsupported operation, unsafe path, target/
ownership conflict, local modification, pinned component, unavailable source/
provenance, unsupported path migration, plan identity mismatch/staleness,
preflight/application/partial failure and skipped/failed/unavailable validation.
`mode_change_requires_review` is a warning, not permission for a mode-only update.

## Executable offline demonstrations

```sh
ruby scripts/examples/initial_adoption.rb
ruby scripts/examples/update_inherited.rb
```

Both use disposable public synthetic repositories, external inputs/evidence and
the actual CLI. They need Git, Ruby and Make, with no credentials, network or model.
The first assesses, adopts inherited and reviewed specialised content, preserves
a native Makefile, previews/checks/dry-runs, applies and explicitly validates.
The second creates two committed local source revisions and verifies exact changed
bytes, selected provenance advancement, and untouched specialised/native records.
They print Git review evidence and delete only their own disposable directories.

Future adapters require an explicitly designed extension of this contract;
existing catalogue adapter taxonomy does not grant composition or mutation
support to this v1 workflow.
