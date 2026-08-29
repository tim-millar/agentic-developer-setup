import pytest

from reference_service.domain import (
    InvalidTaskTitle,
    InvalidTaskTransition,
    Task,
    TaskState,
)


def test_task_creation_sets_identity_title_and_pending_state() -> None:
    task = Task.create(1, "  Write documentation  ")

    assert task.id == 1
    assert task.title == "Write documentation"
    assert task.state is TaskState.PENDING


@pytest.mark.parametrize("title", ["", "   ", "\t\n"])
def test_blank_titles_are_rejected(title: str) -> None:
    with pytest.raises(InvalidTaskTitle):
        Task.create(1, title)


def test_pending_task_can_start() -> None:
    task = Task.create(1, "Start work")

    started = task.start()

    assert started.state is TaskState.IN_PROGRESS


def test_starting_an_in_progress_task_is_idempotent() -> None:
    task = Task.create(1, "Continue work").start()

    started_again = task.start()

    assert started_again == task


def test_pending_task_cannot_complete() -> None:
    task = Task.create(1, "Do not skip start")

    with pytest.raises(InvalidTaskTransition):
        task.complete()


def test_in_progress_task_can_complete() -> None:
    task = Task.create(1, "Finish work").start()

    completed = task.complete()

    assert completed.state is TaskState.COMPLETED


def test_completing_a_completed_task_is_idempotent() -> None:
    task = Task.create(1, "Keep complete").start().complete()

    completed_again = task.complete()

    assert completed_again == task


def test_completed_task_cannot_start() -> None:
    task = Task.create(1, "Do not restart").start().complete()

    with pytest.raises(InvalidTaskTransition):
        task.start()
