# Agent Development Framework

A reusable framework for enabling safe, productive agent-assisted development across application repositories.

This repository provides:

- a **baseline set of repo artefacts** for agent-enabled development
- **stack and environment adapters** for different kinds of projects
- **checklists** for greenfield, existing, and legacy repo adoption
- **prompt packs** for using the framework with LLMs and coding agents
- **examples** showing how the framework can be instantiated in real repositories

The framework is intended to support both:

- **greenfield projects** that are designed for agent-led development from the start
- **existing or legacy codebases** that need to be made safer and more legible for agents over time

## What This Repository Is For

This framework exists to make agents easier to use across repositories in a consistent, bounded, and reviewable way.

It is designed to help standardise:

- agent operating contracts
- issue quality and execution readiness
- development documentation
- validation and testing expectations
- commit and PR metadata conventions
- Makefile command surfaces
- local hooks and CI quality gates

The framework is not a single application template. It is a reusable operating layer that can be instantiated or adapted for many different projects.

## Repository Structure

```text
baseline/    Shared baseline artefacts used in agent-enabled repos
adapters/    Stack- or environment-specific overlays
checklists/  Adoption checklists for different repo types
prompts/     Prompt packs for using the framework with agents/LLMs
examples/    Example instantiated repo shapes
docs/        Documentation about the framework itself
framework.yml  Machine-readable framework metadata
```

## Core Concepts

### Baseline

The `baseline/` directory contains the shared artefacts that define the default framework shape.

These include documents and automation such as:

- `AGENTS.md`
- `docs/AGENT_PROMPT.txt`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `docs/DOMAIN.md`
- `docs/TESTING.md`
- `docs/COMMITS.md`
- `Makefile`
- `lefthook.yml`
- `scripts/run_agent.sh`
- GitHub issue and PR templates
- baseline CI workflow

### Adapters

The `adapters/` directory contains overlays for specific stacks or runtime models.

Examples include:

- `node/`
- `ruby/`
- `elixir/`
- `docker/`
- `non-containerised/`

Adapters are intended to specialise the baseline, not replace it.

### Checklists

The `checklists/` directory describes how to apply the framework in different scenarios.

Typical checklist categories include:

- greenfield application setup
- existing repo adoption
- legacy repo safe enablement
- issue readiness

### Prompts

The `prompts/` directory contains reusable prompts for working with the framework using agents or LLMs.

Examples include:

- bootstrapping a new greenfield repo
- auditing an existing repo
- generating repo documentation from the framework
- turning vague work into agent-ready issues

### Examples

The `examples/` directory shows what instantiated or partially adopted repos may look like.

These examples are intended to illustrate usage patterns, not define mandatory project shapes.

## Primary Usage Modes

### 1. Greenfield bootstrap

Use the framework to initialise a new repository that is intended to support agent-led development from the start.

Typical flow:

1. copy or instantiate the `baseline/`
2. apply relevant adapters
3. specialise the docs for the project domain, architecture, and workflow
4. wire up hooks, Make targets, and CI
5. begin work using issue-driven, agent-compatible processes

### 2. Existing repo adoption

Use the framework to improve an existing repository without forcing a full rewrite of its development model.

Typical flow:

1. compare the repo against the baseline
2. identify the current adoption tier
3. add the missing high-value artefacts first
4. standardise commands and validation incrementally
5. tighten documentation and automation over time

### 3. Legacy repo safe enablement

Use the framework as a safety and clarity overlay for a legacy codebase.

Typical flow:

1. document safe working boundaries
2. introduce the agent contract and local development guide
3. improve issue quality and PR structure
4. expose a safe command surface
5. expand automation and documentation gradually

## Adoption Tiers

The framework supports incremental adoption.

A typical model is:

- **Tier 1: agent-aware**  
  basic documentation and workflow scaffolding

- **Tier 2: agent-operable**  
  standard commands, launcher, hooks, and CI

- **Tier 3: agent-optimised**  
  fuller domain, architecture, testing, and commit-convention support

See the framework documentation and `framework.yml` for the current tier definitions.

## How To Start

Choose the path that matches your goal.

### Starting a new project

- begin with `baseline/`
- select the relevant adapters
- use the greenfield checklist
- instantiate repo-specific docs from the project plan, architecture, and issue set

### Adopting the framework in an existing repo

- start with the existing-repo checklist
- compare the repo against `baseline/`
- adopt the highest-value artefacts first
- preserve useful existing workflow where it is not in conflict with the framework goals

### Enabling a legacy repo safely

- start with the legacy-repo checklist
- treat the framework as an overlay first, not a rewrite
- prioritise bounded scope, explicit risks, and safe validation paths

## Using This Repository With Agents

This repository is intended to be usable directly by coding agents and LLMs.

Typical agent workflows include:

- instantiating the framework for a new repo
- auditing an existing repo against the baseline
- generating draft project docs from existing context
- proposing stack-specific Makefile, hook, and CI overlays
- converting vague work into agent-ready implementation issues

The `prompts/` directory exists to support those workflows.

## Machine-Readable Framework Metadata

The file `framework.yml` provides structured metadata about the framework, including baseline artefacts, adoption tiers, and adapter definitions.

This is intended to make auditing, instantiation, and automated use easier for both humans and agents.

## Further Documentation

See also:

- `FRAMEWORK.md`
- `docs/repo-structure.md`
- `docs/adoption-tiers.md`
- `docs/adapter-format.md`
- `docs/usage-patterns.md`
