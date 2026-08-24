#!/usr/bin/env bash
set -euo pipefail

plugin_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runtime_dir="$plugin_dir/runtime"

omarchy plugin validate "$plugin_dir"
/usr/lib/qt6/bin/qmlformat "$plugin_dir/Panel.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/Desktop.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/LocalTypeState.qml" >/dev/null
/usr/lib/qt6/bin/qmlformat "$plugin_dir/Service.qml" >/dev/null
bash -n "$runtime_dir/toggle.sh"
python3 -m py_compile "$runtime_dir/server.py" "$runtime_dir/state.py" "$runtime_dir/store.py" "$plugin_dir/bin/localtypectl"
python3 -m unittest discover -s "$plugin_dir/tests" -v

printf 'LocalType checks passed.\n'
