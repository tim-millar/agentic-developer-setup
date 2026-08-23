# Claude Code Explore runtime

`claude-explore` reduces ambient authority and blocks common remote, credential, infrastructure, deployment, and shared-state paths while preserving useful local engineering work. It is not a hostile-code sandbox or a complete host security boundary.

It is intended for supervised repository archaeology, migration reconnaissance, dependency and blocker investigation, local prototyping, test/build diagnosis, architecture exploration, and preparation of plans or patches. It is intentionally separate from deterministic issue-to-pull-request automation.

## Boundary and ownership

Three concepts remain separate:

- A repository owns `AGENTS.md`, `CLAUDE.md`, development and architecture documentation, command surfaces, tests, and repository-specific constraints.
- An environment adapter describes how repository commands execute, such as directly on the host or through another development environment.
- A coding-agent runtime controls how the coding-agent process starts and what ambient authority it receives.

`claude-explore` is globally installed coding-agent runtime tooling. It does not install repository context, replace `CLAUDE.md`, become an adapter, provide a `claude` alias, or enable autonomous publication.

## Requirements and installation

Supported platforms are macOS and Linux. The source and installed runtime require Ruby 3.3 or newer and Ruby standard-library components only. Claude Code 2.1.224 or newer is required. On Linux, Claude's native sandbox requires the dependencies documented by Claude Code, including `bubblewrap` and `socat`; the installer does not perform privileged package installation.

Install using the Claude executable found on the pre-install `PATH`:

```sh
ruby agent-runtimes/claude-explore/install.rb install
```

Or pin an explicit executable:

```sh
ruby agent-runtimes/claude-explore/install.rb install \
  --claude-bin /absolute/path/to/claude
```

The installer resolves the canonical executable, rejects recursive wrappers and symlink loops, verifies its version, and records the path. Startup always uses that recorded executable; it does not search the guarded session `PATH` or silently select a replacement.

The default launcher is `~/.local/bin/claude-explore`. Versioned runtime data is installed under `${XDG_DATA_HOME:-$HOME/.local/share}/agent-development-framework/claude-explore/`, and non-secret installation metadata under `${XDG_CONFIG_HOME:-$HOME/.config}/agent-development-framework/claude-explore/`. Shell profiles are not edited. If `~/.local/bin` is absent from `PATH`, the installer reports the manual action.

Same-version `install` is idempotent. Version transitions are explicit:

```sh
ruby agent-runtimes/claude-explore/install.rb upgrade
```

Upgrade validates new source and policy before switching the launcher and reports old/new runtime and policy versions. It does not discover remote updates or provide a general rollback manager.

Uninstall removes only material whose runtime ownership can be proven:

```sh
ruby agent-runtimes/claude-explore/install.rb uninstall
```

It preserves the developer's real Claude installation, Claude sessions and settings, repositories, and unrelated XDG or `~/.local/bin` files.

## Native Claude controls

Every normal session supplies a private generated JSON file using Claude Code's session-level `--settings` interface. It requires:

- `sandbox.enabled: true`;
- `sandbox.failIfUnavailable: true`;
- `sandbox.allowUnsandboxedCommands: false`;
- normal sandbox filesystem isolation, plus credential read denies;
- `disableAllHooks: true`;
- `disableArtifact: true`;
- `permissions.deny` for all MCP tools and configured credential paths.

Claude therefore fails startup if its native sandbox is unavailable rather than warning and continuing, and its unsandboxed retry escape hatch is disabled. The runtime does not select a permission-bypass mode. Sandboxed commands may use Claude's normal auto-approval behaviour.

