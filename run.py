"""Single-process entry point, required for the in-memory task store."""
import logging
import os
from pathlib import Path

import uvicorn

from bridge.config import Settings
from bridge.main import create_app


def main() -> None:
    root = Path(__file__).resolve().parent
    os.chdir(root)
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s %(message)s')
    settings = Settings.from_env(dotenv_path=root / '.env')
    uvicorn.run(create_app(settings), host=settings.host, port=settings.port, workers=1)


if __name__ == '__main__':
    main()
