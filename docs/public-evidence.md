# Public evidence and disclosure boundaries

This document defines how claims associated with this public framework source repository should be interpreted. It separates inspectable repository evidence from experience that may inform design, and it defines what must not be published without separate authority.

## Evidence categories

| Category | Meaning | Examples | Claim or publication constraint |
| --- | --- | --- | --- |
| Publicly inspectable evidence | Independently verifiable from public repository artefacts | Source, `framework.yml`, runtime implementation, tests, validation code, CI, documentation, public issues and pull requests; public examples or evaluations once they exist | May support directly verifiable claims within the limits of what the artefact demonstrates |
| Private/professional experience | Relevant engineering experience that is not publicly auditable | Recurring concerns observed across private personal or professional repositories; differences among application shapes and risk profiles | May explain design motivation, but cannot prove this repository's implementation or outcomes |
| Sanitised/derived evidence | Independently produced public artefacts informed by private experience | Generic diagrams, rewritten examples, synthetic fixtures, authorised aggregate measurements, or non-proprietary case descriptions | Must be independently created, publication-authorised, and free of copied or closely translated protected implementation material |
| Intentionally excluded material | Material that must remain unpublished absent separate authority | Private source, prompts, data, credentials, proprietary structures, sensitive operations, or unclear-ownership material | Must not be committed, quoted, reconstructed, or used as public substantiation |

## Publicly inspectable evidence

Publicly inspectable evidence is material an external reader can independently examine. In this repository it includes:

- source code and reusable baseline artefacts;
- public framework metadata;
- the public Codex runtime implementation;
- public tests, validation code, and CI configuration;
- public documentation;
- public issues and pull requests;
- public examples and evaluation artefacts once they exist.

Claims about implemented framework behaviour should link or otherwise correspond to these sources. [`framework.yml`](../framework.yml), for example, is evidence of declared runtime and adapter status; [`baseline/scripts/run_codex.sh`](../baseline/scripts/run_codex.sh) and its public tests are evidence of implemented launcher behaviour.

A planned file, planned metadata entry, roadmap statement, or open issue is evidence of intent or investigation, not evidence that behaviour exists. Public artefacts also have limited scope: a test pass supports the tested contract under its stated conditions, not universal correctness.

## Private personal and professional experience

This repository is informed by repeated agent-assisted development work across private personal and professional repositories with materially different application shapes and risk profiles. That experience may support statements that:

- a design concern recurred in multiple repository contexts;
- a class of operational friction motivated a reusable control;
- different application shapes required repository-specific specialisation.

External readers cannot audit those repositories, so this category is not publicly verifiable evidence. Private implementation details must not substantiate a claim that should be supported by public source. Private personal work must not be described as commercial or production work unless that description is true, relevant, disclosable, and publication-authorised.

The public framework is independently specified and implemented. Experience can inform general conclusions; private code, prompts, schemas, repository structures, and operational details are not copied or closely translated into this repository.

## Sanitised or derived evidence

Sanitised or derived evidence is new public material informed by private experience but independently rewritten or recreated for public use. It may include:

- generic architecture or control diagrams;
- rewritten examples and synthetic fixtures;
- aggregate measurements where methodology, rights, and publication authority are established;
- public case-study descriptions that omit proprietary implementation details.

Sanitisation alone does not establish ownership. It also does not establish permission to publish. Independently rewriting confidential material does not automatically make disclosure permissible. A public derivation must avoid copying, reconstructing, or closely translating protected private implementation material and must have a clear public provenance.

## Intentionally excluded material

The following must not be published through this repository without separate, explicit authority:

- private source code or other private repository contents;
- private prompts or instructions containing proprietary details;
- private issue bodies or pull-request content;
- credentials, tokens, private keys, secrets, or local environment material;
- internal secret-handling procedures beyond a safe architectural description;
- proprietary schemas, business logic, or repository layouts;
- customer, employee, commercial, or operational data;
- private infrastructure topology;
- private security controls whose disclosure could increase risk;
- unapproved screenshots;
- unapproved adoption data or productivity metrics;
- employer-specific internal workflows;
- any material whose ownership or publication rights are unclear.

Exclusion applies whether material is copied verbatim, reconstructed, paraphrased too closely, or embedded in an example or fixture.

## Claim discipline

Public claims about this framework follow these rules:

- Distinguish implemented features from planned features.
- Distinguish tested behaviour from intended behaviour.
- Treat passing public tests as evidence for the tested contract, not universal correctness.
- Distinguish publicly inspectable evidence from private personal or professional experience.
- Support claims about public framework functionality with inspectable repository evidence.
- Do not describe a private implementation as publicly auditable.
- Do not call private personal work commercial or production work unless that is true and disclosable.
- Do not describe adoption as mandatory, organisation-wide, or company-wide without evidence and publication authority.
- Do not quantify productivity improvement without a documented methodology and authority to publish the underlying result.
- Describe framework controls as reducing particular risks, not as establishing absolute safety.
- Do not represent planned examples, adapters, runtimes, or evaluation work as existing evidence.

The architecture documentation applies these rules to current responsibilities and runtime status in [`architecture.md`](architecture.md). The historical design rationale in [`evolution.md`](evolution.md) is explicitly experience-informed and does not substitute for implementation evidence.
