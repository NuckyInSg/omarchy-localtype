#!/usr/bin/env python3
"""Contextual personal-vocabulary helpers shared by ASR and polishing."""

from __future__ import annotations

import difflib
import json
import os
import re
from pathlib import Path


DEFAULT_PERSONAL_DICTIONARY = {
    "泰普勒式": "Typeless",
    "泰普勒斯": "Typeless",
}

_CJK_RUN = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff]+")
_LATIN_TOKEN = re.compile(r"[A-Za-z0-9]+")


def dictionary_path() -> Path:
    return Path(
        os.environ.get(
            "LOCALTYPE_DICTIONARY",
            Path(os.environ.get("XDG_CONFIG_HOME", Path.home() / ".config"))
            / "localtype/dictionary.json",
        )
    )


def corrections_path(path: Path | None = None) -> Path:
    explicit = os.environ.get("LOCALTYPE_CORRECTIONS")
    if explicit:
        return Path(explicit)
    return (path or dictionary_path()).with_name("learned_corrections.json")


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


def _learned_entries(path: Path) -> list[dict]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(value, list):
            return [entry for entry in value if isinstance(entry, dict)]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return []


def _compact_latin(value: str) -> str:
    return "".join(character.casefold() for character in value if character.isalnum())


def _is_cjk(value: str) -> bool:
    return bool(value) and all(
        "\u3400" <= character <= "\u4dbf" or "\u4e00" <= character <= "\u9fff"
        for character in value
    )


def _phonetic_key(value: str) -> str:
    """Return a Pinyin key when the optional runtime dependency is available."""
    try:
        from pypinyin import Style, lazy_pinyin

        return "".join(
            lazy_pinyin(
                value,
                style=Style.NORMAL,
                errors=lambda characters: list(characters.casefold()),
            )
        ).casefold()
    except ImportError:
        return ""


def _similarity(left: str, right: str) -> float:
    try:
        from rapidfuzz import fuzz

        return float(fuzz.ratio(left, right)) / 100.0
    except ImportError:
        return difflib.SequenceMatcher(a=left, b=right, autojunk=False).ratio()


def _term_priority(
    written: str,
    application_context: str,
    learned: list[dict],
) -> tuple[int, int, str]:
    application = application_context.casefold().strip()
    relevant = [
        entry
        for entry in learned
        if entry.get("status") == "learned"
        and str(entry.get("written", "")).casefold() == written.casefold()
    ]
    same_app = any(
        application
        and str(entry.get("application_class", "")).casefold() == application
        for entry in relevant
    )
    evidence = sum(max(1, int(entry.get("count", 1))) for entry in relevant)
    return (1 if same_app else 0, evidence, written.casefold())


def canonical_terms(
    application_context: str,
    mapping: dict[str, str] | None = None,
    path: Path | None = None,
    limit: int = 100,
) -> list[str]:
    """Return deduplicated spellings, prioritizing terms learned in this app."""
    vocabulary = mapping if mapping is not None else personal_dictionary(path)
    learned = _learned_entries(corrections_path(path))
    unique: dict[str, str] = {}
    for written in vocabulary.values():
        term = str(written).strip()
        if term:
            unique.setdefault(term.casefold(), term)
    ranked = sorted(
        unique.values(),
        key=lambda term: _term_priority(term, application_context, learned),
        reverse=True,
    )
    return ranked[:limit]


def asr_context(
    application_context: str,
    mapping: dict[str, str] | None = None,
    path: Path | None = None,
) -> str:
    """Build Qwen3-ASR context with canonical spellings, never known mistakes."""
    terms = canonical_terms(application_context, mapping, path, limit=100)
    app = str(application_context or "").strip()
    parts = [f"当前输入应用：{app}。"] if app else []
    if terms:
        parts.append(
            "以下是本次语音中可能出现的个人词汇和专有名词。"
            "只在发音与上下文吻合时采用，并严格使用给定拼写："
            + "、".join(terms)
        )
    return "\n".join(parts)[:2000]


def _exact_span(text: str, phrase: str) -> tuple[int, int] | None:
    if not phrase:
        return None
    if all(character.isascii() for character in phrase):
        pattern = re.compile(
            rf"(?<![A-Za-z0-9_]){re.escape(phrase)}(?![A-Za-z0-9_])",
            re.IGNORECASE,
        )
        match = pattern.search(text)
        return match.span() if match else None
    index = text.find(phrase)
    return (index, index + len(phrase)) if index >= 0 else None


def _best_cjk_match(
    text: str,
    seed: str,
    phonetic_cache: dict[str, str],
) -> tuple[str, float] | None:
    def phonetic(value: str) -> str:
        if value not in phonetic_cache:
            phonetic_cache[value] = _phonetic_key(value)
        return phonetic_cache[value]

    seed_key = phonetic(seed)
    if not seed_key:
        return None
    best: tuple[str, float] | None = None
    for run_match in _CJK_RUN.finditer(text):
        run = run_match.group(0)
        for width in range(max(1, len(seed) - 1), len(seed) + 2):
            for start in range(0, len(run) - width + 1):
                segment = run[start : start + width]
                if segment == seed:
                    continue
                segment_key = phonetic(segment)
                if not segment_key:
                    continue
                score = _similarity(segment_key, seed_key)
                if best is None or score > best[1]:
                    best = (segment, score)
    return best


