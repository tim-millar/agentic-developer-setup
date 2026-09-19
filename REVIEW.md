# Repository Review Policy

This is the canonical, repository-owned policy for reviewing
`agentic-developer-setup`. Provider-specific integrations may summarise it but
must not become competing authorities. The PR template remains the separate
author-to-reviewer handoff for change evidence.

## Review objective and finding vocabulary

Find a small number of high-confidence, actionable defects introduced by the
change. Use only these classifications:

- `Important`: a finding that could materially affect correctness, behaviour,
  security, data integrity, an architecture contract, validation confidence, or
  another documented repository invariant.
- `Nit`: a low-impact readability, naming, wording, or maintainability
  observation that is not required for correctness or task acceptance.

Do not invent numeric severity scores or a larger severity hierarchy. Cite
concrete files, lines, behaviours, contracts, or task requirements, and include
why the finding matters and a suggested fix direction.

## Important priorities

Review changes for:

1. correctness and behavioural regressions in framework tooling, validation,
   adoption, runtime, or repository workflows;
2. leakage between root operational behaviour and distributable framework
   source;
3. unsafe changes to reusable `baseline/` artefacts or adapters that silently
   narrow portability or impose repository-specific workflow assumptions on
   adopters;
4. incorrect `framework.yml` source/target relationships, component identity,
   schema semantics, runtime metadata, adapter metadata, or compatibility
   claims;
5. launcher/runtime authority expansion, GitHub capability regressions,
   credential exposure, secret handling, or host/child process boundary
   mistakes;
6. weakening deterministic/offline validation or introducing hidden network,
   credential, live-service, or machine-specific dependencies into standard
   tests;
7. public provenance violations, including private or employer-owned code,
   prompts, schemas, operational details, secrets, or closely reconstructed
   private material;
8. documentation or examples that claim behaviour, compatibility, support, or
   evidence not established by the implementation or tests;
9. backward-compatibility or downstream-adoption risks when reusable artefacts
   or metadata contracts change;
10. missing tests or validation for changed framework behaviour.

An intentional difference between root and baseline artefacts is not itself a
defect. Flag only unjustified leakage, incorrect coupling, or contract
inconsistency.

## Context and scope

Use, in order:

1. direct human instructions and the current task specification;
2. repository-local instructions applicable to the changed path;
3. this `REVIEW.md` policy;
4. relevant architecture, testing, domain, and other repository documentation;
5. `.github/PULL_REQUEST_TEMPLATE.md` handoff evidence.

Review the branch against `main` and focus on defects introduced by the branch,
not unrelated pre-existing code. Use issue acceptance criteria and non-goals to
establish scope. A more specific applicable contract narrows a general rule.

## Do not report

Do not report speculative problems without concrete affected behaviour,
unrelated refactors, unrelated pre-existing defects, or formatting/lint/type
failures already enforced mechanically. Report a mechanical failure only when
the configuration is wrong or it exposes a semantic defect not adequately
represented by that check. Treat missing validation as substantive when the
changed behaviour or repository policy requires it.

## Review style

Prefer a small number of high-confidence findings over review noise. For each
finding, state its classification, path/location, issue, why it matters under
the applicable contract, and suggested fix direction. State explicitly when
there are no Important findings. Keep nits limited to low-impact readability,
naming, wording, or maintainability observations.

## Repository-specific context

When relevant, consult:

- `AGENTS.md` and any more specific local instructions;
- `README.md` for the framework purpose, adoption model, and supported runtime
  boundaries;
- `framework.yml` for declared artefacts, source/target mappings, runtime and
  adapter metadata, adoption tiers, and conventions;
- `docs/architecture.md` and `docs/validation.md` for architecture and
  deterministic validation contracts;
- the changed baseline, adapter, launcher, test, and documentation files;
- `.github/PULL_REQUEST_TEMPLATE.md` for author-provided validation and impact
  evidence.

For reusable artefacts, explicitly check that generic framework source remains
portable and that root-only operational assumptions do not leak into the
baseline. For root specialisations, do not flag an intentional difference from
the baseline unless it creates unjustified coupling or contradicts a declared
contract.
