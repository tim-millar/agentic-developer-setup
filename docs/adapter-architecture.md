# Composable adapter architecture

The adapter subsystem registers, detects, explicitly selects and composes typed
recommendations for one repository scope. It is implemented under
`lib/agentic_developer_setup/adapters/` and exposed by
`require "agentic_developer_setup/adapters"`. Its runtime dependencies are Ruby
3.3 and the standard library. Detection and assessment never install dependencies,
execute target commands, start services or modify the target.

All named adapters in the production `framework.yml` remain **planned**. The
executable examples under `test/adapters/` are synthetic fixtures, not Ruby,
Rails, Docker, Node or Python production support.

## Categories and authority

| Machine category | Source root | Responsibility |
| --- | --- | --- |
| `ecosystem` | `adapters/ecosystems/` | Language, package manager, toolchain and generic development conventions |
| `framework` | `adapters/frameworks/` | Application-framework conventions and specialised validation |
| `runtime` | `adapters/runtimes/` | Application execution environment, service implementations, command wrappers |
| `app-shape` | `adapters/app-shapes/` | Architecture, delivery shape, documentation emphasis and risks |

Prefer **application execution environment** (or environment adapter) in prose.
`runtime` remains the machine identity; there is no `environment` category.
These adapters are separate from coding-agent runtimes under `agent_runtimes`
and from the repository's agent host toolchain. Selecting an ecosystem does not
require installing its language runtime on the coding-agent host. Repository
policy and the chosen execution environment determine host requirements.

An explicitly selected set contains exactly one ecosystem and at most one of
each other category. An unselected assessment needs none. There are no implicit
`generic` or `non-containerised` selections.

## Catalogue, manifests and providers

`framework.yml` schema v2 owns registration identity, category, source directory
and `planned`/`supported` status. Identity is `(category, id)`, independent of
directory spelling. Planned registrations need no directory or manifest and
cannot be selected or instantiated. Supported registrations require
`adapter.yml` and `adapter.rb` at their catalogue-declared directory.

The closed [manifest v1 schema](../schemas/adapter-manifest-v1.schema.json)
defines all required fields. This synthetic example is illustrative; it does
not register production support:

```yaml
schema_version: 1
id: sample
category: ecosystem
version: "1.0.0"
description: Synthetic ecosystem demonstration.
capabilities: [test]
detection_signals: [static_configuration]
contribution_domains: [commands, findings]
compatibility:
  requires: []
  incompatible: []
inputs: []
provider:
  file: adapter.rb
  constant: AgenticDeveloperSetup::Adapters::Providers::Sample
```

Manifest versions use numeric three-component SemVer, with optional valid
prerelease/build suffixes. Compatibility constraints name a category, a
non-empty `one_of` list of registered IDs, and optionally a RubyGems version
requirement, such as `">= 1.0, < 2.0"`. Requirements apply to **adapter versions**.
Build metadata does not affect version comparison. Planned references are valid
metadata but cannot satisfy a selected dependency. Missing references,
self-dependencies, contradictory requirements and invalid dependency cycles fail
registry validation. Alternative dependencies are evaluated as alternatives.

```ruby
registry = AgenticDeveloperSetup::Adapters::Registry.load(
  framework_root: framework_root
)
registry.entries                              # immutable, category/ID order
registry.fetch(category: "ecosystem", id: "sample") # definition or nil
registry.supported                            # excludes planned entries
provider = registry.provider(registry.supported.first)
```

Definitions expose `id`, `category`, `version`, `status`, `source_path`,
`manifest_digest`, `provider_digest`, `capabilities`, `contribution_domains`,
`compatibility`, `input_definitions`, and a plain-value `to_h`. Version and
digests are absent for planned entries. `make validate` checks supported
manifests and provider interfaces through this registry.

A provider class has a no-argument constructor and these public methods:

```ruby
module AgenticDeveloperSetup
  module Adapters
    module Providers
      class Sample
        def detect(context)
          # Return an array of candidate records, possibly empty.
          []
        end

        def contribute(context, inputs:)
          # Omitted domains are empty; unknown domains/fields are errors.
          {"commands" => [{
            "id" => "sample-test", "kind" => "base", "capability" => "test",
            "scope" => context.scope.fetch("path"),
            "argv" => ["sample-tool", "test"],
            "cwd" => context.scope.fetch("path"), "env" => {},
            "profiles" => ["standard"], "preconditions" => [],
            "classification" => ["automated_test"]
          }]}
        end
      end
    end
  end
end
```

Providers execute trusted framework-owned Ruby, not sandboxed third-party code.
Only catalogue-validated, contained, non-symlinked framework source is loaded.
The target repository's Ruby source is never loaded. Provider namespaces are
isolated per instantiation, while public framework helper constants remain
accessible. The context grants no target-code execution or mutation interface.

