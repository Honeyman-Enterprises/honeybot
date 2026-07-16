"""Entrypoint: `python -m voice_relay`."""

from __future__ import annotations

import uvicorn

from voice_relay.app import build_app
from voice_relay.config import Config


def main() -> None:
    config = Config.from_env()
    uvicorn.run(build_app(config), host="0.0.0.0", port=config.port, access_log=True)


if __name__ == "__main__":
    main()
