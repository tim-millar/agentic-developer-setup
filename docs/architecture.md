# Framework architecture

This document describes the agent development framework as an engineering system and this public repository as its source repository. It does not replace the standing instructions in [`AGENTS.md`](../AGENTS.md), and it is distinct from [`baseline/docs/ARCHITECTURE.md`](../baseline/docs/ARCHITECTURE.md), which is a reusable scaffold for architecture documentation in a target repository.

## System boundary

This repository has two roles:

1. It is a maintained software repository with its own operational development contract, validation, runtime entrypoint, and review workflow.
2. It is the public framework source repository for reusable artefacts that target repositories can adopt or adapt.

Reusable framework source includes baseline artefacts, machine-readable metadata, prompts, agent runtime integrations, the adapter taxonomy, adoption guidance, and templates. [`framework.yml`](../framework.yml) is authoritative for declared artefacts and their mappings:

- a **source path** is the location of an artefact in this framework source repository;
- a **target path** is its intended location in an adopted target repository.

For example, `baseline/AGENTS.md` is a source path and `AGENTS.md` is its target path. Root `AGENTS.md` operates this repository; it is a repository-specific specialisation, not the declared reusable source. Matching root and baseline paths are neither interchangeable nor required to be identical.

The same distinction applies to launchers, prompts, Makefiles, workflows, and templates. Metadata describes the reusable framework contract, while the live filesystem establishes whether a declared or documented implementation currently exists.

## Responsibilities

### Framework source repository

The framework supplies reusable structure and controls for repository legibility, task definition, command interfaces, validation, agent access, review handoff, and incremental adoption. It also makes its current implementation choices inspectable through public metadata, source, tests, documentation, issues, and pull requests.

It does not make an adopting repository's engineering decisions. A target repository owns its:

- domain rules, business constraints, and architecture documentation;
- standing agent policy, directory-specific instructions, and task constraints;
- command bindings and native build, package, test, and deployment tooling;
- validation implementation, test strategy, and required CI contract;
- high-risk areas, permissions, access rules, and security boundaries;
- issue or task acceptance criteria, non-goals, and public interfaces.

Baseline artefacts provide places to express these decisions. Adapters can specialise framework assumptions. Neither substitutes for repository-specific judgement.

## Repository contract and execution context

For work in this source repository, instruction precedence is:

1. explicit human instructions for the current task;
2. the current implementation specification or task brief;
3. more specific directory-level instructions;
4. standing repository instructions;
5. general agent defaults.

Architecture and domain documentation provide factual and structural context. They do not independently authorise additional scope. Runtime and session prompts assemble repository, task, access, and execution context for an agent; they do not supersede repository policy or task constraints.

A target repository should make its own equivalent relationships explicit. The exact files and workflow can differ, but an agent must be able to determine which instructions govern and which sources merely describe the system.

## Task boundary

Deterministic autonomous implementation requires an implementation-ready task: the intended behaviour, scope, acceptance criteria, non-goals, architectural constraints, unresolved decisions, public interfaces, security or access implications, and required validation must be resolved far enough for implementation.

That specification may be a GitHub issue, a local document, a prompt, or another structured brief. The reusable principle is resolved material decisions, not a universal issue tracker or planning ceremony.

Work falls into three broad modes:

- **Implementation-ready:** material decisions are resolved and an agent can implement within explicit authority.
- **Discovery or shaping:** investigation or design is needed before deterministic implementation; the output should resolve or expose decisions rather than silently make them.
- **Human-directed bounded work:** focused review, explanation, refactoring, testing, or drafting can be directed interactively without a formal issue.

This source repository applies a procedural policy to substantial issue- or specification-led changes:

```text
one issue or implementation specification
        |
        v
one branch
        |
        v
one pull request
```

That is this repository's workflow policy, not a mandatory workflow for every adopter. A target repository may choose different mechanisms if its standing contract states how scope, authority, validation, and review are controlled.

## Trust and control flow

The following representation shows control ownership and the boundaries at which claims or authority must be checked:

```text
Task / implementation specification                  [scope authority]
        |
        v
Repository contract + repository-specific context    [instruction boundary]
        |
        v
Agent runtime + access policy                         [process and credential boundary]
        |
        v
Repository command surface                            [tool-execution boundary]
        |
        v
Local validation / required CI                        [evidence boundary]
        |
        v
Human review + merge decision                         [acceptance boundary]
```

Information and authority do not pass these boundaries implicitly. A task does not override standing no-go areas; a runtime credential does not broaden task scope; a local pass does not prove a remote CI result; and validation evidence does not make the merge decision.

### Control classes

The framework combines controls with different purposes:

