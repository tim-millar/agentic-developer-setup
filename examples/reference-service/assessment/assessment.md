# Repository assessment

## Executive summary

- Recommended adoption outcome: **tier-2** (high confidence).
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
- Command surface: make format, make format-check, make lint, make setup, make test, make typecheck, make verify, mypy, pytest, ruff, uv run --locked

## Readiness overview

| Dimension | Status | Confidence | Consequence |
| --- | --- | --- | --- |
| `repository_context` | `ready` | `high` | Agents need discoverable repository purpose, roots, and development context. |
| `task_boundary` | `ready` | `high` | Explicit scope, acceptance criteria, and non-goals make agent work reviewable. |
| `command_surface` | `ready` | `high` | A stable command surface bounds how humans and agents discover local work. |
| `deterministic_validation` | `ready` | `high` | Static validation evidence helps constrain agent changes without executing project tools. |
| `ci_alignment` | `ready` | `high` | CI should provide merge-time evidence conceptually aligned with local validation. |
| `sensitive_area_guidance` | `unknown` | `low` | Static inspection cannot establish whether undocumented restricted areas exist. |
| `runtime_access` | `not_applicable` | `high` | No agent runtime requirement is established by static repository evidence. |
| `review_handoff` | `ready` | `high` | Human review needs a visible place for scope and validation evidence. |
| `local_setup_reproducibility` | `ready` | `high` | Agents need reproducible prerequisites without relying on undocumented local state. |

## Adoption-tier recommendation

Outcome: **tier-2** (high confidence).

Blocking gaps: none

Alternative conditions:
- Tier 3 requires discoverable architecture, domain, testing, and repository conventions that can be specialised without invention.

## Component recommendations

| Component | State | Confidence | Rationale |
| --- | --- | --- | --- |
| `agent_instructions` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `agent_launcher` | `evaluate_later` | `low` | This optional runtime or hook component should be evaluated only if its access and workflow value is established. |
| `agent_prompt` | `adopt_now` | `low` | The capability is not currently detected; adopt it incrementally using repository evidence and native conventions. |
| `agent_ready_issue_template` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `architecture_scaffold` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `bug_report_issue_template` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `ci_workflow` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `claude_agent_entrypoint` | `evaluate_later` | `low` | This optional runtime or hook component should be evaluated only if its access and workflow value is established. |
| `command_interface` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `commit_metadata` | `defer` | `low` | The current repository does not establish a need for this source-repository session artefact. |
| `development_guide` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `discovery_or_shaping_issue_template` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `domain_context` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `git_hooks` | `evaluate_later` | `low` | This optional runtime or hook component should be evaluated only if its access and workflow value is established. |
| `github_access_helper` | `evaluate_later` | `low` | This optional runtime or hook component should be evaluated only if its access and workflow value is established. |
| `issue_template_config` | `adopt_now` | `high` | Current framework content is present; retain it and review its applicability. |
| `pull_request_template` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |
| `testing_strategy` | `specialise_now` | `medium` | A framework-like artefact is present; confirm provenance and specialise it to repository evidence. |

## Key gaps

No adoption-specific gaps were recorded from the inspected evidence.

## Key risks

No adoption-specific risks were recorded from the inspected evidence.

## Phased roadmap

