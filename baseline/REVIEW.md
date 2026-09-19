# Repository Review Policy

This document is the repository-owned, provider-neutral policy for reviewing
changes. It defines what useful review means; it does not define review
automation, reviewer selection, amendment loops, approval, or merge policy.

## Objective and scope

Review should primarily identify high-confidence, actionable defects or
contract violations introduced by, exposed by, or materially interacting with
the change under review. Prioritise material engineering risk over the volume
of findings and prefer a small number of well-supported findings to speculative
completeness.

Review the change and its relevant interactions, not the entire repository.
Do not normally report unrelated pre-existing defects, unrelated refactors,
general technical debt, alternative architectures outside the task, or
adjacent hardening that is not required for correctness, security, contracts,
compatibility, or non-interference. A pre-existing condition may be reported
when the change creates a concrete defect by interacting with it.

## Finding classes

Use only these shared finding classes:

### Important

An `Important` finding could materially affect one or more of:

- correctness or externally observable behaviour;
- security, authority, authentication, or authorisation boundaries;
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
compatibility. Report nits sparingly and keep them clearly separate from
`Important` findings.

Do not introduce numeric severity scores, P0/P1/P2 levels, blocker/major/minor
taxonomies, or a second confidence-based severity system.

## Findings and evidence

An `Important` finding should contain enough evidence for another engineer to
evaluate it without rediscovering the entire argument. Where applicable,
include:

- the file/path and relevant location;
- the concrete behaviour or contract being violated;
- why the issue matters;
- the realistic failure or regression mode; and
- a bounded direction for a fix.

Distinguish observed behaviour, documented contract, reasonable inference,
and uncertainty. Do not present unsupported assumptions as established
defects.

## Review noise to omit

Do not report findings that are only:

- speculative concerns with no credible failure path;
- hypothetical defensive hardening unrelated to the requested change;
- style or formatting issues already handled by deterministic tooling;
- lint, type, or format failures already adequately represented by mechanical checks;
- requests for unrelated refactoring;
- preferences presented as correctness requirements;
- duplicates of the same underlying defect;
- documentation wording preferences that do not make a behavioural or contractual claim inaccurate;
- demands to solve a stated non-goal; or
- requests to broaden the task beyond its acceptance criteria.

A mechanical-check failure may still be a review finding when the
configuration is incorrect, the failure represents a semantic problem not
adequately expressed by the tool, or the change weakens or bypasses the
mechanical control.

## Applicable context

Establish the applicable contract from the smallest sufficient set of current
sources, in this order:

1. direct human instructions and the current task or issue specification;
2. repository-local instructions applicable to the changed path;
3. root agent operating instructions where applicable;
4. this `REVIEW.md`;
5. relevant architecture, testing, domain, development, security, or other repository documentation; and
6. pull-request review-handoff evidence.

The task's acceptance criteria and non-goals define the immediate change
boundary. A more specific applicable repository contract may intentionally
narrow a general one. Do not invent an additional precedence system.

## Repository-specific specialisation

Adopters should extend this policy only where the repository has meaningful
risks or invariants. Consider, where relevant:

- domain invariants;
- security boundaries;
- authentication and authorisation;
- tenancy or data isolation;
- persistence and migration risks;
- architecture boundaries;
- public API or compatibility contracts;
- deployment and operational risks;
- external-service boundaries;
- performance-sensitive behaviour; and
- generated or vendored code.

A repository need not invent policy for an area that is not meaningful to it.