- **Preventative:** repository identity checks, explicit no-go areas, scoped credentials, bounded tasks, instruction precedence, and repository-specific access policy.
- **Detective:** tests, linting, type checks, framework validation, required CI, code review, and review of evidence.
- **Procedural:** explicit acceptance criteria, this repository's issue/specification-to-branch-to-PR policy, validation handoff, and documented provenance.
- **Recovery:** stopping on unresolved material ambiguity, preserving diagnostic evidence, recording follow-up work instead of improvising, and tightening the appropriate repository or framework control after failure analysis.

These controls reduce particular risks. They do not make agent-assisted work absolutely safe or eliminate the need for engineering judgement.

## Command and validation boundary

Make is the primary conceptual command interface represented by this framework. Make targets wrap a repository's native package-manager scripts, language tools, containers, build systems, and existing automation; they do not replace useful native tooling. A target repository retains responsibility for the implementation behind each target.

Where practical, humans, agents, hooks, and CI should invoke the same conceptual validation surface. Their responsibilities remain distinct:

- local commands produce fast, reproducible evidence before handoff;
- hooks provide earlier feedback at repository-defined lifecycle points;
- validation evidence records the exact commands actually run and their outcomes;
- where CI is part of a target repository's required validation contract, CI is authoritative for merge-time automated evidence. Local validation and hooks provide earlier feedback but do not substitute for required CI.

The framework does not require every adopter to use CI or an identical CI architecture. A successful local command does not establish that remote CI passed.

This repository's own command and validation contract is documented in [`docs/validation.md`](validation.md).

## Agent runtime and access boundary

Agent runtimes are tool-specific integrations because tools differ in interfaces, prompt handling, credential models, process lifecycles, and security properties. They are not assumed to be interchangeable.

[`framework.yml`](../framework.yml) currently declares Codex as the supported public runtime. Claude Code is planned and must not be treated as supported runtime behaviour. At an architectural level, the public Codex launcher implements:

- repository-root discovery and expected repository identity checking;
- assembly of repository instructions, session metadata, and optional task context;
- `disabled` and GitHub App access modes;
- launcher-side custody of long-lived App source credentials;
- short-lived, repository-scoped installation authority exposed to the child through restricted environment and helper boundaries;
- separation between launcher state and the Codex process environment;
- private temporary resources, signal handling, and cleanup;
- agent, access-mode, Git-mode, and launch provenance metadata where implemented.

The executable implementation is [`baseline/scripts/run_codex.sh`](../baseline/scripts/run_codex.sh); its offline behavioural test architecture is documented in [`docs/launcher-testing.md`](launcher-testing.md). These sources, rather than this overview, define implementation details.

Launcher-managed renewal exists for App-mode GitHub authority. Recovery across sufficiently long process suspension or inactivity remains a lifecycle area under refinement; [Issue #43](https://github.com/tim-millar/agentic-developer-setup/issues/43) tracks that follow-up. This limitation should not be read as a promise of transparent credential availability after arbitrary suspension, nor does this document prescribe the eventual solution.

## Human review boundary

Human judgement is attached to concrete control points:

- task shaping when material requirements remain unresolved;
- product, architecture, security, permission, and dependency-policy decisions;
- approval of high-risk changes or expanded authority;
- review of implementation scope and conformance;
- review of commands run, CI evidence where required, failures, assumptions, and limitations;
- resolution of ambiguity that authorised sources cannot settle;
- the final merge decision.

Agents may make routine implementation decisions within a resolved task. They must not convert missing material decisions into implicit framework, product, security, or repository policy.

## Adoption model

The metadata defines three incremental usage modes:

- **Greenfield bootstrap:** instantiate relevant baseline artefacts and specialisations in a new repository.
- **Existing repository adoption:** audit the repository and adopt high-value controls incrementally while preserving useful native practices.
- **Legacy safe enablement:** add a bounded safety and clarity overlay to a long-running or high-risk repository without treating adoption as a rewrite.

Adoption tiers describe increasing framework capability, not mandatory migration stages:

- **Tier 1: agent-aware** provides basic documentation and workflow scaffolding.
- **Tier 2: agent-operable** adds standard command, launcher, hook, and CI artefacts.
- **Tier 3: agent-optimised** adds fuller architecture, domain, testing, and commit-convention support.

Adapters specialise assumptions by **ecosystem**, **framework**, **runtime**, or **app-shape**. The taxonomy exists now, but all named adapter implementations declared in `framework.yml` are planned. Planned paths are not current implementations.

A target repository may combine baseline artefacts, adapters when available, and its own specialisation to the degree its contract requires. It need not adopt every artefact or process identically, and useful native tooling should generally be preserved.
