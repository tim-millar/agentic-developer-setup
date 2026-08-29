import pytest

from reference_service.domain import TaskNotFound, TaskState
from reference_service.persistence import InMemoryTaskRepository


def test_ids_start_at_one_and_increase_per_repository_instance() -> None:
    repository = InMemoryTaskRepository()

    first = repository.create("First task")
    second = repository.create("Second task")

    assert first.id == 1
    assert second.id == 2
    assert first.state is TaskState.PENDING
    assert second.state is TaskState.PENDING


def test_repository_lists_all_tasks_in_id_order() -> None:
    repository = InMemoryTaskRepository()
    first = repository.create("First task")
    second = repository.create("Second task")

    assert repository.list() == [first, second]


def test_repository_instances_do_not_share_state() -> None:
    first_repository = InMemoryTaskRepository()
    second_repository = InMemoryTaskRepository()

    first_task = first_repository.create("Private task")

    assert second_repository.list() == []
    assert second_repository.create("Separate task").id == 1
    assert first_repository.get(first_task.id) == first_task


def test_unknown_task_raises_task_not_found() -> None:
    repository = InMemoryTaskRepository()

    with pytest.raises(TaskNotFound):
        repository.get(1)
