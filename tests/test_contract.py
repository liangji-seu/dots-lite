"""Client-facing regression tests for reconnects, safety and session identity."""
import asyncio
import json
import time

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from bridge.adapters.base import RunResult
from bridge.config import Settings
from bridge.main import create_app

HEADERS = {'Authorization': 'Bearer ' + 'test-token-' * 4}


class ControlledAgent:
    id = 'codex'
    supports_resume = True

    def available(self):
        return True

    async def run(self, request, emit, cancel):
        await emit({'type': 'session', 'session_id': request.session_id or 'session-1'})
        await emit({'type': 'output', 'stream': 'stdout', 'text': 'first output'})
        if request.prompt == 'hold':
            await cancel.wait()
            return RunResult(130, 'session-1', 'cancelled')
        return RunResult(0, request.session_id or 'session-1')


@pytest.fixture
def client(tmp_path):
    config = tmp_path / 'projects.json'
    config.write_text(json.dumps([{'id': 'p', 'name': 'P', 'path': str(tmp_path)}]), encoding='utf-8')
    settings = Settings(token='test-token-' * 4, project_config=config, shutdown_timeout_seconds=.1)
    with TestClient(create_app(settings, [ControlledAgent()])) as value:
        yield value


def submit(client, prompt='quick'):
    response = client.post('/api/tasks', headers=HEADERS, json={'project_id': 'p', 'prompt': prompt})
    assert response.status_code == 201, response.text
    return response.json()['task_id']


def terminal(client, task_id):
    for _ in range(100):
        value = client.get(f'/api/tasks/{task_id}', headers=HEADERS).json()
        if value['status'] in {'completed', 'failed', 'cancelled'}:
            return value
        time.sleep(.01)
    pytest.fail('task did not reach terminal state')


def test_ws_auth_and_cursor(client):
    task_id = submit(client)
    terminal(client, task_id)
    url = f'/api/tasks/{task_id}/stream'
    for headers in ({}, {'Authorization': 'Bearer wrong'}, {**HEADERS, 'Origin': 'https://example.com'}):
        with pytest.raises(WebSocketDisconnect):
            with client.websocket_connect(url, headers=headers):
                pytest.fail('unauthorized websocket accepted')
    with client.websocket_connect(url, headers=HEADERS) as ws:
        events = []
        with pytest.raises(WebSocketDisconnect) as closed:
            while True:
                events.append(ws.receive_json())
        assert closed.value.code == 1000
    cursor = events[-1]['seq']
    with client.websocket_connect(url + f'?after={cursor}', headers=HEADERS) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1000
    with client.websocket_connect(url + f'?after={cursor + 1}', headers=HEADERS) as ws:
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 1008


def test_disconnect_then_cancel_and_resume_conflict(client):
    task_id = submit(client, 'hold')
    with client.websocket_connect(f'/api/tasks/{task_id}/stream', headers=HEADERS) as ws:
        while ws.receive_json().get('type') != 'output':
            pass
    assert client.get(f'/api/tasks/{task_id}', headers=HEADERS).json()['status'] == 'running'
    assert client.post(f'/api/tasks/{task_id}/messages', headers=HEADERS, json={'prompt': 'next'}).status_code == 409
    assert client.post(f'/api/tasks/{task_id}/cancel', headers=HEADERS).status_code == 200
    parent = terminal(client, task_id)
    assert parent['status'] == 'cancelled'
    response = client.post(f'/api/tasks/{task_id}/messages', headers=HEADERS, json={'prompt': 'quick'})
    assert response.status_code == 201
    child = terminal(client, response.json()['task_id'])
    assert child['conversation_id'] == parent['conversation_id']
    assert child['parent_task_id'] == parent['task_id']
    assert child['session_id'] == parent['session_id']


def test_path_injection_and_model_override_rejected(client):
    for extra in ({'cwd': 'C:\\'}, {'model': 'other'}, {'command': 'echo hi'}, {'session_id': 'other'}):
        response = client.post('/api/tasks', headers=HEADERS,
                               json={'project_id': 'p', 'prompt': 'quick', **extra})
        assert response.status_code == 422


def test_event_byte_budget_and_openapi_contract(client):
    async def exercise():
        manager = client.app.state.manager
        manager.settings.max_event_bytes = 1024
        task = await manager.submit('p', 'quick', 'codex')
        await manager._emit(task, {'type': 'provider_event', 'event': {'huge': 'x' * 2048}})
        assert task.event_bytes <= 1024
        assert any(event['type'] == 'truncated' for event in task.events)
    client.portal.call(exercise)
    schema = client.app.openapi()
    operation = schema['paths']['/api/tasks']['post']
    assert operation['security'] == [{'HTTPBearer': []}]
    assert operation['responses']['201']['content']['application/json']['schema']['$ref'].endswith('/TaskDetail')
