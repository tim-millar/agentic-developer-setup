---
name: framework-review
description: Review this repository against its canonical repository review policy.
---

# Framework review

Use this skill as a workflow wrapper. `REVIEW.md` is the canonical review
policy; do not maintain or invent a second repository-specific policy here.

Before reviewing:

1. Read `REVIEW.md`.
2. Read root `AGENTS.md`.
3. Read the current task, issue, or PR acceptance criteria and non-goals when
   available.
4. Inspect relevant repository documentation, including `README.md`,
   `framework.yml` when framework metadata or distributable artefacts are
   touched, and `.github/PULL_REQUEST_TEMPLATE.md` for handoff evidence.
5. Review the current branch against `main`.

Focus on defects introduced by the branch rather than unrelated pre-existing
code. Apply `REVIEW.md` for priorities, `Important`/`Nit` classification,
do-not-report rules, context precedence, and evidence expectations.

Report using this shape:

1. Important findings
2. Nits
3. Suggested validation commands
4. Readiness for human PR review

If there are no Important findings, say so explicitly. For each finding include
the path/location, issue, why it matters, and a suggested fix direction.
