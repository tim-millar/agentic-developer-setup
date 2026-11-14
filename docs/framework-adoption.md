# Framework adoption metadata

Adopted repositories record their framework relationship at
`.agent-framework/adoption.yml`. Both supported versions use one document per
repository and uses the stable `name` values from `framework.yml` as component
IDs. The machine-readable contract is
[`schemas/framework-adoption-v1.schema.json`](../schemas/framework-adoption-v1.schema.json).

An active component is either `inherited`, `specialised`, or
`repository_owned`. Inherited targets are expected to remain byte-identical to
their recorded source digest. Specialised targets retain repository-specific
content and are not semantically validated. Repository-owned components record
the capability and optional paths or commands without claiming framework-file
provenance.

Lifecycle status is separate from ownership: `deferred`, `declined`, `removed`,
and `blocked` records have a rationale and no active ownership fields. Update
policy is also separate; `pinned` is a policy for inherited or specialised
components and does not suppress local drift detection.

Active framework-managed components record the framework revision and exact raw
source SHA-256 digest from which they were adopted. The inspector compares
local state without writing target files, metadata, or Git state:

```sh
ruby scripts/inspect_adoption.rb /path/to/repository
ruby scripts/inspect_adoption.rb /path/to/repository \
  --framework-source /path/to/local/framework-source
make adoption-inspect REPO=/path/to/repository
```

Candidate comparison is explicit and offline. A changed candidate is only a
candidate or review boundary; it is not treated as newer, safe, or authorised
for application. Declared repository-owned commands are never executed.

Repository assessment emits schema version 2 and consumes the same metadata
library for ownership summaries and confidence. Assessment does not perform
candidate comparison. The separate [adoption transaction CLI](adoption-workflow.md)
consumes these contracts for explicitly selected planning, application, inherited
updates and limited reconciliation; assessment and inspection remain read-only.

The mutation workflow preserves this schema-v1 contract: metadata-only native or
inactive decisions need a valid catalogue identity but do not consume component
source bytes. Limited inherited reconciliation proves the selected mismatch is
committed by comparing HEAD, index, raw blob bytes and supported file mode; it
retains the original adopted source path, revision and digest. These transaction
preconditions do not redefine the read-only inspector's local/candidate states.


## Canonical metadata v2

[`framework-adoption-v2.schema.json`](../schemas/framework-adoption-v2.schema.json)
adds exactly one required top-level field, `adapters`, to `schema_version`,
`framework`, `scope` and `components`. Component ownership/lifecycle semantics are
unchanged. The required adapter block has exactly `source`, `selected`, `inputs`,
`resolutions`, `command_bindings`, `reviewed_files`, `adapter_set_digest`,
`composition_digest`, `adopted_at` and `updated_at`. No authoritative sidecar or
full assessment report is stored.

`source` records the approved Git revision and catalogue digest independently of
component-level and top-level framework provenance. `selected` records one
ecosystem and at most one adapter in each other canonical category, sorted by
category/ID. Each identity includes category, ID, version, selection source and
exact manifest/provider SHA-256 digests. Planned/detected adapters are never
persisted as adopted. Inputs retain typed explicit non-secret values; resolutions
retain the validated #13 records. Scope is the top-level adoption scope.

Bindings contain `command_id`, `capability`, `scope`, `argv`, `cwd`, `env`,
`profiles`, `preconditions`, `classification`, `provenance` and approval
`rationale`. Effective command fields are copied intact from recomputed #13
composition. They grant no command-execution authority and make no executability
or safety claim. Referenced command/base/refinement/wrapper/profile contribution
records remain traceable in the approved plan projection.

Reviewed file records have `component_id`, `target_path`,
`approved_content_digest`, `approved_mode`, `source_adapter_provenance`,
`contribution_ids`, `approved_command_ids` and `review_state`. Only active
specialised components at matching paths can be referenced. Original historical
provenance survives explicit retention after adapter changes; `current` and
`retained_after_adapter_change` distinguish that review status. Metadata validity
does not require historical providers to remain locally available.

Schemas are closed; semantic validation additionally checks uniqueness,
references, adapter-set fingerprint, scope, non-secret values and real ISO
calendar dates. Inspection does not migrate or rewrite metadata. V1 migration
and updates require separately reviewed v2 transactions; see the
[workflow](adoption-workflow.md#adapter-adoption-and-reviewed-updates-v2).

For v2 metadata, inspection emits v2 while retaining component fields. Its
`adapters` section contains the adopted state/scope, optional explicit candidate
comparison, local reviewed-file states and an optional proposed #13 assessment.
Candidate identities distinguish version/manifest/provider changes and report
`unchanged`, `changed` or `missing` only against an available validated candidate.
Unavailable candidates are reported separately, with no inference of retirement.
Reviewed-file states are `in_sync`, `modified`, `missing`, `unsafe` or
`historical_retained`; historical records keep their original provenance.

```sh
ruby scripts/inspect_adoption.rb /path/to/target \
  --framework-source /path/to/explicit/candidate \
  --adapter-selection /tmp/adoption/proposed-selection.yml
```

Omit selection to compare without inventing a proposal. Proposed inspection is
read-only: compatibility/conflicts are informational, no resolutions are approved,
and no plan, migration or target writes occur. A higher version is no safety
claim. Generic repository assessment remains schema v2, consuming only its
established ownership summary fields.
