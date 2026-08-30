#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_dir="$plugin_dir/runtime"

omarchy plugin validate "$plugin_dir"
/usr/lib/qt6/bin/qmlformat "$plugin_dir/Panel.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/LocalTypeApp.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/LocalTypeState.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/Service.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/DictationOverlay.qml" >/dev/null
bash -n "$runtime_dir/toggle.sh"
python3 -m py_compile "$runtime_dir/server.py" "$runtime_dir/state.py" "$runtime_dir/store.py" "$runtime_dir/vocabulary.py" "$runtime_dir/polish_guard.py" "$runtime_dir/record_stream.py" "$runtime_dir/streaming_sessions.py" "$plugin_dir/bin/localtypectl"
test_python=${LOCALTYPE_TEST_PYTHON:-python3}
if [[ -z "${LOCALTYPE_TEST_PYTHON:-}" && -x "$HOME/.local/share/localtype/.venv/bin/python" ]]; then
  test_python="$HOME/.local/share/localtype/.venv/bin/python"
fi
"$test_python" -m unittest discover -s "$plugin_dir/tests" -v

printf 'LocalType checks passed.\n'
