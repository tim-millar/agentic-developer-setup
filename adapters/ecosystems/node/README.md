# Node.js and TypeScript adapter

`ecosystem/node` version **1.0.0** is the first supported public ecosystem
adapter. `framework.yml` owns its registration. It uses manifest, selection and
assessment contract v1 and the existing adoption metadata/transaction v2.
Its Ruby provider needs no Node installation.

This implementation and its disposable fixtures were independently authored
from public ADS contracts and public ecosystem documentation. No private adapter,
application configuration or internal development procedure is a reference.

## Authority and compatibility

Detection records candidates without selecting them. Explicit selection enables
static assessment and composition. Commands remain recommendations. Separate
adoption decisions approve individual bindings; exact plan acceptance authorises
reviewed metadata/file changes. A separately approved validation specification
is needed to execute anything. An adopted binding is not such a specification.

| Evidence or capability | Detected | Assessed | Command recommendation available | Execution verified separately | Unsupported/deferred |
| --- | --- | --- | --- | --- | --- |
| Valid selected `package.json` | Yes | Unique-key object and supported field types | Only eligible supported scripts | Required | Arbitrary script interpretation |
| npm, Yarn, pnpm | Declaration/lockfile | Precedence and contradictions | When manager evidence permits | Required | Version installation, resolution, migration |
| TypeScript | `tsconfig*.json`, dependency and script signals kept distinct | Immediate-scope strict JSON options | Explicit `typecheck`/`type-check` only | Required | JSONC option parsing, `extends`, compiler validation |
| JavaScript | `main` entrypoint or literal `node file.js` script evidence | Limited classification | Supported script vocabulary | Required | Source indexing and JavaScript-only proof |
| ESLint/Prettier | Dependencies and inventory-visible configuration files | Missing-script findings; JS config never evaluated | `lint`/`format:check` only | Required | Configuration rewriting and plugin evaluation |
| Jest/Vitest/Node test runner | Dependency and/or literal script references | Signals do not prove coverage | Explicit supported test scripts | Required | Comprehensive runner/framework interpretation |
| Builds | Tool dependency and supported script | Unmeasured effects/cost | `build` | Required | Automatic output/type-check/test assumptions |
| Workspaces | Package arrays/`packages` and pnpm YAML; nested manifests | Isolation and scope limitations | Selected package scripts only | Required | Follow-up A: inheritance and dependency/task graph |
| GitHub Actions | Inventory-visible YAML | Simple literal invocations and setup-node values | No CI-derived commands | Required | Follow-up B: matrices, expressions, reusable workflows |
| Other managers/frameworks | May be observed | Unsupported or uncertain | No inferred manager fallback | Required | Bun/Deno and framework-specific adapters |

The generic repository assessor has its own heuristic tooling observations.
Only this adapter's explicitly selected composition supplies these Node command
recommendations. A detected dependency, configuration, script, CI invocation and
recommended command are separate evidence states; none proves successful
execution, safety, read-only behaviour, coverage or installed dependencies.

## Evidence and manager precedence

Reads use the existing bounded inventory, Git ignore rules, excluded directories,
symlink/path containment and 256 KiB content limit. The additional allowlisted
metadata names are `.nvmrc`, `.node-version` and `npm-shrinkwrap.json`.
`.npmrc`, installed dependencies, arbitrary source and executable configuration
are not inspected. There is no network, package-manager invocation or target write.

Package JSON must be an object with unique keys at every depth. Malformed,
unreadable, oversized or duplicate-key documents produce controlled findings and
withhold dependent commands. Invalid field types withhold the affected
interpretation while retaining unrelated evidence. Findings never reproduce raw
script bodies. Node evidence includes bounded content digests, so material source
changes remain visible without publishing configuration contents. Recognised
credential values are checked with the existing shared non-secret policy; this
is not a guarantee to recognise every arbitrary secret.

Manager precedence is deterministic:

