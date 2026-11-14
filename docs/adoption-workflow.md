# Safe framework adoption and updates

> Mechanical adoption safety does not establish architectural suitability, organisational approval or safe agent execution permissions.

`scripts/manage_adoption.rb` implements a local, deterministic transaction over
explicitly selected baseline components and separately approved adapter configurations. It does not fetch releases, call models,
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
restoration of missing targets, source/target path migration, general adapter retirement, dependency
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
IDs and source/target mappings. Actions that create inherited or specialised
files, or compare/update inherited candidates, require regular tracked source
files whose exact bytes and executable mode agree with Git. Repository-owned,
deferred and declined decisions require a valid catalogue entry but do not read
its source bytes; their plan `source_file` is `null`. Reconciliation also uses
`source_file: null` and preserves the recorded historical source provenance.
Supported installed file modes are `0644` and `0755`. No chronological ordering is inferred from
revision identity or version labels.

All plans, decisions, assessment inputs, reviewed content, validation specs and
results must be external to both worktrees. Existing parent directories are
required. Unsafe symlinks, hard-link aliases, input/output collisions and paths
resolving inside either worktree are rejected. A safe explicitly chosen plan
output may be replaced. Application and validation results require new paths.
The tool never creates external parent directories. Generated plans, every
application-journal replacement and completed validation results explicitly use
mode `0600`, including their temporary files, independently of the process umask.
Replacing a more permissive plan makes the new file private. Managed repository
files retain their approved `0644`/`0755` modes. Protect destination directories
appropriately and handle artefact contents responsibly: plans embed repository
content, and results can contain operational data or command output.

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

Reconciliation requires the selected target to be a regular file in the target
HEAD tree, with an identical stage-zero index entry. Its exact working-tree bytes
must equal the committed blob and its mode must equal the supported committed
mode; the committed bytes must differ from the adopted source digest. Planning,
check, dry-run and apply preflight repeat these checks. Ignored/untracked targets
and uncommitted changes hidden by assume-unchanged, skip-worktree or ignored mode
changes cannot become specialised ownership. The CLI never changes index flags
or commits content to satisfy this requirement.

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

Validation requires completed matching application evidence. Before execution,
the canonical target and HEAD must match the plan, and every index mode/blob entry
must still equal the starting HEAD tree. The validator compares actual tracked
bytes and executable modes with HEAD, allowing only exact file replacements,
creations and metadata writes declared by the applied plan. New approved files
may remain untracked; unexpected non-ignored untracked files block execution.
Managed outputs and metadata must retain their approved identities. Status output
and index flags cannot hide unrelated changes from these byte/mode checks.

A stale pre-validation state is refused before any project command starts, using
existing diagnostic/exit conventions; prior application evidence is untouched.
After execution has begun, a changed state before a subsequent command stops the
sequence and produces a failed validation result containing completed command
evidence. Post-command comparisons and inspection failures remain recorded.
Validation uses direct argv execution (no implicit shell interpolation) in
declared order and stops at the first unsuccessful command. Children receive only
host `PATH`, fixed `LANG=C.UTF-8`, `LC_ALL=C.UTF-8`,
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
requires considering that trust boundary. The state check is not a general
filesystem snapshot: ignored caches/files, external executables and dependencies
are not guaranteed immutable. Git tracks executable modes, rather than all Unix
permission bits, for unrelated tracked files; planned outputs retain their exact
approved modes. Supply no secrets in specs or command output. Planning/application
stay offline; validation authority is separate.
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

Legacy v1 plans retain their original schema, identity algorithm and authority.
Adapter adoption uses the separate v2 transaction contracts described below.


## Adapter adoption and reviewed updates (v2)

Detection supplies evidence. An explicit `adapter-selection-v1` document selects
supported adapters, non-secret inputs and permitted conflict resolutions. The
public #13 assessor recomputes compatibility and composition; `ready` is a
recommendation, not authorisation. A separate external
`adapter-adoption-decisions-v1` document supplies adoption decisions. Planning
creates an immutable proposal; only exact `--accept-plan-id` approval authorises
application. An independent validation specification authorises command
execution. None of these steps imply another step's authority.

