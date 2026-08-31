# Repository assessment

## Executive summary

- Recommended adoption outcome: **tier-3** (high confidence).
- Readiness findings are capability-specific; this report does not assign an aggregate score.
- Gaps: 0; risks requiring review: 0.

An assessment recommends an adoption strategy. It does not authorise repository changes and does not replace repository-owner, architecture, security, or operational review.

## Repository profile

- Root: `examples/reference-service`
- Git: detected (clean working tree)
- Scope shape: `single_project`
- Project roots: `.`
- Excluded areas: none

## Ecosystem and tooling profile

- `python` (primary, high confidence): `pyproject.toml`, `uv.lock`
- Package managers: uv
- Command surface: make lint, make test, make typecheck, make verify

## Readiness overview

| Dimension | Status | Confidence | Consequence |
| --- | --- | --- | --- |
| `repository_context` | `ready` | `high` | Repository purpose, roots, and context are discoverable. |
| `task_boundary` | `ready` | `high` | Task and review templates expose useful boundaries. |
| `command_surface` | `ready` | `high` | Stable Make commands are discoverable. |
| `deterministic_validation` | `ready` | `high` | Tests and static checks provide deterministic review evidence. |
| `ci_alignment` | `ready` | `high` | CI invokes the documented validation surface. |
| `sensitive_area_guidance` | `ready` | `medium` | Repository instructions provide visible boundaries. |
| `runtime_access` | `not_applicable` | `high` | No runtime requirement is established. |
| `review_handoff` | `ready` | `high` | Human review has visible templates. |
| `local_setup_reproducibility` | `ready` | `high` | Setup and locked dependencies are discoverable. |

## Adoption-tier recommendation

Outcome: **tier-3** (high confidence).

Blocking gaps: none

Alternative conditions:
- None recorded.

## Component recommendations

| Component | State | Confidence | Rationale |
| --- | --- | --- | --- |
| `agent_instructions` | `specialise_now` | `medium` | Specialise the framework-like repository contract. |
| `agent_launcher` | `evaluate_later` | `low` | Optional runtime component deliberately omitted from this fixture. |
| `agent_prompt` | `defer` | `low` | Session prompt is not required by this fixture's repository scope. |
| `agent_ready_issue_template` | `specialise_now` | `medium` | Specialise the framework-like task template. |
| `architecture_scaffold` | `specialise_now` | `medium` | Specialise the architecture document with repository facts. |
| `bug_report_issue_template` | `specialise_now` | `medium` | Retain and specialise the native defect workflow. |
| `ci_workflow` | `specialise_now` | `medium` | Preserve the native workflow while reviewing its repository bindings. |
| `claude_agent_entrypoint` | `evaluate_later` | `low` | No current evidence establishes a need for this optional entrypoint. |
| `command_interface` | `specialise_now` | `medium` | Preserve the native Make surface and its repository bindings. |
| `commit_metadata` | `defer` | `low` | Commit guidance is deliberately unnecessary for this compact fixture. |
| `development_guide` | `specialise_now` | `medium` | Specialise setup and development guidance. |
| `discovery_or_shaping_issue_template` | `specialise_now` | `medium` | Retain the native discovery workflow. |
| `domain_context` | `specialise_now` | `medium` | Specialise domain context with repository facts. |
| `git_hooks` | `evaluate_later` | `low` | Hooks are deliberately omitted because they add no material value here. |
| `github_access_helper` | `evaluate_later` | `low` | No repository credential requirement is established. |
| `issue_template_config` | `adopt_now` | `high` | Exact current-framework content is present. |
| `pull_request_template` | `specialise_now` | `medium` | Specialise the review handoff for the fixture. |
| `testing_strategy` | `specialise_now` | `medium` | Specialise the deterministic testing guidance. |

## Key gaps

No adoption-specific gaps were recorded from the inspected evidence.

## Key risks

No adoption-specific risks were recorded from the inspected evidence.

## Phased roadmap

- **Phase 1 — Review repository contract and validation bindings** (`STEP-001`, component `agent_instructions`)
  - Gaps: none
  - Prerequisites: none
  - Review the specialised contract against the fixture's documented boundaries.

- **Phase 1 — Retain the native Python validation surface** (`STEP-002`, component `testing_strategy`)
  - Gaps: none
  - Prerequisites: none
  - Keep uv, pytest, Ruff, mypy, Make, and CI conceptually aligned.

- **Phase 2 — Evaluate optional runtime and hook controls** (`STEP-003`, component `agent_launcher`)
  - Gaps: none
  - Prerequisites: none
  - Deliberate omissions should be revisited only if repository scope changes.

## Assumptions

- Static inspection is limited to recognised metadata and documentation.
- Existing native mechanisms are capability evidence, not framework provenance.

## Unknowns

- Static evidence cannot prove that commands succeed.
- Repository semantics, ownership, security posture, and operational suitability require human review.
- Optional runtime and hook requirements are not established by this fixture.

## Evidence appendix

- `E001` — file/documentation_presence (`README.md`): README documentation detected
- `E002` — file/documentation_presence (`AGENTS.md`): Repository agent instructions detected
- `E003` — file/pyproject_project_metadata (`pyproject.toml`): Python project metadata and validation configuration detected
- `E004` — file/uv_lockfile (`uv.lock`): uv lockfile detected
- `E005` — directory/test_directory (`tests`): Test directory detected
- `E006` — file/make_command_surface (`Makefile`): Make command surface and verification targets detected
- `E007` — file/ci_invocation (`.github/workflows/ci.yml`): GitHub Actions invokes the repository verification command
- `E008` — file/task_template (`.github/ISSUE_TEMPLATE/agent-ready-implementation.md`): Agent-ready task template detected
- `E009` — file/review_handoff_template (`.github/PULL_REQUEST_TEMPLATE.md`): Pull request review handoff detected
- `E010` — file/documentation_presence (`docs/ARCHITECTURE.md`): Architecture documentation detected
- `E011` — file/documentation_presence (`docs/DEVELOPMENT.md`): Development guidance detected
- `E012` — file/documentation_presence (`docs/DOMAIN.md`): Domain documentation detected
- `E013` — file/documentation_presence (`docs/TESTING.md`): Testing guidance detected
- `E014` — file/framework_exact_content_match (`.github/ISSUE_TEMPLATE/config.yml`): Current framework issue-template configuration content matches
