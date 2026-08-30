#!/usr/bin/env python3
"""Bounded, thread-safe session state for Qwen3-ASR streaming inference."""

from __future__ import annotations

import threading
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable

import numpy as np


@dataclass
class StreamingSession:
    session_id: str
    state: Any
    created_at: float
    last_seen: float
    previous_text: str = ""
    sequence: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)


class StreamingSessionRegistry:
    """Own native Qwen streaming states without exposing them through the API."""

    def __init__(
        self,
        asr_model: Any,
        *,
        ttl_seconds: float = 600,
        max_sessions: int = 2,
        max_audio_seconds: float = 300,
        sample_rate: int = 16000,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.asr_model = asr_model
        self.ttl_seconds = float(ttl_seconds)
        self.max_sessions = int(max_sessions)
        self.max_audio_samples = int(max_audio_seconds * sample_rate)
        self.sample_rate = int(sample_rate)
        self.clock = clock
        self._sessions: dict[str, StreamingSession] = {}
        self._lock = threading.RLock()

    @property
    def available(self) -> bool:
        return getattr(self.asr_model, "backend", "") == "vllm"

    def _expired_ids(self, now: float) -> list[str]:
        return [
            session_id
            for session_id, session in self._sessions.items()
            if now - session.last_seen > self.ttl_seconds
        ]

    def discard_expired(self) -> int:
        now = self.clock()
        with self._lock:
            expired = self._expired_ids(now)
            for session_id in expired:
                self._sessions.pop(session_id, None)
        return len(expired)

    def start(
        self,
        *,
        context: str,
        language: str = "Chinese",
        unfixed_chunk_num: int = 4,
        unfixed_token_num: int = 5,
        chunk_size_sec: float = 1.0,
    ) -> StreamingSession:
        if not self.available:
            raise RuntimeError("the active ASR backend does not support streaming")
        self.discard_expired()
        with self._lock:
            if len(self._sessions) >= self.max_sessions:
                raise RuntimeError("too many active streaming sessions")
            native_state = self.asr_model.init_streaming_state(
                context=context,
                language=language,
                unfixed_chunk_num=unfixed_chunk_num,
                unfixed_token_num=unfixed_token_num,
                chunk_size_sec=chunk_size_sec,
            )
            now = self.clock()
            session = StreamingSession(
                session_id=uuid.uuid4().hex,
                state=native_state,
                created_at=now,
                last_seen=now,
            )
            self._sessions[session.session_id] = session
            return session

    def _get(self, session_id: str) -> StreamingSession:
        self.discard_expired()
        with self._lock:
            session = self._sessions.get(str(session_id))
            if session is None:
                raise KeyError("invalid or expired streaming session")
            session.last_seen = self.clock()
            return session

    def push(self, session_id: str, samples: np.ndarray) -> dict:
        session = self._get(session_id)
        pcm = np.asarray(samples, dtype=np.float32).reshape(-1)
        if pcm.size == 0:
            return self._response(session, decode_ms=0)
        if not np.isfinite(pcm).all():
            raise ValueError("PCM contains non-finite samples")
        with session.lock:
            current_samples = int(session.state.audio_accum.size + session.state.buffer.size)
            if current_samples + pcm.size > self.max_audio_samples:
                raise ValueError("streaming audio exceeds the session duration limit")
            started = time.perf_counter()
            self.asr_model.streaming_transcribe(pcm, session.state)
            decode_ms = round((time.perf_counter() - started) * 1000)
            session.sequence += 1
            session.last_seen = self.clock()
            return self._response(session, decode_ms=decode_ms)

    def finish(self, session_id: str) -> dict:
        session = self._get(session_id)
        with session.lock:
            started = time.perf_counter()
            self.asr_model.finish_streaming_transcribe(session.state)
            decode_ms = round((time.perf_counter() - started) * 1000)
            session.sequence += 1
            response = self._response(session, decode_ms=decode_ms)
        with self._lock:
            self._sessions.pop(session_id, None)
        return response

    def cancel(self, session_id: str) -> bool:
        with self._lock:
            session = self._sessions.pop(str(session_id), None)
        if session is None:
            return False
        # Do not call finish_streaming_transcribe here: cancellation must not
        # launch one last decode, and the final offline pass owns the result.
        with session.lock:
            session.last_seen = self.clock()
        return True

    def status(self) -> dict:
        self.discard_expired()
        with self._lock:
            return {
                "available": self.available,
                "active_sessions": len(self._sessions),
                "max_sessions": self.max_sessions,
                "ttl_seconds": self.ttl_seconds,
            }

    def _response(self, session: StreamingSession, *, decode_ms: int) -> dict:
        text = str(getattr(session.state, "text", "") or "")
        language = str(getattr(session.state, "language", "") or "")
        previous = session.previous_text
        common_prefix = 0
        for old_character, new_character in zip(previous, text):
            if old_character != new_character:
                break
            common_prefix += 1
        session.previous_text = text
        samples = int(session.state.audio_accum.size + session.state.buffer.size)
        return {
            "session_id": session.session_id,
            "sequence": session.sequence,
            "language": language,
            "text": text,
            "revision_start": common_prefix,
            "replaced_suffix": previous[common_prefix:],
            "new_suffix": text[common_prefix:],
            "audio_ms": round(samples / self.sample_rate * 1000),
            "decode_ms": int(decode_ms),
        }
