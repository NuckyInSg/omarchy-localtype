#!/usr/bin/env python3
"""Small atomic state store shared by the dictation runtime and Omarchy UI."""

from __future__ import annotations

import argparse
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path


def state_path() -> Path:
    explicit = os.environ.get("LOCALTYPE_STATE_HOME")
    if explicit:
        return Path(explicit) / "status.json"
    root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    return root / "localtype" / "status.json"


def read_state() -> dict:
    path = state_path()
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        return value if isinstance(value, dict) else {}
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return {}


def write_state(value: dict) -> None:
    path = state_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    value["updated_at"] = datetime.now(timezone.utc).isoformat()
    fd, temporary = tempfile.mkstemp(prefix=".status.", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, separators=(",", ":"))
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    show = subparsers.add_parser("show")
    show.set_defaults(action="show")

    update = subparsers.add_parser("set")
    update.add_argument(
        "status",
        choices=("idle", "recording", "processing", "installing", "starting", "error"),
    )
    update.add_argument("--mode", choices=("smart", "raw"))
    update.add_argument("--text")
    update.add_argument("--raw-text")
    update.add_argument("--partial-text")
    update.add_argument("--error")
    update.add_argument("--detail")
    update.add_argument("--duration-ms", type=int)
    update.add_argument("--processing-ms", type=int)
    update.add_argument("--application-class")
    update.add_argument("--application-title")
    update.set_defaults(action="set")

    clear = subparsers.add_parser("clear")
    clear.set_defaults(action="clear")

    args = parser.parse_args()
    state = read_state()

    if args.action == "show":
        print(json.dumps(state, ensure_ascii=False))
        return

    if args.action == "clear":
        state.pop("last_text", None)
        state.pop("last_raw_text", None)
        state.pop("partial_text", None)
        state.pop("error", None)
        write_state(state)
        return

    state["status"] = args.status
    if args.mode:
        state["mode"] = args.mode
    if args.text is not None:
        state["last_text"] = args.text
    if args.raw_text is not None:
        state["last_raw_text"] = args.raw_text
    if args.status == "recording" and args.partial_text is not None:
        state["partial_text"] = args.partial_text
    else:
        state.pop("partial_text", None)
    if args.error is not None:
        state["error"] = args.error
    elif args.status != "error":
        state.pop("error", None)
    if args.detail is not None:
        state["detail"] = args.detail
    if args.duration_ms is not None:
        state["duration_ms"] = args.duration_ms
    if args.processing_ms is not None:
        state["processing_ms"] = args.processing_ms
    if args.application_class is not None:
        state["application_class"] = args.application_class
    if args.application_title is not None:
        state["application_title"] = args.application_title
    write_state(state)


if __name__ == "__main__":
    main()
