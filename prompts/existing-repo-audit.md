# Existing Repo Audit Prompt

You are using the agent development framework to assess and incrementally adapt an existing repository.

Your task is to read the framework, read the target repository, compare the repository against the framework by capability and intent, and recommend the smallest sensible adoption path.

This prompt is for **existing-repo audit and adaptation**, not for unconstrained greenfield bootstrap.

## Goal

Assess how an existing repository aligns with the framework, identify where it already satisfies the framework in substance, identify what is missing or in conflict, and recommend a minimal, safe, reviewable path toward better framework alignment.

Prefer adaptation over mechanical replacement.

Prefer overlay before rewrite.

## Inputs

You may be given some or all of the following:

### Required

- access to the framework repository
- access to the target repository

### Strongly recommended

- current repository documentation
- architecture notes
- development or onboarding docs
- CI configuration
- hook configuration
- Makefile or equivalent command surface
- package/dependency configuration
- issue or planning context if adoption is tied to a concrete task

### Optional

- target repo PRs or issues
- deployment notes
- team workflow notes
- operational notes
- historical rationale for current tooling choices

## Audit Rules

1. Start by understanding the target repository as it actually exists.
2. Compare the repository against the framework by capability and intent, not by filename or superficial structure.
3. Treat existing production tooling, CI, runtime, and architecture decisions as real constraints unless there is a clear reason to challenge them.
4. Do not assume that differences from the baseline are automatically problems.
5. Prefer preserving healthy local conventions where they already satisfy the framework’s goals.
6. Prefer overlay before rewrite.
7. Be explicit about the consequences of changing existing tooling or conventions.

## What To Assess

Assess the repository across areas such as:

- ecosystem
- application framework
- local runtime model
- app shape
- CI platform and CI structure
- hook tooling
- command surface and Makefile shape
- testing and validation model
- architecture and development documentation
- issue and PR workflow support
- degree of agent-readiness already present

## Framework Comparison Rules

For each relevant framework capability, classify the existing repo state as one of:

- **already satisfied**
- **partially satisfied**
- **missing**
- **conflicting**
- **better left as-is**

Use this classification to reason about framework adoption.

Examples:

- an existing Makefile may already satisfy the framework’s command-surface goal even if it does not match the baseline shape exactly
- an existing CircleCI setup may already satisfy the framework’s CI model even if the baseline examples use GitHub Actions
- an existing Lefthook setup may already align with the framework’s hook expectations
- existing Docker-based development may be a healthy repo constraint rather than something to replace

## Adaptation Rules

When deciding what to recommend:

- preserve strong existing tooling where it already serves the framework’s purpose
- do not rename or replace healthy repo conventions just for visual conformity with the baseline
- recommend changes only where they materially improve clarity, safety, agent usability, or reviewability
- explicitly note when changing an existing tool or convention may affect dependent tooling or developer workflow
- prefer documenting mappings between existing repo conventions and framework concepts where that is sufficient

## Adapter Extraction Rules

As you audit the repo, identify any reusable patterns that suggest future framework adapters.

Examples may include reusable patterns for:

- ecosystem adapters
- framework adapters
- runtime adapters
- app-shape adapters
- CI platform adaptation

Do not force these abstractions into the target repo immediately. Surface them as reusable framework opportunities.

## Missing-Information Rules

If important information is missing:

- make the gap explicit
- produce the best grounded assessment you can
- avoid inventing hidden rationale for existing repo choices
- avoid assuming that undocumented existing behaviour is automatically wrong

## Output Requirements

Produce the output in the following parts.

### 1. Existing Repo Assessment

Summarise the current repository in concrete terms.

Include areas such as:

- ecosystem
- framework
- runtime model
- app shape
- CI platform
- hook tooling
- command surface
- documentation maturity
- testing and validation maturity

### 2. Framework Alignment Analysis

For each relevant framework capability, classify the repo as:

- already satisfied
- partially satisfied
- missing
- conflicting
- better left as-is

Be explicit about the reasoning.

### 3. Recommended Adoption Approach

Describe the smallest sensible path toward better framework alignment.

Separate:

- what should be preserved
- what should be added
- what should be adapted
- what should not be changed yet

### 4. Risk and Compatibility Notes

Call out any meaningful risks in changing current repo conventions.

Examples:

- developer workflow disruption
- Makefile or script dependencies
- CI platform assumptions
- deployment or runtime implications
- tooling that depends on current naming or current command behaviour

### 5. Adapter Extraction Opportunities

Identify any reusable patterns in the repo that should likely inform future framework adapters.

Be explicit about which adapter category each opportunity most naturally fits.

### 6. Proposed Next Actions

List the most useful immediate next actions in a safe order.

Prefer incremental, reviewable changes.

### 7. Optional Generated Artefacts

If clearly justified, propose or generate specific framework-aligned artefacts for the repo.

Do this only after the audit and recommendation sections, and only where the benefit is clear.

## Working Style

- Be concrete where the target repo is concrete.
- Treat the existing repo as a serious system with real constraints.
- Prefer preserving healthy local patterns over forcing baseline conformity.
- Use the framework as a standardising and clarifying layer, not as a template to impose mechanically.
- Make hidden trade-offs visible.
- Surface adapter opportunities where repeated patterns appear reusable.

## Input Bundle

Use the following information as the working input set for this run.

### Framework repo
[PASTE OR LINK HERE]

### Target repository
[PASTE OR LINK HERE]

### Existing repository documentation
[PASTE OR LINK HERE]

### Architecture, onboarding, or development docs
[PASTE OR LINK HERE]

### CI, hook, and command-surface context
[PASTE OR LINK HERE]

### Relevant issues, PRs, or planning context
[PASTE OR LINK HERE]

### Additional repository or team context
[PASTE OR LINK HERE]
