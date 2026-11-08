# Adapters

Adapters provide versioned, evidence-backed recommendations for one repository
scope. The implemented registry, provider interface, compatibility checks,
structured composition, explicit conflict resolution and read-only assessment
are documented in [the adapter architecture](../docs/adapter-architecture.md).

`framework.yml` remains authoritative for identities, categories, paths and
support status. **All named production adapters remain planned.** Supported
executable demonstrations exist only in `test/adapters/` synthetic fixtures.
Generic Node/TypeScript/Python detection does not confer supported adapter status.

| Category | Source path | Responsibility |
| --- | --- | --- |
| `ecosystem` | `adapters/ecosystems/<name>` | Language, package manager and generic tooling |
| `framework` | `adapters/frameworks/<name>` | Application-framework conventions and specialised validation |
| `runtime` | `adapters/runtimes/<name>` | Application execution environment, services and command wrapping |
| `app-shape` | `adapters/app-shapes/<name>` | Architecture, validation emphasis, documentation and risks |

Use **application execution environment** or environment adapter in prose;
`runtime` remains the canonical machine category. Coding-agent runtimes and
the host toolchain are separate concerns. An ecosystem selection alone never
requires its language runtime on the coding-agent host.

Implemented adapters require `adapter.yml` (closed manifest schema v1) and
trusted framework-owned `adapter.rb` implementing `detect(context)` and
`contribute(context, inputs:)`. Planned adapters need neither file. Registry
validation rejects unsafe source paths, invalid metadata, compatibility
references and provider interfaces.

Detection supplies candidates and evidence. Explicit selection supplies one
ecosystem and zero or one of each other category for a repository or workspace
scope. No adapter is accepted automatically. Contributions retain provenance;
material conflicts block composition until resolved through a permitted explicit
repository decision. There is no last-adapter-wins rule.

```sh
ruby scripts/assess_adapters.rb /path/to/repository
ruby scripts/assess_adapters.rb /path/to/repository --selection selection.yml
make assess-adapters REPO=/path/to/repository
make test-adapters
```

Commands remain structured argument vectors and are never executed. Assessment
recommendations do not modify baseline components, repository commands,
permissions, files, adoption plans or ownership metadata. Adapter-aware
transactional adoption is reserved for a separately versioned follow-on task.

Provider candidates can establish independent project roots without conventional
marker files. Manifest and selection YAML reject duplicate mapping keys.
Non-secret input validation and exact provider namespace ownership apply before
contribution collection and during direct composition. Recognised credential
formats are rejected without disclosure; this is not a guarantee that every
arbitrary secret can be identified. Resolved path ownership exposes one
effective owner while retaining original claims and resolution provenance.
Provider lifecycle failures identify the adapter and phase without exposing
arbitrary exception text. See the adapter architecture for details and limits.
