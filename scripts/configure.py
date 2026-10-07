"""Create local-only configuration once; never print the generated secret."""
import json
import secrets
import socket
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def main() -> None:
    env_path = ROOT / '.env'
    if not env_path.exists():
        env_path.write_text(
            'CODEX_BRIDGE_HOST=0.0.0.0\nCODEX_BRIDGE_PORT=8765\n'
            f'CODEX_BRIDGE_TOKEN={secrets.token_urlsafe(32)}\n'
            f'CODEX_BRIDGE_DEVICE_ID={socket.gethostname()}\n'
            'CODEX_PROJECT_CONFIG=config/projects.json\n'
            'CODEX_SANDBOX=read-only\n'
            'CODEX_MODEL=gpt-5.6-luna\nCODEX_REASONING_EFFORT=high\n',
            encoding='utf-8',
        )
        print('Created .env with a random token. Read it locally for device pairing.')
    else:
        print('Kept existing .env.')
    config = ROOT / 'config' / 'projects.json'
    config.parent.mkdir(exist_ok=True)
    if not config.exists():
        config.write_text(json.dumps([
            {'id': 'dots-lite', 'name': 'dots-lite', 'path': str(ROOT)}
        ], ensure_ascii=False, indent=2), encoding='utf-8')
        print('Created config/projects.json with this repository as the only project.')
    else:
        print('Kept existing project whitelist.')


if __name__ == '__main__':
    main()
