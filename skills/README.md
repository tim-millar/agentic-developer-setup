# Optional global agent skills

ADS distributes personal skills independently of repository adoption and agent
runtime installation. The available skill, HumanLayer's `show-me`, presents a
topic you've already investigated using call trees, control-flow sketches,
component trees, structural diffs, diagrams or focused HTML. The repository-local
`code-review` skill continues to apply its repository's `REVIEW.md`. Agent clients
and runtimes retain responsibility for tool access and execution permissions.

The [vendored bundle](show-me/) records the pinned HumanLayer source, Git blob,
plugin version and MIT licence. ADS installs copies of those three files
alongside an ownership record. Installed copies remain usable after you move
or delete the ADS checkout. [Upstream provenance](show-me/UPSTREAM.md)

## Install, inspect and uninstall

Use macOS or Linux with Ruby 3.3.0 or later. The manager uses only the Ruby
standard library and works offline. Set `HOME` to an existing absolute directory
below `/`, using a path with no symlink, `.` or `..` components. Run these
commands from the checkout, or use an absolute path to the script from elsewhere.

```sh
ruby scripts/ads-skills.rb --help
ruby scripts/ads-skills.rb install show-me
ruby scripts/ads-skills.rb install show-me --agent claude
ruby scripts/ads-skills.rb install show-me --agent codex
ruby scripts/ads-skills.rb status show-me --agent both
ruby scripts/ads-skills.rb uninstall show-me --agent both
```

Each operation accepts `claude`, `codex` or `both`. The default is `both`.

| Agent | Personal installation | Expected local invocation |
| --- | --- | --- |
| Claude Code | `$HOME/.claude/skills/show-me/` | `/show-me` |
| Codex | `$HOME/.agents/skills/show-me/` | `$show-me` |

See the clients' discovery documentation for supported environments and settings.
[Claude Code skills](https://code.claude.com/docs/en/skills) · [Codex skills](https://developers.openai.com/codex/skills)

Run `install` again after updating ADS to apply a reviewed bundle revision.
An unchanged current copy is a successful no-op. `uninstall` removes an
unchanged ADS-managed copy, and a missing target is a successful no-op.

Read-only `status` reports each selected destination and exits successfully
only when every selected copy is `current`.

| State | Meaning |
| --- | --- |
| `current` | The verified ADS installation matches the checkout bundle. |
| `outdated` | The ADS installation matches its ownership record and differs from the checkout bundle. |
| `missing` | The destination is absent. |
| `modified` | A valid ADS ownership record exists and managed contents are changed, missing or unexpected. |
| `conflict` | The path is unsafe or ownership could not be verified. |

## Ownership and recovery

The `.ads-install.json` file records ADS ownership and the SHA-256 digest of
each installed file. ADS verifies the files and checks for extra entries before
replacing or removing a copy. The record is an ownership convention for
cooperating tools.

A manually installed copy, a copy managed by another installer, an unsafe
symlink, invalid metadata or local edits block the operation for every selected
destination. Resolve ownership outside the manager. Use the original installer
to remove its copy, or move the existing directory aside and preserve any edits
before running ADS again. Select a single agent to act on just that destination.

ADS stages a complete bundle beside each destination and publishes it by rename.
Updates and removals temporarily retain the original directory as `previous`
inside a private `.ads-show-me-*` workspace. If a change fails, ADS attempts to
restore the original destinations and reports the resulting states. If
restoration fails or the process is interrupted, inspect any reported or
remaining workspaces in the selected personal skills directories. Preserve
`previous` while checking its ownership and contents, and restore it manually
only when the original destination is vacant and safe. If targets were applied
but cleanup failed, inspect the workspace before removing residual files.
Changes across selected destinations can become visible at different times.
Parent directories and sibling skills remain in place after uninstall.

## Update the vendored source

Vendor upstream revisions through a reviewed ADS change. Fetch `SKILL.md` and
the applicable licence from the new pinned public commit, preserve their
bytes, and update `UPSTREAM.md` with the commit, plugin version, blob SHA and
source URLs. Update the expected blob SHA in `test/ads_skills_test.rb`, verify it
with `git hash-object skills/show-me/SKILL.md`, and run `make check`. Lifecycle
commands always use the local bundle and never check upstream for updates.

## Verify local discovery after merging

1. Inspect both personal `show-me` paths and resolve any existing ownership
   conflicts outside ADS.
2. Run `ruby scripts/ads-skills.rb install show-me --agent both`.
3. Run `ruby scripts/ads-skills.rb status show-me --agent both` and confirm
   both report `current`.
4. From a repository without a local `show-me` skill, start ordinary local
   Claude Code and invoke `/show-me` with a focused explanation request.
5. From a repository without a local `show-me` skill, start ordinary local
   Codex and invoke `$show-me` with an equivalent request.
6. Confirm each client actually discovers and uses the personal skill. Record
   the platform, client versions and any discovery limitations.
7. Confirm the installed files are independent copies. Move the ADS checkout
   temporarily if practical and repeat the invocations.

Remote and cloud sessions or isolated runtimes may use a separate `HOME` or
skill-discovery environment. Provisioning those environments is outside this
manager's scope. The offline lifecycle tests use disposable homes. Steps above
are for manual verification on your own machine after merge.
