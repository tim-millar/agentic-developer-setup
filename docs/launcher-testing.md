# Codex launcher testing

The launcher suite provides deterministic evidence for the security- and
workflow-sensitive behaviour of `baseline/scripts/run_codex.sh`. It covers the
public command-line interface, repository checks, prompt construction, optional
GitHub App access and renewal, Git provenance, child-process handling, signals,
host-tool PATH preservation, and cleanup.
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
  environment values, raw child `PATH`, and sanitized credential facts;
- `curl` accepts only the explicitly modelled GitHub endpoints and methods,
  returns synthetic fixture responses, records sanitised renewal timeout facts,
  and fails every unexpected call;
- `jq` supports only the query forms used by the public launcher;
- `openssl` models key validation, base64 operations, and signing without a real
  private key.
- a test-only wait executable exposes explicit renewal boundaries without
  changing the launcher's production 45-minute and 5-minute constants.

App-mode test runs that enable the controlled-wait path must provide that wait
executable. The launcher rejects an incomplete test setup before App API access
or session-state creation, preventing an accidental 45-minute real wait or a
silently exited renewal worker. Test-control environment variables remain on the
launcher side and are not inherited by the fake Codex child.

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

## Agent host PATH

The launcher distinguishes its own command-resolution environment from the host
toolchain selected for Codex. With no `scripts/agent_host_env.sh`, it captures
the inherited non-empty `PATH`. The optional repository hook must be an ordinary
non-symlink regular file; symlinks, including dangling symlinks, and other file
types are rejected. When a valid hook exists, the launcher sources it from the
adopted repository root in a separate Bash subprocess running with `errexit`,
`nounset`, and `pipefail`. The subprocess
starts with the inherited PATH but without GitHub App source credentials,
runtime GitHub tokens, the current-token helper, or `SSH_AUTH_SOCK`.

The hook's stdout and stderr remain diagnostics. Its only result is the exact
resulting `PATH`, written to launcher-private state beneath `${TMPDIR:-/tmp}` as
`<raw PATH bytes><NUL>`. Protocol paths and post-hook executables are held in
readonly launcher-private subprocess variables, so ordinary hook variables
cannot redirect the result write or chmod operation. The launcher rejects hook
failure, an absent or empty result, a missing terminator, and detectable trailing
data; it never falls back after a present hook fails. The private result is
removed immediately after decoding or by the common cleanup trap on failure.
Other hook exports are not imported.

The parent launcher never exports the selected PATH into itself. Launcher-owned
operations therefore continue to use the pre-bootstrap toolchain, and the Codex
executable is selected before bootstrap. Codex receives the raw PATH in its
environment and exactly one launcher-owned structured override for each of
`allow_login_shell=false`,
`shell_environment_policy.experimental_use_profile=false`, and
`shell_environment_policy.set.PATH`. This prevents login-shell startup and
shell-profile reconstruction from reinterpreting the selected PATH. The TOML
basic-string encoder escapes backslash, quote, backspace, tab, newline, form
feed, and carriage return without changing the raw environment value or
flattening argument boundaries.

Forwarded `-c` and `--config` arguments remain supported, including supported
inline spellings, but the launcher rejects assignments to `allow_login_shell`,
`shell_environment_policy`, or any nested `shell_environment_policy.*` key
before repository bootstrap or GitHub App setup. Other forwarded configuration
and ordinary Codex arguments retain their original order and boundaries.

The launcher owns the PATH value it requests, not every Codex configuration
layer. It does not clear or weaken user, project, managed, or organisation
environment filters; broaden environment inheritance; disable secret filtering;
rewrite persistent configuration; or bypass higher-authority policy. Codex
include filtering can remove values supplied through
`shell_environment_policy.set`, so an effective external policy that excludes
`PATH` is incompatible with launcher PATH preservation. If Codex rejects the
effective configuration, the launcher preserves that failure instead of
weakening the external policy. The launcher deliberately does not implement a
general persistent-configuration parser.

This is environment selection, not provisioning. The generic launcher does not
infer runtimes or version managers, source `.envrc`, invoke direnv, install
dependencies, start services, or import the full hook environment. Repository
hooks own any narrow compatibility boundary needed by third-party shell code;
the launcher does not weaken strict mode globally. The credential boundary is
not a comprehensive operating-system sandbox, so reviewed hooks remain trusted
repository code and should be deterministic, non-secret, and narrowly scoped.

Black-box cases use synthetic hooks and JSON argv capture to cover inherited and
modified PATH values, repository-root execution, strict mode, PATH-only import,
readonly protocol routing, regular-file and symlink validation, forwarded-config
ownership, diagnostic separation, credential absence, malformed NUL framing,
spaces, quotes, backslashes and control characters, normal/resume/profile
argument paths, validation ordering, parent-toolchain integrity, and cleanup. No
real runtime manager, Codex process, GitHub credential, or network request is
needed.

## Renewable App credentials

In App mode the launcher keeps the long-lived App ID, installation ID, and
private-key path on the launcher side. It writes the initial installation token
to a private `0700` session directory, with the authoritative token file at
`0600`, then proactively refreshes that token every 45 minutes. A failed refresh
leaves the previous token intact, emits a sanitised warning, and retries after 5
minutes until renewal succeeds.

Only the background installation-token POST uses fixed curl network bounds: a
10-second connection timeout and a 30-second total HTTP timeout. Initial App
validation, token minting, repository resolution, and issue fetching keep their
existing request behaviour. A renewal timeout follows the ordinary failure path,
so Codex keeps running with the last successful token while the worker schedules
the 5-minute retry.

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
a timed-out refresh, verify the 5-minute retry and return to the 45-minute
cadence, and exercise the same lifecycle for resumed sessions. Credential
containment cases also seed exported ambient `JWT` and `TOKEN_JSON` canaries and
verify that neither their replacement launcher values nor their export
attributes reach Codex.

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
