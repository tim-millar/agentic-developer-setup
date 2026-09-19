# Repository Review Policy

This file is the repository-owned policy for code review. It is intentionally
provider-neutral: review tools and agent runtimes should read or summarise it,
not replace it with a competing policy.

## Review objective

Find a small number of high-confidence, actionable defects introduced by the
change. Prioritise evidence over speculation and explain findings so an author
can act on them.

## Finding vocabulary

Use only these classifications:

- `Important`: a finding that could materially affect correctness, behaviour,
  security, data integrity, an architecture contract, validation confidence, or
  another documented repository invariant.
- `Nit`: a low-impact readability, naming, wording, or maintainability
  observation that is not required for correctness or task acceptance.

Do not invent numeric severity scores or a larger severity hierarchy.

## Important priorities

Prioritise, where applicable:

- correctness and behavioural regressions;
- security, access boundaries, and data integrity;
- production behaviour and failure handling;
- documented architecture and repository contracts;
- missing validation for changed behaviour where repository policy requires it;
- compatibility risks for supported users or downstream adopters.

Reviewers should specialise this policy for the repository by documenting its
highest-risk surfaces, including as applicable:

- domain invariants;
- security, tenancy, and authentication boundaries;
- persistence and migration risks;
- architecture boundaries;
- deployment and operations risks;
- other repository-specific contracts that must not regress.

Do not assume this list is a universal application-risk taxonomy. The applicable
repository policy and documentation establish which risks matter most.

## Scope and context

Establish scope from, in order:

1. direct human instructions and the current task specification;
2. repository-local instructions applicable to the changed path;
3. this review policy;
4. relevant architecture, testing, domain, and other repository documentation;
5. pull-request handoff evidence.

Use the task or issue acceptance criteria and non-goals to decide what the
change is meant to do and what is out of scope. When a more specific applicable
contract narrows a general rule, review against that specific contract.

## Do not report

Do not report:

- speculative problems without a concrete affected behaviour or contract;
- unrelated pre-existing defects;
- unrelated refactors or preferences outside the task scope;
- formatting, lint, or type failures already enforced mechanically, unless the
  configuration is wrong or the failure exposes a semantic defect not
  adequately represented by the mechanical check;
- style preferences that do not affect readability, maintainability, or a
  documented convention.

Keep the review focused on defects introduced by the change. A missing test or
validation step is substantive when the changed behaviour or repository policy
requires it; it is not a reason to demand tests unrelated to the change.

## Evidence and review style

Prefer a small number of findings with concrete evidence. For every finding,
include:

- the `Important` or `Nit` classification;
- the file and precise location, when available;
- the observed issue and affected behaviour;
- why it matters under the applicable task, contract, or documentation;
- a suggested fix direction.

State explicitly when there are no Important findings. Distinguish findings
from suggested validation commands and from general observations.
