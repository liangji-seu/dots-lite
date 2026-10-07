"""Generate the public REST contract without loading machine secrets."""
import json
from pathlib import Path
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from bridge.config import Settings
from bridge.main import create_app


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        config = Path(directory) / 'projects.json'
        config.write_text('[]', encoding='utf-8')
        app = create_app(Settings(token='openapi-generation-only-' * 2, project_config=config), adapters=[])
        (ROOT / 'docs' / 'openapi.json').write_text(
            json.dumps(app.openapi(), ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
    print('Exported docs/openapi.json')


if __name__ == '__main__':
    main()
