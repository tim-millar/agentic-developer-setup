# Proposed specification amendments — ADS #79

Date: 2026-10-17. Proposals only: no issue was changed. The [investigation](investigation.md) and [matrix](experiment-matrix.md) define evidence and limits. **verified — human-reported:** E1 ordinary-baseline and E2–E4 prescribed UI checks passed. H2 confirms 1.0.96 by preflight on 17 October 2026, macOS 15.6 arm64, tmux 3.5a, 48 × 166, shared isolated home, empty MCP map and E4 `--disable-builtin-mcps`; Gists hidden and hooks disabled. H1's version remains independently unconfirmed. Only an expected empty PR list was observed; no model request was made in H1–H4. Human descriptions of one/zero MCP counters and an identity `via gh` are not agent-inspected screenshot evidence, transport attribution or credential isolation. **unknown:** valid model-service access, arbitrary MCP suppression, navigation's data source, repository confinement and a trusted native selection callback. **verified — human-reported (H3):** E5a UI/navigation passed on 1.0.96 with isolated gh configuration/status unavailable, reused Copilot home, built-ins disabled, zero servers and `view` retained; Copilot still displayed `via gh`. That discrepancy is **unknown**, not a credential-isolation pass. **blocked:** E5b–E8 enforcement/selection. Reference insertion is not trusted selection.

**verified — human-reported (H4, 17 October 2026):** reused and newly constructed disposable homes in separate 1.0.96 processes, sharing isolated gh config, both retained `via gh`, functional native TUI, ADS query/issues #78/#79, successfully empty PR list and zero MCP servers under built-in disabling/`view`. No profile/authentication state was copied; no authentication/account change or model request was made. Reused Copilot-home state alone is insufficient to explain the identity. **unknown:** actual credential route, model-service requests, child isolation and repository confinement; the source label is not proof and populated PR browsing remains unverified. This applies to all six proposals below, without private-framework verification.

**verified — human-reported (H5):** E5b fixture/host-marker preparation, native launch and restrictive effective-policy display succeeded on Copilot 1.0.96/gh 2.90.0/Python 3.15.0, macOS arm64/tmux; zero MCP and view-only tools remained. A three-secret environment warning was not expanded. The attempted shortcut apparently became chat, produced a refusal and approximately 1.45 AI Credits, followed by a Shell-mode display. The denied home conflicted with a session-file write grant in diagnostics. **unknown at H5:** shortcut routing, warning contents and actual enforcement; H6 below resolves the tested keyboard sequence and explains the historical model invocation. **blocked:** synthetic probe; no child booleans, denial or gh result. No planned model-service/follow-up pass follows from this deviation. H5 applies to all six proposals as public-provider evidence only.

**verified — human-reported (H6, 17 October 2026):** Copilot 1.0.96 launched under the minimal `env -i` environment with the existing restrictive E5b sandbox, zero MCP and model Bash disabled, on macOS arm64/tmux. No environment-secret warning appeared. Quick help opened; one manually typed `!` at empty input, without Enter, immediately activated Shell mode with `Execute shell command`, `Shell` and `esc exit shell mode`. Esc left the mode and exit was normal. No command/model request occurred; the UI showed 0 AIC. The human clarifies H5 submitted command text conversationally before entering Shell mode, explaining that earlier model invocation by the reported interaction sequence. H5's historical deviation remains valid. **unknown:** actual human-shell execution, child credential/filesystem/network enforcement and model-tool equivalence; no probe has run. The old warning's contents remain unknown; its absence in H6 is not proof of secret absence.

