from __future__ import annotations

import json
import os
import socket
from dataclasses import dataclass, field
from pathlib import Path
from typing import Mapping

from dotenv import load_dotenv


@dataclass(frozen=True, slots=True)
class Project:
    id: str
    name: str
    path: Path


@dataclass(slots=True)
class Settings:
    """Runtime settings. Direct construction is useful for embedding and tests.

    ``Settings.from_env()`` is the only place that reads the process environment;
    importing the bridge package never performs configuration validation.
    """

    token: str | None = None
    project_config: Path = Path("config/projects.json")
    host: str = "0.0.0.0"
    port: int = 8765
    codex_executable: str = "codex"
    codex_model: str | None = None
    codex_reasoning_effort: str | None = None
    codex_sandbox: str = "read-only"
    task_timeout_seconds: float = 3600.0
    shutdown_timeout_seconds: float = 5.0
    max_queue_size: int = 64
    max_tasks: int = 100
    max_output_chars: int = 262_144
    max_events: int = 2048
    max_event_bytes: int = 524_288
    heartbeat_seconds: float = 15.0
    max_request_bytes: int = 1_048_576
    allowed_origins: tuple[str, ...] = field(default_factory=tuple)
    device_id: str | None = None
    device_name: str | None = None

    def __post_init__(self) -> None:
        if self.token is None or len(self.token) < 24:
            raise ValueError("token must be at least 24 characters")
        if self.codex_sandbox not in {"read-only", "workspace-write"}:
            raise ValueError("sandbox must be read-only or workspace-write")
        if not 1 <= self.port <= 65535 or self.max_event_bytes < 1024:
            raise ValueError("invalid port or event byte limit")
        self.project_config = Path(self.project_config)
        self.device_id = self.device_id or socket.gethostname()
        self.device_name = self.device_name or socket.gethostname()
        if self.max_queue_size < 1 or self.max_tasks < 1:
            raise ValueError("queue and task capacities must be positive")
        if self.max_output_chars < 1 or self.max_events < 1:
            raise ValueError("output and event capacities must be positive")
        if self.task_timeout_seconds <= 0 or self.shutdown_timeout_seconds <= 0:
            raise ValueError("timeouts must be positive")
        if self.heartbeat_seconds <= 0 or self.max_request_bytes < 1:
            raise ValueError("heartbeat and request limits must be positive")

    @classmethod
    def from_env(cls, env: Mapping[str, str] | None = None, dotenv_path: str | Path | None = None) -> "Settings":
        if dotenv_path is None:
            load_dotenv()
        else:
            load_dotenv(dotenv_path)
        values = os.environ if env is None else env

        def get(name: str, default: str | None = None) -> str | None:
            value = values.get(name)
            return default if value is None or value == "" else value

        def integer(name: str, default: int) -> int:
            return int(get(name, str(default)))

        def number(name: str, default: float) -> float:
            return float(get(name, str(default)))

        origin_value = get("CODEX_BRIDGE_ALLOWED_ORIGINS", "")
        origins = tuple(x.strip() for x in origin_value.split(",") if x.strip())
        token = get("CODEX_BRIDGE_TOKEN")
        return cls(
            token=token,
            project_config=Path(get("CODEX_PROJECT_CONFIG", "config/projects.json")).expanduser().resolve(strict=False),
            host=get("CODEX_BRIDGE_HOST", "0.0.0.0"),
            port=integer("CODEX_BRIDGE_PORT", 8765),
            codex_executable=get("CODEX_EXECUTABLE", "codex"),
            codex_model=get("CODEX_MODEL"),
            codex_reasoning_effort=get("CODEX_REASONING_EFFORT"),
            codex_sandbox=get("CODEX_SANDBOX", "read-only"),
            task_timeout_seconds=number("CODEX_TASK_TIMEOUT_SECONDS", 3600.0),
            shutdown_timeout_seconds=number("CODEX_SHUTDOWN_TIMEOUT_SECONDS", 5.0),
            max_queue_size=integer("CODEX_MAX_QUEUE_SIZE", 64),
            max_tasks=integer("CODEX_MAX_TASKS", 100),
            max_output_chars=integer("CODEX_MAX_OUTPUT_CHARS", 262_144),
            max_events=integer("CODEX_MAX_EVENTS", 2048),
            max_event_bytes=integer("CODEX_MAX_EVENT_BYTES", 524_288),
            heartbeat_seconds=number("CODEX_HEARTBEAT_SECONDS", 15.0),
            max_request_bytes=integer("CODEX_MAX_REQUEST_BYTES", 1_048_576),
            allowed_origins=origins,
            device_id=get("CODEX_BRIDGE_DEVICE_ID"),
            device_name=get("CODEX_BRIDGE_DEVICE_NAME"),
        )


def load_projects(path: Path) -> dict[str, Project]:
    """Load and normalize the project whitelist at app construction time."""
    with Path(path).expanduser().open("r", encoding="utf-8") as handle:
        raw = json.load(handle)
    if isinstance(raw, dict):
        raw = raw.get("projects", [])
    if not isinstance(raw, list):
        raise ValueError("project configuration must be a JSON list")
    projects: dict[str, Project] = {}
    for item in raw:
        if not isinstance(item, dict) or not all(k in item for k in ("id", "name", "path")):
            raise ValueError("each project requires id, name, and path")
        project_id = str(item["id"])
        if not project_id or project_id in projects:
            raise ValueError("project ids must be unique and non-empty")
        project_path = Path(str(item["path"])).expanduser()
        if not project_path.is_absolute() or not project_path.is_dir():
            raise ValueError(f"project {project_id}: path must be an existing absolute directory")
        projects[project_id] = Project(
            id=project_id,
            name=str(item["name"]),
            path=project_path.resolve(strict=True),
        )
    return projects
