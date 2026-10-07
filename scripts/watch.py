"""Native-client-style WebSocket example; authorization stays in the header."""
import argparse
import asyncio
import json
import os
from pathlib import Path

from dotenv import load_dotenv
from websockets.asyncio.client import connect


async def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('task_id')
    parser.add_argument('--base', default='ws://127.0.0.1:8765')
    parser.add_argument('--after', type=int, default=0)
    args = parser.parse_args()
    load_dotenv(Path(__file__).resolve().parents[1] / '.env')
    token = os.environ['CODEX_BRIDGE_TOKEN']
    async with connect(
        f'{args.base}/api/tasks/{args.task_id}/stream?after={args.after}',
        additional_headers={'Authorization': f'Bearer {token}'},
    ) as ws:
        async for message in ws:
            print(json.dumps(json.loads(message), ensure_ascii=False), flush=True)


if __name__ == '__main__':
    asyncio.run(main())