**verified — human-reported (H7, 17 October 2026):** Copilot 1.0.96/macOS arm64/tmux launched under minimal env with unchanged disposable E5b sandbox restrictions, zero MCP and model Bash disabled. Enabled sandbox status and the effective filesystem, Git/gh injection, network, keychain and bypass restrictions were confirmed. Shell mode was entered at empty input with one bang; the existing Python probe command was submitted from that mode without another bang. The provider responded `You have exceeded your monthly quota`. No Python results were obtained; the session showed 0 AIC. **blocked:** actual shell execution by the reported provider quota condition. **unknown:** synthetic filesystem denial, child credential isolation/authentication and child network enforcement. No E5b enforcement pass. No credential values were inspected/disclosed, GitHub mutations or permission relaxations were reported.

The current public ADS issues were read on this date. Their native UI design gates already preserve explicit targeting and defer unverified navigation. The proposals below make acceptance more concrete without claiming those safeguards are absent. PAF issue bodies were not retrieved: their actual wording is **unknown**. Each PAF entry uses only the corresponding role and constraints described publicly in ADS #79; it is a generic proposal for its owner to reconcile, not a reconstruction of private requirements.

## ADS #74 — Shared bounded Copilot substrate

**Current assumption / contract:** [#74](https://github.com/tim-millar/agentic-developer-setup/issues/74) requires native interactive Copilot with isolated config, separate provider/task identities, brokered repository reads, controlled tools/MCP, required sandbox and no arbitrary child network. Its gate already makes native navigation optional and forbids treating a reference as task authority.

**Relevant evidence:** **verified — human-reported (H2):** 1.0.96 native UI/navigation survived the prescribed isolated-home/empty-map/built-in-disable stages. **verified — agent-observed:** installed 1.0.96 supports the discovery/config reads in L1–L4. **documented but unverified:** installed sandbox defaults are too permissive for the profile; user settings differ from an administrator-managed policy floor. **unknown:** safe isolated service login, immutable capability enforcement, native-tab transport and host-side read confinement. **verified — human-reported (H3):** E5a adds a UI-only pass but preserves the gh/Copilot discrepancy. **blocked:** valid service-request and full E5–E7 enforcement verification; no E5b probe has run. Tabs hidden in settings do not establish disabled data retrieval.

**Proposed requirement text:**

> Validate a specific provider version by executing native-TUI and capability-boundary tests independently. Pin execution without silently applying a cached newer release. Record the effective built-in integration inventory. Session-owned settings must not be represented as an immutable policy or credential boundary without behavioral proof. Preserve model access while denying unbrokered GitHub authority across model tools, MCP, custom commands, extensions and host UI actions. Retain read-only native navigation only after proving its host-side identity, reads and operation surface obey the same exact-repository/capability boundary. If it cannot comply, disable the incompatible access using a verified mechanism; tab hiding alone is insufficient. If neither retained nor disabled navigation can meet the boundary, refuse managed launch. Do not add a native picker in v1 absent a supported authenticated selection contract and separately accepted scope.

**Rationale:** help/config availability is evidence of an interface, not a security pass. Source/version differences and host actions must not create a hidden path around the broker.

**Acceptance criterion changes:**

- Record separate outcomes for native UI rendering, service model requests, issue list, PR list, exact repository binding and trusted selection.
- Require a human-command routing gate with no model invocation before any provider-shell probe. Record unexpected model responses/credit use as deviations, not successful shell execution. Do not identify startup secrets by opening real values; qualify an explicit minimal environment separately. Qualify necessary provider-owned runtime/session-state operations separately from access granted to untrusted children or tools. Require implementation-time proof that this separation preserves protected-state confidentiality and integrity, effective sandbox enforcement and the capability boundary. Do not assume safe separation or prescribe blanket filesystem exceptions; fail closed if these protections cannot be demonstrated.
- Demonstrate no child credentials or unbrokered GitHub reads, denied external/loopback child network, inaccessible runtime-private state, blocked bypass/policy relaxation and protected primary source/remote. Include failed-sandbox startup behavior.
- Demonstrate that model changes and supported interactive controls do not change effective capabilities. Test inherited project/user integrations with harmless sentinels in a controlled fixture.
- Qualify explicit-target operation with retained navigation as a conditional candidate, and preserve operation when navigation is safely unavailable. The `via gh` label must be tested independently from env-token removal or isolated gh status; H4's reused/fresh-home control is complete without copied authentication state, so reused-home state alone must not be used as the explanation. Require child-route and host-authority evidence separately. Account metadata, host model identity and child authority are separate. A native `!` probe qualifies only its tested human-shell path, not automatically model `bash`/MCP/LSP or host integrations; zero MCP servers is not complete host-authority evidence.
- Use local synthetic fixtures for credential/tool/filesystem/network negative tests where feasible; do not make open-PR availability a blanket prerequisite. Reserve added GitHub fixtures for populated PR and live cross-repository branches.
- Exercise explicit-target operation when navigation is unavailable. Do not claim success merely because a tab is hidden, an empty list renders or settings echo correctly.

**Host verification expectation:** macOS terminal evidence for E1–E7 on the chosen exact release; meaningful read-only negative tests in a controlled repository. Record Linux prerequisites separately and do not inherit macOS passes.

**Residual uncertainty:** a fully bounded user-installed native session has not been demonstrated; administrator-only policy features may not satisfy a portable launcher. This is a fail-closed design gate, not authority to install MDM or weaken the contract.

## ADS #75 — Interactive PR review

**Current assumption / contract:** [#75](https://github.com/tim-millar/agentic-developer-setup/issues/75) starts with explicit `ads-copilot-review --pr N`, validates one open PR and captures the exact comparison revisions. Native model/conversation controls are required; navigation cannot retarget that review.

**Relevant evidence:** **verified — human-reported:** E1 and E2–E4 PR-tab navigation worked with the expected empty list; H2 pins E2–E4 to 1.0.96, including built-in MCP disabling. Model/context/usage UI worked; no model request or populated PR list was tested. **documented but unverified:** native browsing is useful context, not launcher targeting. **verified — human-reported (H3):** E5a UI also passed despite unavailable isolated gh status and a persistent `via gh` Copilot label. **unknown:** actual child credentials, bounded navigation and authenticated native selection. **blocked:** populated open-PR list/details because authorised ADS has no open PR fixture. An expected empty list is not a failure.

**Proposed requirement text:**

> Keep `--pr N` authoritative for v1. Bind the validated repository, PR and captured comparison revisions before Copilot starts. Neither a native detail view, inserted reference, message attachment, session switch nor model statement may change that binding. Retain native follow-up conversation and model selection independently of PR navigation. Permit retained read-only navigation only when the shared substrate proves exact-repository host reads and unchanged task/capability authority. A native-picker callback is not required for this explicit-target path. If navigation is incompatible, present the limitation and continue only through a verified safe explicit-target native session with that access disabled.

**Rationale:** browsing another item must not change the reviewed contribution or the artifact's identity. A merged historical PR is not evidence that an open-PR navigation workflow works.

**Acceptance criterion changes:**

- In a controlled fixture with an existing open PR, distinguish successful empty search, populated list and details retrieval. Verify open-item eligibility independently of UI state.
- Insert a different harmless reference after binding and prove captured target/revisions, broker authorization, finalization and artifact identity remain unchanged.
- Test model choice/follow-up/resize/exit with navigation unavailable and restrictions active. Preserve ordinary review finalization and staleness semantics; do not add picker scope here.

**Host verification expectation:** inherit the verified #74 release/security profile; human-report the actual native controls, plus read-only target-binding checks. ADS #73/#72 observations alone cannot satisfy the open-PR fixture criterion.

**Residual uncertainty:** no complete managed review session or open-PR navigation was observed. Provider attachment or lifecycle events do not establish trusted selection.

## ADS #76 — Interactive issue shaping

**Current assumption / contract:** [#76](https://github.com/tim-millar/agentic-developer-setup/issues/76) binds `ads-copilot-shape --issue N` to one existing open issue. It separates child investigation from trusted human approval and a selected-issue/body-only publisher. The navigation design gate already forbids silent retargeting.

**Relevant evidence:** **unsupported:** native reference insertion as trusted target selection/approval. **unknown:** another supported callback and fully bounded issue navigation. **verified — human-reported:** E1 ordinary native controls and authorised issue navigation passed, with no reference submitted as a model prompt. **verified — human-reported (H2):** isolated-home, empty-map and built-in-disable UI stages also passed on 1.0.96. **verified — human-reported (H3):** E5a UI passed with the unresolved gh/Copilot status discrepancy. **blocked:** E5b–E8 enforcement/selection; authorisation of #78/#79 permits read-only observations, not publisher or adversarial tests against the active repository.

**Proposed requirement text:**

> Bind the validated issue identity and initial snapshot before launch. Native issue references are conversation context only. They cannot select a publisher target, change the issue being shaped, establish acceptance of a material decision or approve a proposal digest. Keep trusted launcher-side confirmation attached to the exact original target and immutable proposed body. Retain read-only native navigation only under the independently verified shared boundary; it cannot retarget or approve publication. Keep a verified explicit-target fallback when navigation is unavailable.

**Rationale:** navigation, conversational agreement and trusted publication consent have different provenance and authority. UI convenience cannot couple model authentication to write authority.

**Acceptance criterion changes:**

- Same-repository #78/#79 can support later authorised non-writing reference observations without a new GitHub fixture. Actual proposal/target/approval enforcement requires the real bounded mechanism or a narrowly scoped research candidate; an unchanged marker file is insufficient. Never send a GitHub mutation to test denial.
- In a controlled local binding/publisher mock, reject a second target and verify exact proposal/approval identity. Do not mistake a mock pass for acceptance of a nonexistent production publisher.
- Demonstrate no child route to write tools, generic publisher IPC or ambient GitHub credentials, including through native host commands/integrations.
- Exercise model picker, follow-up conversation and local proposal finalization with navigation hidden/unavailable. Do not add or change publication behavior based on this research; retain the existing trusted approval/conflict gates.

**Host verification expectation:** #74's proven isolation first, then human native UI evidence and non-writing target/digest-binding checks. No real publication is part of #79.

**Residual uncertainty:** UI callback provenance and portable host enforcement remain unknown; #79 has not validated the future issue publisher.

## PAF #56 — Shared substrate (generic proposal)

**Current assumption / contract:** public #79 describes this as the private framework's corresponding shared substrate with independent namespace, fixed scope and bounded authority. Actual private issue text and implementation are **unknown**, intentionally uninspected.

**Relevant evidence:** H1 ordinary UI and H2 UI through built-in disabling are **verified — human-reported**, with H2 preflight-confirmed at 1.0.96. This is public-provider evidence, not private-framework verification. L1–L4 are separate agent diagnostics. **verified — human-reported (H3):** an isolated-gh UI pass still retained a Copilot `via gh` label; its cause is unknown and no private-framework inference follows. **blocked:** full E5b–E8; **unknown:** model-auth isolation, host authority and navigation transport; `via gh` requires separate investigation.

**Proposed requirement text:**

> Independently qualify the selected Copilot version and host for native interactive execution, isolated configuration, service/task identity separation and mechanically bounded tools/network/filesystem. Treat retained native navigation as a promising conditional option, supported for UI only by H2–H4, including the isolated-gh reused/fresh-home comparison. Require independent verification of its host identity, reads, exact repository scope and immutable target; preserve an access-disabled explicit-target fallback. Fail closed if restrictions cannot be retained. Do not equate a zero-MCP counter or env-token filtering with isolated GitHub authority. Keep PAF executables, configuration, state and installation ownership independent of ADS; do not depend on ADS executable resolution or session state.

**Rationale:** a shared provider does not imply shared credential custody or framework state. No private source is needed to identify these provider-level verification obligations.

**Acceptance criterion changes:**

- Produce separate native UI, model-service, navigation, repository scope and selection evidence, with the same five conclusion categories and human/agent provenance.
- Independently qualify shortcut routing without model requests, secret-warning handling without value inspection, and necessary provider-owned runtime/session-state operations separately from access granted to untrusted children or tools. Require implementation-time proof that this separation preserves protected-state confidentiality and integrity, effective sandbox enforcement and the capability boundary. Do not assume safe separation or prescribe blanket filesystem exceptions; fail closed if these protections cannot be demonstrated. ADS H5 is not PAF enforcement evidence.
- Demonstrate the effective integration surface and full child/host boundary; reject unsafe login fallback, sandbox bypass and unbrokered authority.
- Qualify explicit-target operation without incompatible tabs before considering a picker. Do not import ADS configuration/state to satisfy a PAF test.

**Host verification expectation:** owner-run macOS tests on PAF's chosen exact version/configuration; ADS diagnostics cannot substitute for PAF security verification. Linux needs its own evidence if supported.

**Residual uncertainty:** no private specification conformance, installed PAF behavior or private architecture has been assessed. Owner must reconcile proposed wording with the real contract before adoption.

## PAF #55 — Interactive review (generic proposal)

**Current assumption / contract:** public #79 describes `paf-copilot-review --pr N` as the corresponding managed review command. Actual private assumptions/revision semantics are **unknown**; no private material was used.

**Relevant evidence:** **verified — human-reported:** E1 and E2–E4 PR-tab navigation passed with an empty list; H2 confirms 1.0.96 and built-in disabling. H3 adds an E5a UI pass but no credential isolation: gh status unavailable and Copilot `via gh` persisted. Neither populated PR behavior nor a PAF session was tested. **unknown:** supported native trusted picker and bounded PR navigation. **blocked:** populated PR tests. The public provider's message/reference interfaces do not independently grant launcher target authority.

**Proposed requirement text:**

> Preserve explicit PR targeting and native conversation/model controls as independent requirements. Validate and bind the repository/PR and review revisions in trusted host context before launch. Browsing, reference insertion or session changes cannot retarget the review or its outputs. Qualify retained read-only PR navigation under the exact same shared security boundary, retaining an access-disabled explicit-target fallback if it cannot comply. A native trusted-picker callback is not required for explicit targeting; do not give the child additional GitHub authority to populate lists.

**Rationale:** read-only browsing convenience must not change review identity or expand the shared substrate profile.

**Acceptance criterion changes:**

- Verify bound-target/artifact identity remains fixed after another harmless item reference and a model change.
- Use an existing open-PR fixture, distinguish empty-success from errors, and verify native UX independently of navigation.
- Demonstrate no child GitHub writes, uncontrolled task credentials or bypass through host commands. Keep finalization requirements owned by the actual review spec.

**Host verification expectation:** use PAF #56's independently qualified provider/configuration, human native interaction and owner-controlled read-only fixtures; do not publish private evidence here.

**Residual uncertainty:** no claims are made about current PAF review behavior, artifact format or existing controls. This proposal requires owner reconciliation, not automatic amendment.

## PAF #57 — Interactive shaping (generic proposal)

**Current assumption / contract:** public #79 describes `paf-copilot-shape --issue N` as the corresponding fixed-target shaping command. Actual private consent/publication mechanisms and wording are **unknown**.

**Relevant evidence:** **verified — human-reported:** E1 and E2–E4 prescribed unsent-reference UI checks passed without a model prompt; H2 ties E2–E4 to 1.0.96. H3 adds a UI-only isolated-gh result; H4 retains the identity in a fresh home, so reused-home state alone is insufficient and the route remains unknown. No PAF session was tested; no trusted event, child isolation or model-service result was established. **unsupported:** promoting reference insertion alone into trusted selection/approval. **unknown:** any other usable native picker event and its provenance. **blocked:** live bounded compatibility.

**Proposed requirement text:**

> Validate and bind one issue before starting the native interactive session. Treat references and model conversation as context rather than target changes or publication approval. Keep any trusted human approval and permitted host publication bound to the original issue and exact immutable proposal. Permit retained read-only navigation only after the shared boundary is proven; disable incompatible access instead of adding child authority, and preserve a verified explicit-target fallback.

**Rationale:** task binding, proposal discussion and trusted approval cannot be inferred from a shared native UI action. This is a generic authority rule, not a description of private publication code.

**Acceptance criterion changes:**

- Verify insertion/discussion of another harmless reference leaves original issue identity and any proposal/approval binding unchanged.
- Demonstrate native model/follow-up controls under PAF #56 restrictions, with navigation unavailable where necessary.
- Establish that no child/model/plugin action can invoke a privileged host mutation or manufacture consent. Use owner-controlled fixtures without writes for this investigation.

**Host verification expectation:** PAF owner verifies the exact host/version with independent state/credentials and reports only authorised sanitised outcomes. Public ADS observations cannot prove private framework behavior.

**Residual uncertainty:** no private publisher, consent flow or implementation was investigated. Reconcile against actual private requirements before accepting any changes.

## Revised proposed decision and follow-up boundary

Do not apply amendments automatically. H2 increases architecture 2's plausibility: isolated native navigation survived through E4, so disabling it is no longer the best-supported assumption on UI-compatibility grounds. Make explicit fixed targeting with retained read-only navigation the leading candidate for further qualification, conditional on exactly the same E5–E8 security/target requirements. Do not call it a fully supported managed design yet. The E5a pass strengthens only the UI evidence: isolated gh status is unavailable while Copilot retains `via gh`. H4 reproduces that identity and navigation in separately launched reused/fresh homes without copying auth state. Reused Copilot-home state alone is insufficient; platform storage, common environment/provider behavior or a label without fresh credential validation remain possible and unknown. H5's unexpected response is not the intended service test; empty PR evidence, unknown host-read/selection mechanisms and missing child enforcement still prevent bounded-design acceptance.

Keep architecture 4 as the smaller explicit-target fallback when incompatible navigation access can actually be disabled; hiding a tab alone is not sufficient. Architecture 3 is optional future pre-launch convenience and cannot repair a failing in-session boundary. Architecture 1 remains unqualified while a documented trusted native selection contract is unknown; UI insertion is not that contract. This is a proposed research priority, not a change to any private/public specification or implementation.

Follow the [unexecuted E5–E8 sequence](experiment-matrix.md#proposed-next-verification--e5e8-not-executed): use completed H4 to narrow H3, use completed H6 for keyboard routing, retain H7's quota-blocked execution attempt; no retry is authorised and actual child enforcement remains unverified, without auth copying, new login or enabling a model shell tool; then effective tools and a harmless model request; then synthetic sandbox/filesystem and controlled network tests; finally supported event discovery and actual fixed-target enforcement checks. Local synthetic probes, a provider request and same-repository #78/#79 observations do not inherently need additional GitHub fixtures. They do require a supported safe test route, legitimate model access where relevant and later human authorisation to execute. A research mock can support only its own tested contract, not production acceptance.

Genuine remaining external prerequisites: a representative existing open-PR fixture for populated PR behavior, an expressly authorised second repository for live cross-repository scope tests, a controlled reachable non-loopback endpoint for external-egress evidence, a supported native event if pursuing architecture 1, and an actual bounded binding/broker mechanism for end-to-end target enforcement. The first two are GitHub-fixture blockers; the others are distinct provider/setup/implementation blockers. Missing fixtures must not block unrelated local evidence work. Actual GitHub mutation probes remain out of scope even if a fixture becomes available.

H4 completes the fresh-home control; the latest human instruction pauses E5b–E8 execution. Preparation does not authorise execution. A fresh home can test state reuse but cannot isolate all host credentials; a successful `!` probe does not establish all model-child routes. The architecture recommendation remains conditional, with explicit-target fallback. These are proposals only: no production code, broader credentials, private-source retrieval, GitHub specification edits, commit, push or publication is authorised or performed.


Archived E5b preparation specifies the exact supported sandbox object, synthetic marker/probe, native-command gates and category-only return record in the [matrix](experiment-matrix.md#e5b-prepared-child-credential-probe--not-executed). It does not change these proposed acceptance gates: a human-invoked `! COMMAND` is not a model-tool execution, a user-owned settings file is not immutable policy, and a synthetic denial is not universal credential isolation. H5 records partial E5b setup/status and an unintended model invocation; no synthetic probe or E6–E8 execution is claimed.

H6 completes the [keyboard checkpoint](experiment-matrix.md#e5b-routing-checkpoint--completed-human-reported). The [corrected execution handoff](experiment-matrix.md#e5b-corrected-human-shell-probe--quota-blocked) retains the minimal launch, every sandbox denial and disabled model Bash; H7 submitted the existing reviewed probe after visible Shell-mode activation, but received the monthly-quota response and no Python results. This is retained as provenance, not an instruction to retry. Even a displayed Shell mode is not evidence of command execution or model-tool equivalence. A required session-write exception would be a separate material boundary question, not a routine fix authorised by this investigation.

For ADS #74 and the generic PAF #56 proposal, qualify the exact human-keyboard route separately from execution: one bang at empty input, no Enter until Execute shell command/Shell/esc exit shell mode are visible, then only the reviewed command without another bang. H6 is human-reported provider UI evidence, not PAF verification. Keep H5's unintended conversational response in provenance. Do not interpret the absent synthetic marker under minimal env as a passed removal-filter test. A human-shell probe cannot establish model-tool, MCP/LSP or host-UI enforcement for any of the six consumers.

## Remaining acceptance work after H7

H7 verifies policy display and correct human-shell submission, while actual execution is **blocked** by provider quota and enforcement stays **unknown**. Do not classify this as a sandbox failure or cure it by changing accounts/tools/security. The architecture recommendation remains conditional: option 2 for qualification, option 4 as an explicit-target fallback only after incompatible access is proven disabled, option 1 without an identified trusted callback still unqualified, option 3 optional and not a repair for unsafe in-session authority.

- **Without further live Copilot:** complete the public-safe research synthesis, source/contract analysis, architecture comparison, all six proposals and deterministic report validation. Retain unknown provider transport/auth internals and callback availability. These reports do not need #74 implementation to document findings.
- **Quota-dependent in this observed path:** an authorised later E5b attempt, provider-child sandbox probes, controlled model/follow-up requests and model-mediated tool tests. H7 does not establish universal credit dependence of all shell/UI operations or the internal quota-check phase. No retry/account change is authorised now.
- **Implementation-dependent:** ADS #74 must supply testable trusted repository/capability binding, broker scope and operation checks, credential custody, protected policy/state, host/child confinement and fail-closed lifecycle before full runtime guarantees can be accepted. ADS #75/#76 additionally need their actual consumer target/revision/proposal/output bindings. Offline unit tests can check implemented host mechanisms without Copilot quota; end-to-end provider checks still need usable service access and appropriate fixtures. Public PAF proposals require analogous owner-qualified mechanisms; no private implementation was inspected.
- **Separate external prerequisites:** existing open-PR fixture, authorised second repository and controlled reachable egress endpoint remain distinct. A native trusted-selection callback is a provider-contract question, not something #74 or quota restoration alone supplies.

Concrete acceptance refinements: ADS #74 and generic PAF #56 should record policy display, command submission, command execution and actual enforcement separately, retaining a quota-blocked result with no fallback authority. ADS #75/#76 and generic PAF #55/#57 should retain explicit targets and require their real consumer bindings before claiming that navigation/model changes cannot retarget outputs or grant approval. Preserve existing no-mutation research limits. Do not apply any proposal or broaden #79 into runtime implementation.
