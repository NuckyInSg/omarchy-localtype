#!/usr/bin/env python3
"""Atomic local data store for LocalType desktop features."""

from __future__ import annotations

import argparse
import difflib
import json
import os
import tempfile
import unicodedata
import uuid
from datetime import datetime, timezone
from pathlib import Path

from prompt_defaults import DEFAULT_POLISH_PROMPT


def config_home() -> Path:
    explicit = os.environ.get("LOCALTYPE_CONFIG_HOME")
    if explicit:
        return Path(explicit)
    return Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config")) / "localtype"


def state_home() -> Path:
    explicit = os.environ.get("LOCALTYPE_STATE_HOME")
    if explicit:
        return Path(explicit)
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "localtype"


DICTIONARY_PATH = config_home() / "dictionary.json"
SCENES_PATH = config_home() / "scenes.json"
SETTINGS_PATH = config_home() / "settings.json"
HISTORY_PATH = state_home() / "history.json"
CORRECTIONS_PATH = config_home() / "learned_corrections.json"

DEFAULT_DICTIONARY = {
    "泰普勒式": "Typeless",
    "泰普勒斯": "Typeless",
}

DEFAULT_SCENES = [
    {
        "id": "codex",
        "name": "Codex",
        "icon": "code",
        "description": "保留技术名词与命令，使用简洁 Markdown",
        "style": "技术",
        "enabled": True,
        "preserve_code": True,
        "markdown": True,
        "remove_fillers": True,
        "auto_submit": False,
        "prompt": "保持技术术语、文件路径和命令不变；优先输出简洁、可执行的句子。",
        "classes": "codex, Alacritty, com.mitchellh.ghostty",
    },
    {
        "id": "chromium",
        "name": "Chromium",
        "icon": "browser",
        "description": "通用润色，自动补充标点",
        "style": "通用",
        "enabled": True,
        "preserve_code": False,
        "markdown": False,
        "remove_fillers": True,
        "auto_submit": False,
        "prompt": "使用自然、清晰的中文，修正标点和明显口误。",
        "classes": "chromium, google-chrome",
    },
    {
        "id": "slack",
        "name": "Slack",
        "icon": "chat",
        "description": "更口语、更简短，不生成标题",
        "style": "聊天",
        "enabled": True,
        "preserve_code": True,
        "markdown": False,
        "remove_fillers": True,
        "auto_submit": False,
        "prompt": "保持口语自然，句子简短，不添加标题。",
        "classes": "Slack, slack",
    },
    {
        "id": "obsidian",
        "name": "Obsidian",
        "icon": "document",
        "description": "整理段落，可生成列表与小标题",
        "style": "笔记",
        "enabled": True,
        "preserve_code": True,
        "markdown": True,
        "remove_fillers": True,
        "auto_submit": False,
        "prompt": "整理段落结构；必要时使用列表和简短小标题。",
        "classes": "obsidian",
    },
]

DEFAULT_SETTINGS = {
    "language": "en",
    "default_mode": "smart",
    "smart_shortcut": "F9",
    "raw_shortcut": "SHIFT + F9",
    "learn_shortcut": "CTRL + SHIFT + F9",
    "keep_history": True,
    "history_days": 30,
    "launch_at_startup": True,
    "prewarm_models": True,
    "terminal_paste": True,
    "polish_prompt": DEFAULT_POLISH_PROMPT,
}


def read_json(path: Path, fallback):
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, type(fallback)):
            return value
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return json.loads(json.dumps(fallback, ensure_ascii=False))


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.stem}.", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def settings_data() -> dict:
    saved = read_json(SETTINGS_PATH, {})
    return {**DEFAULT_SETTINGS, **saved}


def dictionary_entries() -> list[dict]:
    mapping = read_json(DICTIONARY_PATH, DEFAULT_DICTIONARY)
    corrections = read_json(CORRECTIONS_PATH, [])
    learned = {
        str(entry.get("spoken")): entry
        for entry in corrections
        if entry.get("status") == "learned"
    }
    return [
        {
            "spoken": spoken,
            "written": written,
            "learned": spoken in learned,
            "count": int(learned.get(spoken, {}).get("count", 0)),
            "application_class": str(learned.get(spoken, {}).get("application_class", "")),
        }
        for spoken, written in sorted(mapping.items(), key=lambda item: item[1].lower())
    ]


def meaningful_text(value: str) -> str:
    return "".join(
        character
        for character in value
        if not character.isspace() and not unicodedata.category(character).startswith("P")
    )