All named production adapters in this checkout remain planned. Use the synthetic
fixtures under `test/adapters/` and `test/adoption/` to exercise adoption. Once a
supported adapter is available, its provider participates through the same public
registry/assessor interfaces; the transaction engine has no ecosystem branches.

Prepare existing external directories and explicit selection and decision files:

```yaml
# /tmp/adoption/adapter-decisions.yml
schema_version: 1
selection_reviewed: true
adapter_changes: []
commands: []
components: []
retained_files: []
```

Empty `commands` approves no bindings. To approve a recommendation, add a record
with its exact `command_id`, `disposition: approve`, `reviewed: true` and nonblank
`rationale`. The planner copies scope, argv, cwd, env, profiles, preconditions,
classification and provenance from the effective composed command. Wrappers and
repository overrides retain #13 provenance and applied conflict resolutions.
These are approved declarations, not evidence of installation, execution,
completeness, suitability or safety. Bindings do not create Make targets.

```sh
ruby scripts/manage_adoption.rb plan /path/to/target \
  --operation adopt_adapters \
  --framework-source /path/to/clean/framework-source \
  --scope . \
  --adapter-selection /tmp/adoption/selection.yml \
  --adapter-decisions /tmp/adoption/adapter-decisions.yml \
  --effective-date 2026-11-07 \
  --output /tmp/adoption/adapter-plan.yml
ruby scripts/manage_adoption.rb preview /tmp/adoption/adapter-plan.yml
ruby scripts/manage_adoption.rb check /tmp/adoption/adapter-plan.yml
ruby scripts/manage_adoption.rb apply /tmp/adoption/adapter-plan.yml --dry-run
ruby scripts/manage_adoption.rb apply /tmp/adoption/adapter-plan.yml \
  --accept-plan-id sha256:REPLACE_WITH_REVIEWED_PLAN_ID \
  --result /tmp/adoption/adapter-result.yml
```

Adapter operations reject legacy `--tier`, `--component`, `--exclude`,
`--decisions` and `--assessment` inputs. Component-file effects come exclusively
from adapter decisions. No baseline component is copied implicitly. Scope is
required when metadata is absent; existing scope is authoritative and cannot
change. A blocked composition cannot pass check/dry-run/apply. Invalid selection
or decisions are errors, rather than approval to weaken safeguards.

`adopt_adapters` creates metadata v2 from absent metadata or explicitly migrates
valid v1 metadata. Migration preserves each component record and historical
framework adoption date. The selected source HEAD must equal v1's recorded
framework revision; reconcile source/version relationships first when they
differ. Reading, inspecting and ordinary v1 baseline operations never migrate.
A v1 plan becomes stale if its metadata later migrates.

`update_adapters` requires existing v2 adapter metadata and a complete proposed
selection. Every changed/added adapter category needs one `adapter_changes`
record containing `category`, exact complete `previous` identity (or null for an
addition), complete `proposed` identity, `reviewed: true` and `rationale`.
Identity includes version, manifest/provider digests and selection source.
An unchanged adapter needs no change record. Every retained or new binding needs
an `approve` decision; every omitted prior binding needs an explicit `retire`
decision. An unapproved recommendation never becomes a binding. Removing an
entire selected category is unsupported. No file deletion or command regeneration
is inferred from updates or version ordering.

### Reviewed component files

Only canonical baseline component mappings may be used. Each component decision
has `id`, `disposition`, external absolute `content_path`, nonempty unique
`local_ownership`, literal `reviewed: true`, `rationale`, `contribution_ids` and
`approved_command_ids`. References must resolve to composed contributions and
explicitly approved commands. Empty references are suitable only for a reviewed
specialisation whose rationale explains its independence from recommendations.
The tool copies exact approved bytes and mode; it performs no rendering or merge.

