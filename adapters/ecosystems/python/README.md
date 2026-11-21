# Python ecosystem adapter

**Manifest schema v1 · ecosystem/python · provider version 1.0.0**

The Python adapter assesses one repository or explicitly selected workspace
using the ADS Ruby bundle. It contributes evidence, findings, command
recommendations, validation profiles and path classifications through the
[standard adapter contract](../../../docs/adapter-architecture.md). Framework
and runtime adapters own application-specific operations, service provisioning
and deployment. Python interpreters and target dependencies are unnecessary for
assessment and adoption.

## Support matrix

| Surface | Detected | Assessed | Command recommendation supported | Separately verified execution | Unsupported or deferred |
| --- | --- | --- | --- | --- | --- |
| uv | Project configuration and lockfile | Manager version policy, package-mode setting and environment signals | Explicit supported `uv run` or `uv build`, including approved literal `run` flags | Unverified | Lock verification, interpreter provisioning, sync and migration |
| Poetry | Relevant project tables and lockfile | Legacy dependency and Python policy, manager version and package mode | Explicit supported `poetry run` or `poetry build` | Unverified | Dependency resolution, plugins and migration |
| pip and requirements | `requirements*.txt` | Literal dependency names, editable and alternate index evidence | Existing explicit validation through the supported local command surfaces | Unverified | Includes, option evaluation, index access and installation |
| pip-tools | `requirements*.in` and compiled headers | Input and compiled requirements conventions | Existing explicit validation commands | Unverified | Compile, sync and freshness |
| PDM | Project configuration, scripts and lockfile | PEP 621 interpreter policy, distribution setting and bounded `cmd` tasks | `pdm run <task>` for supported tasks and explicit supported tool/build invocations | Unverified | Shell, call, composite, shared settings, hooks and plugins |
| Hatch | Project configuration, environments and build metadata | Literal environment Python selectors and bounded scripts | `hatch run <env>:<task>` for supported named environments and explicit supported tool/build invocations | Unverified | Matrices, plugin or template behaviour, and standalone Hatch config |
| setuptools and PEP 517 | Static backend, `setup.cfg`, `setup.py` presence | Build intent, supported package declarations and executable hooks | Existing explicit build and validation through supported local commands | Unverified | Dynamic metadata, imports, builds and installation |
| Test, lint, format and typing | Named dependency and configuration evidence | Separate declaration, directory, local invocation and literal CI evidence | Explicit supported pytest, unittest, Tox, Ruff, Black, isort, Flake8, Pylint, mypy, Pyright and basedpyright invocations | Unverified | Nox session interpretation, arguments beyond the supported subset, results and coverage |
| Make, Task and shell wrappers | Allowlisted configuration and wrapper paths | Literal task definitions and explicit references | Supported exact task identities and named local wrappers | Unverified | Shell evaluation, opaque recipes and unsupported runner directives |
| GitHub Actions | Scoped workflow files | Literal configured Python versions, commands and visible service or credential requirements | Local commands can be corroborated by CI | Unverified | CI-only recommendations, matrix execution, external actions and reusable workflows |

## Detection, scope and static reads

Valid project names, recognised build backend declarations, static setuptools
metadata and interpretable requirements provide positive evidence. Executable
`setup.py` provides a lower-confidence legacy signal. A manifest without
recognised Python project fields, a lockfile alone or a lone tool marker can
remain ambiguous. Arbitrary Python source files are outside the inventory.

ADS retains repository and explicit workspace scope. Multiple independent
roots use the generic `scope_conflict`. Contradictory ecosystem evidence
uses the existing conflict rules, including a Python project alongside
`package.json` in one scope. Workspace assessment starts a fresh inventory
and excludes other workspaces and parent configuration.

The scoped inventory applies a 256 KiB cap per content read and requires valid
UTF-8 for interpretation. It keeps Git tracked/ignored-file handling, excludes
known environment, cache, vendor and output trees, and checks symlink
ancestors. `setup.py`, `noxfile.py`, allowlisted shell wrappers and known
coverage output identifiers provide presence evidence. A `src`, `tests`
or `test` directory can be observed without enumerating its contents.

