# Greenfield Bootstrap Prompt

You are using the agent development framework to instantiate agent-enabled project documentation and supporting repo artefacts for a new greenfield application.

Your task is to read the framework baseline, apply any relevant adapters, use the supplied project planning materials, and produce the best grounded first-pass version of the project-specific framework files.

## Goal

Create an initial agent-ready repo framework layer for a new project using:

- the framework baseline
- any relevant adapters that exist
- the project’s architecture and planning materials

The output should be immediately usable as a first approximation, while making any missing information or unresolved decisions explicit rather than inventing them silently.

This prompt is for **bootstrap mode**.

Its purpose is to use the framework repository and the supplied project materials to instantiate the target repository so that it can move into normal **development mode**, where work should happen primarily from within the target repo using its repo-local docs, automation, and tightly scoped permissions.

## Inputs

You may be given some or all of the following:

### Required

- access to the framework repository
- access to the target project context or destination repo
- at least one of:
  - an architecture document
  - a roadmap or planning document

### Strongly recommended

- issue list or implementation task list
- intended ecosystem
- intended framework
- intended local runtime model
- intended app shape

### Optional

- domain notes
- testing notes
- deployment notes
- workflow notes
- existing draft docs
- issue templates or PR expectations
- constraints from the owning team

## Framework Usage Rules

1. Start from the framework baseline.
2. Apply only the adapters that are materially justified by the project inputs.
3. Preserve the baseline structure unless the project inputs clearly justify a specialisation.
4. Prefer the minimum set of overrides needed.
5. Instantiate the documents and automation conservatively.
6. When information is missing, leave unresolved sections explicit rather than inventing confident but unsupported detail.

## Adapter Rules

When adapter information is available:

- identify the most relevant ecosystem adapter
- identify the most relevant framework adapter
- identify the most relevant runtime adapter
- identify the most relevant app-shape adapter
- apply only the adapters that are clearly relevant

For example, a Rails monolith running in Docker might use:

- ecosystem: ruby
- framework: rails
- runtime: docker
- app-shape: monolith

When a relevant adapter does not exist:

- continue using the baseline
- make only conservative project-specific specialisations supported by the supplied materials
- explicitly note that a useful adapter appears to be missing
- do not invent a full unofficial adapter implicitly inside the instantiated project files

## Missing-Information Rules

When required project information is incomplete:

- produce the best grounded approximation you can
- keep placeholders or explicit open-question sections where needed
- record the missing information clearly
- do not silently make foundational decisions that different competent implementers could reasonably make differently

Do not silently invent:

- architecture decisions not present in the source materials
- domain rules not present in the source materials
- tooling choices not justified by the ecosystem/framework/runtime/app-shape context
- CI or hook behaviour not justified by the intended workflow
- issue semantics or validation expectations that are not grounded in the framework or project inputs

## What To Generate

Generate the project-specific versions of the relevant framework artefacts.

Typical outputs may include:

- `AGENTS.md`
- `CLAUDE.md`
- `docs/AGENT_PROMPT.txt`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `docs/DOMAIN.md`
- `docs/TESTING.md`
- `docs/COMMITS.md`
- `Makefile`
- `lefthook.yml`
- `scripts/run_codex.sh`
- `.github/PULL_REQUEST_TEMPLATE.md`
- `.github/workflows/ci.yml`
- `.github/ISSUE_TEMPLATE/...`

Only generate artefacts that are justified by the baseline and the available project information.

## Output Requirements

Produce the output in the following parts.

### 1. Generated Artefacts

List the files you generated and provide their contents.

### 2. Adapter Selection Summary

List:

- which adapters were used
- which adapters were considered but not used
- which useful adapters appear to be missing from the framework

### 3. Assumptions and Open Questions

List:

- assumptions you made
- unresolved questions
- places where the project inputs were insufficiently specific
- places where the instantiated files intentionally remain scaffold-like

### 4. Operational Wiring Required

List any steps still needed to make the generated framework fully executable in the target repository.

Examples may include:

- missing `package.json` scripts or equivalent command definitions
- missing dependencies or dev dependencies
- Make targets that refer to commands not yet implemented
- hook tooling that must still be installed or activated
- CI jobs that are expected to fail until repo wiring is completed
- commands whose current implementation is only a placeholder
- repo files that should be created or updated next in order to make the framework operational

Be explicit about the difference between:

- framework files that were generated successfully
- framework behaviour that is not yet wired into the target repo
- expected temporary failures or gaps
- genuine problems or contradictions in the generated setup

### 5. Expected Temporary Failures

List any failures, broken commands, or red CI checks that are expected at this stage because the repo has only been bootstrapped and not yet fully wired.

For each expected temporary failure, include:

- what currently fails
- why it fails
- whether the failure is acceptable for now
- what change is needed to remove the failure

Examples may include:

- `make test` failing because no test runner or test suite is configured yet
- `make typecheck` failing because no TypeScript config or typed source exists yet
- CI jobs failing because the required scripts or dependencies are not present
- hook commands failing because the hook runner has not yet been installed

Do not treat expected temporary failures as completed work. Make them explicit so they can be resolved intentionally.

### 6. Immediate Repo Activation Steps

List the smallest concrete follow-up steps needed to move the target repo from framework bootstrapping into normal day-to-day development mode.

Prioritise steps that:

- make the generated framework operational
- reduce confusion for developers and agents
- turn expected failures into real working commands
- activate local and CI guardrails honestly

Typical examples may include:

- add or update `package.json` scripts for `lint`, `format`, `build`, `test`, or `typecheck`
- install and configure hook tooling
- add minimal lint or formatting config
- add initial CI-safe script implementations
- reduce CI to only the checks that are truly operational today
- add missing repo files needed by the generated docs or automation

Keep this section focused on immediate activation work, not long-term roadmap items.

### 7. Recommended Next Steps

List the most important follow-up actions needed to improve the instantiated repo from this first-pass state.

## Working Style

- Be concrete where the source materials are concrete.
- Be conservative where the source materials are incomplete.
- Prefer explicit gaps over hallucinated certainty.
- Favour framework consistency over one-off improvisation.
- Keep the output immediately usable, even when incomplete.
- Treat the issue list as especially important when determining whether work is intended to be agent-executable.

## Input Bundle

Use the following information as the working input set for this run.

### Framework repo
[PASTE OR LINK HERE]

### Selected adapters
[PASTE OR LINK HERE]

### Project architecture materials
[PASTE OR LINK HERE]

### Project roadmap / planning materials
[PASTE OR LINK HERE]

### Issue list or task materials
[PASTE OR LINK HERE]

### Additional project context
[PASTE OR LINK HERE]