`create_specialised` requires an unrecorded component and absent canonical target.
`replace_reviewed_specialisation` requires an active specialised/manual-merge
component at unchanged source/target mappings. Its target must be a regular
tracked committed file whose HEAD, stage-zero index, working bytes and mode agree.
Inherited, pinned, repository-owned, unowned, moved, unsafe, missing or locally
modified targets cannot be replaced. Framework lineage remains separate from
reviewed target digest/mode and is preserved during replacement.

Potentially affected prior reviewed files require replacement or a
`retained_files` decision with `component_id`, `reviewed: true` and `rationale`.
Retained records keep their original digest, mode and adapter provenance, with
`review_state: retained_after_adapter_change`. They are not attributed to the new
adapter. Existing v1 specialisations gain no fabricated reviewed-file history.

### Integrity, source trust and recovery

V2 binds exact source root/HEAD/catalogue, target root/HEAD/scope, initial metadata,
managed target and bounded assessment-file identities, raw external selection/decision/spec digests and reviewed
content bytes/modes. Every supported manifest/provider the assessor may load is
checked against HEAD, stage-zero index, working bytes/mode and registry digests
before provider execution, including unselected supported adapters. Provider Ruby
belongs to the explicitly selected ADS source trust boundary; it is not a sandboxed
target plugin. No provider is loaded from the target. Source/provider drift without
a version bump still stales the transaction.

Check, dry-run and apply independently rebuild the authoritative assessment,
approved contribution projection, decisions, actions and metadata. Recomputing a
checksum after fabricating an embedded field cannot make the plan applicable.
Plan identity includes raw input digests; changing YAML bytes, including comments
or reordering external entries, changes that identity and invalidates old plans.
Semantically unordered embedded identities and decisions are canonicalised.
Equivalent semantic representations have stable order when raw identities remain
unchanged. Only `plan_id` and informational `created_at` are excluded from the
existing byte-sorted compact-JSON SHA-256 algorithm. The plan ID is an integrity
and exact-acceptance mechanism, not a cryptographic signature or proof of reviewer
identity.

A plan may have zero file actions and still change metadata. The existing durable
journal handles that write, verifies it, and reports `applied_unvalidated`.
`no_changes` requires no file or metadata effect. An equivalent reviewed update
preserves `updated_at` and exact existing metadata bytes even if a later effective
date was supplied. File effects
remain deterministic by component ID; canonical metadata is written last.
Completed result files remain external, private and immutable by this workflow.

The transaction is not globally atomic. Pre-mutation failures are `refused`;
failures after mutation are `partially_applied`; interruption may leave
`in_progress` evidence. Inspect completed/uncertain actions, recorded paths,
metadata state and the last durable journal. Manually restore a coherent clean
state before creating a fresh plan. There is no rollback, resume or Git cleanup.

The existing explicit validation spec v1 remains the only execution authority:

```sh
ruby scripts/manage_adoption.rb validate /tmp/adoption/adapter-plan.yml \
  --application-result /tmp/adoption/adapter-result.yml \
  --output /tmp/adoption/validation-result.yml
```

Supply `--validation-spec` during planning to approve actual validation commands.
An adapter binding or `fast`/`standard`/`extended` recommendation does not populate
it. V2 validation requires matching completed v2 evidence, exact outputs and
unchanged HEAD/index with no unexpected tracked/untracked files. Execution uses
direct argv with the existing restricted environment, bounded capture and
stop-on-failure checks. With no approved commands, validation reports `skipped`.
No validation step edits metadata or application evidence.

The existing `add_components`, `update_inherited` and `reconcile_inherited`
operations use v2 plans/results for v2 metadata and preserve its adapter block,
including its independently approved source identity. A baseline candidate may
advance top-level framework provenance without updating adapters. A differing
adapter source is reported for review. V1 targets retain v1 plans and results.
