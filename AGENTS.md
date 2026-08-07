# Agent Working Agreement

This repository supports agent-assisted development within explicit workflow, scope, provenance, and validation guardrails.

This file is the standing operating contract for agents working on the `agentic-developer-setup` repository itself. It does not replace the current task specification, direct human instructions, acceptance criteria, non-goals, or other task-specific context.

## Instruction precedence

Apply instructions in the following order:

1. explicit human instructions for the current task;
2. the current implementation specification or task brief;
3. more specific instructions in the directory being changed;
4. this root `AGENTS.md`;
5. general agent defaults.

An implementation specification may be supplied through:

* a GitHub issue;
* a local issue or planning document;
* another repository document;
* a task brief included in the prompt;
* an equivalent structured set of instructions.

A literal GitHub issue is not required.

Task-specific instructions may clarify or narrow a broader specification. Do not silently treat them as permission to expand the task.

If applicable instructions conflict and the intended behaviour cannot be established from the repository or current interaction, stop before making the conflicting change and surface the ambiguity.

## Repository role and boundaries

This repository has two distinct roles:

1. it is a maintained repository with its own development workflow;
2. it is the source of reusable framework artefacts intended for adoption by other repositories.

Agents must preserve the distinction between repository-specific operation and distributable framework source.

### Root operational files

Files at the repository root, or in root-level operational directories, govern development of this repository itself.

Examples include:

```text
AGENTS.md
docs/AGENT_PROMPT.txt
scripts/run_codex.sh
```

These files may contain behaviour or policy specific to `tim-millar/agentic-developer-setup`.

### Distributable framework source

Files under areas such as the following define reusable framework material:

```text
baseline/
adapters/
prompts/
checklists/
framework.yml
```

Files under `baseline/` are source artefacts intended to be copied or adapted into target repositories. They must remain generic enough to support repositories with different languages, frameworks, architectures, runtimes, teams, and risk profiles.

Do not:

* add root-only requirements to baseline artefacts unless the task explicitly changes downstream framework behaviour;
* assume a root operational file and its baseline equivalent should be identical;
* modify the baseline merely to satisfy a repository-specific root requirement;
* introduce employer-specific or project-specific assumptions into reusable framework source;
* treat the root self-hosted harness as the canonical distributable implementation;
* impose this repository’s preferred working style on every repository that adopts the framework.

When changing a baseline artefact, consider the effect on every repository that may adopt it.

When changing a root specialisation, determine whether the change belongs only to this repository or represents an intentional framework-wide change.

## Framework flexibility

The framework is intended to support a spectrum of human and agent working styles.

It must be possible to use it for:

* autonomous agent implementation from fully specified tasks;
* human-led development with occasional agent assistance;
* collaborative human-agent implementation;
* focused refactoring, explanation, testing, or review tasks;
* repository preparation performed before an agent session begins;
* agents that do not have access to GitHub or other external systems.

Do not change reusable baseline material in a way that requires every adopter to use:

* GitHub issues as the only task specification;
* fully autonomous agents;
* one particular planning ceremony;
* separate issue-shaping and implementation-plan reviews;
* one universal development process.

Repository-specific contracts may choose a narrower workflow. The reusable framework should provide useful guardrails without unnecessarily prescribing how every team must work.

## Source paths and target paths

`framework.yml` is authoritative for declared framework artefacts and their source-to-target mappings.

A `source_path` identifies an artefact inside this framework source repository.

A `target_path` identifies the intended location of that artefact inside an adopted repository.

For example:

```text
baseline/AGENTS.md -> AGENTS.md
```

means:

* `baseline/AGENTS.md` is the reusable framework source;
* root `AGENTS.md` is this repository’s specialised operational contract.

The existence of a root file at a declared target path does not make that root file the declared source artefact.

Apply the same distinction to prompts, launchers, Makefiles, workflows, documentation, and other framework material.

Do not infer new source-to-target relationships from matching filenames or paths. Update `framework.yml` only when the task explicitly changes the declared metadata contract.

## Read before making changes

Before changing files, agents must:

