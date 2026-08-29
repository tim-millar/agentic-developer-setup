from .application import TaskRepository
from .domain import Task, TaskNotFound


class InMemoryTaskRepository(TaskRepository):
    def __init__(self) -> None:
        self._tasks: dict[int, Task] = {}
        self._next_id = 1

    def create(self, title: str) -> Task:
        task = Task.create(self._next_id, title)
        self._tasks[task.id] = task
        self._next_id += 1
        return task

    def get(self, task_id: int) -> Task:
        try:
            return self._tasks[task_id]
        except KeyError:
            raise TaskNotFound(f"Task {task_id} was not found.") from None

    def list(self) -> list[Task]:
        return [self._tasks[task_id] for task_id in sorted(self._tasks)]

    def save(self, task: Task) -> None:
        if task.id not in self._tasks:
            raise TaskNotFound(f"Task {task.id} was not found.")
        self._tasks[task.id] = task