def correction_candidates(original: str, corrected: str) -> list[dict]:
    """Return conservative local replacements, never whole-sentence rewrites."""
    before = original.strip()
    after = corrected.strip()
    if not before or not after or before == after:
        return []
    matcher = difflib.SequenceMatcher(a=before, b=after, autojunk=False)
    if matcher.ratio() < 0.55:
        return []
    candidates: list[dict] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "replace":
            continue
        spoken = before[i1:i2].strip()
        written = after[j1:j2].strip()
        if not spoken or not written or len(spoken) > 32 or len(written) > 32:
            continue
        if not meaningful_text(spoken) or not meaningful_text(written):
            continue
        candidates.append(
            {
                "spoken": spoken,
                "written": written,
                "confidence": round(matcher.ratio(), 3),
            }
        )
    return candidates


def corrections_entries(status: str = "") -> list[dict]:
    entries = read_json(CORRECTIONS_PATH, [])
    if not status or status == "all":
        return entries
    return [entry for entry in entries if entry.get("status") == status]


def latest_history(application_class: str = "") -> dict | None:
    entries = history_entries()
    if application_class:
        folded = application_class.casefold()
        matched = next(
            (
                entry
                for entry in entries
                if str(entry.get("application_class", "")).casefold() == folded
            ),
            None,
        )
        if matched:
            return matched
    return entries[0] if entries else None


def propose_corrections(args: argparse.Namespace) -> list[dict]:
    history = None
    if args.history_id:
        history = next(
            (entry for entry in history_entries() if entry.get("id") == args.history_id),
            None,
        )
    if history is None:
        history = latest_history(args.application_class)
    if history is None:
        raise SystemExit("No recent LocalType dictation was found")
    original = str(history.get("final_text", ""))
    corrected = args.corrected.strip()
    candidates = correction_candidates(original, corrected)
    if not candidates:
        raise SystemExit(
            "No local word correction was found. Select the complete corrected sentence, not only one word."
        )

    now = datetime.now(timezone.utc).isoformat()
    entries = read_json(CORRECTIONS_PATH, [])
    output: list[dict] = []
    for candidate in candidates:
        existing = next(
            (
                entry
                for entry in entries
                if entry.get("spoken") == candidate["spoken"]
                and entry.get("written") == candidate["written"]
                and entry.get("status") != "ignored"
            ),
            None,
        )
        if existing is None:
            existing = {
                "id": uuid.uuid4().hex,
                "spoken": candidate["spoken"],
                "written": candidate["written"],
                "status": "pending",
                "count": 1,
                "confidence": candidate["confidence"],
                "source": args.source,
                "application_class": args.application_class
                or str(history.get("application_class", "")),
                "application_title": args.application_title
                or str(history.get("application_title", "")),
                "original_text": original,
                "corrected_text": corrected,
                "history_id": str(history.get("id", "")),
                "created_at": now,
                "updated_at": now,
            }
            entries.insert(0, existing)
        else:
            existing["count"] = int(existing.get("count", 1)) + 1
            existing["updated_at"] = now
            existing["corrected_text"] = corrected
            existing["confidence"] = max(
                float(existing.get("confidence", 0)), candidate["confidence"]
            )
        output.append(existing)
    write_json(CORRECTIONS_PATH, entries[:500])
    return output


def accept_correction(correction_id: str) -> None:
    entries = read_json(CORRECTIONS_PATH, [])
    entry = next((item for item in entries if item.get("id") == correction_id), None)
    if entry is None:
        raise SystemExit("Correction was not found")
    mapping = read_json(DICTIONARY_PATH, DEFAULT_DICTIONARY)
    mapping[str(entry["spoken"])] = str(entry["written"])
    write_json(DICTIONARY_PATH, mapping)
    entry["status"] = "learned"
    entry["updated_at"] = datetime.now(timezone.utc).isoformat()
    write_json(CORRECTIONS_PATH, entries)


def delete_correction(correction_id: str) -> None:
    entries = read_json(CORRECTIONS_PATH, [])
    entry = next((item for item in entries if item.get("id") == correction_id), None)
    if entry and entry.get("status") == "learned":
        mapping = read_json(DICTIONARY_PATH, DEFAULT_DICTIONARY)
        if mapping.get(str(entry.get("spoken"))) == str(entry.get("written")):
            mapping.pop(str(entry.get("spoken")), None)
            write_json(DICTIONARY_PATH, mapping)
    write_json(
        CORRECTIONS_PATH,
        [item for item in entries if item.get("id") != correction_id],
    )


