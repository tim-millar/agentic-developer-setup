# Agent Development Framework

A reusable framework for enabling safe, productive agent-assisted development across application repositories.

This repository provides:

- a **baseline set of repo artefacts** for agent-enabled development
- **ecosystem, framework, runtime, and app-shape adapters** for different kinds of projects
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
adapters/    Ecosystem, framework, runtime, and app-shape overlays
checklists/  Adoption checklists for different repo types
prompts/     Prompt packs for using the framework with agents/LLMs
examples/    Example instantiated repo shapes
docs/        Documentation about the framework itself
framework.yml  Machine-readable framework metadata
```

## Core Concepts

### Baseline

The `baseline/` directory contains the shared artefacts that define the default framework shape.

In this source repository, baseline artefacts live under `baseline/`. When adopted into an application repository, they are intended to land at the target paths described in `framework.yml`.

These include target-repository documents and automation such as:

- `AGENTS.md`
- `docs/AGENT_PROMPT.txt`
- `docs/ARCHITECTURE.md`
- `docs/DEVELOPMENT.md`
- `docs/DOMAIN.md`
- `docs/TESTING.md`
- `docs/COMMITS.md`
- `Makefile`
- `lefthook.yml`
- `scripts/run_codex.sh`
- GitHub issue and PR templates
- baseline CI workflow

### Adapters

Adapters capture the assumptions needed to apply the framework to a specific repository. They are grouped into four types:

- ecosystem adapters for language and package-manager assumptions
- framework adapters for application-framework conventions
- runtime adapters for execution, container, and local-development assumptions
- app-shape adapters for architectural patterns such as API services, workers, monoliths, and static sites

A target repository may combine several adapters: for example, Ruby + Rails + Docker + monolith.

Adapters are intended to specialise the baseline, not replace it.

### Agent runtime

An agent runtime is the tool-specific launcher and operating policy for a specific coding agent.

The framework is agent-runtime-aware rather than agent-agnostic: shared repository practices live in the baseline, while agent-specific execution behaviour lives in runtime launchers.

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

1. copy or instantiate artefacts from `baseline/` into their target paths
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

## Example Adoption Workflow

The framework is intended to be adopted incrementally. A typical existing-repository adoption might look like this:

```text
Target repository:
  Existing web application with an established development workflow

Selected adapters:
  ecosystem: node
  framework: nextjs
  runtime: non-containerised
  app-shape: frontend-application
```

1. **Audit the repository**

   Use the existing-repo audit prompt to identify the current development commands, test coverage, CI behaviour, documentation gaps, and agent-readiness risks.

2. **Apply the baseline**

   Copy or adapt the baseline artefacts into the target repository using the `source_path` and `target_path` mappings in `framework.yml`.

   Examples:

   ```text
   baseline/AGENTS.md             -> AGENTS.md
   baseline/docs/DEVELOPMENT.md   -> docs/DEVELOPMENT.md
   baseline/docs/TESTING.md       -> docs/TESTING.md
   baseline/Makefile              -> Makefile
   ```

3. **Wire the command interface**

   Update the Makefile so agents and humans have a common command surface for routine checks.

   Example targets:

   ```text
   make setup
   make lint
   make test
   make typecheck
   make check
   ```

4. **Document repository-specific constraints**

   Fill in the target repository’s architecture, domain, development, and testing notes so agents have grounded context before making changes.

5. **Run agents with constrained access**

   Start with local-only agent sessions and GitHub access disabled. Enable GitHub App access only when the repository contract, permissions, and intended workflow are understood.

6. **Feed failures back into the framework**

   When an agent fails, update the relevant prompt, checklist, adapter, command, or repository document so the same class of failure is less likely to recur.

The goal is not just to complete one agent task, but to make the repository progressively more legible, testable, and safe for repeated agent-assisted development.

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

- begin with the artefacts under `baseline/` and the target paths in `framework.yml`
- select the relevant ecosystem, framework, runtime, and app-shape adapters
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
- proposing adapter-specific Makefile, hook, and CI overlays
- converting vague work into agent-ready implementation issues

The `prompts/` directory exists to support those workflows.

## Agent Runtime Support

This framework is general-purpose at the repository and workflow level, but agent runtimes are intentionally tool-specific.

Different coding agents have different interfaces, strengths, failure modes, and safety characteristics. Rather than hiding those differences behind a single generic wrapper, the framework treats each supported agent as a distinct runtime with its own launcher, prompt assembly, access policy, and operating constraints.

The current public baseline is Codex-first. It includes a Codex launcher for local agent sessions, repository validation, prompt construction, and optional GitHub App access.

The surrounding framework remains reusable across different application repositories through its baseline artefacts, workflow prompts, adoption tiers, metadata, and adapter model. Additional agent runtimes can be added alongside Codex where their behaviour and safety model justify separate support.

## Machine-Readable Framework Metadata

The file `framework.yml` provides structured metadata about the framework, including baseline artefacts, adoption tiers, agent runtime support, and adapter definitions.

For baseline artefacts, `framework.yml` records both the source path in this framework repository and the intended target path in an adopted repository. This makes the baseline usable by humans, agents, and future scaffolding scripts.

This is intended to make auditing, instantiation, and automated use easier for both humans and agents.

## Further Documentation

See also:

- `FRAMEWORK.md`
- `docs/repo-structure.md`
- `docs/adoption-tiers.md`
- `docs/adapter-format.md`
- `docs/usage-patterns.md`
