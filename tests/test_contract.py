from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


PLUGIN = Path(__file__).resolve().parents[1]
RUNTIME = PLUGIN / "runtime"


class PluginContractTests(unittest.TestCase):
    @staticmethod
    def write_executable(path: Path, body: str) -> None:
        path.write_text("#!/usr/bin/env bash\nset -e\n" + body, encoding="utf-8")
        path.chmod(0o755)

    def test_manifest_exposes_bootstrap_service_and_bar_widget(self) -> None:
        manifest = json.loads((PLUGIN / "manifest.json").read_text(encoding="utf-8"))
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["id"], "app.localtype.voice-input")
        self.assertEqual(manifest["kinds"], ["service", "bar-widget", "panel"])
        self.assertEqual(manifest["entryPoints"]["service"], "Service.qml")
        self.assertEqual(manifest["entryPoints"]["barWidget"], "Panel.qml")
        self.assertEqual(manifest["entryPoints"]["panel"], "LocalTypeApp.qml")

    def test_service_exposes_bottom_center_dictation_overlay(self) -> None:
        service = (PLUGIN / "Service.qml").read_text(encoding="utf-8")
        overlay = (PLUGIN / "DictationOverlay.qml").read_text(encoding="utf-8")
        self.assertIn("DictationOverlay", service)
        self.assertIn('statusCommand: "overlay-status"', service)
        self.assertIn("anchors.horizontalCenter: parent.horizontalCenter", overlay)
        self.assertIn("anchors.bottom: parent.bottom", overlay)
        self.assertIn("partial_text", overlay)
        self.assertIn('runtimeState.runAction(["cancel"])', overlay)
        self.assertIn('runtimeState.runAction(["toggle"', overlay)
        self.assertIn("mask: Region { item: controlCapsule }", overlay)

    def test_status_fixture_round_trips_as_json(self) -> None:
        fixture = {
            "phase": "idle",
            "service_active": True,
            "backend_ready": True,
            "recording": False,
            "gpu": {"available": True, "name": "Test GPU"},
        }
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "status.json"
            path.write_text(json.dumps(fixture), encoding="utf-8")
            environment = os.environ.copy()
            environment["LOCALTYPE_STATUS_FIXTURE"] = str(path)
            output = subprocess.check_output(
                [str(PLUGIN / "bin/localtypectl"), "status"],
                text=True,
                env=environment,
            )
        self.assertEqual(json.loads(output), fixture)

    def test_state_store_is_atomic_and_preserves_recent_text(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = directory
            subprocess.run(
                [
                    str(RUNTIME / "state.py"),
                    "set",
                    "idle",
                    "--mode",
                    "smart",
                    "--text",
                    "本地听写测试",
                    "--raw-text",
                    "本地听写测试",
                ],
                check=True,
                env=environment,
            )
            output = subprocess.check_output(
                [str(RUNTIME / "state.py"), "show"],
                text=True,
                env=environment,
            )
        state = json.loads(output)
        self.assertEqual(state["status"], "idle")
        self.assertEqual(state["mode"], "smart")
        self.assertEqual(state["last_text"], "本地听写测试")
        self.assertIn("updated_at", state)

    def test_partial_transcript_is_recording_only_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = directory
            subprocess.run(
                [
                    str(RUNTIME / "state.py"),
                    "set",
                    "recording",
                    "--partial-text",
                    "正在实时识别",
                ],
                check=True,
                env=environment,
            )
            recording = json.loads(
                subprocess.check_output(
                    [str(RUNTIME / "state.py"), "show"], text=True, env=environment
                )
            )
            self.assertEqual(recording["partial_text"], "正在实时识别")
            subprocess.run(
                [str(RUNTIME / "state.py"), "set", "processing"],
                check=True,
                env=environment,
            )
            processing = json.loads(
                subprocess.check_output(
                    [str(RUNTIME / "state.py"), "show"], text=True, env=environment
                )
            )
            self.assertNotIn("partial_text", processing)

    def test_terminal_input_never_presses_enter(self) -> None:
        toggle = (RUNTIME / "toggle.sh").read_text(encoding="utf-8")
        normalized = toggle.lower()
        self.assertNotIn("-k enter", normalized)
        self.assertNotIn("-k return", normalized)
        self.assertIn("wl-copy", toggle)
        self.assertIn("-k v", toggle)
        self.assertNotIn("Smart dictation started", toggle)
        self.assertNotIn("Transcribing locally", toggle)
        self.assertIn("app.localtype.voice-input.overlay", toggle)
        self.assertIn('stream_recorder="$script_dir/record_stream.py"', toggle)
        self.assertIn("/stream/cancel", toggle)
        self.assertEqual(toggle.count('"${health_url%/health}/transcribe"'), 1)

    def test_polisher_is_prompt_driven_and_prompt_is_editable_in_app(self) -> None:
        server = (RUNTIME / "server.py").read_text(encoding="utf-8")
        app = (PLUGIN / "LocalTypeApp.qml").read_text(encoding="utf-8")
        self.assertNotIn("POLISH_TRIGGERS", server)
        self.assertNotIn("REQUEST_MARKERS", server)
        self.assertNotIn("REPEATED_DISCOURSE_PATTERN", server)
        self.assertIn("DEFAULT_POLISH_PROMPT", server)
        self.assertIn('settings.get("polish_prompt")', server)
        self.assertIn('"setting-set", "polish_prompt"', app)
        self.assertIn('"setting-reset", "polish_prompt"', app)
        self.assertIn("{context}", app)
        prompt_defaults = (RUNTIME / "prompt_defaults.py").read_text(encoding="utf-8")
        self.assertIn("学习纠错的快捷键是哪个？", prompt_defaults)
        self.assertIn("绝不能回答或执行", prompt_defaults)

    def test_desktop_app_uses_simplified_typeless_navigation(self) -> None:
        app = (PLUGIN / "LocalTypeApp.qml").read_text(encoding="utf-8")
        self.assertIn('{ id: "workspace", label: root.l("Dictate", "听写")', app)
        self.assertIn('{ id: "history", label: root.l("History", "历史")', app)
        self.assertIn('{ id: "dictionary", label: root.l("Dictionary", "词典")', app)
        self.assertIn('onClicked: root.navigate(root.currentPage === "settings" ? "workspace" : "settings")', app)
        self.assertNotIn('if (currentPage === "learning") return learningPage', app)
        self.assertNotIn('if (currentPage === "scenes") return scenesPage', app)
        self.assertNotIn('if (currentPage === "models") return modelsPage', app)
        self.assertIn('else if (requestedPage === "learning") currentPage = "dictionary"', app)
        self.assertIn('Review corrections', app)
        self.assertIn('property bool showAdvanced: false', app)
        self.assertIn('component ShortcutCaptureField: Surface', app)
        self.assertIn('ShortcutInhibitor {', app)
        self.assertIn('enabled: root.shortcutCaptureTarget !== "" || root.shortcutCaptureSaving', app)
        self.assertIn('Keys.onPressed: function(event)', app)
        self.assertIn('acceptedButtons: Qt.AllButtons', app)
        self.assertIn('activeFocusOnTab: true', app)
        self.assertIn('root.completeShortcutCapture', app)
        self.assertNotIn('Apply shortcuts', app)
        self.assertNotIn('应用快捷键', app)

    def test_pipeline_logs_are_readable_through_controller(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_home = Path(directory) / "localtype"
            state_home.mkdir()
            (state_home / "pipeline.jsonl").write_text(
                '{"event":"transcribe","decision":"accepted_polisher_candidate"}\n',
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment["XDG_STATE_HOME"] = directory
            output = subprocess.check_output(
                [str(PLUGIN / "bin/localtypectl"), "logs", "1"],
                text=True,
                env=environment,
            )
        entries = json.loads(output)
        self.assertEqual(entries[0]["event"], "transcribe")
        self.assertEqual(entries[0]["decision"], "accepted_polisher_candidate")

    def test_toggle_script_record_and_terminal_paste_flow(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            runtime = root / "runtime"
            state_home = root / "state"
            log = root / "calls.log"

            self.write_executable(
                fake_bin / "systemctl",
                'if [[ "$*" == *"is-active"* ]]; then [[ "${FAKE_RECORDING:-0}" == 1 ]]; fi\n',
            )
            self.write_executable(fake_bin / "systemd-run", f'printf "systemd-run\\n" >>"{log}"\n')
            self.write_executable(fake_bin / "notify-send", ":\n")
            self.write_executable(
                fake_bin / "curl",
                'if [[ "$*" == *"/transcribe"* ]]; then '
                'printf \'{"raw_text":"测试原文","text":"测试结果"}\'; '
                'else printf \'{"status":"ready"}\'; fi\n',
            )
            self.write_executable(
                fake_bin / "hyprctl",
                'printf \'{"class":"%s"}\' "${FAKE_WINDOW_CLASS:-foot}"\n',
            )
            self.write_executable(fake_bin / "wl-copy", f'cat >"{root / "clipboard.txt"}"\n')
            self.write_executable(fake_bin / "wtype", f'printf "%s\\n" "$*" >>"{log}"\n')

            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:{environment['PATH']}"
            environment["XDG_RUNTIME_DIR"] = str(runtime)
            environment["XDG_STATE_HOME"] = str(state_home)
            environment["FAKE_RECORDING"] = "0"

            subprocess.run([str(RUNTIME / "toggle.sh"), "smart"], check=True, env=environment)
            started = json.loads((state_home / "localtype/status.json").read_text(encoding="utf-8"))
            self.assertEqual(started["status"], "recording")
            self.assertEqual(started["mode"], "smart")

            audio = runtime / "localtype/recording.wav"
            audio.write_bytes(b"RIFF-test")
            environment["FAKE_RECORDING"] = "1"
            subprocess.run([str(RUNTIME / "toggle.sh"), "smart"], check=True, env=environment)

            finished = json.loads((state_home / "localtype/status.json").read_text(encoding="utf-8"))
            self.assertEqual(finished["status"], "idle")
            self.assertEqual(finished["last_text"], "测试结果")
            self.assertEqual((root / "clipboard.txt").read_text(encoding="utf-8"), "测试结果")
            calls = log.read_text(encoding="utf-8")
            self.assertIn("-M ctrl -M shift -k v -m shift -m ctrl", calls)
            self.assertNotIn("enter", calls.lower())

            environment["FAKE_WINDOW_CLASS"] = "chromium"
            environment["FAKE_RECORDING"] = "0"
            subprocess.run([str(RUNTIME / "toggle.sh"), "smart"], check=True, env=environment)
            audio.write_bytes(b"RIFF-test")
            environment["FAKE_RECORDING"] = "1"
            subprocess.run([str(RUNTIME / "toggle.sh"), "smart"], check=True, env=environment)
            calls = log.read_text(encoding="utf-8")
            self.assertIn("-M ctrl -k v -m ctrl", calls)
            browser_history = json.loads(
                (state_home / "localtype/history.json").read_text(encoding="utf-8")
            )
            self.assertEqual(browser_history[0]["application_class"], "chromium")
            self.assertEqual(browser_history[0]["injection_method"], "clipboard_browser")

    def test_dictionary_is_valid_string_mapping(self) -> None:
        dictionary = json.loads((PLUGIN / "config/dictionary.json").read_text(encoding="utf-8"))
        self.assertTrue(dictionary)
        self.assertTrue(all(isinstance(key, str) and isinstance(value, str) for key, value in dictionary.items()))

    def test_desktop_store_supports_history_dictionary_and_scenes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = os.environ.copy()
            environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
            environment["LOCALTYPE_STATE_HOME"] = str(root / "state")
            store = RUNTIME / "store.py"

            subprocess.run(
                [
                    str(store),
                    "history-add",
                    "--mode",
                    "smart",
                    "--application-class",
                    "foot",
                    "--application-title",
                    "Codex",
                    "--scene",
                    "codex",
                    "--raw-text",
                    "测试原文",
                    "--final-text",
                    "测试结果",
                    "--polished",
                ],
                check=True,
                env=environment,
            )
            history = json.loads(
                subprocess.check_output([str(store), "history-list"], text=True, env=environment)
            )
            self.assertEqual(history[0]["application_title"], "Codex")
            self.assertEqual(history[0]["final_text"], "测试结果")
            self.assertEqual(history[0]["injection_method"], "unknown")

            subprocess.run(
                [str(store), "dictionary-set", "欧马奇", "Omarchy"],
                check=True,
                env=environment,
            )
            dictionary = json.loads(
                subprocess.check_output([str(store), "dictionary-list"], text=True, env=environment)
            )
            self.assertTrue(
                any(
                    entry["spoken"] == "欧马奇" and entry["written"] == "Omarchy"
                    for entry in dictionary
                )
            )

            scenes = json.loads(
                subprocess.check_output([str(store), "scenes-list"], text=True, env=environment)
            )
            self.assertEqual(scenes[0]["id"], "codex")
            self.assertFalse(scenes[0]["auto_submit"])

            settings = json.loads(
                subprocess.check_output([str(store), "settings-show"], text=True, env=environment)
            )
            self.assertEqual(settings["language"], "en")
            self.assertEqual(settings["smart_shortcut"], "F9")
            self.assertEqual(settings["raw_shortcut"], "SHIFT + F9")
            self.assertEqual(settings["learn_shortcut"], "CTRL + SHIFT + F9")
            self.assertIn("给我介绍一下这个项目", settings["polish_prompt"])

            subprocess.run(
                [str(store), "setting-set", "polish_prompt", "只修正标点：{context}"],
                check=True,
                env=environment,
            )
            customized = json.loads(
                subprocess.check_output([str(store), "settings-show"], text=True, env=environment)
            )
            self.assertEqual(customized["polish_prompt"], "只修正标点：{context}")
            subprocess.run(
                [str(store), "setting-reset", "polish_prompt"],
                check=True,
                env=environment,
            )
            restored = json.loads(
                subprocess.check_output([str(store), "settings-show"], text=True, env=environment)
            )
            self.assertIn("给我介绍一下这个项目", restored["polish_prompt"])

    def test_shortcuts_are_persisted_and_rendered_into_managed_bindings(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            fake_bin = root / "bin"
            fake_bin.mkdir()
            bindings = root / "bindings.lua"
            bindings.write_text("-- existing bindings\n", encoding="utf-8")
            self.write_executable(
                fake_bin / "hyprctl",
                'if [[ "$1" == "configerrors" ]]; then printf ""; fi\n',
            )
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:/usr/bin"
            environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
            environment["LOCALTYPE_HYPR_BINDINGS"] = str(bindings)
            result = subprocess.run(
                [
                    str(PLUGIN / "bin/localtypectl"),
                    "shortcuts-set",
                    "ctrl + space",
                    "mouse:275",
                    "xf86audiomute",
                ],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            managed = bindings.read_text(encoding="utf-8")
            self.assertIn('o.bind("CTRL + SPACE"', managed)
            self.assertIn('o.bind("mouse:275"', managed)
            self.assertIn('o.bind("XF86AudioMute"', managed)
            self.assertIn("learn-correction", managed)
            settings = json.loads((root / "config/settings.json").read_text(encoding="utf-8"))
            self.assertEqual(settings["smart_shortcut"], "CTRL + SPACE")
            self.assertEqual(settings["raw_shortcut"], "mouse:275")
            self.assertEqual(settings["learn_shortcut"], "XF86AudioMute")

    def test_clear_correction_is_learned_and_updates_vocabulary(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = os.environ.copy()
            environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
            environment["LOCALTYPE_STATE_HOME"] = str(root / "state")
            store = RUNTIME / "store.py"
            subprocess.run(
                [
                    str(store),
                    "history-add",
                    "--mode",
                    "smart",
                    "--application-class",
                    "chromium",
                    "--application-title",
                    "Chromium",
                    "--raw-text",
                    "我正在使用欧码器写代码",
                    "--final-text",
                    "我正在使用欧码器写代码",
                ],
                check=True,
                env=environment,
            )
            proposed = json.loads(
                subprocess.check_output(
                    [
                        str(store),
                        "correction-propose",
                        "--corrected",
                        "我正在使用 Omarchy 写代码",
                        "--application-class",
                        "chromium",
                    ],
                    text=True,
                    env=environment,
                )
            )
            self.assertEqual(proposed[0]["spoken"], "欧码器")
            self.assertEqual(proposed[0]["written"], "Omarchy")
            self.assertEqual(proposed[0]["status"], "learned")
            dictionary_after = json.loads(
                subprocess.check_output([str(store), "dictionary-list"], text=True, env=environment)
            )
            learned = next(item for item in dictionary_after if item["spoken"] == "欧码器")
            self.assertEqual(learned["written"], "Omarchy")
            self.assertTrue(learned["learned"])

            sys_path = os.environ.get("PYTHONPATH", "")
            vocabulary_env = environment.copy()
            vocabulary_env["PYTHONPATH"] = str(RUNTIME) + (os.pathsep + sys_path if sys_path else "")
            vocabulary_env["LOCALTYPE_DICTIONARY"] = str(root / "config/dictionary.json")
            context = subprocess.check_output(
                [
                    "python3",
                    "-c",
                    "from vocabulary import asr_context; print(asr_context('chromium'))",
                ],
                text=True,
                env=vocabulary_env,
            )
            self.assertIn("Omarchy", context)

    def test_contextual_vocabulary_generates_hints_without_blind_replacement(self) -> None:
        script = """
import json
from vocabulary import apply_confident_corrections, asr_context, correction_hints
mapping = {"欧马奇": "Omarchy", "OpenTypeless": "OpenTypeless"}
exact = correction_hints("我正在使用欧马奇写代码", "chromium", mapping)
print(json.dumps({
    "context": asr_context("chromium", mapping),
    "exact": exact,
    "applied": apply_confident_corrections("我正在使用欧马奇写代码", exact),
    "audio_applied": apply_confident_corrections("我正在使用欧码器写代码", {"candidates": [{"source": "欧码器", "target": "Omarchy", "reason": "pinyin", "score": 0.9, "audio_confirmed": True, "apply": True}]}),
    "latin": correction_hints("please open type less now", "chromium", mapping),
}, ensure_ascii=False))
"""
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(RUNTIME)
        result = json.loads(
            subprocess.check_output(["python3", "-c", script], text=True, env=environment)
        )
        self.assertIn("Omarchy", result["context"])
        self.assertNotIn("欧马奇", result["context"])
        self.assertEqual(result["exact"]["candidates"][0]["target"], "Omarchy")
        self.assertIn("Omarchy", result["applied"][0])
        self.assertIn("Omarchy", result["audio_applied"][0])
        self.assertTrue(
            any(item["target"] == "OpenTypeless" for item in result["latin"]["candidates"])
        )
        server = (RUNTIME / "server.py").read_text(encoding="utf-8")
        self.assertNotIn("dictionary_corrected_text.replace", server)
        self.assertIn("correction_hints", server)

    def test_polish_guard_preserves_structured_tokens_and_rejects_drift(self) -> None:
        script = """
import json
from polish_guard import validate_polish_candidate
print(json.dumps([
    validate_polish_candidate(
        "运行 python3 /tmp/check.py --dry-run，版本是 2.13.0。",
        "运行 Python /tmp/other.py，版本是 2.14.0。",
    )[0],
    validate_polish_candidate(
        "这个方案应该可以解决问题。",
        "这个方案应该可以解决问题！",
    )[0],
    validate_polish_candidate(
        "学习纠错的快捷键是哪个？",
        "学习纠错的快捷键是 Ctrl + E。",
    )[0],
    validate_polish_candidate(
        "学习纠错的快捷键是哪个？",
        "学习纠错的快捷键是哪个？",
    )[0],
    validate_polish_candidate(
        "相关的技术原理，给我介绍一下。",
        "相关的技术原理，我介绍一下。",
    )[0],
    validate_polish_candidate(
        "相关的技术原理，给我介绍一下。",
        "相关的技术原理，给我介绍一下。",
    )[0],
], ensure_ascii=False))
"""
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(RUNTIME)
        guarded, accepted, answered_question, preserved_question, answered_request, preserved_request = json.loads(
            subprocess.check_output(["python3", "-c", script], text=True, env=environment)
        )
        self.assertIn("protected_token_changed", guarded)
        self.assertEqual(accepted, [])
        self.assertIn("question_intent_changed", answered_question)
        self.assertIn("question_mark_removed", answered_question)
        self.assertIn("protected_token_introduced", answered_question)
        self.assertEqual(preserved_question, [])
        self.assertIn("request_intent_changed", answered_request)
        self.assertEqual(preserved_request, [])

    def test_split_product_name_is_extracted_as_one_correction(self) -> None:
        script = (
            "from store import correction_candidates; import json; "
            "print(json.dumps(correction_candidates("
            "'请用 open type less 写文档', '请用 OpenTypeless 写文档'"
            "), ensure_ascii=False))"
        )
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(RUNTIME)
        result = json.loads(
            subprocess.check_output(["python3", "-c", script], text=True, env=environment)
        )
        self.assertEqual(result[0]["spoken"], "open type less")
        self.assertEqual(result[0]["written"], "OpenTypeless")

    def test_auto_learning_can_be_disabled_for_review_first_workflows(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = os.environ.copy()
            environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
            environment["LOCALTYPE_STATE_HOME"] = str(root / "state")
            store = RUNTIME / "store.py"
            subprocess.run(
                [str(store), "setting-set", "auto_learn_corrections", "false"],
                check=True,
                env=environment,
            )
            subprocess.run(
                [
                    str(store), "history-add", "--mode", "smart",
                    "--raw-text", "这个方案因该可行",
                    "--final-text", "这个方案因该可行",
                ],
                check=True,
                env=environment,
            )
            proposed = json.loads(
                subprocess.check_output(
                    [str(store), "correction-propose", "--corrected", "这个方案应该可行"],
                    text=True,
                    env=environment,
                )
            )
            self.assertEqual(proposed[0]["status"], "pending")

    def test_acoustic_learning_retains_only_opted_in_recent_audio(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = os.environ.copy()
            environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
            environment["LOCALTYPE_STATE_HOME"] = str(root / "state")
            store = RUNTIME / "store.py"
            recording = root / "recording.wav"
            recording.write_bytes(b"RIFF-localtype-test-audio")
            subprocess.run(
                [str(store), "setting-set", "acoustic_learning", "true"],
                check=True,
                env=environment,
            )
            subprocess.run(
                [
                    str(store), "history-add", "--mode", "smart",
                    "--raw-text", "我在使用泰普勒斯", "--final-text", "我在使用泰普勒斯",
                    "--audio-path", str(recording),
                ],
                check=True,
                env=environment,
            )
            entry = json.loads(
                subprocess.check_output([str(store), "history-list"], text=True, env=environment)
            )[0]
            saved_audio = Path(entry["audio_path"])
            self.assertTrue(saved_audio.is_file())
            self.assertTrue(saved_audio.is_relative_to(root / "state" / "audio" / "recent"))
            subprocess.run(
                [str(store), "setting-set", "acoustic_learning", "false"],
                check=True,
                env=environment,
            )
            self.assertFalse(saved_audio.exists())
            history = json.loads(
                subprocess.check_output([str(store), "history-list"], text=True, env=environment)
            )
            self.assertEqual(history[0]["audio_path"], "")

    def test_acoustic_memory_is_aligned_and_fused_with_text_candidates(self) -> None:
        acoustic = (RUNTIME / "acoustic_memory.py").read_text(encoding="utf-8")
        server = (RUNTIME / "server.py").read_text(encoding="utf-8")
        toggle = (RUNTIME / "toggle.sh").read_text(encoding="utf-8")
        app = (PLUGIN / "LocalTypeApp.qml").read_text(encoding="utf-8")
        self.assertIn("locate_audio_span", acoustic)
        self.assertIn("dtw_similarity", acoustic)
        self.assertIn("MAX_TEMPLATES_PER_TERM", acoustic)
        self.assertIn("Qwen3-ForcedAligner-0.6B", server)
        self.assertIn('"/acoustic/enroll"', server)
        self.assertIn("enrich_acoustic_profile", server)
        self.assertIn('--audio-path "$audio_file"', toggle)
        self.assertIn('root.settings.acoustic_learning === true', app)

    def test_large_rewrites_and_punctuation_are_not_learned(self) -> None:
        script = (
            "from store import correction_candidates; "
            "import json; "
            "print(json.dumps(["
            "correction_candidates('你好。', '你好！'), "
            "correction_candidates('给我介绍一下项目', '请详细说明系统架构和部署方法')"
            "]))"
        )
        environment = os.environ.copy()
        environment["PYTHONPATH"] = str(RUNTIME)
        result = json.loads(
            subprocess.check_output(["python3", "-c", script], text=True, env=environment)
        )
        self.assertEqual(result, [[], []])

    def test_learning_shortcut_copies_selection_in_browser_terminal_and_desktop(self) -> None:
        for application_class, expected_copy in (
            ("chromium", "-M ctrl -k c -m ctrl"),
            ("foot", "-M ctrl -M shift -k c -m shift -m ctrl"),
            ("org.gnome.TextEditor", "-M ctrl -k c -m ctrl"),
        ):
            with self.subTest(application_class=application_class), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                fake_bin = root / "bin"
                fake_bin.mkdir()
                calls = root / "calls.log"
                paste_count = root / "paste-count"
                self.write_executable(
                    fake_bin / "hyprctl",
                    f'printf \'{{"class":"{application_class}","title":"Test app"}}\'\n',
                )
                self.write_executable(
                    fake_bin / "wtype",
                    f'printf "%s\\n" "$*" >>"{calls}"\n',
                )
                self.write_executable(
                    fake_bin / "wl-paste",
                    f'count=$(cat "{paste_count}" 2>/dev/null || printf 0); '
                    f'count=$((count + 1)); printf "%s" "$count" >"{paste_count}"; '
                    'if [[ "$count" == 1 ]]; then printf "old clipboard"; '
                    'else printf "我正在使用 Omarchy 写代码"; fi\n',
                )
                self.write_executable(fake_bin / "wl-copy", f'cat >>"{calls}" || true\n')
                self.write_executable(fake_bin / "notify-send", ":\n")
                self.write_executable(fake_bin / "omarchy-shell", ":\n")
                environment = os.environ.copy()
                environment["PATH"] = f"{fake_bin}:/usr/bin"
                environment["LOCALTYPE_CONFIG_HOME"] = str(root / "config")
                environment["LOCALTYPE_STATE_HOME"] = str(root / "state")
                subprocess.run(
                    [
                        str(RUNTIME / "store.py"),
                        "history-add",
                        "--mode",
                        "smart",
                        "--application-class",
                        application_class,
                        "--raw-text",
                        "我正在使用欧码器写代码",
                        "--final-text",
                        "我正在使用欧码器写代码",
                    ],
                    check=True,
                    env=environment,
                )
                result = subprocess.run(
                    [str(PLUGIN / "bin/localtypectl"), "learn-correction"],
                    text=True,
                    capture_output=True,
                    env=environment,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected_copy, calls.read_text(encoding="utf-8"))
                corrections = json.loads(
                    subprocess.check_output(
                        [str(RUNTIME / "store.py"), "corrections-list"],
                        text=True,
                        env=environment,
                    )
                )
                self.assertEqual(corrections[0]["written"], "Omarchy")

    def test_installer_has_idempotent_managed_integration(self) -> None:
        controller = (PLUGIN / "bin/localtypectl").read_text(encoding="utf-8")
        self.assertIn("LocalType (managed; edit through the plugin)", controller)
        self.assertIn(".requirements.sha256", controller)
        self.assertIn(".bak.localtype-", controller)
        self.assertIn("configured_shortcuts()", controller)
        self.assertIn('"shortcuts-set"', controller)
        self.assertIn('title = "^LocalType$"', controller)
        self.assertIn("size = { 1400, 980 }", controller)
        self.assertIn("localtype.desktop", controller)
        self.assertIn('"open"', controller)
        self.assertIn("LOCALTYPE_ASR_BACKEND", controller)
        self.assertIn("LOCALTYPE_VLLM_MAX_BATCHED_TOKENS", controller)

    def test_streaming_api_keeps_preview_separate_from_final_transcription(self) -> None:
        server = (RUNTIME / "server.py").read_text(encoding="utf-8")
        recorder = (RUNTIME / "record_stream.py").read_text(encoding="utf-8")
        requirements = (PLUGIN / "requirements.txt").read_text(encoding="utf-8")
        self.assertIn('@app.post("/stream/start")', server)
        self.assertIn('@app.post("/stream/chunk")', server)
        self.assertIn('@app.post("/stream/cancel")', server)
        self.assertIn("StreamingSessionRegistry", server)
        self.assertIn('streaming_sessions.start(\n            context=""', server)
        self.assertIn("partial-text", recorder)
        self.assertIn("PUSH_SAMPLES = SAMPLE_RATE // 2", recorder)
        self.assertIn('"/stream/cancel"', recorder)
        self.assertIn("recorder.returncode not in (None, 0) else 1", recorder)
        self.assertTrue(os.access(RUNTIME / "record_stream.py", os.X_OK))
        self.assertIn("vllm==0.14.0", requirements)
        self.assertIn("torch==2.9.1", requirements)

    def test_bootstrap_runs_non_blocking_runtime_setup(self) -> None:
        bootstrap = (PLUGIN / "Service.qml").read_text(encoding="utf-8")
        self.assertIn('[root.ctlPath, "ensure-runtime"]', bootstrap)
        self.assertIn("Process", bootstrap)
        self.assertNotIn("sudo", bootstrap)

    def test_repo_contains_no_user_specific_absolute_path(self) -> None:
        checked = [
            PLUGIN / "Service.qml",
            PLUGIN / "Panel.qml",
            PLUGIN / "LocalTypeState.qml",
            PLUGIN / "LocalTypeApp.qml",
            PLUGIN / "bin/localtypectl",
            PLUGIN / "runtime/server.py",
            PLUGIN / "runtime/state.py",
            PLUGIN / "runtime/store.py",
            PLUGIN / "runtime/vocabulary.py",
            PLUGIN / "runtime/polish_guard.py",
            PLUGIN / "runtime/acoustic_memory.py",
            PLUGIN / "runtime/record_stream.py",
            PLUGIN / "runtime/streaming_sessions.py",
            PLUGIN / "runtime/toggle.sh",
        ]
        for path in checked:
            self.assertNotIn("/home/xinzhang", path.read_text(encoding="utf-8"), path.name)


if __name__ == "__main__":
    unittest.main()
