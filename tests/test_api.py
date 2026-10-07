from __future__ import annotations

import json
import time
from pathlib import Path

from fastapi.testclient import TestClient

from bridge.adapters.base import RunResult
from bridge.api import create_app
from bridge.config import Settings


class FakeAdapter:
    id = "fake"
    supports_resume = True

    def available(self):
        return True

    async def run(self, request, emit, cancel):
        await emit({"type": "session", "session_id": "session-1"})
        await emit({"type": "output", "stream": "stdout", "text": "hello"})
        return RunResult(0, "session-1")


def make_client(tmp_path: Path) -> TestClient:
    config = tmp_path / "projects.json"
    config.write_text(json.dumps([{"id": "p", "name": "Project", "path": str(tmp_path)}]), encoding="utf-8")
    settings = Settings(token="t" * 24, project_config=config)
    return TestClient(create_app(settings, [FakeAdapter()]))


def test_auth_projects_and_stream(tmp_path):
    token = "t" * 24
    with make_client(tmp_path) as client:
        assert client.get("/api/projects").status_code == 401
        headers = {"Authorization": f"Bearer {token}"}
        assert client.get("/api/projects", headers=headers).json() == [{"id": "p", "name": "Project"}]
        response = client.post("/api/tasks", headers=headers, json={"project_id": "p", "prompt": "hello", "agent_id": "fake"})
        assert response.status_code == 201
        task_id = response.json()["task_id"]
        for _ in range(20):
            detail = client.get(f"/api/tasks/{task_id}", headers=headers).json()
            if detail["status"] == "completed":
                break
            time.sleep(0.01)
        assert detail["output"] == "hello"
        with client.websocket_connect(f"/api/tasks/{task_id}/stream?after=0", headers=headers) as socket:
            events = []
            while True:
                event = socket.receive_json()
                events.append(event)
                if event.get("type") == "status" and event.get("status") == "completed":
                    break
        assert any(event.get("type") == "output" for event in events)
        assert [event["seq"] for event in events if "seq" in event] == sorted(event["seq"] for event in events if "seq" in event)


def test_origin_and_project_injection_are_rejected(tmp_path):
    with make_client(tmp_path) as client:
        headers = {"Authorization": f"Bearer {'t' * 24}"}
        assert client.get("/api/device", headers={**headers, "Origin": "https://evil.example"}).status_code == 403
        response = client.post("/api/tasks", headers=headers, json={"project_id": "../p", "prompt": "hello", "agent_id": "fake"})
        assert response.status_code == 404


def test_websocket_requires_bearer_token(tmp_path):
    with make_client(tmp_path) as client:
        try:
            with client.websocket_connect("/api/tasks/missing/stream"):
                raise AssertionError("websocket should reject missing auth")
        except Exception as exc:
            assert "1008" in str(exc) or "WebSocketDisconnect" in type(exc).__name__


def test_active_resume_conflict(tmp_path):
    class SlowAdapter(FakeAdapter):
        async def run(self, request, emit, cancel):
            await emit({"type": "session", "session_id": "session-1"})
            while not cancel.is_set():
                await __import__("asyncio").sleep(0.01)
            return RunResult(130, "session-1", "cancelled")

    config = tmp_path / "projects.json"
    config.write_text(json.dumps([{"id": "p", "name": "Project", "path": str(tmp_path)}]), encoding="utf-8")
    app = create_app(Settings(token="t" * 24, project_config=config), [SlowAdapter()])
    with TestClient(app) as client:
        headers = {"Authorization": f"Bearer {'t' * 24}"}
        parent = client.post("/api/tasks", headers=headers, json={"project_id": "p", "prompt": "hello", "agent_id": "fake"}).json()
        assert client.post(f"/api/tasks/{parent['task_id']}/messages", headers=headers, json={"prompt": "follow"}).status_code == 409
        assert client.post(f"/api/tasks/{parent['task_id']}/cancel", headers=headers).status_code == 200
