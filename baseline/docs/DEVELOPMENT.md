# Development

## Purpose

This document explains how to work in this repository locally.

It should describe the local development environment, the normal development workflow, the standard commands exposed by the repository, and any repo-specific practices that developers and agents are expected to follow when making changes.

This is not an architecture document. High-level design constraints belong in `docs/ARCHITECTURE.md`. Standing agent behaviour rules belong in `AGENTS.md`.

## Development Model

This repository uses a local, issue- or task-driven development workflow.

In general:

- work should begin from a defined issue, task brief, or scoped change
- changes should be made on a task-specific branch
- developers and agents should prefer the repository’s standard command surface, usually via `make`
- local verification should be run before opening a PR
- CI should act as the final source of truth where possible

Work in this repository will often begin from a GitHub issue or equivalent task brief. When the intent is direct execution by a developer or agent, the preferred form is an implementation-ready issue with clear desired behaviour, scope, non-goals, acceptance criteria, constraints, relevant context, and validation expectations. Work that is still missing material decisions should be tracked as discovery or shaping work rather than treated as ready for deterministic implementation.

Replace or refine this section if the project uses a different working model.

## Branch Naming Conventions

Branch names should make it easy to identify the work being done and how it relates to the repository workflow.

The naming convention should support both:

- issue-driven implementation work, including full agent-driven workflows
- ordinary developer work that may not begin from a GitHub issue

Branch names should be short, readable, and descriptive. They should identify the work, not the execution style.

### Preferred Branch Shapes

#### Issue-linked work

When work is driven from a GitHub issue, especially in the full agent-driven workflow, use:

```text
issue-<number>-<short-slug>
```

#### Non-issue work

When work does not begin from a GitHub issue, use:

```text
<kind>/<short-slug>
```

Recommended kinds include:

- `feature`
- `fix`
- `chore`
- `docs`
- `refactor`
- `spike`

Examples:

`feature/archive-search-index`
- `fix/checkout-tax-rounding`
- `chore/update-eslint-config`
- `docs/testing-strategy`
- `refactor/import-pipeline-cleanup`
- `spike/product-archive-ingestion-options`

### Naming Guidance

Branch names should:

- be concise but descriptive
- use lowercase words separated by hyphens
- describe the work being done rather than the person doing it
- avoid unnecessary ticket-system details when no GitHub issue exists

Branch names should not:

- include developer names
- include agent names or runner names
- include dates or timestamps unless there is a strong repo-specific reason
- try to encode PR state or merge status

### Relationship to Agent Workflows

Branch names should not encode whether work is human-authored, agent-assisted, or agent-authored.

That information belongs in issue metadata, pull request metadata, and related workflow documents, not in the branch name itself.

### Repo-Specific Notes

Document any repository-specific branch naming rules here.

Examples might include:

- whether issue-linked names are mandatory for certain workflows
- whether certain prefixes are reserved
- whether automation exists to create issue branches

## Normal Development Loop

The expected development loop is:

1. read the issue or task brief and confirm that it is sufficiently specified for deterministic implementation
2. read `AGENTS.md`, `README.md`, and `docs/ARCHITECTURE.md`
3. create or switch to the appropriate branch
4. run local setup if needed
5. start the local development environment if needed
6. implement the smallest complete change for the task
7. run the relevant local checks
8. update tests and documentation where required
9. prepare a PR with clear validation notes

This is the default workflow unless the repository documents a more specific process.

## Agent Runtime Support

This repository may support one or more tool-specific agent runtimes.

The baseline framework is agent-runtime-aware rather than agent-agnostic. Shared repository practices belong in `AGENTS.md`, this development guide, the standard command surface, and project documentation. Agent-specific execution behaviour belongs in runtime launchers.

The current public baseline includes the Codex launcher at `scripts/run_codex.sh`. That launcher is intended for Codex sessions, prompt assembly, repository-scoped execution, validation workflow support, and optional GitHub App access. Do not assume it is a generic wrapper for every coding agent.

If another coding agent is supported in this repository, document its separate launcher, access policy, prompt expectations, and runtime-specific constraints here.

### Codex launcher repository identity check

The baseline Codex launcher is repository-scoped. Before launch, `scripts/run_codex.sh` validates that the target repository has an `origin` remote configured as an HTTPS GitHub URL matching `EXPECTED_OWNER/EXPECTED_REPO`.

