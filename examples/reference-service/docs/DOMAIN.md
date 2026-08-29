# Domain

## Task

`Task` is an immutable typed value with:

```text
id: int
title: str
state: TaskState
```

## TaskState

`TaskState` has exactly these values:

```text
PENDING       = pending
IN_PROGRESS   = in_progress
COMPLETED     = completed
```

## Identity and titles

An `InMemoryTaskRepository` allocates positive, monotonically increasing
integer IDs per repository instance. The first task is `1`, the second is `2`.
Repository instances do not share their counters or task state.

Creation trims leading and trailing whitespace from the title and stores the
trimmed value. An empty or whitespace-only title raises `InvalidTaskTitle`.
There is no maximum-length rule.

## Public errors

- `InvalidTaskTitle` means a title is blank after trimming.
- `TaskNotFound` means the requested task ID does not exist.
- `InvalidTaskTransition` means the requested operation is not permitted for the current state.

## State transitions

| Current state | Operation | Result |
| --- | --- | --- |
| `pending` | `start` | `in_progress` |
| `pending` | `complete` | `InvalidTaskTransition` |
| `in_progress` | `start` | `in_progress` |
| `in_progress` | `complete` | `completed` |
| `completed` | `complete` | `completed` |
| `completed` | `start` | `InvalidTaskTransition` |

`start` is idempotent while a task is `in_progress`. `complete` is idempotent
while a task is `completed`. A pending task cannot be completed directly, and
a completed task cannot be started again.

## Listing

`TaskRegistry.list()` returns all tasks in ascending ID, which is also creation
order. Unknown IDs passed to `get`, `start`, or `complete` raise `TaskNotFound`.