1. read this root `AGENTS.md`;
2. read the current implementation specification or direct task instructions;
3. inspect the current branch and working tree;
4. inspect the files and repository areas relevant to the task;
5. read the relevant sections of `README.md`;
6. inspect `framework.yml` when the task affects declared artefacts, source or target paths, runtimes, adapters, adoption tiers, or conventions;
7. inspect related root and baseline files when the task affects the boundary between repository-specific and distributable behaviour.

The task specification may be available through GitHub, a repository document, a supplied local file, or the session prompt.

Do not assume GitHub access is available.

Do not rely only on:

* file names;
* issue titles;
* summaries;
* earlier conversation context;
* generic framework expectations;
* assumed repository conventions.

Inspect the current repository state before making detailed claims.

If a subdirectory defines its own `AGENTS.md` or other local instructions, read and follow those instructions for work in that area.

Do not require absent or planned documentation as though it already exists. When a task introduces a new document, distinguish clearly between the current repository and its intended post-change state.

## Task specifications and working modes

This repository supports more than one agent-assisted working mode.

Follow the mode established by the current human instruction, supplied task context, and existing repository state.

Do not impose an autonomous issue-led workflow on work that is being directed interactively by a human.

### Agent-led implementation

When an agent is expected to implement a substantial change autonomously, it should be given a sufficiently complete implementation specification before implementation begins.

The specification should resolve the material decisions needed to perform the work, including as applicable:

* intended behaviour;
* scope;
* acceptance criteria;
* non-goals;
* public interfaces;
* architectural constraints;
* security or access boundaries;
* dependency constraints;
* required validation.

When the supplied specification is implementation-ready, implement it directly.

Do not require:

* a separate implementation plan;
* a second document restating the issue;
* an additional approval step merely to repeat decisions already contained in the specification.

A fully specified issue or equivalent document is itself the implementation plan.

Ordinary local implementation decisions remain delegated to the agent where they do not change:

* specified behaviour;
* architecture;
* scope;
* public interfaces;
* security boundaries;
* dependencies;
* framework policy.

### Human-led and locally directed work

Not every task requires a formal issue or implementation document.

A human may direct an agent to perform bounded work such as:

* inspecting or explaining existing behaviour;
* reviewing a file or proposed change;
* refactoring a local implementation;
* adding or adjusting a focused test;
* drafting or refining a repository artefact;
* tightening changes already assembled on a branch;
* running validation;
* preparing commits or a pull request;
* investigating a narrow defect.

For such work, the current human instruction is the task specification.

Inspect the relevant context and perform the requested work within the stated boundary.

Do not introduce additional process requirements merely because the work could have been represented as a GitHub issue.

### Existing work on a branch

A human may create a branch and accumulate draft changes before starting an agent session.

In that situation, the agent should:

1. inspect the current branch and working tree;
2. understand which changes already exist;
3. preserve the intended task boundary;
4. review, tighten, complete, or validate those changes as instructed;
5. avoid discarding or replacing human work without a clear reason;
6. avoid creating another branch unless instructed.

The agent is not required to restart the workflow from an empty branch or reproduce work already performed outside the session.

### Sessions without a task

If no implementation specification or direct task has been supplied:

1. read the applicable repository harness and instructions;
2. inspect only enough repository context to understand the working environment;
3. wait for instruction.

Do not independently:

* select an open issue;
* begin roadmap work;
* modify files;
* create a branch;
* make commits;
* infer permission to implement an available task.

## Material and routine decisions

Do not silently make material decisions that have not been delegated through the task specification or current human-led interaction.

A decision is material when it changes matters such as:

* intended behaviour;
* public interfaces;
* framework semantics;
* architecture;
* security or permissions;
* credential handling;
* dependency strategy;
* CI or release policy;
* reusable baseline behaviour;
* task scope.

When a material unresolved decision blocks correct implementation, surface it for direction.

Do not pause unnecessarily over routine implementation details that fit clearly within the supplied task.

Routine decisions may include:

* local naming;
* small helper extraction;
* test fixture organisation;
* minor internal refactoring;
* exact implementation mechanics that do not change the agreed contract.

## Git workflow

For substantial issue-led implementation, the expected workflow is:

```text
one issue = one branch = one pull request
```