def history_entries(query: str = "") -> list[dict]:
    entries = read_json(HISTORY_PATH, [])
    if not query:
        return entries
    needle = query.casefold()
    return [
        entry
        for entry in entries
        if needle in str(entry.get("raw_text", "")).casefold()
        or needle in str(entry.get("final_text", "")).casefold()
        or needle in str(entry.get("application_title", "")).casefold()
    ]


def add_history(args: argparse.Namespace) -> None:
    settings = settings_data()
    if not settings.get("keep_history", True):
        return
    entries = read_json(HISTORY_PATH, [])
    try:
        now = datetime.fromisoformat(args.created_at) if args.created_at else datetime.now(timezone.utc)
    except ValueError:
        now = datetime.now(timezone.utc)
    entries.insert(
        0,
        {
            "id": f"{now.isoformat()}-{uuid.uuid4().hex[:6]}",
            "created_at": now.isoformat(),
            "mode": args.mode,
            "application_class": args.application_class,
            "application_title": args.application_title or args.application_class or "当前应用",
            "scene": args.scene,
            "raw_text": args.raw_text,
            "final_text": args.final_text,
            "polished": args.polished,
            "output_status": "typed",
            "duration_ms": args.duration_ms,
            "processing_ms": args.processing_ms,
            "injection_method": args.injection_method,
        },
    )
    write_json(HISTORY_PATH, entries[:200])


