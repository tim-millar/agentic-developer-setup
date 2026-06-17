# Legacy Safe Enablement Prompt

You are using the agent development framework to assess a legacy repository and identify the safest, smallest, most useful ways to make it more suitable for agent-assisted development.

Your task is to understand the existing repository as it really is, identify where the framework can improve safety and legibility, and recommend a minimal overlay that reduces risk without forcing unnecessary structural change.

This prompt is for **legacy-safe enablement**, not for unconstrained greenfield bootstrap and not for broad repo modernisation.

## Goal

Assess how a legacy production repository can be made safer and more legible for agent-assisted work.

Prioritise:

- safety
- boundedness
- explicit constraints
- preservation of functioning local abstractions
- minimal-risk framework overlay

Do not optimise for mechanical conformity to the framework baseline.

## Inputs

You may be given some or all of the following:

### Required

- access to the framework repository
- access to the target repository

### Strongly recommended

- current repository documentation
- architecture notes or onboarding docs
- CI configuration
- hook configuration
- Makefile or equivalent command surface
- dependency and package management files
- any issue or task context related to the safe-enablement effort

### Optional

- deployment notes
- operational notes
- historical rationale for current tooling or architecture
- examples of known fragile areas
- team workflow notes
- existing incidents or classes of change that are known to be risky

## Legacy Safe-Enablement Rules

1. Start by understanding the repository as a real production system with locked-in constraints.
2. Assume that unusual or legacy choices may still be necessary, even if they are not elegant.
3. Compare the repository against the framework by capability and intent, not by filename or superficial baseline shape.
4. Prefer documenting, constraining, and clarifying over rewriting.
5. Prefer overlay before replacement.
6. Do not recommend changing existing tooling or abstractions unless there is a clear safety, clarity, or reviewability payoff.
7. Be especially cautious about changes that would affect many developers, dependent systems, or fragile runtime behaviour.
8. Make danger zones and non-goals explicit.

## What To Assess

Assess the repository across areas such as:

- ecosystem
- framework(s) and unusual local patterns
- runtime model
- app shape
- CI platform and CI structure
- hook tooling
- command surface and Makefile shape
- testing and validation model
- documentation maturity
- areas of fragility, inconsistency, or poor discoverability
- signs that parts of the repo should be treated as high-risk for routine agent work

## Framework Comparison Rules

For each relevant framework capability, classify the repo state as one of:

- **already satisfied**
- **partially satisfied**
- **missing**
- **conflicting**
- **should not be changed now**

Use this classification to reason about framework adoption in a safety-first way.

Examples:

- an existing Makefile may already satisfy the framework’s command-surface goal and should be preserved
- an existing CircleCI or other CI setup may already satisfy the framework’s CI model and should be adapted rather than replaced
- an unusual ORM or runtime pattern may be awkward but still not a candidate for framework-driven change
- a missing agent contract or development guide may be a good low-risk place to add framework value

## Risk and Fragility Rules

During the assessment, explicitly identify:

- dangerous or brittle subsystems
- areas where local conventions are unusual but important
- workflows where naive cleanup would be risky
- parts of the repo that are likely poor candidates for broad agent autonomy
- places where documentation and explicit non-goals would add more value than code or tooling change

Do not treat age or awkwardness alone as sufficient reason to recommend change.

## Adaptation Rules

When deciding what to recommend:

- preserve strong or dependency-heavy local abstractions where possible
- recommend additions that improve boundedness, reviewability, and safety
- prefer documentation overlays over tooling rewrites when the tooling is already entrenched
- avoid recommending broad changes to CI, runtime, deployment, architecture, or command surface unless the gain is clear and the risk is low
- separate low-risk framework overlays from higher-risk structural suggestions

## Adapter Extraction Rules

As you assess the repo, identify any reusable patterns that suggest future framework adapters.

Examples may include reusable patterns for:

- ecosystem adapters
- framework adapters
- runtime adapters
- app-shape adapters
- CI platform adaptation
- legacy-specific operational guidance

Do not force these abstractions back into the target repo unless they are also the safest local recommendation.

## Missing-Information Rules

If important information is missing:

- make the gap explicit
- produce the safest grounded assessment you can
- avoid inventing clean rationale for messy or legacy behaviour
- avoid assuming that undocumented behaviour is accidental or disposable

## Output Requirements

Produce the output in the following parts.

### 1. Legacy Repo Assessment

Summarise the current repository in concrete terms.

Include areas such as:

- ecosystem
- framework(s)
- runtime model
- app shape
- CI platform
- hook tooling
- command surface
- documentation maturity
- major signs of legacy complexity or fragility

### 2. Risk and Fragility Notes

Identify the main areas of operational, architectural, or workflow risk.

Call out:

- brittle areas
- dangerous change surfaces
- unusual technologies or patterns
- areas that should likely remain tightly bounded for agent work

### 3. Safe-Enablement Assessment

Explain where the framework can improve the repo safely.

Focus on low-risk gains such as:

- better explicit working agreements
- clearer development guidance
- better issue or PR structure
- clearer local command-surface explanation
- clearer documentation of dangerous or off-limits areas

### 4. Framework Alignment Analysis

For each relevant framework capability, classify the repo as:

- already satisfied
- partially satisfied
- missing
- conflicting
- should not be changed now

Be explicit about the reasoning.

### 5. Minimum Safe Overlay

Describe the smallest useful framework overlay for this repository.

Separate:

- what should be preserved
- what should be documented
- what should be added
- what should be adapted carefully
- what should not be changed now

### 6. Adapter Extraction Opportunities

Identify any reusable patterns in the repo that should likely inform future framework adapters or legacy guidance.

Be explicit about which adapter category or framework layer each opportunity most naturally fits.

### 7. Proposed Next Actions

List the most useful immediate next actions in a safe order.

Prefer:

- incremental
- reviewable
- low-risk
- high-clarity

steps.

### 8. Optional Low-Risk Generated Artefacts

If clearly justified, propose or generate specific framework-aligned artefacts for the repo.

Do this only after the assessment and recommendation sections, and only where the gain is clear and the risk is low.

Examples may include:

- `AGENTS.md`
- `CLAUDE.md`
- a development guide
- issue or PR template improvements
- explicit documentation of command-surface semantics
- notes about high-risk or off-limits areas

## Working Style

- Treat the existing repo as a serious system with real operational and organisational constraints.
- Prefer safety, boundedness, and clarity over framework conformity.
- Preserve working local structures unless there is a compelling reason not to.
- Do not assume modernisation is part of the task.
- Make hidden trade-offs visible.
- Prefer a small safe overlay over a broad aspirational change set.

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

### CI, hook, runtime, and command-surface context
[PASTE OR LINK HERE]

### Known fragile areas, unusual technologies, or risk notes
[PASTE OR LINK HERE]

### Relevant issues, PRs, incidents, or planning context
[PASTE OR LINK HERE]

### Additional repository or team context
[PASTE OR LINK HERE]
