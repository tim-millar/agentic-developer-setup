---
name: Agent-ready implementation
about: A scoped reference-service change ready for deterministic implementation
title: ""
labels: []
assignees: []
---

## Summary

Describe the change to the reference service and the outcome it should produce.

## Execution readiness

- [ ] This issue is ready for deterministic implementation.
- [ ] This issue needs clarification or discovery first.

## Desired behaviour

Describe observable behaviour and any required changes to the task registry,
tests, documentation, Make interface, or CI.

## Scope

Identify the files and concerns this issue may change. Keep the three-module
architecture and standard command surface in scope.

## Non-goals

List changes explicitly excluded from this issue, especially external services,
databases, web frameworks, or unrelated framework-adoption features.

## Acceptance criteria

- [ ] The requested behaviour is implemented.
- [ ] Relevant deterministic tests are added or updated.
- [ ] Relevant documentation is accurate.
- [ ] `make verify` passes, unless this issue explicitly narrows validation.

## Constraints

Record the applicable domain invariants, architecture boundaries, Python/uv
tooling constraints, offline verification requirements, and dependency limits.

## Relevant context

Link to the relevant source files and documentation, including
`docs/ARCHITECTURE.md` and `docs/DOMAIN.md` where applicable.

## Validation expectations

State the focused checks and the complete Make targets expected for this work.

## Open questions

List unresolved material decisions. Do not mark this issue implementation-ready
while such a decision would need to be invented by the implementer.
