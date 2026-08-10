# Codex launcher testing

The launcher suite provides deterministic evidence for the security- and
workflow-sensitive behaviour of `baseline/scripts/run_codex.sh`. It covers the
public command-line interface, repository checks, prompt construction, optional
GitHub App access and renewal, Git provenance, child-process handling, signals,
and cleanup.
It does not source launcher functions or substitute the repository-specific root
wrapper for the reusable baseline implementation.

## Architecture

The suite uses Ruby 3.3 and stdlib Minitest. Every test creates an isolated
temporary adopted repository with the framework's declared target shape:

```text
baseline/scripts/run_codex.sh -> scripts/run_codex.sh
```

The installed launcher is a byte-for-byte copy of the current baseline file.
The fixture also has a minimal prompt, a real `.git` repository, repository-local
Git configuration, a synthetic `HOME`, and a test-controlled `TMPDIR`. Tests run
the launcher as a process through its CLI, usually with a caller working
directory outside both the framework checkout and the adopted repository.

Real Bash, Git, temporary-filesystem behaviour, permissions, and ordinary Unix
utilities exercise the launcher. Test-owned executables earlier on `PATH`
replace integrations that would otherwise require network, credentials,
cryptography, or Codex:

- `codex` records the exact argument array, working directory, selected safe
  environment values, and sanitized credential facts;
- `curl` accepts only the explicitly modelled GitHub endpoints and methods,
  returns synthetic fixture responses, and fails every unexpected call;
- `jq` supports only the query forms used by the public launcher;
- `openssl` models key validation, base64 operations, and signing without a real
  private key.
- a test-only wait executable exposes explicit renewal boundaries without
  changing the launcher's production 45-minute and 5-minute constants.

All fake-command events share an ordered log such as:

```text
openssl:key-check
curl:app
curl:token
curl:repository
curl:issue
codex:start
```

Detailed event entries contain methods and boolean authentication-category
matches, never Authorization header values. The fake Codex similarly records
whether token variables are set, empty, or match the synthetic installation
token without persisting the token value. Synthetic credential response and key
fixtures remain confined to each test's temporary directory. Assertions also
check that token and private-key canaries do not enter launcher output, prompts,
fake-command logs, or other non-credential diagnostics.

## Offline and access boundaries

Normal tests require no Codex installation, GitHub credentials, GitHub App, live
API, private repository, or network. Offline behaviour is enforced at the
command boundary: GitHub-disabled scenarios fail if fake `curl` is called, and
App scenarios fail on any URL, method, or authentication category that the test
did not explicitly configure.

Disabled-mode scenarios verify local launching, issue-fetch rejection, isolated
GitHub CLI configuration, ambient credential neutralisation, and absence of
long-lived App inputs from the Codex child. App-mode scenarios model App identity,
installation-token creation, repository verification, and issue retrieval using
only synthetic responses. Renewal scenarios publish token A, explicitly release
the 45-minute boundary, and then model successful token B publication or a
failed attempt followed by the 5-minute retry path. They do not test GitHub
permissions, token lifetime, the live API, real key parsing, or actual Codex
behaviour.

## Renewable App credentials

In App mode the launcher keeps the long-lived App ID, installation ID, and
private-key path on the launcher side. It writes the initial installation token
to a private `0700` session directory, with the authoritative token file at
`0600`, then proactively refreshes that token every 45 minutes. A failed refresh
leaves the previous token intact, emits a sanitised warning, and retries after 5
minutes until renewal succeeds.

The Codex child retains its initial `GH_TOKEN`, `GITHUB_TOKEN`, and
`INSTALL_TOKEN` values for compatibility; a parent cannot update that static
environment. `AGENT_GITHUB_TOKEN_HELPER` instead names a launcher-generated
helper that returns the current token. The generated Git askpass helper reads
the same authoritative state at every invocation, so HTTPS Git authentication
automatically uses renewed credentials. Neither helper contains or receives the
App source credentials.

Renewed tokens are published by writing a private sibling file and atomically
renaming it over the authoritative token. Behavioural tests read concurrently
across that replacement and accept only the complete old or new token. Other
tests remove the token state to verify safe helper failure, retain token A across
a failed refresh, verify the 5-minute retry and return to the 45-minute cadence,
and exercise the same lifecycle for resumed sessions.

## Processes, signals, and cleanup

The fake Codex can publish a deterministic started marker and wait. Signal tests
poll that marker with a bounded timeout before sending `SIGINT` or `SIGTERM` to
the launcher. They then verify forwarding to the child, exit status 130 or 143,
single invocation, termination of the renewal wait process, and removal of the
launcher-owned credential directory, current-token state, token helper, GitHub
configuration, and askpass files. No arbitrary delay is used as the readiness
condition.

Success, child failure, resume, App failure paths where resources exist, and
handled signals assert cleanup beneath the controlled `TMPDIR`. Cleanup stops
and waits for the renewal worker before removing its state, so a worker cannot
race with credential deletion. A debug prompt created by
`DEBUG_CODEX_PROMPT=1` is deliberately retained, checked for mode `0600`, and
compared exactly with the final prompt passed to Codex.

## Running the tests

```sh
make test-launcher
make test
make check
```

`make test-launcher` runs only the launcher-focused file. The sorted
`test/**/*_test.rb` discovery used by `make test` includes it automatically, so
`make check` runs launcher tests once before framework validation. The existing
Ruby 3.3 CI job uses that same `make check` entrypoint.

## Adding a scenario

Add a Minitest case to `test/launcher_test.rb` and extend
`test/support/launcher_harness.rb` only when reusable fixture behaviour is
needed. Prefer an observable CLI outcome, exact argument or prompt assertions,
and sanitized ordered events. Extend a fake with only the command form required
by the new public launcher behaviour; unexpected forms should continue to fail.
Keep each scenario isolated and avoid host-global Git state, ambient credentials,
execution-order assumptions, network calls, and raw secret logging.

The canonical platform is the repository's `ubuntu-latest` CI environment with
Ruby 3.3. The suite also assumes an ordinary supported Bash/Unix environment,
Git, process signals, and standard filesystem permission semantics. Native
Windows support and privileged network-isolation mechanisms are outside this
test contract.
