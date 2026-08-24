#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${LOCALTYPE_RUNTIME_HOME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/localtype}"
audio_file="$runtime_dir/recording.wav"
mode_file="$runtime_dir/mode"
started_file="$runtime_dir/started_at_ms"
record_unit="localtype-record.service"
requested_mode="${1:-smart}"
health_url="${LOCALTYPE_HEALTH_URL:-http://127.0.0.1:8765/health}"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_cmd="$script_dir/state.py"
store_cmd="$script_dir/store.py"
mkdir -p "$runtime_dir"

record_failure() {
  local code=$?
  "$state_cmd" set error --mode "$requested_mode" --error "听写失败（exit $code）" >/dev/null 2>&1 || true
  exit "$code"
}
trap record_failure ERR

if systemctl --user is-active --quiet "$record_unit"; then
  systemctl --user stop "$record_unit"
  notify-send -a "LocalType" "正在识别…"
  mode=$(cat "$mode_file" 2>/dev/null || printf 'smart')
  "$state_cmd" set processing --mode "$mode"
  focused_window=$(hyprctl activewindow -j)
  focused_class=$(jq -r '.class // ""' <<<"$focused_window")
  focused_title=$(jq -r '.title // ""' <<<"$focused_window")
  case "$focused_class" in
    *[Cc]odex*|com.mitchellh.ghostty|Alacritty|kitty|foot|org.wezfurlong.wezterm) scene="codex" ;;
    *[Cc]hromium*|*chrome*) scene="chromium" ;;
    *[Ss]lack*) scene="slack" ;;
    *[Oo]bsidian*) scene="obsidian" ;;
    *) scene="general" ;;
  esac
  stopped_at_ms=$(date +%s%3N)
  started_at_ms=$(cat "$started_file" 2>/dev/null || printf '%s' "$stopped_at_ms")
  duration_ms=$((stopped_at_ms - started_at_ms))
  processing_started_ms=$(date +%s%3N)

  response=$(curl --fail --silent --show-error \
    --max-time 120 \
    -F "audio=@$audio_file;type=audio/wav" \
    -F "smart=$([[ "$mode" == "smart" ]] && printf true || printf false)" \
    -F "context=$focused_class" \
    "${health_url%/health}/transcribe")
  text=$(jq -r '.text // empty' <<<"$response")
  raw_text=$(jq -r '.raw_text // empty' <<<"$response")
  polished=$(jq -r '.polished // false' <<<"$response")
  processing_ms=$(($(date +%s%3N) - processing_started_ms))

  if [[ -n "$text" ]]; then
    if [[ "$focused_class" =~ ^(com\.mitchellh\.ghostty|Alacritty|kitty|foot|org\.wezfurlong\.wezterm)$ ]]; then
      # Terminal TUIs such as Codex need one bracketed-paste event. Sending the
      # transcript as individual virtual keystrokes can be split into bursts.
      printf '%s' "$text" | wl-copy
      wtype -M ctrl -M shift -k v -m shift -m ctrl
    else
      wtype -- "$text"
    fi
    notify-send -a "LocalType" "$text"
    history_args=(
      history-add --mode "$mode"
      --application-class "$focused_class"
      --application-title "$focused_title"
      --scene "$scene"
      --raw-text "$raw_text"
      --final-text "$text"
      --duration-ms "$duration_ms"
      --processing-ms "$processing_ms"
    )
    [[ "$polished" == "true" ]] && history_args+=(--polished)
    "$store_cmd" "${history_args[@]}"
    "$state_cmd" set idle --mode "$mode" --text "$text" --raw-text "$raw_text" \
      --duration-ms "$duration_ms" --processing-ms "$processing_ms" \
      --application-class "$focused_class" --application-title "$focused_title"
    rm -f "$started_file"
  else
    "$state_cmd" set error --mode "$mode" --error "没有识别到文字"
    notify-send -u critical -a "LocalType" "没有识别到文字"
  fi
else
  if ! curl --fail --silent --max-time 2 "$health_url" >/dev/null; then
    notify-send -u critical -a "LocalType" "模型尚未就绪，请稍后再试"
    exit 1
  fi

  rm -f "$audio_file"
  printf '%s' "$requested_mode" > "$mode_file"
  date +%s%3N > "$started_file"
  systemd-run --user --quiet --collect --unit="$record_unit" \
    /usr/bin/pw-record --rate 16000 --channels 1 --format s16 "$audio_file"
  "$state_cmd" set recording --mode "$requested_mode"
  if [[ "$requested_mode" == "smart" ]]; then
    notify-send -a "LocalType" "开始智能听写，再按 F9 结束"
  else
    notify-send -a "LocalType" "开始原文听写，再按 Shift+F9 结束"
  fi
fi
