# Testing

## Purpose

This document defines the testing strategy and automated quality expectations for this repository.

It describes how correctness should be verified, how tests should be structured, and how automated checks should be used to constrain both human and agent development.

This document is intentionally normative. It describes the expected quality model for repositories using this framework, even though the concrete tools and implementations will vary by project.

## Testing Principles

The default testing principles for this repository are:

- code changes should be accompanied by tests that demonstrate correctness
- all public code should have unit tests
- important behaviour should be covered at the appropriate layer
- tests should be comprehensive, reliable, and fast enough to support frequent development
- tests should live in dedicated test suites and should not be colocated with production code
- automated checks should run locally, in hooks where appropriate, and in CI
- CI is the final automated source of truth
- automated checks are not only for detecting regressions; they also document expected behaviour and constrain unsafe change

These principles apply equally to human contributors and agent contributors.

## Test Layers

Repositories using this framework should aim to maintain multiple layers of automated verification.

### Unit tests

Unit tests are the primary correctness layer.

They should:

- verify the behaviour of small, focused units of code
- be fast and deterministic
- cover public code and important branching logic
- minimise unnecessary coupling to infrastructure or external systems

### Integration tests

Integration tests should verify that features work correctly across meaningful boundaries.

Examples of such boundaries may include:

- persistence layers
- network or API boundaries
- message or job processing boundaries
- framework integration points
- interactions between modules or services

Integration tests should prove that the real feature works in a realistic composed environment, while still remaining targeted and maintainable.

### End-to-end tests

End-to-end tests should exercise the system as a whole from an external or user-relevant perspective.

They should be used to verify the most important user or system flows and to catch failures that only emerge when the full system is assembled.

End-to-end tests are valuable, but they should not replace unit or integration tests.

## Expectations for Code Changes

As a general rule:

- code changes should include or update tests
- bug fixes should include regression tests where practical
- new public code should include unit tests
- new features should be supported by integration tests where feature behaviour crosses meaningful boundaries
- important user or system flows should be represented in end-to-end tests where appropriate

It should be unusual for a non-trivial code change to land without test changes or a clearly documented reason.

## Test Suite Structure

Tests should live in dedicated test suites rather than being colocated with production code.

The exact directory layout is repository-specific, but the structure should make it easy to distinguish:

- unit tests
- integration tests
- end-to-end tests
- support fixtures, helpers, or test utilities

Document the actual structure used by the repository below once it is defined.

## Speed, Reliability, and Maintainability

Automated tests should be designed to support frequent local execution and reliable automation.

As a general rule, tests should be:

- fast enough to run regularly during development
- deterministic and stable
- easy to understand
- focused on behaviour rather than incidental implementation detail
- maintainable as the codebase evolves

Avoid test suites that are slow, flaky, opaque, or overly dependent on fragile internal details.

## Automated Quality Checks Beyond Tests

Automated quality checks in this framework include more than tests alone.

They may include:

- linting
- formatting checks
- type checks
- coverage checks
- security checks
- build verification
- static analysis

These checks are part of the same quality system and should be treated as normal constraints on development rather than optional extras.

## Local Development Expectations

Human and agent developers are expected to run relevant checks locally while working.

A typical local workflow is:

- run targeted checks while iterating
- run `make test` for the relevant test suite
- run `make verify` before considering a task complete
- run additional checks such as `make typecheck`, `make security`, or `make coverage` when the change warrants them

Local workflows should be fast enough to support iteration, but thorough enough to catch ordinary mistakes early.

## Hooks and Automated Local Enforcement

Repositories using this framework should use local automation where practical to enforce quality gates.

Typical expectations:

- pre-commit hooks should run fast checks suitable for frequent execution
- pre-push hooks may run broader checks, while still respecting developer workflow speed
- hook behaviour should use the repository’s standard command surface where practical

Examples of hook-facing targets may include:

- `make hook-pre-commit`
- `make hook-pre-push`

Hooks may run only a subset of the full suite in order to stay fast. This is acceptable as long as CI runs the authoritative full suite.

## CI Expectations

CI should run the authoritative automated validation for the repository.

CI checks should be organised in semantically meaningful groups where practical, for example:

- lint
- test
- typecheck
- build
- e2e
- security
- coverage

In repositories using the baseline command model, CI may use targets such as:

- `make ci-lint`
- `make ci-test`
- `make ci-typecheck`
- `make ci-build`
- `make ci-security`
- `make ci-coverage`

CI should make failures easy to inspect and diagnose. It should be straightforward to see which category of validation failed.

## Coverage Expectations

Coverage should be used as a tool for identifying gaps, not as a substitute for good judgment.

A healthy repository should:

- maintain meaningful coverage of public code and important behaviours
- use coverage reporting to identify untested areas
- avoid writing low-value tests solely to inflate metrics

If the repository uses explicit coverage targets or reporting thresholds, document them here.

## Tests as Documentation and Constraints

Tests serve multiple purposes in this framework.

They should:

- prove that the program works as intended
- demonstrate how code is expected to be used
- constrain future development
- reduce the risk of regressions
- make both human and agent contributors operate within documented behavioural expectations

This is one of the reasons automated testing is treated as a first-class part of the development model.

## Repo-Specific Testing Notes

Use this section to document the actual testing implementation for the repository.

Typical areas to fill in once the repo is instantiated include:

- test directory layout
- frameworks and tools used
- fixture or factory conventions
- local commands for each test layer
- how integration environments are provisioned
- how end-to-end tests are run
- how coverage is reported
- any known limitations or trade-offs in the current test suite

## Related Documents

Link related documents here as they are created.

Typical examples:

- `AGENTS.md`
- `docs/DEVELOPMENT.md`
- `docs/ARCHITECTURE.md`
- `README.md`
- `docs/OPERATIONS.md`