## Bounded evidence, scopes and selection

Context exposes:

- `scope`: selected `{ "type" => "repository", "path" => "." }` or explicit
  `{ "type" => "workspace", "path" => "apps/storefront" }`;
- `inventory.files`, `inventory.read(path)`, `inventory.exists?(path)`: read-only,
  bounded, repository-relative paths inside that scope;
- `generic_evidence`: the existing generic detector's static evidence;
- `add_evidence(type:, method:, summary:, path: nil)`: register evidence and
  obtain its stable ID;
- `selected`: selected category/ID records for contribution collection;
- `inputs`: the provider's explicitly supplied, validated non-secret inputs.

Inventory allowlists, read bounds, exclusions and Git ignore handling are reused
from `Assessment::Inventory`. Scope directories must exist, be normalised,
repository-relative, contained and free of symlink traversal. Excluded inventory
subtrees cannot be selected as workspaces. Paths in contributions and evidence
are repository-relative, including for workspace scopes.

Each candidate has exactly `category`, `id`, `scope`, `status`, `confidence`,
`evidence`, `ambiguities`, `incompatible_evidence`. Status is `detected`,
`not_detected` or `ambiguous`; confidence is `high`, `medium` or `low`. The last
three collections contain evidence IDs, all resolved in the result. Providers
may report a narrower workspace candidate, but cannot inspect outside the
requested scope or silently combine project roots. Candidate ordering and IDs
are deterministic. Evidence reuses the generic type/method/path/summary model
with content-derived stable references.

Only supported providers run. Generic Node/TypeScript/Python detection remains
available as evidence and cannot turn a planned adapter into supported code.
Dependency names alone do not authorise framework inference or selection.

The closed [selection v1 schema](../schemas/adapter-selection-v1.schema.json)
requires all five top-level fields:

```yaml
schema_version: 1
scope: {type: repository, path: .}
selected:
  - {category: ecosystem, id: sample, source: explicit}
inputs: []
resolutions: []
```

`explicit` selection can lack positive evidence; the assessment records that
uncertainty. `accepted_detection` is an explicit decision requiring a current,
matching candidate for the same category, ID and scope. Accepting an ambiguous
or negative candidate retains its uncertainty; no positive evidence is invented. Confidence
never accepts a candidate automatically. Unknown/planned adapters, duplicate
categories or identities, missing ecosystem, unsafe scopes, malformed inputs
and malformed resolutions are invocation errors.

Multiple independently configured roots or contradictory ecosystem markers
produce `scope_conflict`. Contradictory positive adapter evidence produces
`repository_evidence_conflict`. A narrower explicit workspace can resolve a
scope conflict. This version has no monorepo hierarchy or cross-scope graph.

## Compatibility and typed contributions

All selected adapters are checked against the complete set. Every `requires`
constraint needs one selected matching ID/version; a matching `incompatible`
constraint forbids the set. Missing or incompatible dependencies block the
result and cannot be waived. Checks record the originating adapter, constraint,
involved adapter versions and outcome.

The [assessment v1 schema](../schemas/adapter-assessment-v1.schema.json) closes
every contribution shape. Providers supply stable IDs; assessment attaches
immutable adapter category/ID/version, contribution ID and scope provenance.
IDs must be unique across a composition. Providers cannot forge provenance.

| Domain | Composition and authority |
| --- | --- |
| `findings` | Additive risks with severity, confidence, summary, evidence and related IDs; matching equivalence IDs deduplicate only identical substantive findings and retain all provenance/evidence |
| `commands` | Ecosystem base commands, framework specialised bases or refinements; runtime may add preconditions only |
| `command_wrappers` | Runtime only; structured prefix/suffix arguments, optional environment and cwd mapping |
| `validation_profiles` | Additive `fast`, `standard`, `extended` membership/emphasis, including app-shape emphasis |
| `paths` | Ecosystem/framework/runtime classifications and optional ownership; conservative union |
| `services` | Ecosystem/framework logical requirements; runtime bindings to named implementations |
| `requirements` | Runtime execution/secret requirements or app-shape risk requirements, without secret values |
| `inputs` | Typed declarations; ecosystem/framework/runtime only |
| `component_recommendations` | Ecosystem/framework/app-shape references to existing baseline component IDs, with rationale |
| `documentation_requirements` | Stable IDs and descriptions; additive, without semantic Markdown merging |

App-shape cannot supply command definitions, wrappers, paths, package-manager
choices or service implementations. Runtime cannot redefine base command
semantics, classification or package-manager choices. Framework refinement
cannot supply `argv`. Unsupported provider output is an error, never successful
composition.

