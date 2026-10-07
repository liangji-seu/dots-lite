"""Opt-in live integration test: starts a temporary server, uses two Codex turns.

Run explicitly; this consumes model usage. No secrets are printed or exported.
"""
from __future__ import annotations

import asyncio
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import time

import httpx
from dotenv import dotenv_values
from websockets.asyncio.client import connect

ROOT = Path(__file__).resolve().parents[1]
TERMINAL = {'completed', 'failed', 'cancelled'}


async def check(base: str, token: str) -> dict:
    headers = {'Authorization': f'Bearer {token}'}
    result: dict = {'checks': {}, 'tasks': []}
    async with httpx.AsyncClient(base_url=base, trust_env=False, timeout=10) as client:
        for _ in range(100):
            try:
                response = await client.get('/api/device', headers=headers)
                if response.status_code == 200:
                    break
            except httpx.TransportError:
                pass
            await asyncio.sleep(.1)
        else:
            raise RuntimeError('Bridge did not start; see .local/smoke-server.log')
        result['checks']['device'] = response.status_code
        result['device'] = response.json()
        response = await client.get('/api/projects', headers=headers)
        response.raise_for_status()
        result['checks']['projects'] = response.status_code
        for label, auth in [('missing_token', {}), ('wrong_token', {'Authorization': 'Bearer invalid'})]:
            response = await client.get('/api/device', headers=auth)
            assert response.status_code == 401, (label, response.text)
            result['checks'][label] = response.status_code
        response = await client.post('/api/tasks', headers=headers, json={'project_id': '../outside', 'prompt': 'test'})
        assert response.status_code == 404, response.text
        result['checks']['unknown_project'] = response.status_code
        response = await client.post('/api/tasks', headers=headers, json={'project_id': 'dots-lite', 'prompt': 'test', 'cwd': 'C:\\'})
        assert response.status_code == 422, response.text
        result['checks']['path_injection'] = response.status_code

        async def stream_task(task_id: str) -> dict:
            events = []
            started = time.monotonic()
            first_output_at = None
            url = base.replace('http://', 'ws://') + f'/api/tasks/{task_id}/stream'
            try:
                async with asyncio.timeout(240):
                    async with connect(url, additional_headers=headers, proxy=None) as ws:
                        async for message in ws:
                            event = json.loads(message)
                            events.append(event)
                            if event.get('type') == 'output' and first_output_at is None:
                                first_output_at = time.monotonic() - started
            except BaseException:
                await client.post(f'/api/tasks/{task_id}/cancel', headers=headers)
                raise
            response = await client.get(f'/api/tasks/{task_id}', headers=headers)
            response.raise_for_status()
            task = response.json()
            summary = {
                'task_id': task_id, 'status': task['status'], 'exit_code': task['exit_code'],
                'session_id': task.get('session_id'), 'event_count': len(events),
                'first_output_seconds': first_output_at, 'total_seconds': time.monotonic() - started,
                'output_chars': len(task.get('output', '')), 'error': task.get('error'),
            }
            print(json.dumps(summary, ensure_ascii=False), flush=True)
            assert task['status'] == 'completed', task
            assert task['exit_code'] == 0 and task.get('output'), task
            assert any(e.get('type') == 'output' for e in events)
            assert any(e.get('type') == 'status' and e.get('status') == 'completed' for e in events)
            assert first_output_at is not None and first_output_at < summary['total_seconds']
            # Reconnect after completion and verify replay exactly by sequence.
            seqs = [e['seq'] for e in events if 'seq' in e and e.get('type') != 'heartbeat']
            assert seqs == sorted(set(seqs)), seqs
            cursor = seqs[len(seqs) // 2]
            replay = []
            async with connect(url + f'?after={cursor}', additional_headers=headers, proxy=None) as ws:
                async for message in ws:
                    replay.append(json.loads(message))
            assert [e['seq'] for e in replay if 'seq' in e] == [s for s in seqs if s > cursor]
            summary['replay_verified'] = True
            return summary

        response = await client.post('/api/tasks', headers=headers, json={
            'project_id': 'dots-lite', 'agent_id': 'codex',
            'prompt': 'Read README.md in the current project and summarize its purpose in one sentence. Do not modify any files. Do not delegate.',
        })
        response.raise_for_status()
        task_id = response.json()['task_id']
        result['tasks'].append(await stream_task(task_id))
        response = await client.post(f'/api/tasks/{task_id}/messages', headers=headers,
                                     json={'prompt': 'Reply exactly DOTS_RESUME_OK. Do not use tools or modify files.'})
        response.raise_for_status()
        followup_id = response.json()['task_id']
        result['tasks'].append(await stream_task(followup_id))
        assert result['tasks'][0]['session_id'] == result['tasks'][1]['session_id']
        task = (await client.get(f'/api/tasks/{followup_id}', headers=headers)).json()
        assert 'DOTS_RESUME_OK' in task['output']
        result['checks']['resume_same_session'] = True
    return result


def main() -> None:
    values = dotenv_values(ROOT / '.env')
    token = os.environ.get('CODEX_BRIDGE_TOKEN') or values.get('CODEX_BRIDGE_TOKEN')
    if not token:
        raise RuntimeError('Run scripts/configure.py first')
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    local = ROOT / '.local'
    local.mkdir(exist_ok=True)
    env = os.environ.copy()
    env.update(CODEX_BRIDGE_HOST='127.0.0.1', CODEX_BRIDGE_PORT=str(port))
    with (local / 'smoke-server.log').open('w', encoding='utf-8') as log:
        server = subprocess.Popen([sys.executable, str(ROOT / 'run.py')], cwd=ROOT, env=env,
                                  stdout=log, stderr=log,
                                  creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        try:
            result = asyncio.run(check(f'http://127.0.0.1:{port}', token))
            (local / 'live-validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding='utf-8')
            print('PASS: real Codex execution, resume, HTTP authorization, whitelist, streaming and replay.')
        finally:
            server.terminate()
            server.wait(timeout=15)


if __name__ == '__main__':
    main()
