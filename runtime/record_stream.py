#!/usr/bin/env python3
"""Record one WAV while best-effort streaming raw PCM to LocalType."""

from __future__ import annotations

import argparse
import array
import json
import math
import os
import queue
import selectors
import signal
import subprocess
import sys
import threading
import urllib.error
import urllib.parse
import urllib.request
import wave
from pathlib import Path

SAMPLE_RATE = 16000
CHANNELS = 1
SAMPLE_WIDTH = 2
PUSH_SAMPLES = SAMPLE_RATE // 2
PUSH_BYTES = PUSH_SAMPLES * SAMPLE_WIDTH


class StreamingWorker(threading.Thread):
    def __init__(
        self,
        *,
        base_url: str,
        context: str,
        mode: str,
        state_command: Path,
        session_file: Path,
        stop_event: threading.Event,
    ) -> None:
        super().__init__(name="localtype-streaming", daemon=True)
        self.base_url = base_url.rstrip("/")
        self.context = context[:512]
        self.mode = mode
        self.state_command = state_command
        self.session_file = session_file
        self.stop_event = stop_event
        self.chunks: queue.Queue[bytes | None] = queue.Queue()
        self.session_id = ""
        self.last_text: str | None = None
        self.accepting = True
        self.voice_started = False
        self.pre_roll: bytes | None = None
        self.start_rms = float(os.environ.get("LOCALTYPE_STREAM_START_RMS", "0.006"))

    def enqueue(self, chunk: bytes) -> None:
        if not self.accepting:
            return
        payload = bytes(chunk)
        if not self.voice_started and self.start_rms > 0:
            samples = array.array("h")
            samples.frombytes(payload)
            if sys.byteorder != "little":
                samples.byteswap()
            rms = math.sqrt(sum(value * value for value in samples) / max(1, len(samples))) / 32768
            if rms < self.start_rms:
                self.pre_roll = payload
                return
            self.voice_started = True
            if self.pre_roll is not None:
                self.chunks.put(self.pre_roll)
                self.pre_roll = None
        self.chunks.put(payload)

    def close(self) -> None:
        self.chunks.put(None)

    def _request(
        self,
        path: str,
        *,
        data: bytes,
        content_type: str,
        timeout: float,
    ) -> dict:
        request = urllib.request.Request(
            self.base_url + path,
            data=data,
            method="POST",
            headers={
                "Content-Type": content_type,
                "User-Agent": "LocalType-stream-recorder/1",
            },
        )
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read(1024 * 1024)
        value = json.loads(payload)
        return value if isinstance(value, dict) else {}

    def _start_session(self) -> bool:
        data = urllib.parse.urlencode({"context": self.context}).encode("utf-8")
        try:
            response = self._request(
                "/stream/start",
                data=data,
                content_type="application/x-www-form-urlencoded",
                timeout=4,
            )
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as error:
            print(f"LocalType streaming unavailable; recording continues: {error}", file=sys.stderr)
            return False
        self.session_id = str(response.get("session_id", ""))
        if not self.session_id:
            return False
        self.session_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.session_file.with_name(f".{self.session_file.name}.{os.getpid()}")
        temporary.write_text(self.session_id + "\n", encoding="utf-8")
        os.replace(temporary, self.session_file)
        return True

    def _publish_text(self, text: str) -> None:
        if self.stop_event.is_set() or text == self.last_text:
            return
        self.last_text = text
        subprocess.run(
            [
                str(self.state_command),
                "set",
                "recording",
                "--mode",
                self.mode,
                "--partial-text",
                text,
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
        if self.stop_event.is_set():
            return
        if shutil_which("omarchy-shell"):
            subprocess.run(
                [
                    "omarchy-shell",
                    "-q",
                    "app.localtype.voice-input.overlay",
                    "refresh",
                ],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )

    def run(self) -> None:
        if not self._start_session():
            self.accepting = False
            return
        failures = 0
        try:
            while not self.stop_event.is_set():
                chunk = self.chunks.get()
                if chunk is None or self.stop_event.is_set():
                    break
                query = urllib.parse.urlencode({"session_id": self.session_id})
                try:
                    response = self._request(
                        f"/stream/chunk?{query}",
                        data=chunk,
                        content_type="audio/L16;rate=16000;channels=1",
                        timeout=30,
                    )
                    failures = 0
                    self._publish_text(str(response.get("text", "") or ""))
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError) as error:
                    failures += 1
                    print(f"LocalType streaming chunk failed: {error}", file=sys.stderr)
                    if failures >= 2:
                        break
        finally:
            self.accepting = False
            if self.session_id:
                query = urllib.parse.urlencode({"session_id": self.session_id}).encode("utf-8")
                try:
                    self._request(
                        "/stream/cancel",
                        data=query,
                        content_type="application/x-www-form-urlencoded",
                        timeout=3,
                    )
                except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
                    pass
            self.session_file.unlink(missing_ok=True)


def shutil_which(command: str) -> str | None:
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = Path(directory) / command
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Record and stream LocalType microphone audio")
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", choices=("smart", "raw"), default="smart")
    parser.add_argument("--context", default="")
    parser.add_argument("--health-url", default="http://127.0.0.1:8765/health")
    parser.add_argument("--state-command", required=True)
    parser.add_argument("--session-file", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    session_file = Path(args.session_file)
    session_file.unlink(missing_ok=True)
    stop_event = threading.Event()

    def request_stop(_signum, _frame) -> None:
        stop_event.set()

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    base_url = str(args.health_url).rsplit("/health", 1)[0]
    worker = StreamingWorker(
        base_url=base_url,
        context=str(args.context),
        mode=str(args.mode),
        state_command=Path(args.state_command),
        session_file=session_file,
        stop_event=stop_event,
    )
    recorder = subprocess.Popen(
        [
            "/usr/bin/pw-record",
            "--raw",
            "--rate",
            str(SAMPLE_RATE),
            "--channels",
            str(CHANNELS),
            "--format",
            "s16",
            "-",
        ],
        stdout=subprocess.PIPE,
        bufsize=0,
    )
    if recorder.stdout is None:
        recorder.terminate()
        raise RuntimeError("pw-record did not expose PCM output")
    worker.start()

    pending = bytearray()
    selector = selectors.DefaultSelector()
    selector.register(recorder.stdout, selectors.EVENT_READ)
    requested_stop = False
    try:
        with wave.open(str(output), "wb") as destination:
            destination.setnchannels(CHANNELS)
            destination.setsampwidth(SAMPLE_WIDTH)
            destination.setframerate(SAMPLE_RATE)
            while not stop_event.is_set():
                events = selector.select(timeout=0.2)
                if not events:
                    if recorder.poll() is not None:
                        break
                    continue
                raw = os.read(recorder.stdout.fileno(), 32768)
                if not raw:
                    break
                destination.writeframesraw(raw)
                pending.extend(raw)
                while len(pending) >= PUSH_BYTES:
                    worker.enqueue(pending[:PUSH_BYTES])
                    del pending[:PUSH_BYTES]
            requested_stop = stop_event.is_set()
    finally:
        stop_event.set()
        worker.close()
        selector.close()
        if recorder.poll() is None:
            recorder.terminate()
        try:
            recorder.wait(timeout=2)
        except subprocess.TimeoutExpired:
            recorder.kill()
            recorder.wait(timeout=2)
        worker.join(timeout=4)
        if worker.is_alive() and worker.session_id:
            query = urllib.parse.urlencode({"session_id": worker.session_id}).encode("utf-8")
            try:
                worker._request(
                    "/stream/cancel",
                    data=query,
                    content_type="application/x-www-form-urlencoded",
                    timeout=3,
                )
            except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
                pass
            session_file.unlink(missing_ok=True)

    # SIGTERM is the normal stop path used by the toggle command. An unexpected
    # recorder exit is surfaced so systemd and diagnostics can report it.
    if requested_stop:
        return 0
    return recorder.returncode if recorder.returncode not in (None, 0) else 1


if __name__ == "__main__":
    raise SystemExit(main())
