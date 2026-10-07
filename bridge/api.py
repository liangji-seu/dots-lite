from __future__ import annotations

import asyncio
import hmac
import logging
import platform
import shutil
import socket
import uuid
from contextlib import asynccontextmanager
from typing import Annotated, Any, Sequence

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, ConfigDict, Field

from .adapters.base import AgentAdapter
from .adapters.codex import CodexAdapter
from .config import Settings, load_projects
from .manager import TERMINAL_STATUSES, ManagerError, TaskManager, TaskRecord, utc_now
from .schemas import AgentResponse, DeviceResponse, ProjectResponse, TaskDetail, TaskPage

logger = logging.getLogger("dots.bridge")


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class CreateTaskRequest(StrictModel):
    project_id: str = Field(min_length=1, max_length=256)
    prompt: str = Field(min_length=1, max_length=32_000)
    agent_id: str = Field(default="codex", min_length=1, max_length=100)


class FollowupRequest(StrictModel):
    prompt: str = Field(min_length=1, max_length=32_000)
    agent_id: str | None = Field(default=None, min_length=1, max_length=100)


def _http_error(error: ManagerError) -> HTTPException:
    statuses = {"project": 404, "not_found": 404, "unavailable": 503, "capacity": 503,
                "conflict": 409, "cursor": 400}
    return HTTPException(status_code=statuses.get(error.code, 400), detail=str(error))


def _summary(record: TaskRecord) -> dict[str, Any]:
    return record.summary()