By default, `EXPECTED_OWNER` is `tim-millar` and `EXPECTED_REPO` is the target repository directory name. Target repositories should override these values where needed.

This check is separate from GitHub API access. `GITHUB_ACCESS_MODE=disabled` prevents the agent session from using GitHub credentials or fetching issue context, but the launcher still verifies repository identity before starting the session.

## Standard Command Surface

This repository should expose a standard command surface through the top-level `Makefile`.

The Makefile is the canonical command interface for agents and humans. Targets and command variables are trusted repository configuration maintained by the project. Do not populate command variables from untrusted issue text, PR descriptions, user prompts, generated files, or other external input. Agents should prefer existing Make targets over inventing ad hoc shell commands.

Common targets may include:

### Core workflow targets

- `make setup`
- `make test`
- `make lint`
- `make verify`

### Recommended quality targets

- `make format`
- `make typecheck`
- `make ci`
- `make clean`

### Optional operational targets

- `make up`
- `make dev`
- `make build`
- `make logs`
- `make bash`
- `make console`
- `make migrate`

### Optional extended checks

- `make e2e`
- `make security`
- `make coverage`

Document below which of these targets are implemented in this repository and what they do.

## Prerequisites

List the local prerequisites required to work in this repo.

Typical examples might include:

- language runtimes
- package managers
- container tooling
- database services
- CLI tooling
- secret or environment configuration access

Replace this section with the actual prerequisites for the project.

## Local Setup

Document the standard local setup path here.

Typical setup steps may include:

1. clone the repository
2. install prerequisites
3. copy or create local environment files if needed
4. run `make setup`
5. start local services with `make up` or the project’s equivalent
6. verify the environment with `make test`, `make lint`, or another smoke check

Replace this section with the actual setup process for the project.

## Environment and Configuration

Document how local configuration works.

Typical areas to cover:

- which environment files or config files are used locally
- which files are safe to edit locally
- which files must never be committed
- how to obtain required secrets or credentials
- how local, test, and CI configuration differ

Do not include secrets in this document.

## Running the Application Locally

Document the normal way to start and interact with the application locally.

Typical areas to cover, where relevant:

- how to start the main app or services
- whether `make up` or `make dev` should be used
- where the app runs locally
- how to access logs
- how to open a shell or console in the runtime environment
- how background workers or auxiliary services are started

Replace this section with actual repo details.

## Testing and Local Verification

Document the expected local validation workflow.

Typical guidance to include:

- which commands should be run for normal feature work
- when to run the full local verification suite
- when formatters, type checks, or e2e tests are expected
- which commands should be run before opening a PR

A good baseline pattern is:

- run targeted checks during development
- run `make verify` before considering a task complete
- run `make ci` when changing workflow, dependencies, quality gates, or anything likely to affect CI behaviour

Replace this section with the actual expectations for the project.

## Persistence, Data, and Migrations

If the project has a database, schema, or other persistent storage, document how changes should be handled locally.

Typical areas to cover:

- how to run migrations
- how local data is created or reset
- whether seed data exists
- how destructive local reset operations work
- which persistence changes require special care

If the project does not use persistence or migrations, say so explicitly.

## Logs, Debugging, and Interactive Access

Document how to inspect runtime behaviour locally.

Typical areas to cover:

- how to stream all logs
- whether more specific log targets exist such as `logs-web` or `logs-worker`
- how to open a shell with `make bash`
- how to open an application console with `make console`
- where useful debugging tools or dashboards live locally

Replace this section with actual repo details.

## Hooks and Automation

Document any local automation that affects normal development.

Typical areas to cover:

- pre-commit hooks
- pre-push hooks
- formatting hooks
- generated files
- code generation steps
- local checks that mirror CI

If hooks are used, explain how to install them and what they enforce.

## Repo-Specific Workflow Notes

Use this section for anything that does not fit cleanly above but materially affects day-to-day development.

Examples might include:

- release workflow implications
- code generation expectations
- local fixture management
- integration testing caveats
- performance considerations for local development
- known limitations of the local environment

## Related Documents

Link related documents here as they are created.

Typical examples:

- `AGENTS.md`
- `CLAUDE.md`
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/DOMAIN.md`
- `docs/TESTING.md`
- `docs/OPERATIONS.md`
