"""Adapter for the local Codex CLI."""

from __future__ import annotations

import asyncio
import codecs
import json
import os
import shutil
import signal
import subprocess
from pathlib import Path
from typing import Any

from .base import Emit, RunRequest, RunResult


_MAX_JSONL_LINE = 1024 * 1024
_CHUNK_SIZE = 16 * 1024
_CANCEL_EXIT_CODE = 130


class CodexAdapter:
    id = "codex"
    supports_resume = True

    def __init__(self, executable: str = "codex", model: str | None = None,
                 reasoning_effort: str | None = None, sandbox: str = "read-only") -> None:
        if sandbox not in {"read-only", "workspace-write"}:
            raise ValueError("sandbox must be 'read-only' or 'workspace-write'")
        self.executable = executable
        self.model = model
        self.reasoning_effort = reasoning_effort
        self.sandbox = sandbox

    def _resolved_executable(self) -> str | None:
        resolved = shutil.which(self.executable)
        if resolved is None and Path(self.executable).is_file():
            resolved = str(Path(self.executable))
        if os.name == "nt" and resolved is not None and Path(resolved).suffix.lower() in {".cmd", ".bat"}:
            return None
        return resolved

    def _is_windows_wrapper(self) -> bool:
        if os.name != "nt":
            return False
        resolved = shutil.which(self.executable)
        candidate = resolved or self.executable
        return Path(candidate).suffix.lower() in {".cmd", ".bat"}

    def available(self) -> bool:
        return self._resolved_executable() is not None

    def _build_argv(self, request: RunRequest) -> list[str]:
        argv = [self.executable, "-a", "never", "-s", self.sandbox, "exec"]
        if request.session_id:
            argv.extend(["resume", "--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"])
            if self.model:
                argv.extend(["-m", self.model])
            if self.reasoning_effort:
                argv.extend(["-c", f"model_reasoning_effort={self.reasoning_effort!r}"])
            argv.extend([request.session_id, "-"])
        else:
            argv.extend(["--json", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules"])
            if self.model:
                argv.extend(["-m", self.model])
            if self.reasoning_effort:
                argv.extend(["-c", f"model_reasoning_effort={self.reasoning_effort!r}"])
            argv.append("-")
        return argv

    @staticmethod
    def _session_from_event(event: dict[str, Any]) -> str | None:
        if event.get("type") not in {"thread.started", "thread.started.v1"}:
            return None
        value = event.get("thread_id")
        if isinstance(value, str) and value:
            return value
        thread = event.get("thread")
        if isinstance(thread, dict) and isinstance(thread.get("id"), str):
            return thread["id"]
        return None

    @staticmethod
    def _event_error(event: dict[str, Any]) -> str:
        value = event.get("error")
        if isinstance(value, str) and value:
            return value
        if isinstance(value, dict):
            for key in ("message", "detail", "code"):
                if value.get(key):
                    return str(value[key])
            try:
                return json.dumps(value, ensure_ascii=False, separators=(",", ":"))
            except (TypeError, ValueError):
                pass
        for key in ("message", "detail"):
            if event.get(key):
                return str(event[key])
        return "Codex turn failed"

    async def _handle_provider_events(self, events: list[dict[str, Any]], emit: Emit, state: dict[str, Any]) -> None:
        for event in events:
            await emit({"type": "provider_event", "event": event})
            session_id = self._session_from_event(event)
            if session_id:
                state["session_id"] = session_id
                await emit({"type": "session", "session_id": session_id})
            if event.get("type") == "turn.failed":
                state["turn_error"] = self._event_error(event)

    async def _read_stream(self, stream: asyncio.StreamReader, name: str, emit: Emit, state: dict[str, Any]) -> None:
        decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        parser = _JsonlParser()
        while True:
            chunk = await stream.read(_CHUNK_SIZE)
            if not chunk:
                break
            text = decoder.decode(chunk, final=False)
            if not text:
                continue
            await emit({"type": "output", "stream": name, "text": text})
            if name == "stderr":
                state["stderr_text"] = (state["stderr_text"] + text)[-_MAX_JSONL_LINE:]
            else:
                await self._handle_provider_events(parser.feed(text), emit, state)
        tail = decoder.decode(b"", final=True)
        if tail:
            await emit({"type": "output", "stream": name, "text": tail})
            if name == "stderr":
                state["stderr_text"] = (state["stderr_text"] + tail)[-_MAX_JSONL_LINE:]
            else:
                await self._handle_provider_events(parser.feed(tail), emit, state)
        if name == "stdout":
            await self._handle_provider_events(parser.finish(), emit, state)

    async def _send_prompt(self, process: asyncio.subprocess.Process, prompt: str, cancel: asyncio.Event) -> bool:
        if process.stdin is None:
            return True
        process.stdin.write(prompt.encode("utf-8"))
        drain_task = asyncio.create_task(process.stdin.drain())
        cancel_task = asyncio.create_task(cancel.wait())
        try:
            done, _ = await asyncio.wait({drain_task, cancel_task}, return_when=asyncio.FIRST_COMPLETED)
            if cancel_task in done and cancel.is_set():
                await self._terminate(process)
                return False
            await drain_task
            return not cancel.is_set()
        finally:
            if not drain_task.done():
                drain_task.cancel()
            if not cancel_task.done():
                cancel_task.cancel()
            await asyncio.gather(drain_task, cancel_task, return_exceptions=True)

    async def run(self, request: RunRequest, emit: Emit, cancel: asyncio.Event) -> RunResult:
        if cancel.is_set():
            return RunResult(_CANCEL_EXIT_CODE, request.session_id, "cancelled")
        executable = self._resolved_executable()
        if executable is None:
            if self._is_windows_wrapper():
                error = f"Windows command wrappers are unsupported: {self.executable}; use an .exe executable"
            else:
                error = f"Codex executable not found: {self.executable}"
            return RunResult(127, request.session_id, error)

        environment = os.environ.copy()
        environment.pop("CODEX_BRIDGE_TOKEN", None)
        kwargs: dict[str, Any] = {
            "stdin": asyncio.subprocess.PIPE, "stdout": asyncio.subprocess.PIPE,
            "stderr": asyncio.subprocess.PIPE, "cwd": str(request.cwd), "env": environment,
        }
        if os.name == "nt":
            kwargs["creationflags"] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
        else:
            kwargs["start_new_session"] = True

        process: asyncio.subprocess.Process | None = None
        spawn_task: asyncio.Task[asyncio.subprocess.Process] | None = None
        stream_tasks: list[asyncio.Task[None]] = []
        wait_task: asyncio.Task[int] | None = None
        cancel_task: asyncio.Task[bool] | None = None
        state: dict[str, Any] = {"session_id": request.session_id, "turn_error": None, "stderr_text": ""}
        cancelled = False
        try:
            if cancel.is_set():
                return RunResult(_CANCEL_EXIT_CODE, request.session_id, "cancelled")
            try:
                argv = self._build_argv(request)
                argv[0] = executable
                spawn_task = asyncio.create_task(asyncio.create_subprocess_exec(*argv, **kwargs))
                process = await asyncio.shield(spawn_task)
            except (FileNotFoundError, NotADirectoryError) as exc:
                return RunResult(127, request.session_id, str(exc))
            except OSError as exc:
                return RunResult(126, request.session_id, str(exc))

            assert process.stdout is not None and process.stderr is not None
            stream_tasks = [asyncio.create_task(self._read_stream(process.stdout, "stdout", emit, state)), asyncio.create_task(self._read_stream(process.stderr, "stderr", emit, state))]
            if cancel.is_set():
                cancelled = True
                await self._terminate(process)
            else:
                try:
                    if not await self._send_prompt(process, request.prompt, cancel):
                        cancelled = True
                finally:
                    if process.stdin is not None:
                        process.stdin.close()

            wait_task = asyncio.create_task(process.wait())
            cancel_task = asyncio.create_task(cancel.wait())
            done, _ = await asyncio.wait({wait_task, cancel_task}, return_when=asyncio.FIRST_COMPLETED)
            if cancel_task in done and cancel.is_set():
                cancelled = True
                await self._terminate(process)
            exit_code = await wait_task
            await asyncio.gather(*stream_tasks)
            if cancelled or cancel.is_set():
                return RunResult(_CANCEL_EXIT_CODE, state["session_id"], "cancelled")
            error = state["turn_error"]
            if error is None and exit_code != 0:
                error = state["stderr_text"].strip() or f"Codex exited with code {exit_code}"
            if error is not None and exit_code == 0:
                exit_code = 1
            return RunResult(exit_code, state["session_id"], error)
        except asyncio.CancelledError:
            if process is None and spawn_task is not None:
                try:
                    process = await asyncio.shield(spawn_task)
                except BaseException:
                    process = None
            if process is not None:
                await self._terminate(process)
            if stream_tasks:
                await asyncio.gather(*stream_tasks, return_exceptions=True)
            raise
        except BaseException:
            if process is not None:
                await self._terminate(process)
            for task in stream_tasks:
                if not task.done():
                    task.cancel()
            if stream_tasks:
                await asyncio.gather(*stream_tasks, return_exceptions=True)
            raise
        finally:
            if cancel_task is not None:
                cancel_task.cancel()
            if wait_task is not None and not wait_task.done():
                wait_task.cancel()
            if process is not None and process.returncode is None:
                await self._terminate(process)

    async def _terminate(self, process: asyncio.subprocess.Process) -> None:
        if os.name == "nt":
            try:
                killer = await asyncio.create_subprocess_exec("taskkill", "/PID", str(process.pid), "/T", "/F", stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                try:
                    await asyncio.wait_for(killer.wait(), timeout=2.0)
                except asyncio.TimeoutError:
                    killer.kill()
            except OSError:
                pass
            if process.returncode is None:
                process.kill()
            try:
                await asyncio.wait_for(process.wait(), timeout=2.0)
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
        else:
            try:
                os.killpg(process.pid, signal.SIGTERM)
            except (OSError, ProcessLookupError):
                try:
                    process.terminate()
                except ProcessLookupError:
                    pass
            try:
                await asyncio.wait_for(process.wait(), timeout=1.0)
            except asyncio.TimeoutError:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except (OSError, ProcessLookupError):
                    try:
                        process.kill()
                    except ProcessLookupError:
                        pass
                await process.wait()


class _JsonlParser:
    def __init__(self, maximum: int = _MAX_JSONL_LINE) -> None:
        self._maximum = maximum
        self._buffer = ""
        self._discarding = False

    @staticmethod
    def _parse(raw: str) -> dict[str, Any] | None:
        try:
            value = json.loads(raw.strip())
        except (TypeError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def feed(self, text: str) -> list[dict[str, Any]]:
        events: list[dict[str, Any]] = []
        for part in text.splitlines(keepends=True):
            if self._discarding:
                if part.endswith(("\n", "\r")):
                    self._discarding = False
                continue
            self._buffer += part
            if len(self._buffer.encode("utf-8")) > self._maximum:
                self._buffer = ""
                if not part.endswith(("\n", "\r")):
                    self._discarding = True
                continue
            if not part.endswith(("\n", "\r")):
                continue
            value = self._parse(self._buffer)
            self._buffer = ""
            if value is not None:
                events.append(value)
        return events

    def finish(self) -> list[dict[str, Any]]:
        if self._discarding:
            self._buffer = ""
            return []
        value = self._parse(self._buffer)
        self._buffer = ""
        return [value] if value is not None else []