def _best_latin_match(text: str, seed: str) -> tuple[str, float] | None:
    seed_key = _compact_latin(seed)
    if len(seed_key) < 4:
        return None
    tokens = list(_LATIN_TOKEN.finditer(text))
    best: tuple[str, float] | None = None
    for first in range(len(tokens)):
        for width in range(1, min(4, len(tokens) - first) + 1):
            last = tokens[first + width - 1]
            segment = text[tokens[first].start() : last.end()].strip()
            if segment.casefold() == seed.casefold():
                continue
            segment_key = _compact_latin(segment)
            if not segment_key:
                continue
            score = _similarity(segment_key, seed_key)
            if best is None or score > best[1]:
                best = (segment, score)
    return best


def correction_hints(
    transcript: str,
    application_context: str = "",
    mapping: dict[str, str] | None = None,
    path: Path | None = None,
    limit: int = 12,
) -> dict:
    """Generate exact and phonetic candidates for contextual LLM reranking.

    Fuzzy candidates are deliberately hints rather than unconditional replacements:
    a homophone may be acoustically plausible while still being wrong in context.
    """
    vocabulary = mapping if mapping is not None else personal_dictionary(path)
    terms = canonical_terms(application_context, vocabulary, path, limit=60)
    candidates: list[dict] = []
    seen: set[tuple[str, str]] = set()
    learned = _learned_entries(corrections_path(path))
    learned_by_pair = {
        (str(entry.get("spoken", "")).casefold(), str(entry.get("written", "")).casefold()): entry
        for entry in learned
        if entry.get("status") == "learned"
    }

    def append(
        source: str,
        target: str,
        score: float,
        reason: str,
        apply: bool = False,
    ) -> None:
        source = source.strip()
        target = target.strip()
        identity = (source.casefold(), target.casefold())
        if (
            not source
            or not target
            or source.casefold() == target.casefold()
            or identity in seen
            or target.casefold() in transcript.casefold()
        ):
            return
        seen.add(identity)
        candidates.append(
            {
                "source": source[:80],
                "target": target[:80],
                "score": round(score, 3),
                "reason": reason,
                "apply": apply,
            }
        )

    # Explicit aliases remain useful evidence, but the language model decides
    # whether the replacement makes sense in this sentence.
    for spoken, written in sorted(vocabulary.items(), key=lambda item: len(item[0]), reverse=True):
        alias = str(spoken).strip()
        target = str(written).strip()
        if alias.casefold() == target.casefold():
            continue
        span = _exact_span(transcript, alias)
        if span:
            learned_entry = learned_by_pair.get((alias.casefold(), target.casefold()))
            same_app = bool(
                learned_entry
                and application_context.strip()
                and str(learned_entry.get("application_class", "")).casefold()
                == application_context.casefold().strip()
            )
            repeated = bool(learned_entry and int(learned_entry.get("count", 1)) >= 2)
            cross_script_proper = bool(
                any(_is_cjk(character) for character in alias)
                and any(character.isascii() and character.isalpha() for character in target)
            )
            stable_latin_spelling = bool(
                all(character.isascii() for character in alias + target)
                and _similarity(_compact_latin(alias), _compact_latin(target)) >= 0.88
            )
            append(
                transcript[span[0] : span[1]],
                target,
                1.0,
                "learned_alias",
                same_app or repeated or cross_script_proper or stable_latin_spelling,
            )

    # Match both canonical-only vocabulary and known pronunciations. Chinese
    # uses Pinyin; Latin product names tolerate spaces, punctuation, and case.
    seeds: list[tuple[str, str]] = []
    seeds.extend((term, term) for term in terms)
    seeds.extend(
        (str(spoken).strip(), str(written).strip())
        for spoken, written in vocabulary.items()
        if str(spoken).strip().casefold() != str(written).strip().casefold()
    )
    phonetic_cache: dict[str, str] = {}
    for seed, target in seeds:
        if _is_cjk(seed):
            match = _best_cjk_match(transcript, seed, phonetic_cache)
            if match and match[1] >= 0.85:
                append(match[0], target, match[1], "pinyin")
        elif any(character.isascii() and character.isalpha() for character in seed):
            match = _best_latin_match(transcript, seed)
            if match and match[1] >= 0.88:
                append(match[0], target, match[1], "orthographic")

    candidates.sort(
        key=lambda item: (item["reason"] == "learned_alias", item["score"], len(item["source"])),
        reverse=True,
    )
    return {"terms": terms, "candidates": candidates[:limit]}


def apply_confident_corrections(transcript: str, profile: dict) -> tuple[str, list[dict]]:
    """Apply only exact, high-confidence aliases selected by scope/type policy."""
    text = transcript
    applied: list[dict] = []
    candidates = [
        item
        for item in profile.get("candidates", [])
        if isinstance(item, dict)
        and (
            item.get("reason") == "learned_alias"
            or item.get("audio_confirmed") is True
        )
        and item.get("apply") is True
    ]
    for item in sorted(candidates, key=lambda value: len(str(value.get("source", ""))), reverse=True):
        source = str(item.get("source", ""))
        target = str(item.get("target", ""))
        if not source or not target:
            continue
        if all(character.isascii() for character in source):
            pattern = re.compile(
                rf"(?<![A-Za-z0-9_]){re.escape(source)}(?![A-Za-z0-9_])",
                re.IGNORECASE,
            )
            updated, count = pattern.subn(lambda _match: target, text)
        else:
            count = text.count(source)
            updated = text.replace(source, target) if count else text
        if count:
            text = updated
            applied.append(
                {
                    "source": source,
                    "target": target,
                    "count": count,
                    "reason": (
                        "audio_confirmed_alias"
                        if item.get("audio_confirmed") is True
                        else "scoped_exact_alias"
                    ),
                }
            )
    return text, applied
