# Claude Code Explore runtime

`claude-explore` is a globally installed, reduced-authority Claude Code runtime for supervised repository archaeology, migration reconnaissance, local prototyping, test/build diagnosis, and planning. It permits local working-tree edits, project commands, staging and local commits, and deterministically local PostgreSQL access. It is not a publishing or autonomous execution runtime.

The runtime is coding-agent infrastructure, not a repository adapter or a replacement for repository-owned `AGENTS.md`, `CLAUDE.md`, development commands, or execution environments. Its installed path is independent of project-selected Ruby, Python, Node, package-manager, and language-manager versions. Repository toolchains remain on the ordinary `PATH`, subject to runtime policy. The source policy in [`policy.sh`](../../agent-runtimes/claude-explore/policy.sh) is authoritative; this document summarises it rather than duplicating every list.

## Prerequisites and lifecycle

Supported hosts are macOS and Linux with `/bin/sh`, `/bin/bash` 3.2 or newer, a real `realpath`, normal system filesystem/process utilities, and Claude Code 2.1.224 or newer. The developer installs and authenticates Claude separately. The runtime does not require Ruby, Python, Node, npm, Bundler, a virtual environment, or a compiled framework helper.

Install from this checkout:

```sh
agent-runtimes/claude-explore/install.sh install
```

The installer discovers `claude` on the pre-install `PATH`. Select a particular stable launcher explicitly when necessary:

```sh
agent-runtimes/claude-explore/install.sh install --claude-bin /absolute/path/to/claude
```

Upgrade or uninstall with:

```sh
agent-runtimes/claude-explore/install.sh upgrade
agent-runtimes/claude-explore/install.sh uninstall
```

Installation is user-level. The stable command is `~/.local/bin/claude-explore`; versioned runtime data and strict line-oriented metadata use the normal XDG data/config roots. Explicit `XDG_DATA_HOME` and `XDG_CONFIG_HOME` values must be absolute; relative roots fail rather than creating state under the caller's working directory. Shell profiles are never edited. If `~/.local/bin` is absent from `PATH`, the installer prints the manual action required. Uninstall removes only ownership-proven framework resources and preserves Claude, Claude settings and sessions, repositories, and unrelated user files.

The metadata records Claude's stable launcher path, not only its current binary target. Installation and every invocation validate the launcher and resolved target path hierarchy: root-owned or current-user-owned, non-group/world-writable components are accepted, as are normal root-owned sticky temporary roots. A normal Claude updater symlink change therefore takes effect without reinstalling `claude-explore`; a missing, recursive, replaceable through an unsafe ancestor, unparseable, or too-old target fails rather than triggering a `PATH` search.

Activation stages the version directory, `current` link, stable launcher, and metadata before replacing any live path. Link replacement does not follow an existing symlink-to-directory, and prior links, metadata, and same-version content remain available until every activation step succeeds. A failed upgrade rolls those resources back and removes transaction artefacts.

## Runtime controls

Small `/bin/sh` entrypoints remove shell-startup control variables before invoking `/bin/bash --noprofile --norc -p`. Privileged Bash startup prevents exported `BASH_FUNC_*` definitions from becoming trusted installer/runtime/guard functions; function definitions are also removed before Claude is launched. Each bootstrap validates the expected executable runtime files and non-executable policy before handing off. Trusted runtime logic remains Bash 3.2-compatible and keeps argv as arrays. Each session creates a unique mode-0700 control directory outside the repository and removes only its own directory at exit.

The generated Claude settings require the native sandbox, fail when it is unavailable, retain filesystem isolation, and prohibit unsandboxed command retries. They disable all hooks and Artifact, deny writes to installed/session controls, protect the policy credential-file list through sandbox credentials plus `Read` denies, and reinforce runtime writes through `Edit` denies. The runtime also sets `CLAUDE_CODE_SUBPROCESS_ENV_SCRUB=1` and `CLAUDE_CODE_DISABLE_ARTIFACT=1`.

MCP is empty in v1: the launcher supplies an empty per-session MCP file with strict MCP configuration and denies `mcp__*`. Browser automation is disabled with `--no-chrome`. Runtime-owned system guidance tells Claude to report `CLAUDE_EXPLORE_BLOCKED` rather than evade policy. Repository `CLAUDE.md` discovery remains normal; user flags that replace/append system guidance or change settings, tools, MCP, plugins, worktrees, browser, cloud, remote-control, background, non-interactive, or maintenance modes are rejected. Unknown option-like arguments fail closed. Safe interactive session/model/effort/resume options and the documented non-bypass permission modes remain available.

## Environment and guarded commands

The runtime preserves ordinary project `PATH`, locale, terminal/editor, and language-manager settings. It strips the policy's source-control, cloud, infrastructure, deployment, container, database, and package credentials; points `GH_CONFIG_DIR` at an empty private directory; disables Git credential prompting; and installs a refusing askpass helper. Claude's own supported authentication state is intentionally preserved.

