#!/usr/bin/env python3
"""Local acoustic exemplar storage and matching for personal ASR corrections."""

from __future__ import annotations

import hashlib
import json
import math
import os
import tempfile
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterable

import librosa
import numpy as np
import soundfile as sf


FEATURE_VERSION = "mfcc-delta-dtw-v1"
MAX_TEMPLATES_PER_TERM = 5
MAX_TEMPLATES = 200
AUDIO_CONFIRM_THRESHOLD = 0.76


def state_home() -> Path:
    explicit = os.environ.get("LOCALTYPE_STATE_HOME")
    if explicit:
        return Path(explicit)
    return Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state")) / "localtype"


def acoustic_home() -> Path:
    explicit = os.environ.get("LOCALTYPE_ACOUSTIC_HOME")
    return Path(explicit) if explicit else state_home() / "acoustic-memory"


def index_path() -> Path:
    return acoustic_home() / "index.json"


def _read_index() -> list[dict]:
    try:
        value = json.loads(index_path().read_text(encoding="utf-8"))
        if isinstance(value, list):
            return [entry for entry in value if isinstance(entry, dict)]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        pass
    return []


def _write_index(entries: list[dict]) -> None:
    path = index_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=".index.", suffix=".json", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(entries, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        os.replace(temporary, path)
        path.chmod(0o600)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def entries() -> list[dict]:
    return _read_index()


def template_count() -> int:
    return len(_read_index())


def has_templates(canonical: str = "") -> bool:
    learned = _read_index()
    if not canonical:
        return bool(learned)
    folded = canonical.casefold().strip()
    return any(str(entry.get("canonical", "")).casefold() == folded for entry in learned)


def meaningful_characters(value: str) -> list[str]:
    return [
        character.casefold()
        for character in value
        if not character.isspace()
        and not unicodedata.category(character).startswith("P")
    ]


def _unit_value(unit, name: str, default=None):
    if isinstance(unit, dict):
        return unit.get(name, default)
    return getattr(unit, name, default)


def locate_audio_span(
    transcript: str,
    phrase: str,
    aligned_units: Iterable,
    audio_duration: float,
    padding: float = 0.08,
    character_span: tuple[int, int] | None = None,
) -> tuple[float, float] | None:
    """Project one transcript substring onto forced-alignment timestamps."""
    transcript_folded = transcript.casefold()
    phrase_folded = phrase.casefold().strip()
    if character_span and 0 <= character_span[0] < character_span[1] <= len(transcript):
        start, end = character_span
    else:
        start = transcript_folded.find(phrase_folded)
        if start < 0 or not phrase_folded:
            return None
        end = start + len(phrase_folded)

    transcript_chars: list[str] = []
    transcript_positions: list[int] = []
    for position, character in enumerate(transcript):
        normalized = meaningful_characters(character)
        for item in normalized:
            transcript_chars.append(item)
            transcript_positions.append(position)
    selected = [
        index
        for index, position in enumerate(transcript_positions)
        if start <= position < end
    ]
    if not selected:
        return None
    selected_start, selected_end = min(selected), max(selected) + 1

    aligned_chars: list[str] = []
    aligned_times: list[tuple[float, float]] = []
    for unit in aligned_units:
        unit_text = str(_unit_value(unit, "text", ""))
        try:
            unit_start = float(_unit_value(unit, "start_time", 0.0))
            unit_end = float(_unit_value(unit, "end_time", unit_start))
        except (TypeError, ValueError):
            continue
        for character in meaningful_characters(unit_text):
            aligned_chars.append(character)
            aligned_times.append((unit_start, unit_end))
    if not aligned_chars or not aligned_times:
        return None

    import difflib

    matcher = difflib.SequenceMatcher(
        a="".join(transcript_chars),
        b="".join(aligned_chars),
        autojunk=False,
    )
    mapped: list[int] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        if tag != "equal":
            continue
        overlap_start = max(i1, selected_start)
        overlap_end = min(i2, selected_end)
        for transcript_index in range(overlap_start, overlap_end):
            mapped.append(j1 + transcript_index - i1)

    # A mismatched proper noun can have no equal aligned characters. In that
    # case, use its character position only as a bounded fallback; neighboring
    # unchanged text still keeps the estimate local.
    if not mapped:
        denominator = max(len(transcript_chars), 1)
        left = round(selected_start / denominator * len(aligned_chars))
        right = round(selected_end / denominator * len(aligned_chars))
        mapped = list(range(max(0, left), min(len(aligned_chars), max(left + 1, right))))
    if not mapped:
        return None

    span_start = min(aligned_times[index][0] for index in mapped)
    span_end = max(aligned_times[index][1] for index in mapped)
    if span_end <= span_start:
        return None
    return max(0.0, span_start - padding), min(audio_duration, span_end + padding)


def slice_audio(
    audio: np.ndarray,
    sample_rate: int,
    span: tuple[float, float],
) -> np.ndarray:
    start, end = span
    left = max(0, int(round(start * sample_rate)))
    right = min(audio.size, int(round(end * sample_rate)))
    return np.asarray(audio[left:right], dtype=np.float32)


def acoustic_features(audio: np.ndarray, sample_rate: int) -> np.ndarray:
    """Create a compact speaker-normalized frame sequence for DTW matching."""
    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    if sample_rate != 16000:
        samples = librosa.resample(samples, orig_sr=sample_rate, target_sr=16000)
        sample_rate = 16000
    if samples.size < int(sample_rate * 0.12):
        raise ValueError("audio segment is too short for acoustic learning")
    trimmed, _ = librosa.effects.trim(samples, top_db=35)
    if trimmed.size >= int(sample_rate * 0.12):
        samples = trimmed
    peak = float(np.max(np.abs(samples)))
    if peak > 1e-5:
        samples = samples / peak
    mfcc = librosa.feature.mfcc(
        y=samples,
        sr=sample_rate,
        n_mfcc=13,
        n_fft=400,
        win_length=400,
        hop_length=160,
        center=True,
    ).T
    if mfcc.shape[0] < 3:
        raise ValueError("audio segment produced too few feature frames")
    width = min(9, mfcc.shape[0] if mfcc.shape[0] % 2 == 1 else mfcc.shape[0] - 1)
    width = max(3, width)
    delta = librosa.feature.delta(mfcc.T, width=width, mode="nearest").T
    features = np.concatenate((mfcc, delta), axis=1).astype(np.float32)
    mean = features.mean(axis=0, keepdims=True)
    deviation = np.maximum(features.std(axis=0, keepdims=True), 1e-4)
    features = (features - mean) / deviation
    norms = np.maximum(np.linalg.norm(features, axis=1, keepdims=True), 1e-6)
    return features / norms


def dtw_similarity(left: np.ndarray, right: np.ndarray) -> float:
    """Return a conservative 0..1 similarity for two variable-length phrases."""
    first = np.asarray(left, dtype=np.float32)
    second = np.asarray(right, dtype=np.float32)
    if first.ndim != 2 or second.ndim != 2 or not first.size or not second.size:
        return 0.0
    duration_ratio = min(len(first), len(second)) / max(len(first), len(second))
    if duration_ratio < 0.45:
        return 0.0
    costs = np.clip(1.0 - first @ second.T, 0.0, 2.0)
    rows, columns = costs.shape
    accumulated = np.full((rows + 1, columns + 1), np.inf, dtype=np.float32)
    steps = np.zeros((rows + 1, columns + 1), dtype=np.int32)
    accumulated[0, 0] = 0.0
    for row in range(1, rows + 1):
        for column in range(1, columns + 1):
            options = (
                (accumulated[row - 1, column - 1], steps[row - 1, column - 1]),
                (accumulated[row - 1, column], steps[row - 1, column]),
                (accumulated[row, column - 1], steps[row, column - 1]),
            )
            best_cost, best_steps = min(options, key=lambda item: item[0])
            accumulated[row, column] = costs[row - 1, column - 1] + best_cost
            steps[row, column] = best_steps + 1
    mean_cost = float(accumulated[rows, columns]) / max(int(steps[rows, columns]), 1)
    return round(max(0.0, min(1.0, math.exp(-1.8 * mean_cost) * math.sqrt(duration_ratio))), 4)


def enroll(
    canonical: str,
    observed: str,
    audio: np.ndarray,
    sample_rate: int,
    *,
    correction_id: str = "",
    application_class: str = "",
    history_id: str = "",
    start_time: float = 0.0,
    end_time: float = 0.0,
) -> dict:
    canonical = canonical.strip()
    observed = observed.strip()
    if not canonical or not observed:
        raise ValueError("canonical and observed text are required")
    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    features = acoustic_features(samples, sample_rate)
    fingerprint = hashlib.sha256(samples.tobytes()).hexdigest()[:16]
    entry_id = f"{correction_id or 'sample'}-{fingerprint}"
    home = acoustic_home()
    clips = home / "clips"
    feature_dir = home / "features"
    clips.mkdir(parents=True, exist_ok=True)
    feature_dir.mkdir(parents=True, exist_ok=True)
    clip_path = clips / f"{entry_id}.flac"
    feature_path = feature_dir / f"{entry_id}.npz"
    sf.write(clip_path, samples, sample_rate, format="FLAC", subtype="PCM_16")
    np.savez_compressed(feature_path, features=features)
    clip_path.chmod(0o600)
    feature_path.chmod(0o600)

    now = datetime.now(timezone.utc).isoformat()
    learned = [entry for entry in _read_index() if entry.get("id") != entry_id]
    entry = {
        "id": entry_id,
        "correction_id": correction_id,
        "canonical": canonical,
        "observed": observed,
        "application_class": application_class,
        "history_id": history_id,
        "clip_path": str(clip_path),
        "feature_path": str(feature_path),
        "feature_version": FEATURE_VERSION,
        "sample_rate": sample_rate,
        "duration_ms": round(samples.size / sample_rate * 1000),
        "start_time": round(start_time, 3),
        "end_time": round(end_time, 3),
        "created_at": now,
    }
    learned.insert(0, entry)

    kept: list[dict] = []
    term_counts: dict[str, int] = {}
    for item in learned:
        key = str(item.get("canonical", "")).casefold()
        if term_counts.get(key, 0) >= MAX_TEMPLATES_PER_TERM or len(kept) >= MAX_TEMPLATES:
            for field in ("clip_path", "feature_path"):
                try:
                    Path(str(item.get(field, ""))).unlink()
                except (FileNotFoundError, OSError):
                    pass
            continue
        term_counts[key] = term_counts.get(key, 0) + 1
        kept.append(item)
    _write_index(kept)
    return entry


def match(canonical: str, audio: np.ndarray, sample_rate: int) -> dict:
    query = acoustic_features(audio, sample_rate)
    folded = canonical.casefold().strip()
    scores: list[tuple[float, dict]] = []
    for entry in _read_index():
        if str(entry.get("canonical", "")).casefold() != folded:
            continue
        if entry.get("feature_version") != FEATURE_VERSION:
            continue
        try:
            with np.load(str(entry["feature_path"])) as payload:
                reference = payload["features"]
            scores.append((dtw_similarity(reference, query), entry))
        except (FileNotFoundError, KeyError, OSError, ValueError):
            continue
    if not scores:
        return {"score": 0.0, "templates": 0, "confirmed": False}
    scores.sort(key=lambda item: item[0], reverse=True)
    best_score, best_entry = scores[0]
    return {
        "score": round(best_score, 4),
        "templates": len(scores),
        "confirmed": best_score >= AUDIO_CONFIRM_THRESHOLD,
        "template_id": str(best_entry.get("id", "")),
    }
