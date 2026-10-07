from __future__ import annotations

import asyncio
import contextlib
import datetime as dt
import logging
import json
import uuid
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

from .adapters.base import AgentAdapter, RunRequest, RunResult
from .config import Project, Settings

TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled"})
logger = logging.getLogger("dots.bridge.manager")


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


@dataclass
class TaskRecord:
    task_id: str
    project: Project
    agent_id: str
    prompt: str
    status: str = "queued"
    created_at: str = field(default_factory=utc_now)
    started_at: str | None = None
    finished_at: str | None = None
    exit_code: int | None = None
    output: str = ""
    error: str | None = None
    session_id: str | None = None
    parent_task_id: str | None = None
    conversation_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    output_truncated: bool = False
    cancel_event: asyncio.Event = field(default_factory=asyncio.Event, repr=False)
    events: deque[dict[str, Any]] = field(default_factory=deque, repr=False)
    event_sizes: deque[int] = field(default_factory=deque, repr=False)
    event_bytes: int = 0
    seq: int = 0
    condition: asyncio.Condition = field(default_factory=asyncio.Condition, repr=False)

    def summary(self) -> dict[str, Any]:
        return {
            "task_id": self.task_id,
            "project_id": self.project.id,
            "agent_id": self.agent_id,
            "status": self.status,
            "created_at": self.created_at,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "exit_code": self.exit_code,
            "session_id": self.session_id,
            "parent_task_id": self.parent_task_id,
            "conversation_id": self.conversation_id,
        }

    def detail(self) -> dict[str, Any]:
        result = self.summary()
        result.update({"prompt": self.prompt, "output": self.output, "error": self.error,
                       "output_truncated": self.output_truncated})
        return result


class ManagerError(Exception):
    def __init__(self, message: str, code: str) -> None:
        super().__init__(message)
        self.code = code


