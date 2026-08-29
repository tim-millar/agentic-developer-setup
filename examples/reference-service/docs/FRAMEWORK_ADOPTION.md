# Framework adoption walkthrough

## 1. Purpose

This directory is a concrete, repository-shaped manual adoption of the public
agentic developer setup framework. It shows how selected framework artefacts
are specialised for a small synthetic task registry, then connected to native
Python tooling, a stable Make interface, tests, CI, and an agent-ready
repository contract.

This is a selected greenfield reference adoption. It is reference material,
not a universal project template or a production service.

## 2. Fixture versus standalone repository

`examples/reference-service/` models the root of an adopted repository while
remaining an ordinary source-controlled directory inside this framework
repository. It is not a nested Git repository and contains no nested `.git`
state.

The nested `.github/workflows/ci.yml` represents the workflow the target
repository would use if materialised as its own repository. GitHub will not
discover or execute that nested workflow as part of this framework repository's
workflow discovery. Later tooling may copy the fixture into a temporary
standalone Git repository when actual repository-level Git semantics are
needed.

## 3. Framework source → fixture target mapping

The following mappings use the source/target relationships declared in the
live `framework.yml`; this example does not register itself as framework
metadata:

| Framework source | Fixture target |
| --- | --- |
| `baseline/AGENTS.md` | `AGENTS.md` |
| `baseline/Makefile` | `Makefile` |
| `baseline/docs/ARCHITECTURE.md` | `docs/ARCHITECTURE.md` |
| `baseline/docs/DEVELOPMENT.md` | `docs/DEVELOPMENT.md` |
| `baseline/docs/DOMAIN.md` | `docs/DOMAIN.md` |
| `baseline/docs/TESTING.md` | `docs/TESTING.md` |
| `baseline/.github/PULL_REQUEST_TEMPLATE.md` | `.github/PULL_REQUEST_TEMPLATE.md` |
| `baseline/.github/ISSUE_TEMPLATE/agent-ready-implementation.md` | `.github/ISSUE_TEMPLATE/agent-ready-implementation.md` |
| `baseline/.github/ISSUE_TEMPLATE/bug-report.md` | `.github/ISSUE_TEMPLATE/bug-report.md` |
| `baseline/.github/ISSUE_TEMPLATE/discovery-or-shaping.md` | `.github/ISSUE_TEMPLATE/discovery-or-shaping.md` |
| `baseline/.github/ISSUE_TEMPLATE/config.yml` | `.github/ISSUE_TEMPLATE/config.yml` |
| `baseline/.github/workflows/ci.yml` | `.github/workflows/ci.yml` |

`README.md` and `docs/FRAMEWORK_ADOPTION.md` are fixture-specific additions,
not baseline components.

## 4. Minimally changed artefacts

The pull-request template, issue-template chooser, and the three issue
templates retain the baseline framework's review, readiness, defect, and
discovery roles. Their wording is shortened or made specific to this fixture's
task-registry scope rather than copied without project-specific detail.

## 5. Specialised artefacts

Every adopted document is specialised enough to describe this repository:

- `domain.py`, `DOMAIN.md`, and the domain tests define the task registry's exact invariants.
- `ARCHITECTURE.md` records the three-module boundary and the in-memory persistence choice.
- `DEVELOPMENT.md` and `Makefile` bind the shared command concept to Python 3.14, uv, and the locked tools.
- `TESTING.md` records the three focused test responsibilities and offline validation rules.
- `AGENTS.md` makes the pre-read, decision-sensitive, scope, and validation contract operational.
- the target CI workflow has one verify job that uses the same Make interface as developers.

## 6. Native tooling

Python, uv, pytest, Ruff, and mypy remain the native application and
validation tools. Make wraps them to provide the framework's stable shared
command surface. `make setup` performs dependency bootstrap; post-setup
commands use locked uv execution with offline mode enabled.

## 7. Deliberate omissions

The fixture intentionally omits the following optional or later-stage concerns:

- `CLAUDE.md`, because agent-client entrypoints are independent optional concerns.
- `scripts/run_codex.sh` and `docs/AGENT_PROMPT.txt`, because agent runtime authority and session entrypoints are independent of repository-readiness documentation.
- `docs/COMMITS.md`, because commit-guidance adoption is unnecessary for this compact example.
- `lefthook.yml`, because hooks would add a host prerequisite without materially improving this fixture.
- GitHub App runtime/helper artefacts, because this example requires no repository credentials or agent runtime access.
- formal adoption metadata such as `.agent-framework.yml`, component digests, or framework version/adoption metadata; no such schema is created here.
- repository assessment output such as `assessment.yml`, assessment reports, adoption plans, or result records, because those belong to later repository-adoption work.
- automatic update metadata or adoption/update tooling, because safe automated adoption belongs to later repository-adoption work.
- evaluation/run metadata, because evaluation telemetry is outside this reference application.

These omissions are deliberate and are not defects in the selected adoption.

## 8. Greenfield decisions

Because this example is greenfield, it can choose Python 3.14, uv, a packaged
`src/` layout, Make, a single verification job, and the architecture document
locations directly. There is no existing workflow or native tool to preserve
at those boundaries.

## 9. Existing-repository differences

A real established repository should generally preserve useful native
equivalents rather than replacing them merely to match this fixture. Its
existing task runner, CI, documentation, pull-request and issue templates,
package manager, or architecture conventions may be more appropriate. An
adoption should specialise the framework around those facts and use the
smallest safe change.

## 10. Relationship to #8–#10

Future work may assess this fixture, add reviewed formal ownership and version
relationships for adopted components, and exercise safe plan/apply/update
workflows. Those are the subjects of issues #8, #9, and #10. This fixture does
not create their assessment outputs, adoption plans, ownership/version
metadata, or automatic update behaviour.

## 11. Limitations

The fixture does not demonstrate production deployment, distributed execution,
authentication, authorisation, external persistence, HTTP or API design,
frontend development, model integration, retrieval, embeddings, RAG,
autonomous agent operation, framework assessment, automatic adoption, framework
update behaviour, component ownership/version metadata, agent evaluation,
measured productivity improvement, production security, or suitability as a
universal application template.

It demonstrates only:

```text
manual framework adoption
+
repository-specific specialisation
+
deterministic repository readiness
```

See the linked source, tests, and repository documents rather than treating
this walkthrough as a duplicate of them.
