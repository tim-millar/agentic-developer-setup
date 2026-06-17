# Runtime Adapters

## Purpose

Runtime adapters specialise the framework baseline for the way a repository is run locally.

They capture differences in local execution model rather than differences in language, framework, or business domain.

Path:

```text
adapters/runtimes/<name>
```

Examples include:

- Docker
- non-containerised

## What Belongs Here

Runtime adapters should usually capture things such as:

- how the standard Makefile command surface maps to local execution
- how local services are started
- how logs are accessed
- how shell or console access works
- how local commands differ from CI commands, where relevant
- how infrastructure or runtime complexity is hidden behind standard commands

These adapters should help answer questions such as:

- Does `make up` start containers or local processes?
- What should `make logs` do in this runtime model?
- How should shell access be exposed?
- How should local setup and runtime bootstrapping work?

## What Does Not Belong Here

Runtime adapters should not usually contain:

- ecosystem-specific tooling conventions
- framework-specific development patterns
- project-specific architecture
- domain-specific behaviour
- broad application-role guidance that belongs in an app-shape adapter

For example:

- Node package manager conventions belong in an ecosystem adapter
- Rails migration and console conventions belong in a framework adapter
- API-service testing emphasis belongs in an app-shape adapter

## Relationship to Other Adapters

A runtime adapter is usually combined with:

- one ecosystem adapter
- one framework adapter
- optionally one app-shape adapter

Examples:

- Node + Next.js + non-containerised
- Ruby + Rails + Docker
- Elixir + Phoenix + Docker + Admin app

## Design Principle

Runtime adapters should focus on local execution shape and operational ergonomics.

They should make it easier for humans and agents to use a consistent command surface regardless of whether the underlying runtime is container-based or local-tooling-based.