Path classifications are `generated`, `cache_owned`, `sensitive`,
`migration_or_schema`, `framework_managed`, `protected`, and
`required_for_validation`. Recursive ancestor protections apply conservatively
to descendants. Ownership disagreement on overlapping paths blocks composition.
Choosing an owner cannot remove any protection and never changes permissions
or ignore files.

Logical service requirements identify `service_id` and required profiles;
runtime bindings identify `service_id` and `implementation`. A missing binding
is `unresolved_required_input`; incompatible bindings are
`service_binding_conflict`. Binding does not assert a service is running,
reachable or credentialled.

Manifest input declarations have namespace-qualified `key` (for example
`runtime/docker.service`), `type`, `required`, `description`, and optional
`allowed_values`/`default`. Types are `string`, `boolean`, `integer`,
`relative_path`. Explicit values live in selection `inputs`, not resolutions.
Required inputs need explicit values, even when defaults recommend a value.
Compatible declarations combine; conflicting definitions block. Providers only
receive validated explicit values declared in their manifest. No ambient
credentials are inspected. Secret material must never be supplied as an input;
secret needs belong in value-free requirements.

## Commands, conflicts and repository decisions

Base commands contain `id`, `kind: base`, semantic `capability`, scope path,
`argv`, `cwd`, structured `env`, profiles, preconditions and classification.
Refinements contain `id`, `kind: refinement`, `command_id`, profiles,
preconditions and classification. Runtime refinements can add only
preconditions. Wrappers contain `id`, `command_id`, `prefix_argv`,
`suffix_argv`, and optional `env`/`cwd`. All gain authoritative provenance.

There is no ordering-based precedence. Different command bases for one
scope/capability and multiple applicable wrappers are conflicts. Frameworks can
introduce a different capability without replacing a generic base. Final
commands retain base/refinement/profile/wrapper provenance, `wrapper_ids`,
`decision_source`, and `overridden_contribution_ids`.

Arguments remain ordered tokens, including spaces and punctuation. Wrappers
concatenate argument arrays only. Shell-evaluation forms such as `bash -c` are
rejected, including inside wrappers. `Shellwords.join(argv)` may render an
informational command, but is never an execution primitive. Environment keys
and values are validated; credential-like variables are rejected, conflicting
values block, and incompatible cwd mappings block. Paths and overrides receive
the same safeguards.

Every conflict records `id`, `code`, `domain`, scope, semantic subject,
severity/blocking, status, contributors, evidence IDs, description, permitted
resolutions and nullable applied resolution. Unresolved conflicts retain
`resolution: null`; resolved conflicts stay visible.

| Conflict codes | Resolution |
| --- | --- |
| `missing_required_adapter`, `incompatible_adapters`, `adapter_version_incompatible`, `unsupported_adapter` | Correct selection/metadata; no waiver (unsupported selection is rejected before composition) |
| `scope_conflict`, `repository_evidence_conflict` | Correct selection/evidence or narrow scope; no waiver |
| `duplicate_capability_ownership`, `incompatible_command_proposals` | `choose_command` or `override_command` |
| `command_wrapper_conflict` | `choose_wrapper` |
| `command_environment_conflict` | Correct structured proposals; no generic suppression |
| `path_ownership_conflict` | `choose_path_owner`, retaining all safety classifications |
| `input_definition_conflict`, `unresolved_required_input`, `service_binding_conflict` | Correct declarations, supply explicit inputs/binding; no generic suppression |
| `metadata_inconsistency`, `unsupported_contribution` | Correct metadata/provider output; malformed provider output is an error |

Resolutions have `conflict_id`, `kind`, closed `value`, and non-empty `rationale`.
`choose_command`/`choose_wrapper` values contain `contribution_id`;
`choose_path_owner` contains a declared `owner`; `override_command` contains a
complete validated `command`. Overrides retain scope and capability, identify
the explicit decision source, and retain overridden contributions. Unknown,
stale, duplicate, forbidden and inapplicable resolutions fail validation.
Unsafe paths, execution semantics, permissions and compatibility cannot be waived.

### Complete synthetic composition example

The tests construct real synthetic catalogues, manifests and provider files
outside the production registry. An ecosystem proposes:

```yaml
id: ruby-test
kind: base
capability: test
scope: .
argv: [bundle, exec, rspec]
cwd: .
env: {}
profiles: [standard]
preconditions: []
classification: [automated_test]
```

A framework proposes:

```yaml
id: rails-refinement
kind: refinement
command_id: ruby-test
profiles: [extended]
preconditions: [migration review]
classification: [integration_test]
```