`pyproject.toml` uses the pinned pure-Ruby [tomlrb 3.0.0 parser](https://rubygems.org/gems/tomlrb/versions/3.0.0)
in TOML 1.0 mode. Ruby's standard library has no TOML interpreter. The gem has
no additional runtime gem dependencies and implements duplicate-key rejection.
ADS caps interpreted TOML depth at 48 and withholds dependent recommendations
for invalid encoding, duplicate keys, malformed documents and unsupported
policy shapes. Update the pin and lockfile with `bundle lock --update tomlrb`,
review the dependency diff, and run the tests with the bundle installed.
`bundle lock --local` and `bundle install --local` work from the local
cache. `make check` runs offline with the installed bundle.

The legacy INI subset covers literal section headers, assignments, indented
continuations and whole-line comments. It rejects repeated sections and
options and treats interpolation and nonliteral command values as unresolved.
Requirements interpretation covers common PEP 508 name/specifier lines and
value-free editable, alternate index and platform signals. Includes and unusual
forms are reported with limited interpretation. Workflow and Taskfile YAML use
bounded, duplicate-key-checked safe loading without aliases. The adapter
does not resolve inherited config, read environment variables or follow
dependency sources.

## Interpreter, manager and layout policy

Interpreter evidence is labelled by role. Compatibility declarations come
from `project.requires-python`, `tool.poetry.dependencies.python` and
`setup.cfg` `options.python_requires`. Local selection comes from
`.python-version`. Supported Tox and Hatch environment fields provide separate
interpreter evidence. GitHub Actions contributes quoted literal
`actions/setup-python` versions and simple literal `python-version` matrix axes
as configured coverage.

Numeric three-component exact pins can be compared directly, including `==`
compatibility pins. Two-component versions, ranges, wildcards, alternative
interpreters and unsupported syntax stay unresolved for compatibility
comparison. Known conflicts between exact compatibility and local policy
withhold native recommendations. CI selection differences remain advisory
findings. Installed interpreter versions and successful matrix coverage are
unverified.

Primary manager signals are `uv.lock`, `poetry.lock`, `pdm.lock`, explicit
supported `tool.uv.required-version` or `tool.poetry.requires-poetry` policy,
and legacy Poetry project dependency policy. Different primary managers, a
reviewed choice conflicting with primary policy, or an explicit uv project
management opt-out with uv policy produce review findings and withhold commands.
Tool sections alone can coexist with primary policy. Without primary policy a
single configured PDM/Hatch task surface can identify the runner. Otherwise
recognised requirements conventions identify pip/pip-tools where no active
managed settings remain unresolved. A lock establishes a locking convention.
Manager identity, manager version constraints, lock validity and installed
dependencies are separate states.

The optional `ecosystem/python.package_manager` input accepts `uv`, `poetry`,
`pip`, `pip-tools`, `pdm` and `hatch`. It lets the repository owner review
a choice in the absence of primary evidence. Generic selection rejects
unknown or credential-bearing input values. CI and documentation corroborate
operational workflows. They provide no override of primary manager policy.

A `src` directory or literal setuptools package search metadata can identify
a likely layout. Explicit root searches, single-module declarations and
namespace settings provide more specific hints. Distribution intent comes from
packaging or build metadata, while uv/Poetry/PDM packaging opt-outs can
suggest application or dependencies-only use. Entry point declarations and
recognised server dependencies are CLI or service signals. Exact import
roots, namespace membership, dynamic entry points and deployment
architecture remain unresolved.

## Native commands and review

Recognised capabilities are test, lint, format check, type check, build and
aggregate verify. Each recommendation requires an explicit supported
invocation and retains its repository-relative working directory and
structured arguments. Different eligible invocations for one capability
are passed to the generic composer for conflict resolution.

- **Make.** One recognised Makefile with literal named targets, simple
  recipes containing recognised commands, and aggregate targets with explicit
  eligible prerequisites. Includes, substitutions and unsupported directives
  withhold recommendations.
- **Task.** One version 3 `Taskfile.yml` or `Taskfile.yaml` with literal
  `cmds` and no includes or shared execution settings.
- **PDM and Hatch.** Supported `cmd` definitions and named environment
  scripts retain `pdm run <task>` and `hatch run <env>:<task>`. Supported
  task contents use recognised literal validation commands. Hatch environment
  substitutions, matrices and install hooks, and PDM hook/shared settings
  require review outside this subset.
- **Tox and Nox.** Supported `tox.ini` `[testenv:<name>]` definitions
  can supply `tox -e <name>`. Recognised option names and literal command
  bodies are required. Nox is presence evidence.
- **Documentation and wrappers.** An entire inline code command or a
  literal line in a recognised shell fence can corroborate or supply an
  explicit invocation. Referenced runner tasks must exist. Recognised
  `./scripts/<task>.sh` wrappers must be present. Wrapper bodies are opaque.
- **Tools.** The literal subset supports `pytest`, `python -m unittest`,
  `python -m pytest`, `ruff check`, `ruff format --check`, `black --check`,
  `isort --check-only`, Flake8, Pylint, the supported type checkers and
  `python -m build` with bounded flags and relative arguments. A known
  managed environment requires a supported repository-native wrapper or
  an eligible runner environment. A dependency or console entrypoint alone
  does not establish a development task.

A command suggestion can invoke arbitrary project-controlled code if it is
separately executed. Shell evaluation, credential-bearing forms and known
mutating actions are withheld. Review must cover task contents, environment
initialisation, dependencies, side effects and service requirements. Setup,
editable installs, explicit indexes, platform-specific dependencies and
migration or generator evidence are findings for that review.

`fast` and `standard` can group eligible lint and format checks, `standard`
can include tests and type checks, and `extended` can include eligible builds.
Tox, aggregate verification and known stateful, service-dependent or
credential-dependent validation stay outside the suggested profiles. Profiles
express advisory grouping. Cost, coverage and execution approval are
unverified.

Simple GitHub Actions commands are matched by literal arguments and working
directory. The report distinguishes local-only, CI-only, apparent alignment
and incomplete interpretation. Matching invocations can run in different
environments. Expressions, shell-dependent and reusable jobs, and matrix
expansion are outside the comparison. Visible service and credential
requirements appear without their values. The adapter leaves target CI intact.

Python environment and tool-cache directories are classified when their
presence is observable. Packaging and coverage evidence can justify
conventional build, distribution and coverage output classifications. The
adapter assigns no operational owner or migration path. Custom generated
paths and ignore-file changes need review outside this implementation.

## Complete reviewed adoption example

Use a clean, committed ADS source containing the Python adapter and an
installed ADS Ruby bundle. Run from that source. The following creates a
disposable fixture and keeps review and transaction files beside it.

```sh
ads_source="$(pwd -P)"
demo="$(mktemp -d)"
target="$demo/target"
mkdir -p "$target/tests"
git -C "$target" init -q
cat > "$target/pyproject.toml" <<'TOML'
[project]
name = "ads-python-example"
version = "0.1.0"
requires-python = ">=3.12,<3.14"

[dependency-groups]
dev = ["pytest>=8"]

[tool.uv]
required-version = ">=0.8"
package = false
TOML
printf '3.12.4\n' > "$target/.python-version"
printf 'test:\n\tuv run pytest -q\n' > "$target/Makefile"
cat > "$target/tests/test_example.py" <<'PYTHON'
from pathlib import Path

def test_example():
    Path("python-executed").touch()
PYTHON
git -C "$target" add .
git -C "$target" -c core.hooksPath=/dev/null \
  -c user.name="ADS public example" -c user.email=ads@example.invalid \
  commit -qm "Create synthetic uv fixture"
git -C "$target" status --porcelain

bundle exec ruby scripts/assess_adapters.rb "$target" --output "$demo/detected.yml"
cat > "$demo/selection.yml" <<'YAML'
schema_version: 1
scope:
  type: repository
  path: .
selected:
  - category: ecosystem
    id: python
    source: explicit
inputs: []
resolutions: []
YAML
bundle exec ruby scripts/assess_adapters.rb "$target" \
  --selection "$demo/selection.yml" --output "$demo/assessed.yml"
cat "$demo/assessed.yml"
```

Review the findings and confirm the only proposed command is `make test` at
`.`. Copy its command ID from `composition.commands` into the decisions
document, replacing `REPLACE_WITH_REVIEWED_COMMAND_ID`.

```sh
cat > "$demo/decisions.yml" <<'YAML'
schema_version: 1
selection_reviewed: true
adapter_changes: []
commands:
  - command_id: REPLACE_WITH_REVIEWED_COMMAND_ID
    disposition: approve
    reviewed: true
    rationale: Reviewed the synthetic make test binding and its repository scope.
components: []
retained_files: []
YAML
bundle exec ruby scripts/manage_adoption.rb plan "$target" \
  --operation adopt_adapters --framework-source "$ads_source" --scope . \
  --adapter-selection "$demo/selection.yml" --adapter-decisions "$demo/decisions.yml" \
  --effective-date 2026-11-21 --output "$demo/plan.yml"
bundle exec ruby scripts/manage_adoption.rb preview "$demo/plan.yml"
bundle exec ruby scripts/manage_adoption.rb check "$demo/plan.yml"
bundle exec ruby scripts/manage_adoption.rb apply "$demo/plan.yml" --dry-run
git -C "$target" status --porcelain
```

Review the preview and replace `sha256:REPLACE_WITH_REVIEWED_PLAN_ID` with
the exact approved plan ID. The decision and plan approval persist binding
metadata. Executing the command requires separate authorisation.

```sh
bundle exec ruby scripts/manage_adoption.rb apply "$demo/plan.yml" \
  --accept-plan-id sha256:REPLACE_WITH_REVIEWED_PLAN_ID --result "$demo/result.yml"
bundle exec ruby scripts/inspect_adoption.rb "$target" --framework-source "$ads_source"
cat "$demo/result.yml"
cat "$target/.agent-framework/adoption.yml"
git -C "$target" status --porcelain
test ! -e "$target/python-executed"
test ! -e "$target/.venv"
```

The result should be `applied_unvalidated` with verified metadata. The
metadata records the framework source, explicit Python adapter identity and
version, scope, reviewed inputs, command binding and provenance. The only
target file added is the ADS ownership metadata.

Negative cases are exercised in
[the synthetic transaction tests](../../../test/adoption/python_transaction_test.rb).
An unknown command ID is refused during planning. Conflicting manager
evidence can leave a metadata-only route. Independent project roots block
application until a valid scope is chosen. Changed decision/selection bytes or
drift in the committed provider prevent use of the previous plan. See the
[generic adoption workflow](../../../docs/adoption-workflow.md#adapter-adoption-and-reviewed-updates-v2)
for exact-plan validation, application and update semantics.

## Fixture and requirement traceability

The fixtures use public synthetic data. Run `make test-adapters` and
`make test-adoption` with the ADS Ruby bundle. The Python assessment suite
covers F01–F22 and the CLI transaction suite covers F22–F24, including
execution interception, exact acceptance, metadata verification and drift.

| Original #12 requirement | Disposition |
| --- | --- |
| FR-01 to FR-04 registration, inventory, Python project detection and static configuration | Python provider, scoped generic inventory and bounded TOML/INI/YAML interpretation |
| FR-05 to FR-07 interpreter, dependency managers, package and application layout | Python provider supports literal evidence and exact-pin comparisons. Full constraint solving, dynamic metadata and source enumeration are outside the subset. |
| FR-08 to FR-10 native commands, validation tools and local/CI comparison | Python provider supports the documented command and CI subset. Generic command composition handles competing proposals. |
| FR-11 to FR-13 paths, risk findings and validation profiles | Python provider contributes typed conventional paths, risks and advisory profiles. Custom output discovery and operational ownership are deferred. |
| FR-14 to FR-15 selection, provenance, adoption and update | Existing ADS contracts supply reviewed inputs and bindings, exact-plan authority, snapshots, stale-plan rejection and durable metadata. |
| SI-01 to SI-06 non-executing assessment, bounded evidence, non-secret inputs, ambiguity and regression | Python provider uses the inventory, typed contracts and synthetic negative tests. Generic plumbing preserves scope, provenance and reviewed authority. |
| Runtime provisioning, services, migrations, framework-specific generation and deployment | Deferred to framework and runtime adapters. |
| Application scaffolding, dependency migration, orchestration and agent telemetry | Outside the revised issue scope. |

## Public technical references

- [TOML 1.0 specification](https://toml.io/en/v1.0.0)
- [Python packaging project metadata](https://packaging.python.org/en/latest/specifications/pyproject-toml/)
- [uv project settings](https://docs.astral.sh/uv/reference/settings/)
- [Poetry project configuration](https://python-poetry.org/docs/pyproject/)
- [Pip requirements file format](https://pip.pypa.io/en/stable/reference/requirements-file-format/)
- [PDM scripts](https://pdm-project.org/en/latest/usage/scripts/)
- [Hatch environments](https://hatch.pypa.io/latest/environment/)
- [Tox configuration](https://tox.wiki/en/latest/config.html)
- [GitHub Actions workflow syntax](https://docs.github.com/actions/reference/workflows-and-actions/workflow-syntax)
