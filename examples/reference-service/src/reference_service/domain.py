from __future__ import annotations

from dataclasses import dataclass, replace
from enum import Enum


class InvalidTaskTitle(ValueError):
    """Raised when a task title is empty after trimming."""


class TaskNotFound(LookupError):
    """Raised when a requested task ID does not exist."""


class InvalidTaskTransition(ValueError):
    """Raised when a task cannot perform the requested state transition."""


class TaskState(Enum):
    PENDING = "pending"
    IN_PROGRESS = "in_progress"
    COMPLETED = "completed"


@dataclass(frozen=True, slots=True)
class Task:
    id: int
    title: str
    state: TaskState

    @classmethod
    def create(cls, task_id: int, title: str) -> Task:
        normalised_title = title.strip()
        if not normalised_title:
            raise InvalidTaskTitle("Task title must not be blank.")
        return cls(id=task_id, title=normalised_title, state=TaskState.PENDING)

    def start(self) -> Task:
        if self.state in (TaskState.PENDING, TaskState.IN_PROGRESS):
            return replace(self, state=TaskState.IN_PROGRESS)
        raise InvalidTaskTransition("A completed task cannot be started.")

    def complete(self) -> Task:
        if self.state in (TaskState.IN_PROGRESS, TaskState.COMPLETED):
            return replace(self, state=TaskState.COMPLETED)
        raise InvalidTaskTransition("A pending task cannot be completed.")