An execution environment proposes a wrapper:

```yaml
id: docker-test
command_id: ruby-test
prefix_argv: [docker, compose, run, --rm, app]
suffix_argv: []
```

If a second wrapper conflicts, the repository decision references the actual
conflict ID emitted by assessment:

```yaml
# Place in selection.resolutions; copy the real conflict_id from the result.
conflict_id: "sha256:<64 hexadecimal characters from the reported conflict>"
kind: choose_wrapper
value: {contribution_id: docker-test}
rationale: Repository owner chose the isolated application service recommendation.
```

The final structured recommendation is:

```yaml
id: ruby-test
kind: base
capability: test
scope: .
argv: [docker, compose, run, --rm, app, bundle, exec, rspec]
cwd: .
env: {}
profiles: [extended, standard]
preconditions: [migration review]
classification: [automated_test, integration_test]
wrapper_ids: [docker-test]
# provenance retains ecosystem, framework and environment identities/versions.
# The visible resolved conflict retains the repository decision and rationale.
```

Run the real, deterministic examples with:

```sh
bundle exec ruby -Ilib -Itest test/adapters/composition_test.rb --name test_base_refinement_wrapper_end_to_end
bundle exec ruby -Ilib -Itest test/adapters/conflict_test.rb --name test_blocked_then_explicit_command_choice_without_mutation
bundle exec ruby -Ilib -Itest test/adapters/conflict_test.rb --name test_conflicting_wrappers_and_explicit_choice
```

The first validates the complete registry → detection → selection → compatibility
→ contributions → base/refinement/wrapper → schema-valid output sequence.
The others exercise blocked → explicit decision → ready without target mutation.

## Assessment, identity and compatibility boundary

```sh
ruby scripts/assess_adapters.rb TARGET
ruby scripts/assess_adapters.rb TARGET --selection selection.yml --output /outside/target/assessment.yml
make assess-adapters REPO=/path/to/repository
make test-adapters
```

Without a selection, status is `not_selected`, selected/contributions/final
commands are empty and digests are null. A selected set is `ready` only when
all mandatory checks, required inputs and blocking conflicts are satisfied;
otherwise it is `blocked`. Blocked output remains a valid informational result
(exit 0), not executable configuration or adoption approval. Invalid invocation,
registry/provider/schema or unsafe output errors exit nonzero.

The assessor returns an alias-free plain-value hash; CLI emits machine-readable
YAML to stdout or uses the existing generic assessor's atomic, revalidated
external-output writer. It writes no target files, Git state or adoption metadata.
The independent result includes framework identity, scope, candidates, selected
versions and source digests, compatibility checks, typed source contributions,
final composed `composition.commands`, validated `composition.explicit_inputs`,
conflicts, applied decisions and
self-contained evidence.

`Adapters::Composer.new(definitions:, scope:, contributions:, inputs: {},
resolutions: [], component_ids: [], evidence_ids: [], initial_conflicts: []).compose`
is independently usable with validated definitions and stamped contributions.
It performs no filesystem, subprocess or network operations. The assessor owns
filesystem validation before calling it.

Conflict IDs hash canonical code, scope, domain, semantic subject and contributing
adapter identities/versions. They exclude descriptions, absolute target paths,
timestamps and incidental ordering. Semantically unordered collections sort;
`argv` order remains meaningful.

The adapter-set digest hashes scope plus sorted identities/versions and exact
manifest/provider SHA-256 digests. The composition digest additionally hashes
normalised structured contributions, explicit inputs, validated resolutions and
final status. Both use `sha256:<64 lowercase hexadecimal characters>`. Generated
presentation text and volatile metadata are excluded. Source content changes
(including a manifest/provider change without a version bump) change adapter
identity. Digests establish identity, not authenticity or authorisation.

`registry.compare(previous_selected_record)` is a pure comparison against the
validated local registry and returns `unchanged`, `changed`, or `missing`.
A removed or no-longer-supported registration is missing. A change does not
mean newer, safe or eligible for adoption.

Framework metadata remains v2; generic assessment remains v2 with unchanged
output and fixtures. Adoption metadata, plans, decisions, application and
validation contracts remain v1. No adapter selection is inferred from adoption
metadata and no adapter contribution reaches the transaction engine. The new
selection/assessment schemas are independent v1 contracts. Adapter-aware
persistence, approvals, staleness and transactional application require a
separately specified versioned extension.

Production adapters, automatic selection/adoption, target execution, shell
scripts, service startup, dependency installation, credentials, cross-scope
composition, coding-agent runtime integration and Markdown merging are outside
this implementation. Downstream ecosystem adapters can register a supported
manifest/provider and implement these public interfaces without changing the
composition engine.