For substantial implementation based on an equivalent non-GitHub specification, the expected workflow is:

```text
one implementation specification = one branch = one pull request
```

For issue-led work, prefer an issue-based branch name:

```text
issue-<number>-<short-slug>
```

For example:

```text
issue-21-self-hosted-harness
```

For work without an issue number, use a clear task-based branch name such as:

```text
docs/self-hosted-harness
fix/launcher-root-resolution
test/framework-validator
```

Before editing or committing:

* inspect the current branch;
* inspect the working tree;
* determine whether the intended task branch already exists;
* preserve work already assembled on that branch.

Do not:

* make implementation changes directly on `main`;
* commit directly to `main`;
* assume the launcher has created or selected a safe branch;
* create an unnecessary replacement branch when the correct task branch already exists;
* include unrelated local changes in the task;
* force-push unless explicitly instructed;
* amend or rewrite history unless explicitly instructed;
* encode agent identity in the branch name.

Verify the active branch before committing.

These are required workflow rules even when the current launcher does not technically enforce them.

Small read-only tasks, explanations, reviews, and draft generation do not require a branch when no repository changes are being made.

## Scope control

Agents may:

* implement the supplied task;
* add or update focused tests needed by the task;
* update documentation directly affected by the change;
* perform small local refactors necessary to complete the task safely;
* improve existing draft work where explicitly requested.

Agents must not:

* expand the task beyond its stated goal;
* bundle unrelated cleanup or drive-by fixes into the same change;
* introduce speculative abstractions;
* redesign adjacent framework concepts;
* add runtimes, adapters, schema fields, workflows, or dependencies not required by the task;
* turn a narrow documentation change into a general rewrite;
* change reusable baseline behaviour unless the task explicitly requires it;
* reinterpret broad acceptance criteria as permission to change unrelated architecture.

Prefer the smallest complete change that satisfies the supplied task.

## Out-of-scope discoveries

During work, agents may discover:

* defects outside the current task;
* missing prerequisites;
* inconsistencies in metadata or documentation;
* technical debt;
* possible framework improvements;
* security or provenance concerns;
* underspecified architecture.

When this happens:

1. determine whether the discovery blocks safe completion;
2. do not silently absorb non-blocking work into the current task;
3. record non-blocking discoveries as follow-up work;
4. stop and surface the problem if it prevents correct implementation;
5. avoid making an unreviewed framework-level decision merely to continue.

A nearly complete change must not be expanded with adjacent work simply because it was discovered during implementation.

## Framework-level changes requiring explicit scope

The following changes require clear task-level authorisation:

* changing the structure or meaning of `framework.yml`;
* adding or removing schema fields;
* changing source-path or target-path semantics;
* adding or changing supported agent runtimes;
* adding or changing adapter taxonomy;
* changing adoption-tier definitions;
* changing baseline artefacts used by adopted repositories;
* changing the public interface or access model of an agent launcher;
* changing GitHub App, credential, permission, or secret-handling behaviour;
* adding significant dependencies or a new implementation runtime;
* introducing generation, scaffolding, or synchronisation systems;
* changing root or baseline CI policy;
* introducing new architectural layers or framework-wide abstractions;
* imposing a new mandatory workflow on framework adopters.

If such a change is explicitly specified, proceed within the task’s boundaries.

If it is not specified, do not introduce it as an incidental implementation decision.

## Public repository and provenance boundary

This is a public repository. All contributed material must have a clear and appropriate public provenance.

Do not copy, reconstruct, expose, or closely translate:

* private Palace source code;
* employer-owned prompts or agent instructions;
* internal repository structures;
* private schemas or data models;
* credentials, secrets, tokens, or environment values;
* unpublished operational procedures;
* private incidents, issue details, or internal discussions;
* company-specific names, codenames, configuration, or infrastructure details;
* implementation material from a private framework unless it has been independently redesigned for this public repository.

Conceptual experience may inform the public design, but implementation must be expressed independently and generically.

Use public, neutral examples.

Do not assume that similarity between this repository and a private system grants permission to copy from that system.

If a task appears to require private or employer-owned material, stop and identify the provenance problem rather than approximating or publishing it.

## Validation expectations

