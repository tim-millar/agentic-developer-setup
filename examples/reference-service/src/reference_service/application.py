from typing import Protocol

from .domain import Task


class TaskRepository(Protocol):
    def create(self, title: str) -> Task: ...

    def get(self, task_id: int) -> Task: ...

    def list(self) -> list[Task]: ...

    def save(self, task: Task) -> None: ...


class TaskRegistry:
    def __init__(self, repository: TaskRepository) -> None:
        self._repository = repository

    def create(self, title: str) -> Task:
        return self._repository.create(title)

    def get(self, task_id: int) -> Task:
        return self._repository.get(task_id)

    def list(self) -> list[Task]:
        return self._repository.list()

    def start(self, task_id: int) -> Task:
        task = self._repository.get(task_id)
        updated_task = task.start()
        self._repository.save(updated_task)
        return updated_task

    def complete(self, task_id: int) -> Task:
        task = self._repository.get(task_id)
        updated_task = task.complete()
        self._repository.save(updated_task)
        return updated_task