1. A valid supported `packageManager` declaration, retaining identity separately
   from version text. Numeric versions/constraints, simple distribution tags and
   Corepack-style version/hash suffixes are recognised. URLs/remote resolution
   and unknown/malformed declarations are unsupported, with no npm fallback.
2. Exactly one lockfile family: npm (`package-lock.json`, `npm-shrinkwrap.json`),
   Yarn (`yarn.lock`) or pnpm (`pnpm-lock.yaml`). Lockfile presence does not prove
   validity, currency or installed dependencies.
3. Optional reviewed `ecosystem/node.package_manager` input when primary evidence
   is missing. It has no default and accepts only `npm`, `yarn`, `pnpm`.
4. CI is corroborating or divergent evidence; it cannot replace primary policy.
   Ordinary configuration signals cannot establish manager authority.

Different-manager lockfiles, declaration/lockfile disagreement or contradictory
input withhold manager-backed commands. Matching input corroborates evidence.
Unknown explicit managers remain unsupported even with an input. Both npm lockfile
forms remain npm evidence with a coexistence finding; the adapter does not choose
universal precedence across npm versions. These findings do not create new
composer conflict types. A provider `blocking` finding is distinct from a generic
blocking composition conflict: metadata-only adoption can remain available.

Node runtime policy is observed separately from manager versions in
`engines.node`, `volta.node`, `.nvmrc`, `.node-version` and literal setup-node
`node-version`. Evidence records source and declaration type, safely representable
value and exact/constraint/selector status. Different exact versions generate a
disagreement. Ranges, selectors and expressions produce uncertainty rather than
an invented incompatibility; no general SemVer solver or installed-version check
is performed. No declaration means compatibility cannot be assessed.

## Scripts, profiles and tool evidence

Every proposal is `[MANAGER, "run", SCRIPT]`, with one literal supported name,
the selected repository-relative scope as both `scope` and `cwd`, an empty `env`,
review preconditions and `unexecuted_native_script` classification. There is no
shell wrapper and target script bodies never become ADS argv or shell strings.

| Script | Stable command ID | Capability | Recommended profiles |
| --- | --- | --- | --- |
| `test` | `node-test` | `test` | standard |
| `test:unit` | `node-test-unit` | `test_unit` | standard |
| `test:e2e` | `node-test-e2e` | `test_e2e` | extended |
| `lint` | `node-lint` | `lint` | fast, standard |
| `format:check` | `node-format-check` | `format_check` | fast, standard |
| `typecheck`, otherwise `type-check` | `node-typecheck` | `typecheck` | standard |
| `build` | `node-build` | `build` | extended |
| `verify` | `node-verify` | `verify` | unassigned pending cost/scope review |

Both type-check spellings produce one capability proposal, preferring `typecheck`
and reporting the alternative. Profiles are recommended groupings, not measured
cost or automatic execution permission. A build does not imply type checking,
tests, read-only execution, an output directory or independence from services.
`test` does not imply complete test coverage. `format`, `lint:fix`, `check` and
`validate` do not create supported validation capabilities.

Empty/non-string scripts, known echo/exit/true/false placeholders, clearly stated
`--fix`/`--write` behaviour and recognised credential-bearing definitions are
withheld. This is not a shell safety proof: an otherwise eligible invocation may
run arbitrary target code and lifecycle hooks. Review implementation before
separately approving execution. Installation, Corepack setup and script execution
never occur during assessment or adoption.

TypeScript, ESLint and Prettier configuration without a matching supported script
produces a finding rather than fabricated `tsc`, linter or formatter commands.
Declared dependencies include common build/test tools but do not create commands.
Only strict unique-key JSON TypeScript options are interpreted: `module`,
`moduleResolution`, `noEmit`, `outDir`. JSONC files still establish configuration
presence, but their options remain unresolved. No `extends` file is followed.

`node_modules` receives a conventional cache classification, without ownership.
A safely scoped, explicitly declared TypeScript `outDir` with emission permitted
receives a generated-path classification. Generic `dist`, `build`, coverage and
report paths are not invented. No excluded directory is traversed, ignore file
rewritten or generated content removed.

