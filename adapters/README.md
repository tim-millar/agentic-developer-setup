# Adapters

## Purpose

The `adapters/` directory contains overlays that specialise the framework baseline for particular stacks or local runtime models.

Adapters exist so that repositories can share a common agent-development framework while still applying the conventions, tooling patterns, and operational details that make sense for their ecosystem.

Adapters are intended to be:

- small
- composable
- focused
- additive where possible

They are not intended to replace the baseline.

## Core Principle

The baseline defines the shared framework shape.

Adapters specialise that shape where a repository’s stack or runtime model requires it.

In general:

- start from `baseline/`
- apply only the adapters that materially affect the repository
- preserve the baseline where no specialisation is needed

Adapters should extend or override the baseline only where there is a clear reason to do so.

## Adapter Types

The framework currently treats adapters as belonging to two broad categories.

### Stack adapters

Stack adapters specialise the baseline for a language or ecosystem.

Examples include:

- `node/`
- `ruby/`
- `elixir/`

A stack adapter may provide guidance or overlays for:

- Makefile command mappings
- testing, linting, formatting, and type-check patterns
- CI runtime/tooling setup
- hook integrations
- documentation notes relevant to that ecosystem

### Environment adapters

Environment adapters specialise the baseline for a local runtime model.

Examples include:

- `docker/`
- `non-containerised/`

An environment adapter may provide guidance or overlays for:

- how the standard command surface maps to local execution
- how runtime startup is handled
- how logs, shell access, and interactive consoles work
- how local and CI commands differ
- how infrastructure complexity is hidden behind the Makefile

## Adapters Are Composable

Repositories will often use more than one adapter.

Typical combinations include:

- Node + Docker
- Ruby + Docker
- Elixir + non-containerised

This is the intended usage model.

Adapters should therefore be designed to combine cleanly rather than assuming that only one adapter will be applied.

## What Belongs in an Adapter

Adapters should usually contain small overlays such as:

- Makefile fragments or examples
- CI setup snippets
- hook-related examples
- testing notes for the relevant stack or runtime model
- local development notes that refine `docs/DEVELOPMENT.md`
- stack-specific notes that refine `docs/TESTING.md`

Adapters should not usually contain:

- a full replacement baseline
- a complete application template
- project-specific architecture
- project-specific domain documentation

If an adapter starts to look like an entire standalone framework, it is probably too large.

## Choosing Adapters

When applying the framework to a repository:

1. start from the baseline
2. choose the stack adapter that best matches the dominant application ecosystem
3. choose the environment adapter that best matches the local development model
4. apply only the specialisations that are actually needed
5. keep the number of overrides as small as practical

A good rule is:

- prefer the baseline by default
- use adapters to handle real stack or runtime differences
- avoid introducing adapter-specific behaviour without a clear need

## Greenfield vs Existing Repositories

### Greenfield repositories

For greenfield repos, adapters can be applied early and cleanly.

This usually means:

- start with `baseline/`
- choose the relevant stack and environment adapters
- instantiate the repo docs and command surface using those overlays

### Existing or legacy repositories

For existing repos, adapters should be applied more selectively.

This usually means:

- compare the repo against the baseline first
- identify where the current repo already matches the framework goals
- use adapters only where they clarify or standardise existing behaviour
- avoid rewriting healthy repo-specific patterns just to match an adapter mechanically

## Adapter Structure

Each adapter directory should be small and legible.

A typical adapter may contain files such as:

- `README.md`
- `make/`
- `ci/`
- `hooks/`
- `docs/`

Not every adapter needs all of these.

The exact structure should reflect the minimal set of overlays needed for that adapter.

For more formal guidance on adapter layout and conventions, see:

- `docs/adapter-format.md`

## Relationship to Other Framework Parts

See also:

- `baseline/` for the shared framework layer
- `framework.yml` for machine-readable adapter metadata
- `checklists/` for practical adoption flows
- `docs/adapter-format.md` for adapter authoring guidance
- `README.md` for the high-level framework overview
