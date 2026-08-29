# Reference service

This small Python package is a synthetic task registry used as a concrete,
executable example of manual framework adoption. It is a selected greenfield
reference adoption: repository instructions, documentation, native tooling,
Make commands, tests, and CI are visible together in one inspectable fixture.

It is not a production service, a universal project template, or evidence of
agent effectiveness.

## Prerequisites and setup

Use Python 3.14 and install [uv](https://docs.astral.sh/uv/). The committed
lockfile defines the development environment.

```sh
make setup
```

Run the complete deterministic verification suite with:

```sh
make verify
```

Setup may contact the package registry. After setup, the test, lint,
format-check, type-check, and verify commands use the locked environment in
uv offline mode and need no credentials, services, or local configuration.

## Inspecting application behaviour

The package exposes a small application service over an in-memory repository:

```sh
uv run --locked --offline python -c 'from reference_service import InMemoryTaskRepository, TaskRegistry; registry = TaskRegistry(InMemoryTaskRepository()); task = registry.create("Read the example"); print(registry.start(task.id))'
```

Read [the architecture guide](docs/ARCHITECTURE.md), [the domain reference](docs/DOMAIN.md),
[the development guide](docs/DEVELOPMENT.md), [the testing guide](docs/TESTING.md), and
[the framework adoption walkthrough](docs/FRAMEWORK_ADOPTION.md) for the repository contract
and rationale.
