"""Exercise the native Swift client against a real HTTP/WebSocket Bridge.

Uses an isolated, in-process fixture adapter. Never calls Codex or reads .env.
Run with the development virtualenv: python scripts/smoke_iphone_client.py.
"""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

import uvicorn

from bridge.adapters.base import RunResult
from bridge.api import create_app
from bridge.config import Settings


class ClientFixtureAdapter:
    id = "fake"
    supports_resume = True

    def available(self) -> bool:
        return True

    async def run(self, request, emit, cancel) -> RunResult:
        session = request.session_id or f"fixture-{request.task_id}"
        await emit({"type": "session", "session_id": session})
        if request.prompt == "CANCEL_WAIT":
            await cancel.wait()
            return RunResult(130, session, "cancelled")
        for text in ("native ", "client ", "stream\n"):
            if cancel.is_set():
                return RunResult(130, session, "cancelled")
            await emit({"type": "output", "stream": "stdout", "text": text})
            await asyncio.sleep(0.05)
        return RunResult(0, session)


def main() -> None:
    # Build separately so the fixture's execution timeout is not a build timeout.
    subprocess.run(
        ["swift", "build", "--package-path", str(ROOT / "ios/DotsCore"), "--product", "DotsProbe"],
        cwd=ROOT, check=True, timeout=180,
    )
    binary_dir = subprocess.check_output(
        ["swift", "build", "--package-path", str(ROOT / "ios/DotsCore"), "--show-bin-path"],
        cwd=ROOT, text=True, timeout=30,
    ).strip()
    with tempfile.TemporaryDirectory(prefix="dots-client-smoke-") as directory:
        config = Path(directory) / "projects.json"
        config.write_text(json.dumps([
            {"id": "dots-lite", "name": "Client fixture", "path": str(ROOT)}
        ]), encoding="utf-8")
        token = secrets.token_urlsafe(32)
        settings = Settings(token=token, project_config=config, device_id="client-fixture")
        app = create_app(settings, [ClientFixtureAdapter()])
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen(128)
            port = listener.getsockname()[1]
            server = uvicorn.Server(uvicorn.Config(app, log_level="error", access_log=False))
            thread = threading.Thread(target=server.run, kwargs={"sockets": [listener]}, daemon=True)
            thread.start()
            try:
                deadline = time.monotonic() + 10
                while not server.started:
                    if not thread.is_alive() or time.monotonic() > deadline:
                        raise RuntimeError("Client fixture did not start")
                    time.sleep(0.05)
                environment = os.environ.copy()
                environment.update(
                    DOTS_PROBE_BASE_URL=f"http://127.0.0.1:{port}",
                    DOTS_PROBE_TOKEN=token,
                )
                subprocess.run(
                    [str(Path(binary_dir) / "DotsProbe")], cwd=ROOT,
                    env=environment, check=True, timeout=45,
                )
            finally:
                server.should_exit = True
                thread.join(timeout=10)
                if thread.is_alive():
                    raise RuntimeError("Client fixture did not shut down")
    print("PASS: native client exercised a real Bridge with a fixture adapter; no model calls.")


if __name__ == "__main__":
    main()