Recognised setup/packaging lifecycle names are `preinstall`, `install`,
`postinstall`, `prepare`, `prepack`, `postpack`. Their presence is reported without
publishing bodies or claiming the hooks are safe or unsafe.

## Workspace and CI limits

Root packages and explicitly selected packages under existing workspace directories
are supported. Package workspace arrays, `workspaces.packages`, pnpm package
patterns and bounded nested manifests are observed without expanding glob membership.
Multiple roots preserve generic `scope_conflict`; Node supplies no bypass or
recursive composition. A single selected workspace cannot import parent scripts,
manager declarations or lockfiles from outside its inventory. It may need the
reviewed manager input; that does not reconstruct complete monorepo policy.

Safe YAML inspection recognises simple literal package-manager run invocations.
Findings distinguish matching local names, supported local scripts absent from
inspected CI, missing local scripts, extra arguments, other manager invocations,
and unsupported/CI-only commands. Literal setup-node values join runtime policy
evidence. Matching names do not prove semantic equivalence or actual execution.
Expressions, matrix/reusable workflow semantics, dynamic commands, unsupported
working directories and version-file indirection remain incomplete observations.
No application CI is created or rewritten.

## Complete reviewed adoption example

Use a clean committed ADS source containing the supported adapter and a separate
clean committed eligible target with `scripts.test` and unambiguous manager
evidence. Keep selection, decisions, plan and result outside both worktrees.
Create the external directory first, for example `/tmp/node-adoption`.

```yaml
# /tmp/node-adoption/selection.yml
schema_version: 1
scope:
  type: repository
  path: .
selected:
  - category: ecosystem
    id: node
    source: explicit
inputs: []
resolutions: []
```

For an isolated scope, use `scope: {type: workspace, path: packages/web}`.
When primary manager evidence is absent, replace `inputs: []` with:

```yaml
inputs:
  - key: ecosystem/node.package_manager
    value: pnpm
```

This does not resolve contradictory primary evidence. First assess and inspect
`composition.commands` and findings:

```sh
ruby scripts/assess_adapters.rb /path/to/target
ruby scripts/assess_adapters.rb /path/to/target \
  --selection /tmp/node-adoption/selection.yml \
  --output /tmp/node-adoption/assessment.yml
```

After reviewing the actual `node-test` recommendation, approve just that binding:

```yaml
# /tmp/node-adoption/decisions.yml
schema_version: 1
selection_reviewed: true
adapter_changes: []
commands:
  - command_id: node-test
    disposition: approve
    reviewed: true
    rationale: Reviewed synthetic repository test command binding.
components: []
retained_files: []
```

If `node-test` is absent, this decision is refused. For metadata-only adoption
without bindings, use `commands: []`. No component file action is required.
Initial `adapter_changes` is empty under the existing #86 contract.

```sh
ruby scripts/manage_adoption.rb plan /path/to/target \
  --operation adopt_adapters --framework-source /path/to/clean/ads \
  --scope . --effective-date 2026-11-15 \
  --adapter-selection /tmp/node-adoption/selection.yml \
  --adapter-decisions /tmp/node-adoption/decisions.yml \
  --output /tmp/node-adoption/plan.yml
ruby scripts/manage_adoption.rb preview /tmp/node-adoption/plan.yml
ruby scripts/manage_adoption.rb check /tmp/node-adoption/plan.yml
ruby scripts/manage_adoption.rb apply /tmp/node-adoption/plan.yml --dry-run
ruby scripts/manage_adoption.rb apply /tmp/node-adoption/plan.yml \
  --accept-plan-id sha256:REPLACE_WITH_EXACT_REVIEWED_PLAN_ID \
  --result /tmp/node-adoption/application.yml
```

