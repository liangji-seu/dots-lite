"""Public response contracts independent of any agent provider."""
from typing import Literal

from pydantic import BaseModel


TaskStatus = Literal['queued', 'running', 'completed', 'failed', 'cancelled']


class ProjectResponse(BaseModel):
    id: str
    name: str


class AgentResponse(BaseModel):
    id: str
    available: bool
    supports_resume: bool


class Capability(BaseModel):
    available: bool


class DeviceResponse(BaseModel):
    api_version: int
    instance_id: str
    id: str
    name: str
    hostname: str
    status: Literal['online']
    platform: str
    version: str
    capabilities: dict[str, Capability]


class TaskSummary(BaseModel):
    task_id: str
    project_id: str
    agent_id: str
    status: TaskStatus
    created_at: str
    started_at: str | None
    finished_at: str | None
    exit_code: int | None
    session_id: str | None
    parent_task_id: str | None
    conversation_id: str


class TaskDetail(TaskSummary):
    prompt: str
    output: str
    error: str | None
    output_truncated: bool


class TaskPage(BaseModel):
    items: list[TaskSummary]
    offset: int
    limit: int
    total: int
