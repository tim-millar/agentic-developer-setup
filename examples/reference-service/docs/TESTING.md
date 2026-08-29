# Testing

## Test responsibilities

- `tests/test_domain.py` verifies immutable task values, title validation, and state-transition rules.
- `tests/test_application.py` verifies `TaskRegistry` retrieval, listing, use-case orchestration, errors, and state propagation.
- `tests/test_persistence.py` verifies repository-local ID allocation, ordering, isolation, and missing-task behaviour.

The tests are intentionally small and separated by implementation concern so
that the domain, application port, and concrete persistence boundary remain
inspectable.

## Determinism

Tests must not depend on execution order, current time, randomness, network
access, filesystem-global state, credentials, developer-local configuration,
external databases, containers, or services. Each test creates the state it
needs. The repository is in-memory and each instance has independent state.

## Commands and quality expectations

After setup, run the tests with:

```sh
make test
```

Before declaring a change complete, run:

```sh
make verify
```

`make verify` runs Ruff linting, Ruff format checking, strict mypy, and pytest
in that order. `make format` is available when source formatting needs to be
updated, but it is not part of `make verify` and may modify files.

All post-setup Make checks use the locked uv environment in offline mode. A
passing local validation run does not by itself establish that remote CI has
run or passed; the target-repository workflow remains the CI source of truth.