class TaskManager:
    """Bounded, serial task executor and per-task event journal."""

    def __init__(self, settings: Settings, projects: dict[str, Project], adapters: Iterable[AgentAdapter]) -> None:
        self.settings = settings
        self.projects = projects
        self.adapters = {adapter.id: adapter for adapter in adapters}
        self.tasks: dict[str, TaskRecord] = {}
        self._queue: asyncio.Queue[TaskRecord] = asyncio.Queue(maxsize=settings.max_queue_size)
        self._lock = asyncio.Lock()
        self._worker: asyncio.Task[None] | None = None
        self._stopping = False

    @property
    def is_started(self) -> bool:
        return self._worker is not None and not self._worker.done()

    async def start(self) -> None:
        if self._worker is None or self._worker.done():
            self._stopping = False
            self._worker = asyncio.create_task(self._worker_loop(), name="dots-task-worker")

    async def stop(self) -> None:
        self._stopping = True
        for record in self.tasks.values():
            if record.status in {"queued", "running"}:
                record.cancel_event.set()
                if record.status == "queued":
                    await self._finish(record, "cancelled", error="cancelled", exit_code=130)
        worker = self._worker
        if worker is not None:
            with contextlib.suppress(asyncio.TimeoutError):
                await asyncio.wait_for(worker, timeout=self.settings.shutdown_timeout_seconds)
            if not worker.done():
                worker.cancel()
                with contextlib.suppress(asyncio.CancelledError):
                    await worker
        self._worker = None

    async def submit(self, project_id: str, prompt: str, agent_id: str = "codex", *,
                     parent_task_id: str | None = None, conversation_id: str | None = None,
                     session_id: str | None = None) -> TaskRecord:
        if self._stopping:
            raise ManagerError("task manager is stopping", "capacity")
        if project_id not in self.projects:
            raise ManagerError("unknown project", "project")
        adapter = self.adapters.get(agent_id)
        if adapter is None or not adapter.available():
            raise ManagerError("agent adapter unavailable", "unavailable")
        async with self._lock:
            if len(self.tasks) >= self.settings.max_tasks or self._queue.full():
                raise ManagerError("task capacity reached", "capacity")
            if conversation_id is not None and any(
                x.conversation_id == conversation_id and x.status in {"queued", "running"}
                for x in self.tasks.values()
            ):
                raise ManagerError("conversation has an active task", "conflict")
            task_id = str(uuid.uuid4())
            record = TaskRecord(task_id=task_id, project=self.projects[project_id], agent_id=agent_id,
                                prompt=prompt, parent_task_id=parent_task_id,
                                conversation_id=conversation_id or str(uuid.uuid4()), session_id=session_id)
            self.tasks[task_id] = record
            try:
                self._queue.put_nowait(record)
            except asyncio.QueueFull:
                self.tasks.pop(task_id, None)
                raise ManagerError("task capacity reached", "capacity")
        await self._emit_status(record, "queued")
        logger.info("task queued task_id=%s project_id=%s agent_id=%s", record.task_id, project_id, agent_id)
        if not self.is_started:
            await self.start()
        return record

    async def cancel(self, task_id: str) -> TaskRecord:
        record = self.tasks.get(task_id)
        if record is None:
            raise ManagerError("task not found", "not_found")
        if record.status in TERMINAL_STATUSES:
            return record
        record.cancel_event.set()
        if record.status == "queued":
            await self._finish(record, "cancelled", error="cancelled", exit_code=130)
        return record

    def get(self, task_id: str) -> TaskRecord | None:
        return self.tasks.get(task_id)

    def list(self, offset: int = 0, limit: int = 50) -> tuple[list[TaskRecord], int]:
        values = list(self.tasks.values())
        return values[offset:offset + limit], len(values)

    async def replay(self, task_id: str, after: int) -> tuple[list[dict[str, Any]], bool]:
        record = self.tasks.get(task_id)
        if record is None:
            raise ManagerError("task not found", "not_found")
        async with record.condition:
            if after > record.seq:
                raise ManagerError("event cursor is ahead", "cursor")
            retained = list(record.events)
            result: list[dict[str, Any]] = []
            if retained and after < retained[0]["seq"] - 1:
                result.append({"type": "gap", "task_id": task_id, "timestamp": utc_now(),
                               "after": after, "oldest": retained[0]["seq"]})
            result.extend(event for event in retained if event["seq"] > after)
            terminal = record.status in TERMINAL_STATUSES
            return result, terminal

    async def wait_events(self, task_id: str, after: int) -> tuple[list[dict[str, Any]], bool]:
        record = self.tasks.get(task_id)
        if record is None:
            raise ManagerError("task not found", "not_found")
        async with record.condition:
            if after > record.seq:
                raise ManagerError("event cursor is ahead", "cursor")
            while True:
                retained = list(record.events)
                result: list[dict[str, Any]] = []
                if retained and after < retained[0]["seq"] - 1:
                    result.append({"type": "gap", "task_id": task_id, "timestamp": utc_now(),
                                   "after": after, "oldest": retained[0]["seq"]})
                result.extend(event for event in retained if event["seq"] > after)
                terminal = record.status in TERMINAL_STATUSES
                if result or terminal:
                    return result, terminal
                try:
                    await asyncio.wait_for(record.condition.wait(), timeout=self.settings.heartbeat_seconds)
                except asyncio.TimeoutError:
                    return ([{"type": "heartbeat", "task_id": task_id, "timestamp": utc_now()}], False)

    async def _worker_loop(self) -> None:
        while not self._stopping:
            record = await self._queue.get()
            try:
                if record.status == "cancelled" or record.cancel_event.is_set():
                    if record.status != "cancelled":
                        await self._finish(record, "cancelled", error="cancelled", exit_code=130)
                    continue
                await self._run(record)
            finally:
                self._queue.task_done()

    async def _run(self, record: TaskRecord) -> None:
        adapter = self.adapters[record.agent_id]
        record.started_at = utc_now()
        logger.info("task running task_id=%s agent_id=%s", record.task_id, record.agent_id)
        await self._emit_status(record, "running")
        request = RunRequest(task_id=record.task_id, prompt=record.prompt, cwd=record.project.path,
                             session_id=record.session_id)

        async def emit(message: dict[str, Any]) -> None:
            kind = message.get("type")
            if kind == "output":
                text = str(message.get("text", ""))
                if text:
                    combined = record.output + text
                    if len(combined) > self.settings.max_output_chars:
                        record.output = combined[-self.settings.max_output_chars:]
                        record.output_truncated = True
                    else:
                        record.output = combined
                await self._emit(record, {"type": "output", "stream": message.get("stream", "stdout"), "text": text})
            elif kind == "session":
                record.session_id = str(message.get("session_id"))
                await self._emit(record, {"type": "session", "session_id": record.session_id})
            elif kind == "provider_event":
                await self._emit(record, {key: value for key, value in message.items() if key != "seq"})

        try:
            result = await asyncio.wait_for(adapter.run(request, emit, record.cancel_event), self.settings.task_timeout_seconds)
        except asyncio.TimeoutError:
            record.cancel_event.set()
            await self._finish(record, "failed", error="task timed out", exit_code=-1)
            return
        except asyncio.CancelledError:
            record.cancel_event.set()
            if record.status not in TERMINAL_STATUSES:
                await self._finish(record, "cancelled", error="cancelled", exit_code=130)
            raise
        except Exception as exc:  # adapter failures are isolated to one task
            await self._finish(record, "failed", error=str(exc), exit_code=-1)
            return
        if record.cancel_event.is_set() or result.error in {"canceled", "cancelled"}:
            await self._finish(record, "cancelled", error=result.error or "cancelled", exit_code=result.exit_code or 130,
                               session_id=result.session_id)
        elif result.error or result.exit_code != 0:
            await self._finish(record, "failed", error=result.error, exit_code=result.exit_code,
                               session_id=result.session_id)
        else:
            await self._finish(record, "completed", exit_code=result.exit_code, session_id=result.session_id)

    async def _finish(self, record: TaskRecord, status: str, *, error: str | None = None,
                      exit_code: int | None = None, session_id: str | None = None) -> None:
        if record.status in TERMINAL_STATUSES:
            return
        if session_id is not None:
            record.session_id = session_id
        record.status = status
        record.error = error
        record.exit_code = exit_code
        record.finished_at = utc_now()
        await self._emit_status(record, status)
        logger.info("task finished task_id=%s status=%s exit_code=%s", record.task_id, status, record.exit_code)

    async def _emit_status(self, record: TaskRecord, status: str) -> None:
        record.status = status
        await self._emit(record, {"type": "status", "status": status,
                                  "exit_code": record.exit_code, "error": record.error})

    async def _emit(self, record: TaskRecord, event: dict[str, Any]) -> None:
        async with record.condition:
            record.seq += 1
            event = dict(event)
            event.update({"seq": record.seq, "task_id": record.task_id, "timestamp": utc_now()})
            size = len(json.dumps(event, ensure_ascii=False).encode("utf-8"))
            if size > self.settings.max_event_bytes:
                event = {"seq": record.seq, "task_id": record.task_id, "timestamp": utc_now(),
                         "type": "truncated", "original_type": event.get("type"), "original_bytes": size}
                size = len(json.dumps(event).encode("utf-8"))
            record.events.append(event)
            record.event_sizes.append(size)
            record.event_bytes += size
            while len(record.events) > self.settings.max_events or record.event_bytes > self.settings.max_event_bytes:
                record.events.popleft()
                record.event_bytes -= record.event_sizes.popleft()
            record.condition.notify_all()
