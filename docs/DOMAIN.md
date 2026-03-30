# Domain

## Purpose

This document records the domain context for this repository.

It should explain the problem space the project operates in, define the important domain concepts and terminology, and capture any business or operational rules that developers and agents need in order to make correct changes.

This is not an architecture or implementation document. Technical design belongs in `docs/ARCHITECTURE.md`. Local workflow guidance belongs in `docs/DEVELOPMENT.md`.

## Domain Overview

Describe the domain this project operates in.

Useful questions to answer:

- What problem is the project solving?
- What part of the business, organisation, or workflow does it support?
- What does the system represent, manage, analyse, or automate?
- What outcomes matter in this domain?

Replace this section with a short project-specific overview once the domain is known.

## Users, Stakeholders, and Actors

List the people, roles, or systems that interact with or depend on this project.

Examples might include:

- end users
- operators or internal teams
- administrators
- partner systems
- downstream consumers of the data or outputs

Document only the roles that matter for understanding the domain.

## Core Concepts and Terminology

Define the important domain concepts used in this project.

For each important term, record:

- the meaning of the term in this project
- how it differs from similar terms, if relevant
- any important edge cases or exclusions

This section is especially important. Agents and new contributors should be able to read it and understand what the main entities and concepts in the domain actually mean.

Replace this guidance text with actual project terminology.

## Domain Rules and Constraints

Record any rules that are true because of the domain, not because of the current implementation.

Examples might include:

- required states or transitions
- legal, compliance, or policy constraints
- business invariants
- permission or ownership rules
- timing or sequencing rules
- data retention or audit requirements

Only include rules that are actually agreed and important.

## Important Domain Workflows

Describe any workflows or processes that matter for understanding the domain.

These are domain workflows, not engineering workflows.

Examples might include:

- how a product moves through a lifecycle
- how a user request is processed
- how records are reviewed or approved
- how information is ingested, transformed, or published

Replace this section with actual project-specific workflows if they exist.

## External Systems and Dependencies

List any external systems, upstream sources, downstream consumers, or organisational dependencies that shape the domain behaviour of the project.

Examples might include:

- external APIs
- source-of-truth systems
- partner platforms
- reporting consumers
- internal operational systems

Document the domain significance of these systems, not just the technical integration details.

## Common Misunderstandings and Ambiguities

Record anything that developers or agents are likely to get wrong without domain context.

Examples might include:

- overloaded terms
- concepts that sound similar but are not interchangeable
- assumptions that are common but false
- edge cases that matter a lot in practice
- things the system intentionally does not model

This section is often one of the highest-value parts of the document.

## Open Domain Questions

If important parts of the domain are still not fully understood or agreed, record them here.

This is especially useful in greenfield projects, where terminology, users, workflows, or constraints may still be evolving.

Do not let unresolved domain questions remain implicit if they materially affect implementation choices.

## Related Documents

Link related documents here as they are created.

Typical examples:

- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `docs/DATA_MODEL.md`
- `docs/OPERATIONS.md`
- `docs/DECISIONS/`
