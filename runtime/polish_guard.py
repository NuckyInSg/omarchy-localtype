#!/usr/bin/env python3
"""Deterministic fidelity checks for generative ASR post-correction."""

from __future__ import annotations

import collections
import difflib
import re
import unicodedata


_SHORTCUT_PATTERN = re.compile(
    r"\b(?:Ctrl|Control|Alt|Shift|Super|Meta|Cmd|Command|Win)"
    r"(?:\s*\+\s*(?:Ctrl|Control|Alt|Shift|Super|Meta|Cmd|Command|Win|"
    r"[A-Za-z0-9]|F(?:[1-9]|1[0-2])|Esc|Enter|Tab|Space|Backspace|Delete))+\b",
    re.IGNORECASE,
)

_PROTECTED_PATTERNS = (
    _SHORTCUT_PATTERN,
    re.compile(r"https?://[^\s<>\"'，。！？]+", re.IGNORECASE),
    re.compile(r"\b[\w.+-]+@[\w.-]+\.[A-Za-z]{2,}\b"),
    re.compile(r"(?<!\w)(?:~?/|\.{1,2}/)[^\s，。！？,;]+"),
    re.compile(r"`[^`\n]+`"),
    re.compile(r"(?<![\w.])--?[A-Za-z][A-Za-z0-9_-]*"),
    re.compile(r"\b[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+\b"),
    re.compile(r"\b(?:[A-Za-z][A-Za-z0-9]*_[A-Za-z0-9_]+|[A-Za-z]+\d+[A-Za-z0-9]*|[A-Z]{2,})\b"),
    re.compile(r"(?<![\w.])[+-]?\d+(?:[.:/-]\d+)*(?:\.\d+)?%?(?![\w.])"),
)


def _meaningful(value: str) -> str:
    return "".join(
        character.casefold()
        for character in value
        if not character.isspace()
        and not unicodedata.category(character).startswith("P")
    )


def protected_tokens(value: str) -> list[str]:
    tokens: list[tuple[int, int, str]] = []
    for pattern in _PROTECTED_PATTERNS:
        for match in pattern.finditer(value):
            start, end = match.span()
            if any(not (end <= old_start or start >= old_end) for old_start, old_end, _ in tokens):
                continue
            tokens.append((start, end, match.group(0)))
    return [token for _, _, token in sorted(tokens)]


def _protected_identity(token: str) -> str:
    if _SHORTCUT_PATTERN.fullmatch(token):
        return re.sub(r"\s+", "", token).casefold()
    return token


_REQUEST_MARKERS = re.compile(
    r"(?:^|[，,。；;！？!?\s])(?:请(?:你)?|麻烦(?:你)?|帮我|帮忙|替我|为我|给我(?!的)|劳驾|务必|记得|不要|别)"
)

_QUESTION_PHRASES = re.compile(
    r"(?:是哪个|是哪一个|是哪种|是什么|为什(?:么)?|为何|怎么|如何|"
    r"在哪里|在哪儿|哪一个|多少|几点|何时|是否|能否|可否|"
    r"有没有|是不是|要不要|可不可以|行不行)"
)


def _has_question_intent(value: str) -> bool:
    text = value.strip().rstrip("\"'”’」』）)]}")
    return text.endswith(("?", "？")) or bool(_QUESTION_PHRASES.search(text)) or bool(
        re.search(r"(?:吗|么|呢)[。.!！]?$", text)
    )


def _ends_as_question(value: str) -> bool:
    return value.strip().rstrip("\"'”’」』）)]}").endswith(("?", "？"))


def _has_request_intent(value: str) -> bool:
    return bool(_REQUEST_MARKERS.search(value.strip()))


def validate_polish_candidate(source: str, candidate: str) -> tuple[list[str], dict]:
    """Return fallback reasons and compact metrics for one generated candidate."""
    reasons: list[str] = []
    source_clean = source.strip()
    candidate_clean = candidate.strip()
    source_meaningful = _meaningful(source_clean)
    candidate_meaningful = _meaningful(candidate_clean)

    if not candidate_clean:
        reasons.append("empty_candidate")
    if source_clean and len(candidate_clean) < len(source_clean) * 0.55:
        reasons.append("candidate_too_short")
    if source_clean and len(candidate_clean) > len(source_clean) * 1.6:
        reasons.append("candidate_too_long")

    similarity = difflib.SequenceMatcher(
        a=source_meaningful,
        b=candidate_meaningful,
        autojunk=False,
    ).ratio() if source_meaningful and candidate_meaningful else 0.0
    if len(source_meaningful) >= 12 and similarity < 0.35:
        reasons.append("candidate_semantic_drift")

    source_question = _has_question_intent(source_clean)
    candidate_question = _has_question_intent(candidate_clean)
    if source_question and not candidate_question:
        reasons.append("question_intent_changed")
    if _ends_as_question(source_clean) and not _ends_as_question(candidate_clean):
        reasons.append("question_mark_removed")
    if source_question and len(source_meaningful) >= 6 and similarity < 0.72:
        reasons.append("question_semantic_drift")

    source_request = _has_request_intent(source_clean)
    candidate_request = _has_request_intent(candidate_clean)
    if source_request and not candidate_request:
        reasons.append("request_intent_changed")

    source_protected = collections.Counter(
        _protected_identity(token) for token in protected_tokens(source_clean)
    )
    candidate_protected = collections.Counter(
        _protected_identity(token) for token in protected_tokens(candidate_clean)
    )
    missing = list((source_protected - candidate_protected).elements())
    introduced = list((candidate_protected - source_protected).elements())
    if missing:
        reasons.append("protected_token_changed")
    if introduced:
        reasons.append("protected_token_introduced")

    metrics = {
        "similarity": round(similarity, 3),
        "source_question": source_question,
        "candidate_question": candidate_question,
        "source_request": source_request,
        "candidate_request": candidate_request,
        "protected_tokens": list(source_protected.elements())[:20],
        "missing_protected_tokens": missing[:20],
        "introduced_protected_tokens": introduced[:20],
    }
    return reasons, metrics