For workspace adoption, `--scope packages/web` must match selection. Read the
actual plan ID from the reviewed plan; the placeholder above is not an approval.
The unchanged engine independently verifies source/target Git identity, every
supported provider's committed bytes/mode, raw input digests, composition and
approved bindings at each preflight. It writes canonical metadata v2 last using
the existing durable journal. It does not execute scripts or install dependencies.
Metadata records exact adapter version/digests, selected inputs, bindings and
provenance. Later changes use `update_adapters` with explicit identity/binding
review as described in [the adoption workflow](../../../docs/adoption-workflow.md).
No adapter schema, source verification boundary or transaction mechanism changes.

The public lifecycle is exercised by
`test/adoption/node_transaction_test.rb`, including preview, check, CLI dry-run,
exact acceptance, result/journal evidence, no execution, metadata-only adoption,
unknown command refusal, stale input bytes, hidden source drift and multi-root
refusal. Generic #86 tests retain coverage of partial-write recovery and updates.

## Fixture and deferred-requirement traceability

Fixtures are generated disposable repositories, independently authored in
`test/adapters/node_support.rb`, `node_test.rb`, `test/assessment/node_inventory_test.rb`
and `test/adoption/node_transaction_test.rb`. No declared dependency is installed.

| Issue #11 fixture | Coverage |
| --- | --- |
| F1 | `f1` npm TypeScript fixture; complete real adapter adoption lifecycle |
| F2–F3 | Yarn/pnpm rows of the manager matrix and every-script tests |
| F4–F5 | JavaScript/TypeScript/mixed evidence tests without source-level certainty |
| F6–F9 | Missing/input/conflicting/declaration-disagreement and npm coexistence matrix |
| F10 | Exact disagreement, uncertain ranges and setup-node evidence |
| F11–F12 | Workspace declarations, generic conflict, isolated scope and no parent inheritance |
| F13 | Tool configuration without scripts; strict TypeScript options |
| F14–F15 | Jest/Vitest/Node runner, lifecycle, mutating and placeholder cases |
| F16–F17 | CI differences, unsupported managers, duplicate/malformed/oversized metadata |
| F18 | Ignored, symlinked, oversized, excluded and out-of-scope metadata boundaries |

| Original #11 requirement group | Disposition |
| --- | --- |
| Public `node` registration, detection, managers, native scripts, typed contributions, bounded fixtures and docs | Implemented |
| Selection, generic scope conflicts, composition, structural/non-secret checks and provenance | Satisfied by existing #13/#98 infrastructure |
| Immutable plans, reviewed individual bindings/files, source verification, metadata v2, journalling and independent execution approval | Satisfied by existing #86 infrastructure; genuine Node lifecycle added |
| Tool/module/version/CI/generated-path interpretation | Partially supported with the limits above; advanced work goes to Follow-up B |
| Workspace depth, parent manager policy, membership and multi-package recommendations | Deferred to Follow-up A; generic scope semantics preserved |
| Source indexing, exact JavaScript/mixed classification, compiler/module resolution, additional runners/frameworks, richer CI and output evidence | Deferred to Follow-up B |
| Private adapter review and private classification deliverable | Explicitly superseded; no private material used |

Follow-up A and B are scope descriptions from #11; this change creates no follow-up
issues and does not claim those capabilities complete.

## Public technical references

Interpretation is based on public specifications, with bounded static behaviour
as documented above:

- [Node/Corepack package-manager declarations](https://nodejs.org/api/corepack.html)
  and [Corepack's declaration/hash documentation](https://github.com/nodejs/corepack#when-authoring-packages).
- [npm package manifests](https://docs.npmjs.com/cli/v11/configuring-npm/package-json/)
  and [lifecycle scripts](https://docs.npmjs.com/cli/v11/using-npm/scripts/).
- [npm v11 lockfiles](https://docs.npmjs.com/cli/v11/configuring-npm/package-lock-json/):
  version-specific precedence is not asserted as universal across npm versions.
- [Yarn manifest declarations](https://yarnpkg.com/configuration/manifest).
- [pnpm workspace declarations](https://pnpm.io/workspaces/).
- [Node package/module semantics](https://nodejs.org/api/packages.html).