A private guard directory precedes the original `PATH`. Publication, GitHub, cloud, infrastructure, deployment, SSH, Docker/Podman, common privilege wrappers, remote-capable database clients, and PostgreSQL client/admin companions declared by policy always return 126 without delegation. The fixed list is inspectable in `policy.sh`. Local file-backed embedded database tools are not prohibited solely because they are database clients.

Git permits the policy's local subcommands and safe global options. Push, fetch, pull, clone, credential helpers, network mail operations, global execution/configuration overrides, submodules, unknown subcommands, upstream mutation, remote mutation, config writes, and tag mutation are blocked. Git configuration/execution environment variables, including indexed `GIT_CONFIG_KEY_*`/`GIT_CONFIG_VALUE_*` forms, are removed both before Claude starts and immediately before Git delegation. Local staging, commits, branches, diffs, history, merges, rebases, stashes, resets, and worktrees remain usable under the declared classifier.

`psql` is the only permitted network-capable direct database client. With PostgreSQL variables removed, an omitted host and a plain database name are local. Explicit hosts must be `localhost`, `127.0.0.1`, `::1`, or an absolute Unix-socket path. PostgreSQL URIs must use one of those loopback hosts. Service/key-value, multi-host, ambiguous, fragment, and every query-string form are blocked.

Direct psql execution is non-interactive. The guard always injects `-X`, blocks command files and password prompts, rejects backslash/meta-command content in every `-c`/`--command` value, and connects stdin to `/dev/null`. Ordinary SQL supplied with `-c` can run against an already-classified local target; target/help/version-only forms cannot consume interactive commands. Connection-selector variables are removed again immediately before delegation, then `PGPASSFILE` is set to a private, empty mode-0600 session file. Both `~/.psqlrc` and `~/.pgpass` are therefore excluded from delegated execution.

Normal application commands such as `make test`, `bundle exec …`, and `npm test` remain available. The runtime does not prove that application configuration points only at local services, and it does not comprehensively intercept generic HTTP clients or package managers.

## Diagnostics and inspection

Intentional policy blocks begin with `CLAUDE_EXPLORE_BLOCKED` and exit 126. They report stable runtime, policy, category, normalized-operation, rule, reason, and safe-next-action identifiers without echoing credentials, prompts, complete argv, or database URIs. Runtime/installation failures exit 1, malformed runtime-owned calls exit 2, and internal guard failures exit 125. Normal Claude child status is preserved.

Inspect the installed/runtime/client boundary without starting a session:

```sh
claude-explore --claude-explore-runtime-info
```

Classify a structured command without executing Claude or the command:

```sh
claude-explore --claude-explore-check-command -- git status
claude-explore --claude-explore-check-command -- git push
claude-explore --claude-explore-check-command -- psql -d mydb -c 'select 1'
```

Allowed classifications begin with `CLAUDE_EXPLORE_CLASSIFICATION` and exit 0; blocked classifications use the normal blocked diagnostic and exit 126.

## Threat model and limitations

This is a cooperating-agent reduced-authority guardrail, not hostile-code containment, a VM/container, or same-user isolation. A deliberately evasive same-user process can bypass it. Absolute executable paths can bypass `PATH` guards; blocked binaries and credential files are finite lists; equivalent unclassified tools and OS keychains/browser sessions may exist; generic HTTP and application code may retain sandbox-permitted network access; application configuration may reach remote/shared services; package scripts execute code; managed Claude configuration may retain higher authority; and Claude authentication remains usable. Supervision and review remain required.

## Disposable manual smoke procedure

Use a disposable user/XDG environment and synthetic credentials, then:

1. install with an explicit stable Claude launcher and inspect runtime info;
2. enter repositories selecting incompatible Ruby, Node, and Python versions and confirm the wrapper still starts;
3. start a normal session and inspect `/sandbox` to confirm sandbox/file controls are active;
4. inspect, edit, and test disposable project files, then stage and create a local commit;
5. confirm `git push`, `gh`, cloud/infra/deployment CLIs, privilege wrappers, Docker/Podman, PostgreSQL companions, remote `psql`, and query-bearing PostgreSQL URIs return 126;
6. confirm `psql -d mydb -c 'select 1'` reaches a disposable local server where available, while `-f`, backslash commands, `.psqlrc`, `.pgpass`, and stdin commands do not;
7. confirm synthetic denied environment variables/files are unavailable;
8. confirm MCP, Chrome, cloud/remote-control, background, print, and system-prompt override modes are rejected;
9. exercise dry-run allowed/blocked classification without executing either command;
10. confirm a normal exit and `SIGINT` remove only the current session directory;
11. run uninstall and confirm real Claude, repositories, Claude settings/sessions, and unrelated XDG files remain.

Automated offline coverage uses fake tools and disposable homes:

```sh
make test-claude-runtime
make check
```
