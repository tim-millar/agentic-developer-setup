# Commit Metadata Conventions

## Purpose

This document defines local commit metadata conventions for work in this repository.

Because this repository typically uses **squash and merge**, branch commits are mainly working history. The primary durable review and attribution surface is the pull request, together with the linked issue and the final squash merge commit.

These conventions therefore exist to keep branch history readable and useful during development, while leaving durable attribution and execution context primarily to the pull request.

## Relationship to Pull Requests and Squash Merge

In this repository:

- feature branch commits are mainly an implementation and review aid
- pull requests are the primary durable record of change intent, validation, risks, and agent involvement
- squash merge commits are typically the long-term visible Git history entry
- issue linkage should normally be captured through the PR and merge workflow, rather than relying only on branch commit history

As a result, commit metadata conventions are **supportive rather than authoritative**. Agent involvement must be captured reliably in the pull request template. Commit-level metadata is useful, but secondary.

## Commit Authorship Model

The default authorship model for local agent-assisted development is:

- the supervising developer remains the Git author and committer
- agent involvement may be recorded in branch commits where useful
- agent/bot authorship may be used only where explicitly configured for a different execution model

This default preserves useful ownership and context in Git history while keeping local branch work understandable.

## Commit Message Expectations

Commits should use:

1. a clear subject line
2. an optional body where useful
3. optional structured trailers when they add useful branch-level context

### Subject line

The subject line should:

- be short and specific
- describe the actual change
- use clear imperative language
- avoid vague summaries such as `updates` or `misc fixes`

Examples:

- `Add archive import validation for missing product dates`
- `Fix analytics job retry handling for timeout failures`

## Optional Structured Trailers

When agent metadata would be useful in branch history, the following trailers may be used:

- `Agent: <agent-name>`
- `Agent-Mode: <assisted|authored>`
- `Launched-By: <developer name> <developer email>`
- `Issue: #<number>` when the commit is associated with an issue

Example:

```text
Add archive import validation for missing product dates

Agent: codex
Agent-Mode: assisted
Launched-By: Tim Millar <tim@palaceskateboards.com>
Issue: #123
```

These trailers should appear at the end of the commit message.

They are useful when branch commits are likely to be inspected directly, but they are not the primary long-term record of agent involvement in a squash-and-merge workflow.

## When Commit Metadata Is Useful

Commit-level agent metadata is most useful when:

- a feature branch contains several meaningful intermediate commits
- branch history is likely to be reviewed directly
- a developer wants clearer local traceability during implementation
- automation is available to add or validate metadata with low friction

It is less important to enforce aggressively when the durable attribution and review record already lives in the pull request.

## Agent Metadata Semantics

Where used, the trailers have the following meanings:

- `Agent` identifies the runner or agent used for the work
- `Agent-Mode: assisted` means the developer remained the primary author and decision-maker, but the agent materially contributed
- `Agent-Mode: authored` means the agent produced the bulk of the implementation under developer supervision
- `Launched-By` identifies the developer who initiated and supervised the agent session
- `Issue` identifies the related GitHub issue when one exists

## Relationship to Issue-Based Workflow

When work is performed from a GitHub issue, issue linkage should normally be captured in the pull request and merge flow.

Including the `Issue` trailer in branch commits can still be useful, but it is secondary to the durable issue/PR relationship.

## Automation and Enforcement

These conventions should be easy to follow where practical, but should not create unnecessary friction.

Typical support mechanisms may include:

- `run_codex.sh` exporting session metadata
- a commit message template
- a commit helper script that appends trailers
- optional `commit-msg` validation for teams that want stronger local consistency

In this framework, stronger emphasis should usually be placed on:

- accurate PR metadata
- clear PR descriptions
- issue linkage
- validation notes in the PR

rather than on strict enforcement of branch-commit metadata.

## Repo-Specific Notes

Document any repository-specific commit rules here.

Examples might include:

- whether conventional commit prefixes are required
- whether issue linkage is mandatory
- whether agent metadata is encouraged or required on branch commits
- whether commit-msg hooks are enabled
- whether any remote or bot-style authorship workflows exist