def create_app(settings: Settings | None = None, adapters: Sequence[AgentAdapter] | None = None) -> FastAPI:
    runtime = settings or Settings.from_env()
    projects = load_projects(runtime.project_config)
    configured_adapters = list(adapters) if adapters is not None else [
        CodexAdapter(executable=runtime.codex_executable, model=runtime.codex_model,
                     reasoning_effort=runtime.codex_reasoning_effort, sandbox=runtime.codex_sandbox)
    ]
    manager = TaskManager(runtime, projects, configured_adapters)
    instance_id = str(uuid.uuid4())

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        logger.info("bridge started device_id=%s api_version=1", runtime.device_id)
        await manager.start()
        try:
            yield
        finally:
            await manager.stop()

    app = FastAPI(title="dots-lite bridge", version="1", lifespan=lifespan,
                  docs_url=None, redoc_url=None, openapi_url=None)
    app.state.settings = runtime
    app.state.manager = manager
    app.state.instance_id = instance_id

    @app.middleware("http")
    async def request_guard(request: Request, call_next):
        if request.url.path.startswith("/api"):
            origin = request.headers.get("origin")
            if origin and origin not in runtime.allowed_origins:
                return JSONResponse(status_code=403, content={"detail": "browser Origin is not allowed"})
            authorization = request.headers.get("authorization", "")
            scheme, separator, supplied = authorization.partition(" ")
            if (not separator or scheme.lower() != "bearer" or not supplied or
                    not hmac.compare_digest(supplied.encode(), (runtime.token or "").encode())):
                return JSONResponse(status_code=401, content={"detail": "authentication required"},
                                    headers={"WWW-Authenticate": "Bearer"})
            size = request.headers.get("content-length")
            if size:
                try:
                    if int(size) > runtime.max_request_bytes:
                        return JSONResponse(status_code=413, content={"detail": "request body too large"})
                except ValueError:
                    return JSONResponse(status_code=400, content={"detail": "invalid content length"})
            if request.method in {"POST", "PUT", "PATCH"}:
                chunks: list[bytes] = []
                total = 0
                async for chunk in request.stream():
                    total += len(chunk)
                    if total > runtime.max_request_bytes:
                        return JSONResponse(status_code=413, content={"detail": "request body too large"})
                    chunks.append(chunk)
                body = b"".join(chunks)
                request._body = body
                async def replay_body() -> dict[str, Any]:
                    return {"type": "http.request", "body": body, "more_body": False}
                request._receive = replay_body
        return await call_next(request)

    bearer = HTTPBearer(auto_error=False)

    async def auth(credentials: HTTPAuthorizationCredentials | None = Depends(bearer)) -> None:
        if credentials is None:
            raise HTTPException(status_code=401, detail="authentication required",
                                headers={"WWW-Authenticate": "Bearer"})
        if credentials.scheme.lower() != "bearer" or not hmac.compare_digest(credentials.credentials.encode(), (runtime.token or "").encode()):
            raise HTTPException(status_code=401, detail="invalid bearer token",
                                headers={"WWW-Authenticate": "Bearer"})

    @app.get("/healthz")
    async def healthz() -> dict[str, Any]:
        return {"status": "ok", "api_version": 1, "instance_id": instance_id}

    @app.get("/api/device", response_model=DeviceResponse)
    async def device(_: None = Depends(auth)) -> dict[str, Any]:
        capabilities = {}
        for name in ("git", "python", "codex", "nvidia-smi", "nvcc"):
            capabilities[name] = {"available": shutil.which(name) is not None}
        return {"api_version": 1, "instance_id": instance_id, "id": runtime.device_id,
                "name": runtime.device_name, "hostname": socket.gethostname(),
                "status": "online", "platform": platform.system().lower(),
                "version": platform.version(), "capabilities": capabilities}

    @app.get("/api/projects", response_model=list[ProjectResponse])
    async def project_list(_: None = Depends(auth)) -> list[dict[str, str]]:
        return [{"id": p.id, "name": p.name} for p in projects.values()]

    @app.get("/api/agents", response_model=list[AgentResponse])
    async def agent_list(_: None = Depends(auth)) -> list[dict[str, Any]]:
        return [{"id": a.id, "available": bool(a.available()), "supports_resume": bool(a.supports_resume)}
                for a in configured_adapters]

    @app.post("/api/tasks", status_code=201, response_model=TaskDetail)
    async def create_task(body: CreateTaskRequest, _: None = Depends(auth)) -> dict[str, Any]:
        try:
            record = await manager.submit(body.project_id, body.prompt, body.agent_id)
        except ManagerError as exc:
            raise _http_error(exc) from exc
        return record.detail()

    @app.get("/api/tasks", response_model=TaskPage)
    async def list_tasks(_: None = Depends(auth), offset: int = Query(default=0, ge=0), limit: int = Query(default=50, ge=1, le=200)) -> dict[str, Any]:
        records, total = manager.list(offset, limit)
        return {"items": [_summary(record) for record in records], "offset": offset, "limit": limit, "total": total}

    @app.get("/api/tasks/{task_id}", response_model=TaskDetail)
    async def task_detail(task_id: str, _: None = Depends(auth)) -> dict[str, Any]:
        record = manager.get(task_id)
        if record is None:
            raise HTTPException(status_code=404, detail="task not found")
        return record.detail()

    @app.post("/api/tasks/{task_id}/cancel", response_model=TaskDetail)
    async def cancel_task(task_id: str, _: None = Depends(auth)) -> dict[str, Any]:
        try:
            return (await manager.cancel(task_id)).detail()
        except ManagerError as exc:
            raise _http_error(exc) from exc

    @app.post("/api/tasks/{task_id}/messages", status_code=201, response_model=TaskDetail)
    async def followup(task_id: str, body: FollowupRequest, _: None = Depends(auth)) -> dict[str, Any]:
        parent = manager.get(task_id)
        if parent is None:
            raise HTTPException(status_code=404, detail="task not found")
        if parent.status not in TERMINAL_STATUSES:
            raise HTTPException(status_code=409, detail="conversation has an active task")
        if not parent.session_id:
            raise HTTPException(status_code=409, detail="task has no resumable session")
        if body.agent_id is not None and body.agent_id != parent.agent_id:
            raise HTTPException(status_code=409, detail="follow-up cannot switch agents")
        adapter = manager.adapters.get(parent.agent_id)
        if adapter is None or not adapter.supports_resume:
            raise HTTPException(status_code=409, detail="agent does not support resume")
        agent_id = parent.agent_id
        try:
            record = await manager.submit(parent.project.id, body.prompt, agent_id,
                                          parent_task_id=parent.task_id,
                                          conversation_id=parent.conversation_id,
                                          session_id=parent.session_id)
        except ManagerError as exc:
            raise _http_error(exc) from exc
        return record.detail()

    @app.websocket("/api/tasks/{task_id}/stream")
    async def task_events(websocket: WebSocket, task_id: str, after: int = Query(default=0, ge=0)) -> None:
        origin = websocket.headers.get("origin")
        if origin and origin not in runtime.allowed_origins:
            await websocket.close(code=1008, reason="browser Origin is not allowed")
            return
        authorization = websocket.headers.get("authorization")
        scheme, separator, supplied = (authorization or "").partition(" ")
        if not separator or scheme.lower() != "bearer" or not supplied or not hmac.compare_digest(supplied.encode(), (runtime.token or "").encode()):
            await websocket.close(code=1008, reason="authentication required")
            return
        if manager.get(task_id) is None:
            await websocket.close(code=1008, reason="task not found")
            return
        await websocket.accept()
        cursor = after
        try:
            while True:
                try:
                    events, terminal = await manager.wait_events(task_id, cursor)
                except ManagerError as exc:
                    await websocket.close(code=1008, reason=str(exc))
                    return
                for event in events:
                    await websocket.send_json(event)
                    if "seq" in event:
                        cursor = max(cursor, int(event["seq"]))
                if terminal:
                    await websocket.close(code=1000)
                    return
        except WebSocketDisconnect:
            return

    return app
