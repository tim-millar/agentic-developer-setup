# Framework adoption metadata

Adopted repositories record their framework relationship at
`.agent-framework/adoption.yml`. Version 1 is deliberately one document per
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
candidate comparison. Planning, mutation, update, and reconciliation remain
out of scope for Issue #9 and belong to Issue #10.
