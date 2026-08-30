from __future__ import annotations

import http.server
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

try:
    import numpy as np
except ModuleNotFoundError:  # The lightweight plugin contract runner has no runtime deps.
    np = None


RUNTIME = Path(__file__).resolve().parents[1] / "runtime"
sys.path.insert(0, str(RUNTIME))

from record_stream import PUSH_BYTES, StreamingWorker  # noqa: E402

if np is not None:
    from streaming_sessions import StreamingSessionRegistry  # noqa: E402


class FakeStreamingModel:
    backend = "vllm"

    def __init__(self) -> None:
        self.outputs = ["你好", "你们好", "你们好。"]
        self.finish_calls = 0

    def init_streaming_state(self, **kwargs):
        return SimpleNamespace(
            audio_accum=np.zeros((0,), dtype=np.float32),
            buffer=np.zeros((0,), dtype=np.float32),
            text="",
            language="Chinese",
            chunk_size_sec=kwargs["chunk_size_sec"],
            unfixed_chunk_num=kwargs["unfixed_chunk_num"],
            unfixed_token_num=kwargs["unfixed_token_num"],
        )

    def streaming_transcribe(self, samples, state):
        state.audio_accum = np.concatenate([state.audio_accum, samples])
        state.text = self.outputs.pop(0)
        return state

    def finish_streaming_transcribe(self, state):
        self.finish_calls += 1
        state.text = self.outputs.pop(0) if self.outputs else state.text
        return state


class RecorderWorkerTests(unittest.TestCase):
    def test_leading_silence_is_held_until_voice_starts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            worker = StreamingWorker(
                base_url="http://127.0.0.1:1",
                context="test",
                mode="smart",
                state_command=Path("/bin/true"),
                session_file=Path(directory) / "session",
                stop_event=threading.Event(),
            )
            silence = bytes(PUSH_BYTES)
            voice = (1000).to_bytes(2, "little", signed=True) * (PUSH_BYTES // 2)
            worker.enqueue(silence)
            self.assertTrue(worker.chunks.empty())
            worker.enqueue(voice)
            self.assertEqual(worker.chunks.get_nowait(), silence)
            self.assertEqual(worker.chunks.get_nowait(), voice)

    def test_worker_cancels_native_session_and_removes_session_file(self) -> None:
        requests: list[str] = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length", "0"))
                self.rfile.read(length)
                path = self.path.split("?", 1)[0]
                requests.append(path)
                payload = {"session_id": "test-session"} if path == "/stream/start" else {"status": "cancelled"}
                encoded = json.dumps(payload).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(encoded)))
                self.end_headers()
                self.wfile.write(encoded)

            def log_message(self, _format: str, *_args) -> None:
                return

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server_thread = threading.Thread(target=server.serve_forever, daemon=True)
        server_thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                session_file = Path(directory) / "stream-session"
                stop_event = threading.Event()
                worker = StreamingWorker(
                    base_url=f"http://127.0.0.1:{server.server_port}",
                    context="test",
                    mode="smart",
                    state_command=Path("/bin/true"),
                    session_file=session_file,
                    stop_event=stop_event,
                )
                worker.start()
                deadline = time.monotonic() + 2
                while not session_file.exists() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(session_file.exists())
                stop_event.set()
                worker.close()
                worker.join(timeout=4)
                self.assertFalse(worker.is_alive())
                self.assertFalse(session_file.exists())
                self.assertEqual(requests, ["/stream/start", "/stream/cancel"])
        finally:
            server.shutdown()
            server.server_close()


@unittest.skipIf(np is None, "numpy is installed in the LocalType runtime environment")
class StreamingSessionTests(unittest.TestCase):
    def test_streaming_reports_suffix_revision_without_committing_text(self) -> None:
        model = FakeStreamingModel()
        registry = StreamingSessionRegistry(model, sample_rate=4, max_audio_seconds=10)
        session = registry.start(context="canonical words", chunk_size_sec=1.0)

        first = registry.push(session.session_id, np.ones(4, dtype=np.float32))
        second = registry.push(session.session_id, np.ones(4, dtype=np.float32))

        self.assertEqual(first["text"], "你好")
        self.assertEqual(first["revision_start"], 0)
        self.assertEqual(second["text"], "你们好")
        self.assertEqual(second["revision_start"], 1)
        self.assertEqual(second["replaced_suffix"], "好")
        self.assertEqual(second["new_suffix"], "们好")
        self.assertEqual(second["audio_ms"], 2000)

    def test_cancel_does_not_launch_a_final_streaming_decode(self) -> None:
        model = FakeStreamingModel()
        registry = StreamingSessionRegistry(model)
        session = registry.start(context="")
        self.assertTrue(registry.cancel(session.session_id))
        self.assertFalse(registry.cancel(session.session_id))
        self.assertEqual(model.finish_calls, 0)
        with self.assertRaises(KeyError):
            registry.push(session.session_id, np.ones(2, dtype=np.float32))

    def test_finish_removes_session_and_returns_last_text(self) -> None:
        model = FakeStreamingModel()
        registry = StreamingSessionRegistry(model)
        session = registry.start(context="")
        registry.push(session.session_id, np.ones(2, dtype=np.float32))
        result = registry.finish(session.session_id)
        self.assertEqual(result["text"], "你们好")
        self.assertEqual(model.finish_calls, 1)
        self.assertEqual(registry.status()["active_sessions"], 0)

    def test_duration_and_session_limits_are_enforced(self) -> None:
        model = FakeStreamingModel()
        registry = StreamingSessionRegistry(
            model,
            sample_rate=4,
            max_audio_seconds=1,
            max_sessions=1,
        )
        session = registry.start(context="")
        with self.assertRaises(RuntimeError):
            registry.start(context="second")
        with self.assertRaises(ValueError):
            registry.push(session.session_id, np.ones(5, dtype=np.float32))

    def test_transformers_backend_is_reported_unavailable(self) -> None:
        model = FakeStreamingModel()
        model.backend = "transformers"
        registry = StreamingSessionRegistry(model)
        self.assertFalse(registry.available)
        with self.assertRaises(RuntimeError):
            registry.start(context="")


if __name__ == "__main__":
    unittest.main()
