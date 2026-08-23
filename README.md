# Agent Development Framework

A reusable framework for enabling safe, productive agent-assisted development across application repositories.

This public framework source repository provides:

- a **baseline set of repo artefacts** for agent-enabled development
- an **ecosystem, framework, runtime, and app-shape adapter taxonomy**, with implementations currently planned
- **adoption prompts** for greenfield, existing, and legacy repositories
- **prompt packs** for using the framework with LLMs and coding agents
- public technical documentation for the framework architecture, evolution, and evidence boundaries

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
adapters/    Adapter taxonomy and planned implementation locations
agent-runtimes/  Globally installed coding-agent runtime source
prompts/     Prompt packs for using the framework with agents/LLMs
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

A target repository may eventually combine several adapters. All named adapter implementations in `framework.yml` are currently planned; the repository currently provides their taxonomy and composition guidance.

Adapters are intended to specialise the baseline, not replace it.

### Agent runtime

An agent runtime is the tool-specific launcher and operating policy for a specific coding agent.

The framework is agent-runtime-aware rather than agent-agnostic: shared repository practices live in the baseline, while agent-specific execution behaviour lives in runtime launchers.

### Prompts

The `prompts/` directory contains reusable prompts for working with the framework using agents or LLMs.

Examples include:

- bootstrapping a new greenfield repo
- auditing an existing repo
- generating repo documentation from the framework
- turning vague work into agent-ready issues

## Primary Usage Modes

### 1. Greenfield bootstrap

Use the framework to initialise a new repository that is intended to support agent-led development from the start.

Typical flow:

1. copy or instantiate artefacts from `baseline/` into their target paths
2. apply relevant adapters when implementations are available
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

Potential adapter specialisations (when implementations are available):
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

6. **Feed failures back into the appropriate control**

   Diagnose whether a failure is repository-specific or reusable, then update the relevant prompt, command, repository document, runtime policy, or framework control.

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
- select relevant adapters when implementations are available
- use `prompts/greenfield-bootstrap.md`
- instantiate repo-specific docs from the project plan, architecture, and issue set

### Adopting the framework in an existing repo

- use `prompts/existing-repo-audit.md`
- compare the repo against `baseline/`
- adopt the highest-value artefacts first
- preserve useful existing workflow where it is not in conflict with the framework goals

### Enabling a legacy repo safely

- use `prompts/legacy-safe-enablement.md`
- treat the framework as an overlay first, not a rewrite
- prioritise bounded scope, explicit risks, and safe validation paths

## Using This Repository With Agents

This repository is intended to be usable directly by coding agents and LLMs.

This framework source repository uses a minimal self-hosted agent harness:

- root `AGENTS.md` defines the operating contract for work on this repository
- root `docs/AGENT_PROMPT.txt` provides the repository-specific session bootstrap
- root `scripts/run_codex.sh` is the supported Codex entrypoint

Launch Codex from the repository root with:

```sh
./scripts/run_codex.sh
```

These root files govern this repository only. The corresponding files under `baseline/` remain the reusable framework source artefacts declared in `framework.yml`. The root launcher supplies repository-specific location and identity defaults, then delegates to the executable canonical implementation at `baseline/scripts/run_codex.sh` rather than duplicating its behaviour. Keeping that baseline launcher executable supports both direct delegation here and direct use when the artefact is adopted into another repository.

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

Two coding-agent runtimes are supported with deliberately separate purposes and distribution models:

- Codex is repository-distributed through baseline launcher and prompt artefacts for deterministic implementation and optional GitHub App workflows.
- [`claude-explore`](docs/runtimes/claude-explore.md) is globally installed user tooling for supervised exploratory engineering with reduced ambient authority. It is not an autonomous issue-to-PR workflow.

Coding-agent runtimes are separate from repository enablement and environment adapters. Repository files such as `AGENTS.md` and `CLAUDE.md` provide project context; environment adapters describe where repository commands execute; a coding-agent runtime controls how the coding-agent process is launched.

The launcher also requests preservation of the host command `PATH` used by Codex. An adopting repository may provide an optional non-symlink regular file at `scripts/agent_host_env.sh` to select already-installed host tools; without it, the inherited `PATH` is preserved explicitly. The hook runs in an isolated credential-sanitised Bash subprocess, returns only `PATH`, and does not alter the parent launcher's command resolution. Launcher sessions disable Codex login-shell startup and shell-profile environment reconstruction, and forwarded Codex configuration cannot override those settings or `shell_environment_policy`; unrelated forwarded configuration remains supported.

The launcher does not weaken user, project, managed, or organisation environment filtering, broaden inheritance, disable secret filtering, or rewrite persistent Codex configuration. An effective higher-authority Codex policy that filters out `PATH` is therefore incompatible with launcher PATH preservation; any resulting Codex configuration failure is reported rather than bypassed. This mechanism is independent of application ecosystem and execution model, and trusted repository hooks are not an operating-system sandbox.

The surrounding framework remains reusable across different application repositories through its baseline artefacts, workflow prompts, adoption tiers, metadata, and adapter model. Additional agent runtimes can be added alongside Codex where their behaviour and safety model justify separate support.

## Machine-Readable Framework Metadata

The file `framework.yml` provides structured metadata about the framework, including baseline artefacts, adoption tiers, agent runtime support, and adapter definitions.

For baseline artefacts, `framework.yml` records both the source path in this framework repository and the intended target path in an adopted repository. This makes the baseline usable by humans, agents, and future scaffolding scripts.

This is intended to make auditing, instantiation, and automated use easier for both humans and agents.

Validate the root repository tests, live metadata, and required source structure with:

```sh
make check
```

See `docs/validation.md` for the validation contract, path semantics, and extension guidance.
Run the focused offline Codex launcher suite with `make test-launcher`; see
`docs/launcher-testing.md` for its black-box fixture and fake-command architecture.
Run the focused offline Claude exploration runtime suite with
`make test-claude-runtime`.

## Further Documentation

See also:

- [`docs/architecture.md`](docs/architecture.md) for framework architecture, responsibilities, trust boundaries, and current capability status
- [`docs/evolution.md`](docs/evolution.md) for the framework's engineering evolution and public/private provenance model
- [`docs/public-evidence.md`](docs/public-evidence.md) for public claim and disclosure boundaries
- `framework.yml` for machine-readable framework metadata
- `docs/validation.md` for framework self-validation
- `docs/launcher-testing.md` for the offline baseline launcher test architecture
- [`docs/runtimes/claude-explore.md`](docs/runtimes/claude-explore.md) for installation, policy, threat model, and smoke testing
- `adapters/README.md` for adapter taxonomy and composition guidance
- `prompts/greenfield-bootstrap.md` for greenfield framework adoption
- `prompts/existing-repo-audit.md` for existing repository assessment
- `prompts/legacy-safe-enablement.md` for legacy safe-enablement planning