- **Phase 1 — Document architecture boundaries for adoption** (`STEP-001`, component `architecture_scaffold`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 1 — Document deterministic testing and validation strategy** (`STEP-002`, component `testing_strategy`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 1 — Document domain context for adoption** (`STEP-003`, component `domain_context`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 1 — Document reproducible local development** (`STEP-004`, component `development_guide`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 1 — Document the agent session brief and repository orientation** (`STEP-005`, component `agent_prompt`)
  - Gaps: none
  - Prerequisites: none
  - The capability is not currently detected; adopt it incrementally using repository evidence and native conventions.

- **Phase 1 — Establish a stable repository command interface** (`STEP-006`, component `command_interface`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 1 — Establish repository agent instructions and boundaries** (`STEP-007`, component `agent_instructions`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 2 — Align the CI validation workflow** (`STEP-008`, component `ci_workflow`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 2 — Configure the issue-template chooser** (`STEP-009`, component `issue_template_config`)
  - Gaps: none
  - Prerequisites: none
  - Current framework content is present; retain it and review its applicability.

- **Phase 2 — Establish the agent-ready task workflow** (`STEP-010`, component `agent_ready_issue_template`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 2 — Establish the defect-report workflow** (`STEP-011`, component `bug_report_issue_template`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 2 — Establish the discovery and shaping workflow** (`STEP-012`, component `discovery_or_shaping_issue_template`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

- **Phase 2 — Establish the human review handoff** (`STEP-013`, component `pull_request_template`)
  - Gaps: none
  - Prerequisites: none
  - A framework-like artefact is present; confirm provenance and specialise it to repository evidence.

## Assumptions

- Static inspection is limited to recognised repository metadata and documentation; arbitrary source code is not analysed.
- Existing repository-native mechanisms are treated as capability evidence, not as framework provenance.

## Unknowns

- Static evidence cannot prove that a documented command succeeds or that an unobserved area does not exist.
- Repository semantics, ownership, security posture, and operational suitability require human review.
- The assessment does not recursively assess each project root in a multi-project repository.
- No assessor context was supplied for facts that are not discoverable from repository files.

## Evidence appendix

- `E001` — ci_invocation/ci_invocation (`.github/workflows/ci.yml`): GitHub Actions invokes make setup
- `E002` — ci_invocation/ci_invocation (`.github/workflows/ci.yml`): GitHub Actions invokes make verify
- `E003` — directory/test_directory (`tests`): Generic test directory detected
- `E004` — documented_command/documented_command (`README.md`): Repository command documented: make setup
- `E005` — documented_command/documented_command (`README.md`): Repository command documented: make verify
- `E006` — documented_command/documented_command (`README.md`): Repository command documented: uv run --locked
- `E007` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make format
- `E008` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make format-check
- `E009` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make lint
- `E010` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make setup
- `E011` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make test
- `E012` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make typecheck
- `E013` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: make verify
- `E014` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: mypy
- `E015` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: pytest
- `E016` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: ruff
- `E017` — documented_command/documented_command (`docs/DEVELOPMENT.md`): Repository command documented: uv run --locked
- `E018` — documented_command/documented_command (`docs/FRAMEWORK_ADOPTION.md`): Repository command documented: make setup
- `E019` — documented_command/documented_command (`docs/FRAMEWORK_ADOPTION.md`): Repository command documented: mypy
- `E020` — documented_command/documented_command (`docs/FRAMEWORK_ADOPTION.md`): Repository command documented: pytest
- `E021` — documented_command/documented_command (`docs/TESTING.md`): Repository command documented: make format
- `E022` — documented_command/documented_command (`docs/TESTING.md`): Repository command documented: make test
- `E023` — documented_command/documented_command (`docs/TESTING.md`): Repository command documented: make verify
- `E024` — documented_command/documented_command (`docs/TESTING.md`): Repository command documented: mypy
- `E025` — documented_command/documented_command (`docs/TESTING.md`): Repository command documented: pytest
- `E026` — file/documentation_presence (`.github/ISSUE_TEMPLATE/agent-ready-implementation.md`): Issue templates detected
- `E027` — file/framework_like_path (`.github/ISSUE_TEMPLATE/agent-ready-implementation.md`): Recognised framework-style artefact path detected for agent_ready_issue_template
- `E028` — file/documentation_presence (`.github/ISSUE_TEMPLATE/bug-report.md`): Issue templates detected
- `E029` — file/framework_like_path (`.github/ISSUE_TEMPLATE/bug-report.md`): Recognised framework-style artefact path detected for bug_report_issue_template
- `E030` — file/documentation_presence (`.github/ISSUE_TEMPLATE/config.yml`): Issue templates detected
- `E031` — file/framework_exact_content_match (`.github/ISSUE_TEMPLATE/config.yml`): Current framework artefact content matches issue_template_config
- `E032` — file/documentation_presence (`.github/ISSUE_TEMPLATE/discovery-or-shaping.md`): Issue templates detected
- `E033` — file/framework_like_path (`.github/ISSUE_TEMPLATE/discovery-or-shaping.md`): Recognised framework-style artefact path detected for discovery_or_shaping_issue_template
- `E034` — file/documentation_presence (`.github/PULL_REQUEST_TEMPLATE.md`): Pull request template detected
- `E035` — file/framework_like_path (`.github/PULL_REQUEST_TEMPLATE.md`): Recognised framework-style artefact path detected for pull_request_template
- `E036` — file/framework_like_path (`.github/workflows/ci.yml`): Recognised framework-style artefact path detected for ci_workflow
- `E037` — file/github_actions_workflow (`.github/workflows/ci.yml`): GitHub Actions workflow detected
- `E038` — file/documentation_presence (`AGENTS.md`): Repository agent instructions detected
- `E039` — file/framework_like_path (`AGENTS.md`): Recognised framework-style artefact path detected for agent_instructions
- `E040` — file/framework_like_path (`Makefile`): Recognised framework-style artefact path detected for command_interface
- `E041` — file/make_command_surface (`Makefile`): Makefile command interface detected
- `E042` — file/make_target (`Makefile`): Make target format declared
- `E043` — file/make_target (`Makefile`): Make target format-check declared
- `E044` — file/make_target (`Makefile`): Make target lint declared
- `E045` — file/make_target (`Makefile`): Make target setup declared
- `E046` — file/make_target (`Makefile`): Make target test declared
- `E047` — file/make_target (`Makefile`): Make target typecheck declared
- `E048` — file/make_target (`Makefile`): Make target verify declared
- `E049` — file/make_validation_target (`Makefile`): Make target lint invokes a linting tool
- `E050` — file/make_validation_target (`Makefile`): Make target test invokes a test tool
- `E051` — file/make_validation_target (`Makefile`): Make target typecheck invokes a type checking tool
- `E052` — file/verification_command (`Makefile`): Standard verification Make target detected
- `E053` — file/documentation_presence (`README.md`): README documentation detected
- `E054` — file/documentation_presence (`docs/ARCHITECTURE.md`): Architecture documentation detected
- `E055` — file/framework_like_path (`docs/ARCHITECTURE.md`): Recognised framework-style artefact path detected for architecture_scaffold
- `E056` — file/documentation_presence (`docs/DEVELOPMENT.md`): Development guidance detected
- `E057` — file/framework_like_path (`docs/DEVELOPMENT.md`): Recognised framework-style artefact path detected for development_guide
- `E058` — file/documentation_presence (`docs/DOMAIN.md`): Domain documentation detected
- `E059` — file/framework_like_path (`docs/DOMAIN.md`): Recognised framework-style artefact path detected for domain_context
- `E060` — file/documentation_presence (`docs/TESTING.md`): Testing guidance detected
- `E061` — file/framework_like_path (`docs/TESTING.md`): Recognised framework-style artefact path detected for testing_strategy
- `E062` — file/mypy_configuration (`pyproject.toml`): mypy configuration or dependency detected
- `E063` — file/pyproject_project_metadata (`pyproject.toml`): Python project metadata detected
- `E064` — file/pytest_configuration (`pyproject.toml`): pytest configuration or dependency detected
- `E065` — file/python_build_configuration (`pyproject.toml`): Python build configuration detected
- `E066` — file/ruff_configuration (`pyproject.toml`): Ruff configuration or dependency detected
- `E067` — file/ruff_formatter_configuration (`pyproject.toml`): Ruff formatter configuration or dependency detected
- `E068` — file/uv_lockfile (`uv.lock`): uv lockfile detected
- `E069` — framework_metadata/framework_catalogue (`framework.yml`): Current framework catalogue and metadata detected
- `E070` — git/git_branch: Current Git branch detected
- `E071` — git/git_commit: Current Git commit detected
- `E072` — git/git_repository_detection: Git repository detection completed
- `E073` — git/git_working_tree: Git working-tree state detected
