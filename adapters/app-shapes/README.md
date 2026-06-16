# App-Shape Adapters

## Purpose

App-shape adapters specialise the framework baseline for the broad kind of system a repository represents.

They capture the operational, documentation, and testing implications of the application’s role, without trying to define its full architecture.

Examples include:

- API service
- Frontend app
- Fullstack monolith
- Admin app

## What Belongs Here

App-shape adapters should usually capture things such as:

- likely command-surface emphasis
- likely testing emphasis
- likely documentation emphasis
- common CI validation categories
- common operational concerns for this kind of system

These adapters should help answer questions such as:

- Is this repo likely to care most about API/integration testing or browser/e2e testing?
- Which Make targets are most important to expose clearly?
- Which documentation sections are likely to need more detail?
- Which quality gates are especially important for this kind of repo?

## What Does Not Belong Here

App-shape adapters should not usually contain:

- language-specific tooling choices
- framework-specific workflow assumptions
- project-specific architecture decisions
- project-specific domain rules
- local execution model details that belong in a runtime adapter

For example:

- Express-specific conventions belong in a framework adapter
- Docker-specific local workflow belongs in a runtime adapter
- the actual service boundaries of a particular monolith belong in the instantiated repo’s `docs/ARCHITECTURE.md`

## Relationship to Other Adapters

An app-shape adapter is usually combined with:

- one ecosystem adapter
- one framework adapter
- one runtime adapter

Examples:

- Node + Express + Docker + API service
- Node + Next.js + non-containerised + Frontend app
- Ruby + Sinatra + Docker + Fullstack monolith
- Elixir + Phoenix + Docker + Admin app

## Design Principle

App-shape adapters should stay broad and operational.

They are not a substitute for real architecture documentation. Their role is to capture the common workflow, validation, and documentation implications of a broad application type so that the baseline can be specialised more intelligently.
