---
name: code-review
description: >
  Perform an independent implementation review of a proposed repository
  change using REVIEW.md, applicable agent instructions, the accepted task,
  the base-to-head change, PR handoff evidence, and available validation.
  Use for pull-request and code-review tasks. Do not determine approval or
  merge readiness.
---

# Independent implementation review

Use this skill to perform one independent review of a proposed implementation.
The repository's `REVIEW.md`, when present, is the canonical policy for review
semantics and repository-specific priorities. This skill is the procedure for
applying that policy; it is not a second policy authority.

## Role boundary

Review only the implementation contribution. Inspect the proposed change and
report concrete, evidence-supported defects or contract violations. Do not
perform an independent specification review, adjudicate another reviewer's
findings, expand the accepted task, write an amendment plan, modify the
implementation, grant approval, decide RTM or merge readiness, or merge.

## Procedure

1. Establish the review context already available from the host or repository:
   the proposed change, base or merge-base information, task or specification
   context, PR handoff, and validation evidence. Do not require remote
   retrieval merely to begin.
2. Read applicable repository-local agent instructions, including `AGENTS.md`
   and more-specific instructions for changed paths.
3. Read `REVIEW.md` when it exists. Defer to it for review scope, finding
   semantics, risk priorities, evidence expectations, and do-not-report
   guidance. Do not reproduce its policy in this skill.
4. Use the accepted task, explicit acceptance criteria, non-goals, PR
   description, and local task documentation when available. Do not invent
   missing product intent or acceptance criteria.
5. Establish the review target as the contribution from the accepted base or
   merge base to `HEAD` (conceptually `base...HEAD`). Inspect surrounding
   repository state only as needed to understand changed behaviour; do not
   turn the review into a whole-repository audit.
6. Inspect available handoff, validation, test, architecture, testing,
   domain, and security evidence. Do not assume a validation result that the
   available evidence does not establish.
7. Perform the implementation review independently using the applicable
   instructions, task evidence, `REVIEW.md` when present, base-to-head change,
   and available validation or handoff evidence. Focus on concrete
   branch-introduced defects and contract violations, and omit speculative or
   unrelated work.
8. Report bounded findings with the affected path or location, concise
   problem, affected behaviour, why it matters, supporting requirement or
   evidence, and a bounded fix direction where useful. When `REVIEW.md` is
   present, use its finding classes and semantics rather than introducing a
   second severity vocabulary.

## Degraded context

If `REVIEW.md` is unavailable, continue with an evidence-led implementation
review using applicable instructions, available task context, the branch
contribution, and available validation evidence. State the review limitation
when useful; do not claim repository-policy coverage, invent repository risk
priorities, or reconstruct a missing policy.

If accepted task or specification context is unavailable, continue using the
evidence that is available and report only supportable findings. Concrete
correctness regressions, unsafe credential exposure, broken repository
invariants, invalid API usage, and validation required by explicit repository
policy may still be reported. Do not claim violation of absent acceptance
criteria or infer product intent.

## Output and termination

If no material findings are identified, the review may state: `No Important
findings identified.` That is a review observation only. Do not describe the
change as approved, RTM, ready to merge, safe to merge, or mergeable, directly
or indirectly.

Stop after producing the independent implementation review. The skill does not
edit files, commit, fetch remote context, call GitHub or MCP services, request
another review, invoke an implementation agent, rerun review, submit approval,
mark a pull request ready, or merge.
