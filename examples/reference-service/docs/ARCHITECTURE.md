# Architecture

## Purpose and shape

The reference service is a small packaged domain/application service library.
It demonstrates repository boundaries and deterministic validation without
adding an HTTP, API, frontend, external service, or database server.

The implementation has exactly three concerns:

1. `src/reference_service/domain.py` contains `Task`, `TaskState`, the three
   public errors, title validation, and permitted state transitions.
2. `src/reference_service/application.py` contains the `TaskRegistry` use
   cases and the `TaskRepository` protocol consumed by them.
3. `src/reference_service/persistence.py` contains the
   `InMemoryTaskRepository` implementation.

## Dependency direction

Dependencies point from the concrete persistence implementation through the
application port to the domain:

```text
domain
  ↑
application
  ↑
persistence implementation
```

The domain imports no application or persistence code. The application imports
domain types and depends on the repository protocol, not on the in-memory
repository. Persistence implements that protocol and may use application and
domain types.

## Persistence boundary

`InMemoryTaskRepository` owns task storage and monotonically increasing IDs for
one repository instance. It is sufficient because this fixture is intended to
show a real persistence boundary with deterministic, process-local behaviour.
There is no SQLite database, external database, migration system, or service
dependency.

## Why there is no web/API layer

The example demonstrates how a repository contract, application service,
tests, Make interface, and CI fit together. HTTP routing and transport concerns
would add application surface without clarifying that adoption relationship,
so the public interface is the typed `TaskRegistry` service instead.

## Changing the architecture

Do not add architecture layers, event buses, CQRS, command frameworks,
dependency-injection frameworks, service containers, or additional persistence
implementations without explicit task scope. Changes to the three concerns,
their dependency direction, or the persistence strategy are decision-sensitive
and must be specified before implementation.
