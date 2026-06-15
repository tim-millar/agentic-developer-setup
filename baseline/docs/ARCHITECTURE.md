# Architecture

## Purpose

This document records the current high-level architecture of the repository and the most important design constraints that agents and developers are expected to follow.

It is the top-level summary of architectural decisions, not an exhaustive design document. More detailed technical decisions may be recorded in ADRs, decision logs, or supporting documents under `docs/`.

## Status

This architecture is currently:

- [ ] provisional
- [ ] evolving
- [ ] agreed baseline
- [ ] legacy system under change

Mark the current status and keep this section up to date.

For greenfield projects, it is normal for this document to begin with open questions and incomplete decisions. Do not treat missing detail as permission to invent architecture without explicit direction.

## System Overview

Describe, in a few paragraphs, what the system is for and the major parts it is expected to contain.

Include only what is actually known and agreed.

Typical areas to cover, where relevant:

- the main product or service responsibility
- the main user or operator interactions
- the major runtime components or subsystems
- important external integrations
- important data or workflow boundaries

Do not guess. Remove this guidance text once the actual overview is written.

## Architectural Principles

Record the principles that should guide implementation and future design decisions.

Examples of useful principle categories include:

- simplicity over unnecessary abstraction
- explicit boundaries between major concerns
- predictable operational workflows
- security and permission boundaries are treated as first-class concerns
- observability and debuggability matter
- reversible, incremental change is preferred over large rewrites

Replace these examples with the real principles for this project.

## Current Architectural Decisions

Record the current decisions that agents and developers should treat as binding unless an issue explicitly calls for changing them.

Use short, concrete statements.

Example structure:

- The application is structured as a single deployable service with clearly separated internal modules.
- External integrations are isolated behind dedicated adapter layers.
- Background work is handled through a separate worker process.
- Runtime configuration is supplied through environment variables.
- Domain logic should not depend directly on delivery-layer concerns.

Only include decisions that are actually agreed.

## Open Questions and Undecided Areas

List the important areas that are not yet settled.

This section is especially important in greenfield projects. It helps prevent accidental architecture drift caused by agents or developers silently making foundational decisions during normal feature work.

Examples of things that may belong here:

- service decomposition is not yet finalised
- persistence technology has not yet been fixed
- asynchronous processing strategy is still under evaluation
- deployment topology is still under evaluation
- public API shape is still under evaluation

If an issue requires resolving one of these questions, the resolution should be documented here or in a linked decision record.

## Change Guidance for Agents

Agents should treat the decisions recorded in this file as architectural constraints.

Agents must not:

- invent architecture that is not documented
- introduce new architectural layers or major abstractions without clear need
- silently change documented boundaries, data flow, security assumptions, or operational shape
- treat unresolved areas as implicitly decided

If a task appears to require architectural change, the agent should:

1. re-read this file and the issue scope
2. choose the smallest viable implementation consistent with current decisions
3. document any assumptions clearly
4. stop for explicit instruction if the change would alter a major architectural decision

## Related Documents

Link related documents here as they are created.

Typical examples:

- `docs/DEVELOPMENT.md`
- `docs/DOMAIN.md`
- `docs/DATA_MODEL.md`
- `docs/OPERATIONS.md`
- `docs/DECISIONS/`
