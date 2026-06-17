# Ecosystem Adapters

## Purpose

Ecosystem adapters specialise the framework baseline for a programming language or tooling ecosystem.

They capture the conventions and operational patterns that are common across repositories built in the same ecosystem, even when those repositories use different frameworks or serve different application roles.

Path:

```text
adapters/ecosystems/<name>
```

Examples include:

- Node
- Ruby
- Elixir

## What Belongs Here

Ecosystem adapters should usually capture things such as:

- package and dependency management conventions
- common linting, formatting, and type-checking patterns
- common testing tool expectations
- common CI runtime setup patterns
- common hook tooling patterns
- common Make target mappings for that ecosystem

These adapters should help answer questions such as:

- How are dependencies typically installed?
- What kinds of validation commands are normal in this ecosystem?
- What does a typical CI setup need in order to run?
- What hook or tooling patterns are common and reasonable defaults?

## What Does Not Belong Here

Ecosystem adapters should not usually contain:

- framework-specific workflow assumptions
- project-specific architecture
- project-specific domain documentation
- local runtime model details that belong in a runtime adapter
- broad system-role guidance that belongs in an app-shape adapter

For example:

- Rails-specific console or migration conventions belong in a framework adapter, not the generic Ruby ecosystem adapter
- Docker-specific execution patterns belong in a runtime adapter, not in the ecosystem adapter

## Relationship to Other Adapters

An ecosystem adapter is usually combined with:

- one framework adapter
- one runtime adapter
- optionally one app-shape adapter

Examples:

- Node + Express + Docker + API service
- Ruby + Sinatra + Docker + monolith
- Elixir + Phoenix + non-containerised + Admin app

## Design Principle

Ecosystem adapters should stay broad enough to be reusable across multiple frameworks in the same ecosystem.

If an adapter starts to depend heavily on one framework’s assumptions, that logic probably belongs in a framework adapter instead.
