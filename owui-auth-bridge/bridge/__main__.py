"""Entrypoint: `python -m bridge`."""

from __future__ import annotations

from aiohttp import web

from bridge.app import build_app
from bridge.config import Config


def main() -> None:
    config = Config.from_env()
    web.run_app(build_app(config), host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
