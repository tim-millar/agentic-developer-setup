# Agent Working Agreement

This repository supports agent-assisted development. Agents may work in this repo, but must do so within explicit workflow, scope, and validation guardrails.

This file is the standing operating contract for agent behaviour in this repository. It is not a substitute for task-specific instructions, issue acceptance criteria, or architecture documentation.

## Read Before Making Changes

Before changing code, agents must read:

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/DEVELOPMENT.md`
4. this `AGENTS.md`
5. the linked GitHub issue or task brief, including acceptance criteria and non-goals

If working in a subdirectory that contains its own `AGENTS.md` or architecture/development documentation, agents must also read and follow those local instructions.

If instructions conflict, the more specific local instructions take precedence over this top-level file.

When work begins from a GitHub issue, treat the issue as a primary source of truth for scope, acceptance criteria, non-goals, and constraints.

## Core Working Principles

- For issue-led implementation, one issue = one branch = one PR
- Do not introduce unrelated refactors
- Prefer small, explicit, testable changes
- Follow existing repo conventions unless the issue explicitly requires changing them
- Use existing commands and automation rather than improvising new workflows
- Do not invent new architecture when the current architecture already provides a clear path

## Required Workflow

Agents performing implementation must follow this workflow unless explicitly instructed otherwise:

1. Read the issue or task brief carefully
2. Restate the implementation plan briefly before coding
3. Create and switch to a branch for the task
4. Implement the smallest complete change that satisfies the task
5. Run the relevant validation commands
6. Complete any publication steps required by the conditional contract below
7. Summarise what changed, how it was validated and delivered, and any follow-ups

Do not commit directly to `main` or `master`.

GitHub issues are a primary execution surface in this repository. When working from an issue, agents should prefer issues that are ready for deterministic implementation, meaning the intended behaviour, scope boundaries, acceptance criteria, constraints, and validation expectations are clear enough that another competent implementer would make materially the same decisions. If those elements are still unresolved, treat the work as discovery or shaping rather than silently making foundational decisions during implementation.

## Conditional Publication Contract

When an agent is performing autonomous issue-led implementation, repository write access is available, repository changes are required or have been made, and the human has not explicitly requested a narrower delivery state, commit, push, pull-request publication, and verification are required completion steps. A validated local working tree is not a complete delivery in that mode.

Issue context or write access alone does not activate this contract. It does not apply automatically to read-only inspection, explanation, review, investigation, issue shaping, debugging without requested implementation, validation-only work, human-led local work, non-issue work, sessions without repository write access, or sessions in which no repository change is required. Do not create empty commits or pull requests for no-change results. Direct human instructions for local-only, no commit, no push, no pull request, or another bounded delivery state take precedence.

For qualifying work, the task authorises and requires task-only commits, normal task-branch pushes, creation of a draft pull request when no relevant open pull request exists, reuse of a single relevant existing open pull request, bounded pull-request body updates that preserve human-authored content, and remote verification. Repository- and runtime-specific instructions determine how write capability and credential recovery are established.

Resolve the intended base before pull-request lookup or creation. Reuse an existing open pull request only when it is the single same-head pull request targeting that base, and preserve its current draft or ready-for-review state. Newly created pull requests must be drafts. Conflicting, multiple, closed, or merged same-head pull requests require human direction rather than silent replacement or mutation.

Publication is complete only after verifying that the active task branch is correct, all task changes are committed, the local task HEAD exactly equals the remote task-branch HEAD and the pull-request head commit, exactly one relevant pull request is open against the intended base, and its review state is correct. Report this publication evidence with validation results. Do not force-push, rewrite history, change a pull-request base or readiness state, request reviewers, enable auto-merge, merge, or close the issue unless separately authorised.

An understood validation failure may be published when the task-only state remains coherent, safe, and reviewable, but publication completion and implementation acceptance must be reported separately. Do not publish unsafe, secret-bearing, destructive, unrelated, or ambiguous state. If publication fails, report the last verified local, remote, and pull-request state without claiming complete delivery.

## Branch Naming

Branches should use a predictable issue-led format, when working from a GitHub issue:

```text
issue-<number>-<short-slug>
```

Examples:

- `issue-12-add-product-import`
- `issue-34-fix-archive-filtering`

If no issue exists, use `<kind>/<slug>`.

Do not encode agent identity in the branch name.

## Scope Rules

Agents may:

- implement the requested issue or task
- add or update tests needed for the task
- update documentation relevant to the task
- perform small local refactors only when required to complete the task safely

Agents must not:

- expand the task beyond its stated goal
- bundle unrelated cleanups or drive-by fixes into the same PR
- change core architecture, security-sensitive behaviour, authentication, authorisation, data isolation, deployment configuration, CI policy, or production infrastructure unless the issue explicitly requires it
- add, remove, or significantly upgrade dependencies without stating the reason clearly in the PR or task summary

## Handling Out-of-Scope Discoveries

While working on a task, agents may discover:

- bugs not covered by the issue
- missing prerequisites
- technical debt
- possible follow-up improvements
- risky or unclear architectural concerns

In these cases:

- do not silently expand scope
- do not implement unrelated follow-up work in the current PR
- record the discovery in the PR or handoff notes under follow-ups or known limitations
- stop and ask for explicit direction if the discovery blocks safe completion of the task

## High-Risk Changes Require Explicit Instruction

Agents must stop and ask before proceeding if the change would:

- alter authentication or authorisation behaviour
- change data isolation, tenancy, permissions, or access boundaries
- modify security-critical flows or secret handling
- introduce or remove significant dependencies
- change database schema, migrations, or persistence strategy in a non-routine way
- change CI, release, deployment, or infrastructure behaviour in a way that affects other developers or environments
- introduce new architectural layers, abstractions, or framework-level patterns not clearly required by the issue

Routine low-risk work such as documentation updates, local refactors required for the task, tests, repo hygiene, and straightforward feature implementation within existing patterns should proceed without unnecessary pauses.

## Preferred Command Surface

Agents should prefer the repository’s standard command surface wherever possible.

Use `make` targets first when they exist, rather than calling lower-level tooling directly.

Typical examples include:

- `make setup`
- `make test`
- `make lint`
- `make format`
- `make typecheck`
- `make verify`
- `make ci`

If the repo defines different or additional commands, follow `docs/DEVELOPMENT.md` and the `Makefile` as the source of truth.

## Validation Expectations

Before declaring work complete, agents should run all relevant checks for the files and behaviour they changed.

At minimum, agents should run the relevant combination of:

- tests
- linting
- formatting or format checks
- type checks
- build or compile checks if applicable

If the task changes dependencies, Make targets, CI workflows, database schema, or other developer workflow mechanics, the agent must include a clear verification note listing:

- the commands run
- whether they succeeded
- any limitations or commands the reviewer should run manually

Do not claim success without stating what was actually validated.

## Git and Commit Behaviour

- Do not force-push unless explicitly instructed
- Prefer additive commits over rewriting history
- Do not amend commits unless explicitly instructed
- Keep commit messages clear and task-related
- If the repo defines agent commit metadata conventions, follow them
- If the launcher sets agent-specific Git metadata, do not override it manually unless instructed

## Documentation Expectations

When a change affects behaviour, workflows, or architecture-relevant usage, update the relevant documentation in the same PR where practical.

Do not create large speculative documentation that is not needed for the current task.

## Environment and Secrets

- Never commit secrets, tokens, credentials, or local environment files
- Treat local developer environment files as developer-owned unless the repo explicitly says otherwise
- Use documented test or example environment files where the repo provides them
- If temporary local files are needed for validation, do not commit them

## When in Doubt

If a design choice is unclear:

1. re-read `docs/ARCHITECTURE.md`
2. re-read the issue acceptance criteria and non-goals
3. choose the smallest change that satisfies the task
4. document assumptions in the PR or handoff notes

Do not invent new architecture or broaden scope without explicit instruction.
