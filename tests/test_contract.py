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

    def test_terminal_input_never_presses_enter(self) -> None:
        toggle = (RUNTIME / "toggle.sh").read_text(encoding="utf-8")
        normalized = toggle.lower()
        self.assertNotIn("-k enter", normalized)
        self.assertNotIn("-k return", normalized)
        self.assertIn("wl-copy", toggle)
        self.assertIn("-k v", toggle)

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
            self.assertIn({"spoken": "欧马奇", "written": "Omarchy"}, dictionary)

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
                [str(PLUGIN / "bin/localtypectl"), "shortcuts-set", "ctrl + space", "shift + f8"],
                text=True,
                capture_output=True,
                env=environment,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            managed = bindings.read_text(encoding="utf-8")
            self.assertIn('o.bind("CTRL + SPACE"', managed)
            self.assertIn('o.bind("SHIFT + F8"', managed)
            settings = json.loads((root / "config/settings.json").read_text(encoding="utf-8"))
            self.assertEqual(settings["smart_shortcut"], "CTRL + SPACE")
            self.assertEqual(settings["raw_shortcut"], "SHIFT + F8")

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
            PLUGIN / "runtime/toggle.sh",
        ]
        for path in checked:
            self.assertNotIn("/home/xinzhang", path.read_text(encoding="utf-8"), path.name)


if __name__ == "__main__":
    unittest.main()
