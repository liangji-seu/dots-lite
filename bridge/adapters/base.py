"""Common contracts for bridge agent adapters."""

from __future__ import annotations

import asyncio
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable, Protocol


@dataclass(slots=True)
class RunRequest:
    task_id: str
    prompt: str
    cwd: Path
    session_id: str | None = None


@dataclass(slots=True)
class RunResult:
    exit_code: int
    session_id: str | None = None
    error: str | None = None


Emit = Callable[[dict[str, Any]], Awaitable[None]]


class AgentAdapter(Protocol):
    id: str
    supports_resume: bool

    def available(self) -> bool: ...

    async def run(self, request: RunRequest, emit: Emit, cancel: asyncio.Event) -> RunResult: ...