Use the repository’s documented root command surface when it exists.

Prefer root `make` targets over lower-level tools when those targets cover the required validation.

Until a root command exists for a check, use the focused deterministic commands supplied by the task or appropriate to the changed files.

Before declaring repository work complete:

* run the checks relevant to the changed files and behaviour;
* distinguish syntax checks from behavioural tests;
* report commands exactly as run;
* state whether each command succeeded;
* identify checks that could not be run;
* report environmental or tooling limitations;
* do not infer success from inspection alone;
* do not claim validation that was not performed.

Validation should be offline and deterministic unless the task explicitly requires a live integration check.

Do not introduce network access, credentials, external services, or live agent execution into standard tests without explicit task scope.

## Completion evidence

When completing implementation work, provide a concise handoff containing the following.

### Changed files

List the files added, modified, or removed and the purpose of each change.

### Validation

List the exact validation commands run and their results.

### Limitations

State any relevant limitations, unverified behaviour, unavailable tooling, or assumptions.

### Follow-up work

List out-of-scope discoveries that should be considered separately.

Do not state that a command, test, commit, push, pull request, issue update, or other action occurred unless it actually occurred.

For read-only, explanatory, or drafting tasks, provide evidence appropriate to the task rather than forcing an implementation handoff format.

## Git and commit behaviour

Keep Git operations deliberate and reviewable.

Before committing, agents must:

* inspect the active branch;
* inspect the working tree;
* avoid staging unrelated files;
* understand pre-existing changes;
* keep commits related to the current task;
* use clear commit messages;
* preserve useful existing history;
* respect documented commit metadata conventions when they exist;
* preserve launcher-provided authorship or metadata unless explicitly instructed otherwise.

Do not:

* commit credentials, tokens, local environment files, or temporary files;
* overwrite developer-owned local configuration;
* force-push, amend, rebase, or squash without explicit instruction;
* discard pre-existing changes without authorisation;
* claim a clean working tree without checking it;
* claim a branch or commit exists without verifying it.

## Documentation expectations

Update documentation when the task changes:

* public behaviour;
* supported workflows;
* command interfaces;
* metadata contracts;
* repository structure;
* adoption guidance;
* architecture-relevant usage.

Keep documentation changes proportional to the task.

Distinguish clearly between:

* behaviour that exists now;
* behaviour introduced by the current change;
* behaviour planned for a later task.

Do not:

* describe planned files or commands as already available;
* create speculative architecture documentation;
* duplicate detailed command documentation across multiple files;
* mix root repository documentation with target-repository scaffolds;
* rewrite broad sections of the README unless explicitly required;
* present this repository’s preferred agent workflow as mandatory for all framework adopters.

Root documentation should describe this framework repository.

Documentation under `baseline/` should remain suitable for adaptation by target repositories.

## Dependencies and generated material

Do not add, remove, or significantly upgrade dependencies unless the task explicitly requires it.

When a dependency is necessary:

* explain why the standard library or existing tooling is insufficient;
* keep the addition narrowly scoped;
* update relevant setup and validation documentation;
* avoid introducing package-manager requirements unrelated to the repository’s current implementation.

Do not commit generated, cached, temporary, or machine-specific material unless the repository explicitly treats it as source.

## Secrets and local environment

Never commit:

* credentials;
* access tokens;
* private keys;
* local environment files;
* generated GitHub App tokens;
* temporary prompt files containing sensitive context;
* machine-specific configuration.

Treat local developer files as developer-owned unless the repository explicitly states otherwise.

Do not print secret values while debugging or include them in validation evidence.

## Handling ambiguity

When a design or implementation choice is unclear:

1. re-read the current task specification and direct human instructions;
2. inspect the current repository state;
3. inspect `framework.yml` when metadata relationships are involved;
4. inspect the relevant root and baseline artefacts;
5. identify the current working mode;
6. preserve the distinction between repository-specific operation and reusable framework source;
7. choose the smallest change supported by the supplied task;
8. record non-blocking uncertainty as follow-up work;
9. stop before making an unresolved material framework-level decision.

Do not invent architecture, broaden scope, or convert an incidental similarity into a new framework invariant.