def scene_by_id(scene_id: str) -> tuple[list[dict], dict | None]:
    scenes = read_json(SCENES_PATH, DEFAULT_SCENES)
    return scenes, next((scene for scene in scenes if scene.get("id") == scene_id), None)


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    history_list = subparsers.add_parser("history-list")
    history_list.add_argument("--query", default="")
    history_add = subparsers.add_parser("history-add")
    history_add.add_argument("--mode", choices=("smart", "raw"), required=True)
    history_add.add_argument("--application-class", default="")
    history_add.add_argument("--application-title", default="")
    history_add.add_argument("--scene", default="general")
    history_add.add_argument("--raw-text", required=True)
    history_add.add_argument("--final-text", required=True)
    history_add.add_argument("--polished", action="store_true")
    history_add.add_argument("--duration-ms", type=int, default=0)
    history_add.add_argument("--processing-ms", type=int, default=0)
    history_add.add_argument("--injection-method", default="unknown")
    history_add.add_argument("--created-at", default="")
    history_delete = subparsers.add_parser("history-delete")
    history_delete.add_argument("id")
    subparsers.add_parser("history-clear")

    subparsers.add_parser("dictionary-list")
    dictionary_set = subparsers.add_parser("dictionary-set")
    dictionary_set.add_argument("spoken")
    dictionary_set.add_argument("written")
    dictionary_delete = subparsers.add_parser("dictionary-delete")
    dictionary_delete.add_argument("spoken")

    corrections_list = subparsers.add_parser("corrections-list")
    corrections_list.add_argument("--status", default="all", choices=("all", "pending", "learned", "ignored"))
    correction_propose = subparsers.add_parser("correction-propose")
    correction_propose.add_argument("--corrected", required=True)
    correction_propose.add_argument("--history-id", default="")
    correction_propose.add_argument("--application-class", default="")
    correction_propose.add_argument("--application-title", default="")
    correction_propose.add_argument("--source", default="selection", choices=("selection", "history"))
    correction_accept = subparsers.add_parser("correction-accept")
    correction_accept.add_argument("id")
    correction_ignore = subparsers.add_parser("correction-ignore")
    correction_ignore.add_argument("id")
    correction_delete = subparsers.add_parser("correction-delete")
    correction_delete.add_argument("id")

    subparsers.add_parser("scenes-list")
    scene_toggle = subparsers.add_parser("scene-toggle")
    scene_toggle.add_argument("id")
    scene_toggle.add_argument("enabled", choices=("true", "false"))
    scene_set = subparsers.add_parser("scene-set")
    scene_set.add_argument("id")
    scene_set.add_argument("field")
    scene_set.add_argument("value")
    scene_save = subparsers.add_parser("scene-save")
    scene_save.add_argument("id")
    scene_save.add_argument("style")
    scene_save.add_argument("prompt")
    scene_save.add_argument("classes")

    subparsers.add_parser("settings-show")
    setting_set = subparsers.add_parser("setting-set")
    setting_set.add_argument("key")
    setting_set.add_argument("value")
    setting_reset = subparsers.add_parser("setting-reset")
    setting_reset.add_argument("key")
    shortcuts_set = subparsers.add_parser("shortcuts-set")
    shortcuts_set.add_argument("smart")
    shortcuts_set.add_argument("raw")
    shortcuts_set.add_argument("learn", nargs="?", default="CTRL + SHIFT + F9")

    args = parser.parse_args()

    if args.command == "history-list":
        print(json.dumps(history_entries(args.query), ensure_ascii=False))
    elif args.command == "history-add":
        add_history(args)
    elif args.command == "history-delete":
        write_json(HISTORY_PATH, [e for e in history_entries() if e.get("id") != args.id])
    elif args.command == "history-clear":
        write_json(HISTORY_PATH, [])
    elif args.command == "dictionary-list":
        print(json.dumps(dictionary_entries(), ensure_ascii=False))
    elif args.command == "dictionary-set":
        mapping = read_json(DICTIONARY_PATH, DEFAULT_DICTIONARY)
        mapping[args.spoken] = args.written
        write_json(DICTIONARY_PATH, mapping)
    elif args.command == "dictionary-delete":
        mapping = read_json(DICTIONARY_PATH, DEFAULT_DICTIONARY)
        mapping.pop(args.spoken, None)
        write_json(DICTIONARY_PATH, mapping)
        corrections = read_json(CORRECTIONS_PATH, [])
        for correction in corrections:
            if correction.get("spoken") == args.spoken and correction.get("status") == "learned":
                correction["status"] = "ignored"
                correction["updated_at"] = datetime.now(timezone.utc).isoformat()
        write_json(CORRECTIONS_PATH, corrections)
    elif args.command == "corrections-list":
        print(json.dumps(corrections_entries(args.status), ensure_ascii=False))
    elif args.command == "correction-propose":
        print(json.dumps(propose_corrections(args), ensure_ascii=False))
    elif args.command == "correction-accept":
        accept_correction(args.id)
    elif args.command == "correction-ignore":
        entries = read_json(CORRECTIONS_PATH, [])
        for entry in entries:
            if entry.get("id") == args.id:
                entry["status"] = "ignored"
                entry["updated_at"] = datetime.now(timezone.utc).isoformat()
        write_json(CORRECTIONS_PATH, entries)
    elif args.command == "correction-delete":
        delete_correction(args.id)
    elif args.command == "scenes-list":
        print(json.dumps(read_json(SCENES_PATH, DEFAULT_SCENES), ensure_ascii=False))
    elif args.command == "scene-toggle":
        scenes, scene = scene_by_id(args.id)
        if scene is not None:
            scene["enabled"] = args.enabled == "true"
            write_json(SCENES_PATH, scenes)
    elif args.command == "scene-set":
        scenes, scene = scene_by_id(args.id)
        if scene is not None:
            if args.field in {"enabled", "preserve_code", "markdown", "remove_fillers", "auto_submit"}:
                scene[args.field] = args.value.lower() == "true"
            elif args.field in {"style", "prompt", "classes"}:
                scene[args.field] = args.value
            write_json(SCENES_PATH, scenes)
    elif args.command == "scene-save":
        scenes, scene = scene_by_id(args.id)
        if scene is not None:
            scene["style"] = args.style
            scene["prompt"] = args.prompt
            scene["classes"] = args.classes
            write_json(SCENES_PATH, scenes)
    elif args.command == "settings-show":
        print(json.dumps(settings_data(), ensure_ascii=False))
    elif args.command == "setting-set":
        settings = settings_data()
        if args.key in {"keep_history", "launch_at_startup", "prewarm_models", "terminal_paste"}:
            settings[args.key] = args.value.lower() == "true"
        elif args.key == "history_days":
            settings[args.key] = max(1, int(args.value))
        elif args.key == "default_mode" and args.value in {"smart", "raw"}:
            settings[args.key] = args.value
        elif args.key == "language" and args.value in {"en", "zh"}:
            settings[args.key] = args.value
        elif args.key == "polish_prompt":
            if not args.value.strip():
                raise SystemExit("polish_prompt must not be empty")
            if len(args.value) > 12000:
                raise SystemExit("polish_prompt must be 12000 characters or fewer")
            settings[args.key] = args.value
        write_json(SETTINGS_PATH, settings)
    elif args.command == "setting-reset":
        if args.key != "polish_prompt":
            raise SystemExit("only polish_prompt can be reset")
        settings = settings_data()
        settings["polish_prompt"] = DEFAULT_POLISH_PROMPT
        write_json(SETTINGS_PATH, settings)
    elif args.command == "shortcuts-set":
        settings = settings_data()
        settings["smart_shortcut"] = args.smart
        settings["raw_shortcut"] = args.raw
        settings["learn_shortcut"] = args.learn
        write_json(SETTINGS_PATH, settings)


if __name__ == "__main__":
    main()
