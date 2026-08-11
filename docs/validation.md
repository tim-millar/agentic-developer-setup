# Framework self-validation

This repository validates its own schema-v1 metadata and the framework source structure before those inputs are used for adoption, audit, or assessment work. Validation is deterministic and applies to this framework source repository, not to an instantiated downstream repository.

The validation surface depends on the root self-hosted harness and review handoff used by this repository. In particular, root `AGENTS.md`, `docs/AGENT_PROMPT.txt`, `scripts/run_codex.sh`, and `.github/PULL_REQUEST_TEMPLATE.md` must exist as repository-operational files.

## Requirements and commands

Local validation requires GNU Make and Ruby 3.3. It uses Ruby's standard YAML/Psych, Minitest, filesystem, and pathname libraries; Bundler and third-party gems are not required.

Run the live metadata and repository validator:

```sh
make validate
```

Run all deterministic root tests:

```sh
make test
```

`make test` discovers every sorted `test/**/*_test.rb` file, including validator tests and any focused root-wrapper tests.

Run the authoritative local and CI sequence—tests first, then validation of the live repository—with:

```sh
make check
```

The public validator entrypoint is `scripts/validate_framework.rb`. It resolves the repository root from its own location, so it can be invoked from another working directory either directly or with Ruby.

## What is validated

Validation has three distinct responsibilities:

1. **Schema and type validation** checks schema version 1, required and unknown fields, exact object shapes, scalar and collection types, non-empty values, closed status values, and uniqueness rules.
2. **Semantic and cross-reference validation** checks declared relationships among baseline artefacts, supported runtimes, issue templates, adoption tiers, and adapter taxonomy entries.
3. **Filesystem and repository-structure validation** checks repository-local source paths, supported implementations, symlink containment, and the minimum root structure required to interpret and operate the framework.

The validator reports all independent errors that remain safe to evaluate. Diagnostics are written to standard error, start with `ERROR:`, and are sorted deterministically. Invalid metadata exits with status 1 and ordinary metadata failures do not produce stack traces. Successful validation exits with status 0 and prints `Framework validation passed.`

YAML parse failures stop validation because later diagnostics would not be reliable.

## Source, target, and root paths

A concrete `source_path` identifies an artefact inside this framework source repository. It must be a safe, relative, repository-contained path and must resolve to the expected file or directory type. A concrete `target_path` identifies where the artefact is intended to land in an adopted repository. It receives relative-path syntax validation but is never required to exist here.

Only metadata fields explicitly defined as concrete paths are resolved. Descriptive values under `path_conventions`, adapter taxonomy patterns, convention command strings, and other prose-like path concepts are not treated as repository files.

The root self-hosted harness and the distributable baseline are separate layers:

- root `AGENTS.md`, `docs/AGENT_PROMPT.txt`, `scripts/run_codex.sh`, and `.github/PULL_REQUEST_TEMPLATE.md` operate this repository;
- `baseline/AGENTS.md`, `baseline/docs/AGENT_PROMPT.txt`, and `baseline/scripts/run_codex.sh` are reusable source artefacts declared by `framework.yml`;
- matching root target-like paths do not satisfy, shadow, or alter a declared baseline `source_path`.

The validator derives baseline, prompt, runtime, and issue-template artefact checks from `framework.yml`; it does not maintain a duplicate hard-coded inventory of distributable artefacts.

Planned adapter paths are canonical intended implementation locations, so their directories are not required to exist. Supported adapter paths must exist as directories. The same supported-versus-planned distinction applies to runtime implementation metadata as defined by schema version 1.

## Extending validation

When adding a schema field:

1. update `framework.yml` and the explicit schema-v1 shape in `scripts/validate_framework.rb` together;
2. decide whether the field is descriptive or a concrete source or target path;
3. document any new type, closed set, uniqueness rule, or relationship;
4. add focused valid and invalid fixture scenarios in `test/framework_validation_test.rb`;
5. run `make check`.

Adding a schema-controlled field changes the public metadata contract and should have explicit task-level authorisation. Unknown fields intentionally fail until the validator recognizes them.

When adding a semantic rule, keep it separate from object shape and type checks. Run it only after the fields it needs have usable types, name the explicit metadata relationship it enforces, and cover both matching and failing references with isolated fixture tests.

Each test scenario should mutate or remove only the minimum fixture state needed, invoke the public validator script, and assert exit status plus meaningful diagnostic content. Temporary fixtures must not modify the checkout, depend on test order, access the network, or leave files behind.

## Intentional exclusions

Schema version 1 deliberately does not validate these incidental or future relationships:

- prompt IDs do not need to equal usage-mode IDs;
- adoption tiers do not need disjoint artefact sets;
- baseline categories are not a globally closed enum;
- planned adapter directories do not need to exist;
- planned runtimes do not declare launcher or prompt implementations;
- descriptive `path_conventions` values are not concrete paths;
- conventional Make target strings are not checked against root or baseline Makefiles;
- documentation links and file contents are not checked;
- runtime launcher behaviour and executable permissions are not inspected;
- root self-hosted files are not inferred to be distributable baseline sources.

## Offline boundary

`make validate`, `make test`, and the test/validator stages of `make check` initiate no network access and require no AI model, Codex process, GitHub credentials, GitHub App, secrets, or external service. GitHub Actions may use normal checkout and Ruby setup before it runs the same `make check` command used locally.
