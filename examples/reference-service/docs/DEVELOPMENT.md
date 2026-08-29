# Development

## Prerequisites

The fixture targets Python 3.14, as declared by `.python-version` and
`pyproject.toml`, and uses uv 0.12.7. Both CI workflows pin that uv version;
the `uv_build==0.12.7` build backend is intentionally aligned with the CLI.
Install [uv](https://docs.astral.sh/uv/) 0.12.7 before using the commands
below. No credentials, services, database, container runtime, or
developer-local configuration is required.

## Setup

Run:

```sh
make setup
```

This is the native uv bootstrap command, equivalent to `uv sync --locked`.
It may access the configured package registry to install the exact committed
lockfile environment. Post-setup verification remains locked and offline.

## Stable command surface

Make is the stable shared interface; Python and uv remain the native project
tooling. The fixture's Makefile wraps locked uv execution:

| Command | Purpose |
| --- | --- |
| `make setup` | Install the exact environment from `uv.lock`; network access may be needed. |
| `make test` | Run pytest for `tests/` in locked uv offline mode. |
| `make lint` | Run Ruff lint checks in locked uv offline mode. |
| `make format` | Apply Ruff formatting to `src/` and `tests/`; this may modify files. |
| `make format-check` | Check Ruff formatting without modifying files. |
| `make typecheck` | Run strict mypy over `src/` and `tests/`. |
| `make verify` | Run `lint`, `format-check`, `typecheck`, then `test` without write-mode formatting. |

All commands except setup use `uv run --locked --offline`. After setup,
verification therefore requires no network, external service, credential,
model, or local configuration.

Useful native equivalents include:

```sh
uv run --locked --offline pytest
uv run --locked --offline ruff check src tests
uv run --locked --offline ruff format --check src tests
uv run --locked --offline mypy src tests
```

## Project structure

```text
src/reference_service/   packaged application code
tests/                    domain, application, and persistence tests
docs/                     repository and adoption documentation
.github/                  target-repository templates and CI
```

The `src/` layout ensures tests exercise the packaged import rather than an
unpackaged repository-root module.

## Scope of development

Keep application runtime code on the Python standard library. Changes to the
Python version, package manager, runtime dependencies, architecture, or CI
contract require explicit task scope.
