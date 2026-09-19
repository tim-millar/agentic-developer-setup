# Repository Review Policy

This is the canonical, provider-neutral review policy for this public
framework repository. It defines what good review means. It does not define
when reviews run, which model or provider performs them, how amendment loops
are orchestrated, or when a pull request is approved or merged.

## Objective and scope

Review should primarily identify high-confidence, actionable defects or
contract violations introduced by, exposed by, or materially interacting with
the change under review. Prioritise material engineering risk over finding
volume and prefer a small number of well-supported findings to speculative
completeness.

Review the change and its relevant interactions, not the entire repository.
Do not normally report unrelated pre-existing defects, unrelated refactors,
general technical debt, alternative architectures outside task scope, or
adjacent hardening that is not required for correctness, security, contracts,
compatibility, or non-interference. A pre-existing condition is in scope when
the proposed change interacts with it to create a concrete defect.

## Finding classes

Use only these finding classes:

### Important

An `Important` finding could materially affect one or more of:

- correctness or externally observable framework behaviour;
- security, authority, authentication, authorisation, credential, or host/child-process boundaries;
- data integrity, persistence, or migration correctness;
- documented architecture boundaries or public/internal contracts;
- backward compatibility or downstream adopters;
- production behaviour or deterministic validation confidence; or
- another documented repository invariant.

Do not call something `Important` merely because another implementation would
be cleaner, more defensive, or more to a reviewer's preference.

### Nit

A `Nit` is a low-impact observation about wording, naming, readability,
minor maintainability, or small local consistency where correction is not
required for correctness, task acceptance, safety, architecture, or
compatibility. Report nits sparingly and clearly separate them from
`Important` findings.

Do not introduce numeric severity scores, P0/P1/P2 levels, blocker/major/minor
taxonomies, or a second confidence-based severity system.

## Findings and evidence

An `Important` finding should contain enough evidence for another engineer to
evaluate it without rediscovering the entire argument. Where applicable,
include the file/path and relevant location, the concrete behaviour or
contract violated, why it matters, the realistic failure or regression mode,
and a bounded direction for a fix.

Distinguish observed behaviour, documented contract, reasonable inference,
and uncertainty. Do not present unsupported assumptions as established
defects.

## Review noise to omit

Do not report findings that are only speculative concerns with no credible
failure path, hypothetical defensive hardening unrelated to the requested
change, style or formatting issues already handled by deterministic tooling,
lint/type/format failures already adequately represented by mechanical checks,
unrelated refactoring requests, preferences presented as correctness
requirements, duplicate findings, documentation wording preferences that do
not make a behavioural or contractual claim inaccurate, demands to solve a
stated non-goal, or requests to broaden the task beyond its acceptance
criteria.

A mechanical-check failure may still be a review finding when the
configuration is incorrect, the failure represents a semantic problem not
adequately expressed by the tool, or the change weakens or bypasses the
mechanical control.

## Applicable context

Establish the applicable contract from the smallest sufficient set of current
sources, in this order:

1. direct human instructions and the current task or issue specification;
2. repository-local instructions applicable to the changed path;
3. these root agent operating instructions where applicable;
4. this `REVIEW.md`;
5. relevant architecture, testing, domain, development, security, or other repository documentation; and
6. pull-request review-handoff evidence.

The task's acceptance criteria and non-goals define the immediate change
boundary. A more specific applicable repository contract may intentionally
narrow a general one. Do not invent an additional precedence system.

## Important priorities for this repository

Review should pay particular attention to:

1. correctness and behavioural regressions in framework tooling, validation, adoption, runtime, or repository workflows;
2. leakage between root operational behaviour and distributable framework source;
3. reusable `baseline/` artefacts or adapters that impose repository-specific assumptions on adopters;
4. incorrect `framework.yml` source/target relationships, component identity, schema semantics, runtime metadata, adapter metadata, or compatibility claims;
5. launcher/runtime authority expansion, GitHub capability regressions, credential exposure, secret handling, or host/child-process boundary mistakes;
6. weakening deterministic/offline validation or introducing hidden network, credential, live-service, or machine-specific dependencies into standard validation;
7. public-provenance violations, including private or employer-owned code, prompts, schemas, operational details, secrets, or closely reconstructed private material;
8. documentation or examples claiming behaviour, support, compatibility, or evidence that implementation/tests do not establish;
9. backward-compatibility or downstream-adoption risk when reusable artefacts or metadata contracts change; and
10. missing validation for materially changed framework behaviour.

Do not request adjacent-scope hardening once a change satisfies its specified
contract unless the finding represents a genuine correctness, security,
compatibility, contract, or non-interference defect. This is the repository's
bounded-convergence rule.
