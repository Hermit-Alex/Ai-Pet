from __future__ import annotations

import argparse

from .config import load_settings
from .service import AipetBridgeService
from .storage import SQLiteStore


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="aipet-bridge")
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("init-db", help="Create the local SQLite database and default pet profile.")
    subparsers.add_parser("seed-demo", help="Insert a tiny demo event and memory note.")
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    settings = load_settings()
    store = SQLiteStore(settings.database_path)
    service = AipetBridgeService(settings=settings, store=store)
    service.initialize()

    if args.command == "init-db":
        print(f"Initialized database: {settings.database_path}")
        return

    if args.command == "seed-demo":
        service.seed_demo_data()
        print(f"Seeded demo data for pet: {settings.default_pet_id}")
        return

    parser.error(f"Unknown command: {args.command}")


if __name__ == "__main__":
    main()
