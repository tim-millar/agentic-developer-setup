# Inspect local agent runs

`ads-agent-runs` is an offline, read-only terminal view of the local evidence
written by the Codex and Claude Explore launchers. It reads existing records;
it does not reconcile outcomes, call provider or GitHub APIs, create indexes,
or modify telemetry.

## Install and remove

Ruby 3.3 or later is required. From an ADS checkout, run:

```sh
ruby scripts/manage_agent_runs.rb install
ruby scripts/manage_agent_runs.rb status
```

The executable is `~/.local/bin/ads-agent-runs`; its self-contained payload is
under `${XDG_DATA_HOME:-$HOME/.local/share}/agent-development-framework/agent-runs/`.
The installer reports if `~/.local/bin` is not on `PATH`; add it using the
instructions for your shell. The installer does not edit shell configuration.
Run `install` again to update a managed installation. Remove it with
`ruby scripts/manage_agent_runs.rb uninstall`. Status is read-only. Foreign or
locally modified files are reported as conflicts and are not overwritten or
removed. The installed command uses Ruby's standard library and does not need
the checkout, Bundler, credentials, or a network connection.

## Commands

```text
ads-agent-runs list [--telemetry-dir ABSOLUTE_PATH] [--repository OWNER/REPO] [--limit N | --all]
ads-agent-runs show <run_id|unique-prefix|latest> [--telemetry-dir ABSOLUTE_PATH] [--repository OWNER/REPO]
ads-agent-runs report [--telemetry-dir ABSOLUTE_PATH] [--repository OWNER/REPO] [--as-of YYYY-MM-DDTHH:MM:SSZ] [--output ABSOLUTE_PATH]
```

No command prints help. `-h` and `--help` work globally and per command.
`list` defaults to the 20 newest valid runs. It sorts by parsed UTC start time,
then full run ID descending; unusable timestamps follow dated records. `--limit`
accepts a positive decimal integer and cannot be combined with `--all`.
`--repository` compares validated GitHub identities case-insensitively. Without
it, records for all local repositories and supported runtimes are included,
regardless of the current directory. Path-digest identities remain visible.

`show` accepts a full canonical run ID, a case-sensitive unique prefix, or
`latest`. The repository filter applies before selection. Ambiguous prefixes
ask for a longer selector. Show displays the validated run, task identity,
execution lifecycle, observed usage, confirmed outcome evidence, and the local
evidence paths. It never opens or prints `task.txt` contents. Elapsed duration
is calendar time, including waiting and interruptions. `completed` describes
execution termination only; it does not mean the implementation was accepted.

`report` invokes the existing longitudinal Markdown reporter and preserves its
aggregation and output-file rules. Give `--as-of` an explicit UTC timestamp to
reproduce a report for a fixed evidence snapshot.

## Evidence, scope and privacy

Root selection is `--telemetry-dir`, then nonempty `AGENT_TELEMETRY_DIR`, then
nonempty absolute `XDG_DATA_HOME` plus
`agent-development-framework/telemetry/runs`, then
`$HOME/.local/share/agent-development-framework/telemetry/runs`. An explicit
root must be absolute, existing and readable. A missing implicit root is an
empty corpus and is never created.

Runs join by canonical `run_id`: `run.json` is execution evidence,
`usage.json` is provider usage and cost evidence, `outcome.json` is recorded
GitHub lifecycle evidence, and `task.txt` is an optional private snapshot.
Missing, disabled, unavailable, partial, invalid and zero-valued usage remain
distinct. A missing outcome sidecar does not establish whether reconciliation
was attempted or why evidence is absent. Candidate PRs are not confirmed
associations. Provider-reported runtime estimates are not invoices. Review,
change and check observations are not quality, acceptance or RTM evidence.

Displayed timestamps are ISO 8601 UTC ending in `Z`; no local-time conversion
or relative-time wording is used. The command escapes terminal controls in
record values, skips symlinked evidence, validates records before presentation,
and omits invalid base runs while reporting their count. It does not execute
telemetry content or access networks or credentials.

The command builds on the common run identity from [#53](https://github.com/tim-millar/agentic-developer-setup/issues/53),
the outcome evidence from [#57](https://github.com/tim-millar/agentic-developer-setup/issues/57),
the usage sidecar from [#56](https://github.com/tim-millar/agentic-developer-setup/issues/56),
and the longitudinal reporter from [#91](https://github.com/tim-millar/agentic-developer-setup/issues/91).
See [telemetry storage and privacy](run-telemetry.md), [usage semantics](run-usage.md),
and [longitudinal report definitions](run-reporting.md) for their source contracts.
