# Framework evolution

This framework developed from repeated engineering work rather than from a universal repository template. Its history explains why it separates reusable controls from repository-specific implementation, but private work is not evidence for current public behaviour. Current behaviour must be established from this repository's public artefacts as described in [`public-evidence.md`](public-evidence.md).

## From repository practice to a public framework

The broad evolution was:

1. Repository-specific agent-assisted development practices were used in a substantial private personal application.
2. Repeated implementation work exposed recurring controls and workflow patterns.
3. Those observations informed more reusable internal patterns and conventions.
4. Related principles were applied in an established production repository with different constraints and risk boundaries.
5. Further use across greenfield and differently shaped private applications tested which concerns were genuinely reusable and which required specialisation.
6. The reusable public framework in this repository was independently specified and implemented.

Private personal and professional experience informs general engineering conclusions and reusable design principles. Private code, prompts, schemas, repository structures, operational details, and other proprietary implementation material were not copied or closely translated into this public repository. The framework should remain understandable and supportable entirely from its public source.

Generic categories such as a secure document platform, production commerce application, constrained analytics service, staged archive platform, greenfield application, or established production repository describe relevant differences without asserting public access to private implementations or implying employer endorsement.

## Concerns that proved reusable

Across different repository contexts, the reusable concerns were categories of engineering control rather than identical file layouts:

- standing repository instructions and explicit instruction precedence;
- bounded tasks with acceptance criteria and non-goals;
- repository legibility through development, architecture, domain, and testing context;
- common conceptual command interfaces over native tooling;
- deterministic validation and inspectable CI or review evidence where required;
- separation of runtime policy from repository policy;
- bounded access and credentials;
- issue, task, commit, and pull-request handoff structure;
- public provenance and evidence discipline;
- escalation of unresolved material decisions to an authorised human.

These patterns do not prove that every private repository used the same files, commands, ceremonies, or runtime implementation. They explain the design questions that the public baseline, metadata, prompts, templates, and supported runtime address.

## Concerns that remain repository-specific

Domain models, system architecture, persistence, application frameworks, infrastructure, security models, deployment, business rules, validation implementations, detailed test strategies, risk boundaries, permission models, and operational constraints remain specialised.

Those choices depend on the target repository's users, data, threat model, history, tooling, and delivery environment. Generalising them would either erase important constraints or embed one project's decisions as misleading defaults. The framework instead provides structures in which a target repository can state and enforce its own decisions.

## Baseline plus specialisation

Application shape, repository maturity, native tooling, security boundaries, team practice, agent runtime, and desired adoption depth vary materially. The framework therefore combines:

- reusable baseline artefacts with explicit source paths and target paths;
- machine-readable metadata for declared relationships and status;
- repository-specific instructions and documentation;
- adapters for ecosystem, framework, runtime, and app-shape differences;
- incremental adoption tiers and usage modes.

This is preferable to a monolithic universal repository template. A greenfield service can adopt a fuller baseline early; an established production repository can add only the controls that fit safely; a legacy repository can expose a narrow validated command surface before making deeper changes.

The framework's current architecture and adoption boundaries are documented in [`architecture.md`](architecture.md). [`framework.yml`](../framework.yml) remains authoritative for declared artefacts, tier contents, runtime status, and adapter status.

## Preserve native tooling

Adoption should normally wrap or expose valid existing commands rather than replace them for cosmetic uniformity. A Make target might delegate to package-manager scripts, language-native test tools, container commands, or an existing build system. The stable conceptual surface helps humans and agents discover the right operation, while the repository retains the implementation suited to its ecosystem.

Replacement is justified only by a repository-specific need, not by the framework's preference for a common entrypoint. The framework does not prescribe a package manager, language, application framework, container model, or CI provider.

## Runtime-specific policy

Coding agents have different process models, configuration precedence, prompt interfaces, access mechanisms, and failure modes. Runtime integration may therefore require different:

- launchers and repository identity checks;
- credential and renewal models;
- prompt and task-context assembly;
- access controls and process-environment boundaries;
- lifecycle, suspension, and cleanup handling;
- documented operational limitations.

A single launcher cannot safely be assumed to abstract every coding agent. Shared repository principles can remain stable while each supported agent runtime receives its own explicit policy and implementation.

## Feedback from friction and failure

The intended improvement loop is:

```text
operational friction or failure
        |
        v
diagnosis
        |
        v
repository-specific cause or reusable cause?
        |
        v
tighten repository guidance, validation, runtime policy,
task specification, or reusable framework control as appropriate
```

Diagnosis matters because a local application defect should not become a universal framework rule, while a repeated control failure should not be patched independently in every repository. The resulting change should be made at the narrowest correct layer and supported by public evidence when it affects this framework.

This feedback model is a design intention, not a claim about measured productivity or a record of undocumented incidents.

## Deliberately not generalised

The framework does not seek to generalise or publish:

- proprietary domain logic or employer-specific workflows;
- organisation-specific infrastructure or security details;
- private prompts, schemas, or repository layouts;
- every development ceremony;
- every agent runtime behind one abstraction;
- every application architecture;
- every CI implementation.

These boundaries keep the public framework reusable without turning private implementation choices into unsupported universal policy.
