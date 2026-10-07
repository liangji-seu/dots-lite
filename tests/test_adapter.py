from __future__ import annotations

import asyncio
import sys
import tempfile
from pathlib import Path

from bridge.adapters import CodexAdapter, RunRequest


FAKE_CLI = r"""
import json, os, sys, time
args = sys.argv[1:]
prompt = sys.stdin.read()
if '--fail' in prompt:
    print(json.dumps({'type': 'thread.started', 'thread_id': 'failed-session'}), flush=True)
    print(json.dumps({'type': 'turn.failed', 'error': {'message': 'provider rejected'}}), flush=True)
    sys.exit(0)
if '--sleep' in prompt:
    print(json.dumps({'type': 'thread.started', 'thread_id': 'sleep-session'}), flush=True)
    time.sleep(30)
print(json.dumps({'type': 'thread.started', 'thread_id': 'new-session'}), flush=True)
print('hello', flush=True)
print('warning', file=sys.stderr, flush=True)
"""


class FakeCodex(CodexAdapter):
    def __init__(self, script: Path, **kwargs):
        super().__init__(executable=sys.executable, **kwargs)
        self.script = script

    def _build_argv(self, request):
        return [sys.executable, str(self.script), *super()._build_argv(request)[1:]]


def make_adapter(tmp_path: Path) -> FakeCodex:
    script = tmp_path / "fake_codex.py"
    script.write_text(FAKE_CLI, encoding="utf-8")
    return FakeCodex(script)


def test_builds_safe_argv_and_emits_output_and_session():
    with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
        tmp_path = Path(directory)
        adapter = make_adapter(tmp_path)
        assert adapter.supports_resume
        argv = adapter._build_argv(RunRequest("t", "x", tmp_path))
        assert "--ignore-user-config" in argv
        assert "--ignore-rules" in argv
        assert "-s" in argv and "read-only" in argv
        events = []
        result = asyncio.run(adapter.run(RunRequest("t", "hello", tmp_path), _collector(events), asyncio.Event()))
        assert result.exit_code == 0
        assert result.session_id == "new-session"
        assert any(e["type"] == "session" and e["session_id"] == "new-session" for e in events)
        assert any(e["type"] == "output" and e["stream"] == "stdout" and "hello" in e["text"] for e in events)
        assert any(e["type"] == "output" and e["stream"] == "stderr" and "warning" in e["text"] for e in events)


def test_turn_failed_is_nonzero_even_when_cli_exits_zero():
    with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
        tmp_path = Path(directory)
        adapter = make_adapter(tmp_path)
        events = []
        result = asyncio.run(adapter.run(RunRequest("t", "--fail", tmp_path), _collector(events), asyncio.Event()))
        assert result.exit_code != 0
        assert result.error == "provider rejected"
        assert any(e["type"] == "provider_event" for e in events)


def test_cancellation_kills_real_process():
    async def exercise(tmp_path: Path):
        adapter = make_adapter(tmp_path)
        cancel = asyncio.Event()
        events = []
        task = asyncio.create_task(adapter.run(RunRequest("t", "--sleep", tmp_path), _collector(events), cancel))
        await asyncio.sleep(0.2)
        cancel.set()
        return await asyncio.wait_for(task, timeout=5)

    with tempfile.TemporaryDirectory(dir=Path.cwd()) as directory:
        result = asyncio.run(exercise(Path(directory)))
        assert result.exit_code == 130
        assert result.error == "cancelled"


def _collector(events):
    async def emit(event):
        events.append(event)

    return emit
