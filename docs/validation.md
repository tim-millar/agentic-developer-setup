# Framework self-validation

This repository validates its own schema-v2 metadata and the framework source structure before those inputs are used for adoption, audit, or assessment work. Validation is deterministic and applies to this framework source repository, not to an instantiated downstream repository. Schema v1 is no longer accepted.

The validation surface depends on the root self-hosted harness and review policy/handoff used by this repository. In particular, root `AGENTS.md`, `REVIEW.md`, `.ruby-version`, `Gemfile`, `Gemfile.lock`, `lefthook.yml`, `docs/AGENT_PROMPT.txt`, `scripts/run_codex.sh`, `scripts/agent_host_env.sh`, and `.github/PULL_REQUEST_TEMPLATE.md` must exist as repository-operational files.

## Requirements and commands

Local development requires GNU Make, the exact Ruby declared by `.ruby-version`, currently `ruby-3.3.12`, and Bundler. If the Ruby declaration changes, it remains the only repository-owned Ruby-version requirement. Ruby development dependencies are declared in `Gemfile` and their exact resolutions are committed in `Gemfile.lock`.

Prepare the local Ruby environment and install the root Git hooks with:

```sh
make setup
```

`make setup` runs `bundle install` and `bundle exec lefthook install`. Validation commands do not install dependencies.

Check maintained Ruby code without modifying files:

```sh
make lint
```

Apply Standard Ruby's safe mechanical formatting explicitly with:

```sh
make format
```

Run the live metadata and repository validator inside the locked bundle:

```sh
make validate
```

Run all deterministic root tests inside the locked bundle:

```sh
make test
```

`make test` discovers every sorted `test/**/*_test.rb` file, including validator tests and any focused root-wrapper tests.

Run only the focused Claude runtime tests with:

```sh
make test-claude-runtime
```

Run the authoritative local and CI sequence—lint, tests, then validation of the live repository—with:

```sh
make check
```

The public validator entrypoint is `scripts/validate_framework.rb`. It resolves the repository root from its own location, so it can be invoked from another working directory either directly or with Ruby.

The focused Ruby targets use the same bundle:

```sh
make test-launcher
make test-claude-runtime
make test-assessment
```

The repository-assessment script also remains a direct public entrypoint:

```sh
ruby scripts/assess_repository.rb TARGET
```

That direct assessor contract uses only its intended Ruby/stdlib dependencies. The root `make assess REPO=TARGET` wrapper may run it inside the development bundle, but the assessor library does not depend on Standard, Lefthook, or Bundler at runtime.

Git hooks use the same Make surface as local validation. Pre-commit runs `make lint`; pre-push runs `make check`. CI does not install Lefthook and runs `make check` directly after `ruby/setup-ruby` installs or caches the committed bundle.

## What is validated

Validation has three distinct responsibilities:

1. **Schema and type validation** checks schema version 2, required and unknown fields, exact object shapes, scalar and collection types, non-empty values, closed status values, runtime distributions and roles, configuration discriminators, and uniqueness rules.
2. **Semantic and cross-reference validation** checks declared relationships among baseline artefacts, supported runtimes, issue templates, adoption tiers, and adapter taxonomy entries.
3. **Filesystem and repository-structure validation** checks repository-local source paths, supported implementations, symlink containment, and the minimum root structure required to interpret and operate the framework.

The validator reports all independent errors that remain safe to evaluate. Diagnostics are written to standard error, start with `ERROR:`, and are sorted deterministically. Invalid metadata exits with status 1 and ordinary metadata failures do not produce stack traces. Successful validation exits with status 0 and prints `Framework validation passed.`

YAML parse failures stop validation because later diagnostics would not be reliable.

## Source, target, and root paths

A concrete `source_path` identifies an artefact inside this framework source repository. It must be a safe, relative, repository-contained path and must resolve to the expected file or directory type. A concrete `target_path` identifies where the artefact is intended to land in an adopted repository. It receives relative-path syntax validation but is never required to exist here. Repository-distributed runtime artefacts may declare target paths where applicable; global-user runtime artefacts prohibit them.

Only metadata fields explicitly defined as concrete paths are resolved. Descriptive values under `path_conventions`, adapter taxonomy patterns, convention command strings, and other prose-like path concepts are not treated as repository files.

The root self-hosted harness and the distributable baseline are separate layers:

- root `AGENTS.md`, `REVIEW.md`, `.ruby-version`, `Gemfile`, `Gemfile.lock`, `lefthook.yml`, `docs/AGENT_PROMPT.txt`, `scripts/run_codex.sh`, `scripts/agent_host_env.sh`, and `.github/PULL_REQUEST_TEMPLATE.md` operate this repository;
- `baseline/AGENTS.md`, `baseline/REVIEW.md`, `baseline/docs/AGENT_PROMPT.txt`, and `baseline/scripts/run_codex.sh` are reusable source artefacts declared by `framework.yml`;
- matching root target-like paths do not satisfy, shadow, or alter a declared baseline `source_path`.

`REVIEW.md` is the canonical repository-owned review policy. The root file is
specialised for this framework source repository and is required by its
self-hosted structure check; `baseline/REVIEW.md` is a generic recommended
component that adopters may copy to the declared target path and specialise.
The root policy and baseline policy are intentionally not required to have
identical prose. `.github/PULL_REQUEST_TEMPLATE.md` remains a separate
author-to-reviewer evidence handoff.

The root `scripts/agent_host_env.sh` hook validates before Codex starts that the inherited host `PATH` resolves the exact Ruby version declared by `.ruby-version`. It validates the environment only: it does not select or install Ruby, invoke a version manager, or modify `PATH`. Developers must prepare the host shell/toolchain before launching a self-hosted Codex session.

The validator derives baseline, prompt, runtime, and issue-template artefact checks from `framework.yml`; it does not maintain a duplicate hard-coded inventory of distributable artefacts.

Planned adapter paths are canonical intended implementation locations, so their directories are not required to exist. Supported adapter paths must exist as directories. Supported runtime source artefacts must exist and every supported runtime has exactly one launcher. Claude Explore additionally has exactly one installer and policy; Codex retains its single prompt relationship. Planned runtimes declare identity and description only.

## Extending validation

When adding a schema field:

1. update `framework.yml` and the explicit schema-v2 shape in `scripts/validate_framework.rb` together;
2. decide whether the field is descriptive or a concrete source or target path;
3. document any new type, closed set, uniqueness rule, or relationship;
4. add focused valid and invalid fixture scenarios in `test/framework_validation_test.rb`;
5. run `make check`.

Adding a schema-controlled field changes the public metadata contract and should have explicit task-level authorisation. Unknown fields intentionally fail until the validator recognizes them.

When adding a semantic rule, keep it separate from object shape and type checks. Run it only after the fields it needs have usable types, name the explicit metadata relationship it enforces, and cover both matching and failing references with isolated fixture tests.

Each test scenario should mutate or remove only the minimum fixture state needed, invoke the public validator script, and assert exit status plus meaningful diagnostic content. Temporary fixtures must not modify the checkout, depend on test order, access the network, or leave files behind.

## Intentional exclusions

Schema version 2 deliberately does not validate these incidental or future relationships:

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

After `make setup` has completed, `make lint`, `make test`, `make validate`, `make test-claude-runtime`, and all stages of `make check` initiate no network access and require no real AI model, Codex or Claude process, GitHub credentials, GitHub App, database, secrets, or external service. The Claude suite installs the runtime only into disposable test homes and uses synthetic executables. GitHub Actions uses normal checkout and Ruby setup with Bundler caching before it runs the same `make check` command used locally.
