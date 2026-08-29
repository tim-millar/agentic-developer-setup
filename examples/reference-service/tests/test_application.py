import pytest

from reference_service.application import TaskRegistry
from reference_service.domain import InvalidTaskTransition, TaskNotFound, TaskState
from reference_service.persistence import InMemoryTaskRepository


def make_registry() -> TaskRegistry:
    return TaskRegistry(InMemoryTaskRepository())


def test_existing_task_can_be_retrieved() -> None:
    registry = make_registry()
    created = registry.create("Inspect the registry")

    assert registry.get(created.id) == created


def test_unknown_task_raises_task_not_found_for_each_lookup_use_case() -> None:
    registry = make_registry()

    with pytest.raises(TaskNotFound):
        registry.get(1)
    with pytest.raises(TaskNotFound):
        registry.start(1)
    with pytest.raises(TaskNotFound):
        registry.complete(1)


def test_list_returns_tasks_in_creation_order() -> None:
    registry = make_registry()
    first = registry.create("First")
    second = registry.create("Second")

    assert registry.list() == [first, second]


def test_start_and_complete_changes_are_visible_through_retrieval() -> None:
    registry = make_registry()
    task = registry.create("Observe state changes")

    started = registry.start(task.id)
    assert registry.get(task.id).state is TaskState.IN_PROGRESS

    completed = registry.complete(task.id)
    assert started.state is TaskState.IN_PROGRESS
    assert completed.state is TaskState.COMPLETED
    assert registry.get(task.id).state is TaskState.COMPLETED


def test_completing_pending_task_is_rejected_by_the_service() -> None:
    registry = make_registry()
    task = registry.create("Follow the state rules")

    with pytest.raises(InvalidTaskTransition):
        registry.complete(task.id)


def test_repeated_service_operations_preserve_idempotency() -> None:
    registry = make_registry()
    task = registry.create("Repeat safely")

    started = registry.start(task.id)
    assert registry.start(task.id) == started

    completed = registry.complete(task.id)
    assert registry.complete(task.id) == completed
