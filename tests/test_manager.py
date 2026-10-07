from __future__ import annotations

import asyncio
from pathlib import Path

from bridge.adapters.base import RunResult
from bridge.config import Project, Settings
from bridge.manager import TaskManager


class FakeAdapter:
    id = "fake"
    supports_resume = True

    def available(self):
        return True

    async def run(self, request, emit, cancel):
        await emit({"type": "session", "session_id": "session-1"})
        await emit({"type": "output", "stream": "stdout", "text": "hello"})
        return RunResult(exit_code=0, session_id="session-1")


def make_manager(tmp_path: Path) -> TaskManager:
    settings = Settings(token="t" * 24, project_config=tmp_path / "projects.json", max_events=3)
    return TaskManager(settings, {"p": Project("p", "P", tmp_path)}, [FakeAdapter()])


def test_serial_task_lifecycle_and_ring_gap(tmp_path):
    async def exercise():
        manager = make_manager(tmp_path)
        record = await manager.submit("p", "hello", "fake")
        await asyncio.sleep(0.05)
        assert record.status == "completed"
        assert record.output == "hello"
        events, terminal = await manager.wait_events(record.task_id, 0)
        assert terminal
        seqs = [event["seq"] for event in events if "seq" in event]
        assert seqs == sorted(seqs)
        gap, _ = await manager.replay(record.task_id, 0)
        assert gap[0]["type"] == "gap"
        await manager.stop()

    asyncio.run(exercise())


def test_cancelled_queued_task_is_terminal(tmp_path):
    async def exercise():
        manager = make_manager(tmp_path)
        await manager.start()
        record = await manager.submit("p", "hello", "fake")
        await manager.cancel(record.task_id)
        assert record.status in {"cancelled", "completed"}
        await manager.stop()

    asyncio.run(exercise())


def test_timeout_is_failed_and_worker_survives(tmp_path):
    class HangingAdapter(FakeAdapter):
        async def run(self, request, emit, cancel):
            if request.prompt == 'hang':
                await asyncio.Event().wait()
            return RunResult(0)

    async def exercise():
        manager = make_manager(tmp_path)
        manager.adapters['fake'] = HangingAdapter()
        manager.settings.task_timeout_seconds = .02
        manager.settings.shutdown_timeout_seconds = .01
        first = await manager.submit('p', 'hang', 'fake')
        second = await manager.submit('p', 'quick', 'fake')
        await asyncio.wait_for(manager._queue.join(), 1)
        assert first.status == 'failed' and first.error == 'task timed out'
        assert second.status == 'completed'
        await manager.stop()
    asyncio.run(exercise())


def test_shutdown_cancels_active_and_queued_and_rejects_new_work(tmp_path):
    class WaitingAdapter(FakeAdapter):
        async def run(self, request, emit, cancel):
            await cancel.wait()
            return RunResult(130, error='cancelled')

    async def exercise():
        from bridge.manager import ManagerError
        manager = make_manager(tmp_path)
        manager.adapters['fake'] = WaitingAdapter()
        manager.settings.shutdown_timeout_seconds = .1
        first = await manager.submit('p', 'first', 'fake')
        second = await manager.submit('p', 'second', 'fake')
        await asyncio.sleep(.01)
        assert first.status == 'running' and second.status == 'queued'
        await manager.stop()
        assert first.status == second.status == 'cancelled'
        try:
            await manager.submit('p', 'new', 'fake')
        except ManagerError as exc:
            assert exc.code == 'capacity'
        else:
            raise AssertionError('shutdown must reject new tasks')
    asyncio.run(exercise())