Official Claude documentation describes the [`--settings` precedence](https://code.claude.com/docs/en/settings), [sandbox controls](https://code.claude.com/docs/en/sandboxing), [permission rules](https://code.claude.com/docs/en/permissions), and [artifact disable control](https://code.claude.com/docs/en/artifacts). `--settings` overrides user, project, and local settings for the session but remains below managed organisation settings. Managed hooks cannot be disabled by a lower settings scope. If higher-authority management makes the required contract impossible and Claude reports that conflict, the session must fail; the runtime does not claim to override management policy.

Repository `CLAUDE.md` context remains available normally. User and project preferences may affect unrelated behaviour. Managed settings, plugins, skills, repository instructions, and other same-user configuration surfaces remain residual authority where they cannot be generically removed without breaking normal use.

## Environment and credential files

The child environment is constructed from the developer environment rather than cleared wholesale. Normal inputs such as `PATH`, locale, home, terminal, editors, and language/toolchain configuration remain. The policy removes the enumerated GitHub/source-control, SSH agent, AWS, Google Cloud, Azure/ARM, Kubernetes, Terraform, deployment, direct database/cache, and package-registry credential variables.

It also sets:

```text
GIT_TERMINAL_PROMPT=0
GCM_INTERACTIVE=never
AWS_EC2_METADATA_DISABLED=true
GH_CONFIG_DIR=<private empty session directory>
GIT_ASKPASS=<runtime refusal helper>
```

This intentionally prevents private-registry credentials in version 1. Claude's supported existing login/session state is not deliberately removed and no Anthropic API key is required when the developer's normal Claude Code authentication works.

The generated sandbox and permission settings deny reads of the policy-declared paths under `~/.ssh`, `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.kube`, `~/.config/gh`, Git credentials, `.netrc`, Docker config, and common npm, Python, and Ruby registry credential files. This is a finite list, not comprehensive credential discovery. OS keychains, browser sessions, repository-local secrets, application configuration, unlisted stores, and other user-readable files remain risks.

## Command policy

Each session creates a mode-0700 temporary directory, prepends a private guard directory to `PATH`, and generates argv-preserving wrappers from [`policy.yml`](../../agent-runtimes/claude-explore/policy.yml). Wrappers never use `eval` or rebuild a shell string. Allowed operations invoke the resolved real executable structurally and preserve its status; blocked operations never invoke it and return 126.

Git permits the explicitly classified local inspection, working-tree, branch, history, staging, merge/rebase, worktree, and commit operations in policy. It permits read-only `git remote` listing/get-url, explicit read forms of `git config`, tag listing, and ordinary local branch operations. It blocks remote Git commands, credentials, upstream mutation, remote mutation/network queries, configuration writes, tag publication-oriented mutation, network-capable submodules, and every unclassified subcommand.

`gh` is fully blocked. The policy also fully blocks the listed cloud, cluster, infrastructure, secrets, hosting/deployment, SSH/file-transfer, Docker/Podman, and non-PostgreSQL direct database/cache clients. An executable absent from the finite list is not certified safe.

`psql` is filtered. No explicit host uses local socket behaviour after `PG*` variables are stripped. `localhost`, `127.0.0.1`, `::1`, and absolute Unix-socket paths are allowed. Remote hosts, service names, libpq key/value strings, ambiguous strings, and PostgreSQL URIs without a deterministically permitted explicit host are blocked. Hostnames are never resolved through DNS to infer locality. Diagnostics never repeat a connection URI or full argv.

Application and test commands remain allowed to load repository-owned configuration. Application-mediated access can mutate whichever service the repository configuration points at. `claude-explore` does not inspect or prove that repository-owned application configuration is safe.

## Diagnostics and inspection

A blocked runtime operation is an intentional authority boundary. Claude should report the blocked action and the state of the local work rather than recommend bypassing the runtime.

The stable diagnostic begins with `CLAUDE_EXPLORE_BLOCKED`, includes runtime/policy versions, category, rule and normalized operation, and gives a safe human-follow-up action. It never prints arbitrary complete argv, connection URLs, tokens, passwords, or credential values. Session guidance tells Claude not to recommend unrestricted Claude, restored credentials, an alternate binary, a disabled guard path, edited installed policy, or an unrestricted shell in response; this guidance is not itself an enforcement guarantee.

Inspect effective installation and policy metadata without launching a session:

```sh
claude-explore --claude-explore-runtime-info
```

Classify structured argv without execution:

```sh
claude-explore --claude-explore-check-command -- git push origin main
claude-explore --claude-explore-check-command -- psql -h localhost
```

Allowed classification exits 0; blocked classification exits 126; malformed runtime-owned flags exit 2.

## Lifecycle and threat model

The launcher preserves interactive standard streams and the exact normal Claude exit status, forwards SIGINT and SIGTERM to the child, and removes only the unique session directory it created. It validates security-relevant installed files are current-user-owned regular files, not group/world writable, and contained in expected installation paths.

The developer who owns the runtime files can deliberately modify or bypass them. Absolute executable paths can bypass a simple `PATH` guard; a process may discover an unclassified executable; generic clients such as `curl`, `wget`, package managers, and application code can still use the network within Claude's native sandbox policy; package scripts execute code. Shell wrappers and a finite denylist are not adversarial same-user containment. Docker socket access is not granted, but this runtime is not a VM, container, or comprehensive network/database boundary.

## Manual smoke test

Use a current Claude Code client, a disposable public or synthetic repository, and synthetic credential values only.

1. Install `claude-explore`, then run `claude-explore --claude-explore-runtime-info`.
2. Export synthetic values for representative stripped variables such as `GITHUB_TOKEN`, `AWS_ACCESS_KEY_ID`, and `DATABASE_URL`.
3. Start `claude-explore` in the disposable repository and confirm the sandbox is active.
4. Ask Claude to inspect files, make a local edit, run the repository tests/build, stage files, and create a local commit.
5. Confirm `git push`, every `gh` form, a cloud/infrastructure CLI, Docker/Podman, and remote `psql` are blocked with exit 126 and the stable runtime diagnostic.
6. Where PostgreSQL is locally available, confirm a loopback or Unix-socket `psql` invocation is delegated.
7. Confirm the synthetic ambient credentials are absent without displaying real credentials.
8. Confirm dry-run classification for an allowed and blocked command.
9. Exit normally and by SIGINT in separate sessions; confirm status/signal behaviour and session cleanup.
10. Uninstall and confirm the real `claude` executable, its settings, and the disposable repository remain intact.

Automated coverage is offline and uses fake executables and temporary repositories. Run the focused suite with `make test-claude-runtime`; `make check` remains authoritative.
