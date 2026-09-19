# Repository review instructions

`REVIEW.md` is the canonical review policy for this repository. Apply it rather
than inventing a provider-specific policy.

Prioritise high-confidence, actionable findings about correctness and
behavioural regressions; root versus distributable `baseline/` separation and
downstream portability; `framework.yml` metadata and source/target contracts;
launcher, runtime, GitHub, credential, secret, and process-boundary safety;
deterministic/offline validation; public provenance; unsupported documentation
claims; compatibility; and missing validation for changed behaviour.

Read applicable `AGENTS.md` instructions, the current task or issue scope and
non-goals, relevant repository documentation, and the PR handoff evidence in
`.github/PULL_REQUEST_TEMPLATE.md`. Review the branch against `main` and focus
on defects introduced by it. An intentional root/baseline difference is not
itself a defect.

Use only `Important` and `Nit`. Prefer a small number of concrete,
evidence-backed findings; avoid speculative findings, unrelated refactors, and
comments duplicating mechanical CI checks unless the configuration is wrong or
the failure reveals a semantic defect. Include the path/location, issue, why it
matters, and a suggested fix direction. State explicitly when there are no
Important findings.
