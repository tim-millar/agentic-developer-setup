# Reference service agent contract

This file is the repository-specific operating contract for the reference
service. Before implementing a change, an agent must read:

1. `README.md`
2. `docs/ARCHITECTURE.md`
3. `docs/DOMAIN.md`
4. `docs/DEVELOPMENT.md`
5. `docs/TESTING.md`
6. the current task specification

The current task specification is authoritative for scope, acceptance
criteria, constraints, and non-goals. Do not infer material design decisions
from an incomplete request.

## Architecture

- Domain code in `src/reference_service/domain.py` must not depend on application or persistence code.
- Application and use-case orchestration belongs in `src/reference_service/application.py`.
- Concrete in-memory storage belongs in `src/reference_service/persistence.py`.
- Do not introduce a new architecture layer without explicit task scope.

## Domain contract

The exact task title, ID, state, transition, error, and listing invariants in
`docs/DOMAIN.md` are authoritative. In particular, titles are trimmed and
blank titles are rejected; repository-local IDs begin at one; tasks move only
from pending to in-progress to completed; and the documented idempotent
operations remain idempotent.

## Commands and validation

Prefer the stable repository command surface over equivalent improvised
commands:

```text
make setup
make test
make lint
make format
make format-check
make typecheck
make verify
```

Run `make verify` before declaring implementation complete unless the task
explicitly narrows validation. `make format` may modify files; the other
verification commands are intended to be non-mutating.

## Decision-sensitive changes

An explicit task specification is required before changing:

- state-transition semantics
- ID semantics
- task-title invariants
- architecture boundaries
- persistence strategy
- Python version
- package manager
- lint, format, or type-check policy
- CI contract
- runtime dependencies

## Prohibited scope expansion

Do not introduce external services, network dependencies, databases, web
frameworks, new runtime dependencies, authentication, or deployment
infrastructure without explicit task scope.

## Ambiguity and provenance

Do not silently turn an unresolved material design question into repository
policy. Keep the example synthetic and public: do not add private application
concepts, paths, prompts, workflows, credentials, or other confidential
material.
