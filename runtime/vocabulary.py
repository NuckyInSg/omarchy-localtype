#!/usr/bin/env python3
"""Personal vocabulary helpers shared by ASR and desktop tooling."""

from __future__ import annotations

import json
import os
from pathlib import Path


DEFAULT_PERSONAL_DICTIONARY = {
    "泰普勒式": "Typeless",
    "泰普勒斯": "Typeless",
}


def dictionary_path() -> Path:
    return Path(
        os.environ.get(
            "LOCALTYPE_DICTIONARY",
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "localtype/dictionary.json",
        )
    )


def personal_dictionary(path: Path | None = None) -> dict[str, str]:
    source = path or dictionary_path()
    try:
        value = json.loads(source.read_text(encoding="utf-8"))
        if isinstance(value, dict):
            return {
                str(spoken): str(written)
                for spoken, written in value.items()
                if str(spoken).strip() and str(written).strip()
            }
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return dict(DEFAULT_PERSONAL_DICTIONARY)


def asr_context(application_context: str, mapping: dict[str, str] | None = None) -> str:
    """Build a compact Qwen3-ASR context containing canonical vocabulary."""
    vocabulary = mapping if mapping is not None else personal_dictionary()
    terms: list[str] = []
    seen: set[str] = set()
    for written in vocabulary.values():
        term = str(written).strip()
        folded = term.casefold()
        if not term or folded in seen:
            continue
        seen.add(folded)
        terms.append(term)
        if len(terms) >= 100:
            break
    app = str(application_context or "").strip()
    parts = [f"Application: {app}"] if app else []
    if terms:
        parts.append("Personal vocabulary: " + ", ".join(terms))
    return "\n".join(parts)[:2000]
