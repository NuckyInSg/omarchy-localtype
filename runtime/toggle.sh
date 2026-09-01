#!/usr/bin/env bash
set -euo pipefail

runtime_dir="${LOCALTYPE_RUNTIME_HOME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/localtype}"
audio_file="$runtime_dir/recording.wav"
mode_file="$runtime_dir/mode"
started_file="$runtime_dir/started_at_ms"
stream_session_file="$runtime_dir/stream-session"
review_file="$runtime_dir/review.json"
record_unit="localtype-record.service"
requested_mode="${1:-smart}"
health_url="${LOCALTYPE_HEALTH_URL:-http://127.0.0.1:8765/health}"
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
state_cmd="$script_dir/state.py"
store_cmd="$script_dir/store.py"
stream_recorder="$script_dir/record_stream.py"
settings_json=$($store_cmd settings-show 2>/dev/null || printf '{}')
language=$(jq -r '.language // "en"' <<<"$settings_json")
message() {
  if [[ "$language" == "zh" ]]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}
refresh_overlay() {
  command -v omarchy-shell >/dev/null 2>&1 || return 0
  omarchy-shell -q app.localtype.voice-input.overlay refresh >/dev/null 2>&1 || true
}
cancel_stream() {
  local session_id
  session_id=$(cat "$stream_session_file" 2>/dev/null || true)
  rm -f "$stream_session_file"
  [[ -n "$session_id" ]] || return 0
  curl --fail --silent --max-time 3 \
    --data-urlencode "session_id=$session_id" \
    "${health_url%/health}/stream/cancel" >/dev/null 2>&1 || true
}
mkdir -p "$runtime_dir"

record_failure() {
  local code=$?
  "$state_cmd" set error --mode "$requested_mode" --error "$(message "Dictation failed (exit $code)" "听写失败（exit $code）")" >/dev/null 2>&1 || true
  exit "$code"
}
trap record_failure ERR

if systemctl --user is-active --quiet "$record_unit"; then
  systemctl --user stop "$record_unit"
  cancel_stream
  mode=$(cat "$mode_file" 2>/dev/null || printf 'smart')
  "$state_cmd" set processing --mode "$mode"
  refresh_overlay
  focused_window=$(hyprctl activewindow -j)
  focused_class=$(jq -r '.class // ""' <<<"$focused_window")
  focused_title=$(jq -r '.title // ""' <<<"$focused_window")
  focused_address=$(jq -r '.address // ""' <<<"$focused_window")
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
    # Do not modify the target application yet. The focused target and all
    # transcription metadata are kept until the user confirms the editable
    # overlay; review-commit performs one paste and learns any local post-edit.
    review_tmp="$review_file.tmp.$$"
    jq -n \
      --arg text "$text" --arg raw_text "$raw_text" --arg mode "$mode" \
      --arg application_class "$focused_class" --arg application_title "$focused_title" \
      --arg target_address "$focused_address" --arg scene "$scene" \
      --arg audio_path "$audio_file" --argjson polished "$polished" \
      --argjson duration_ms "$duration_ms" --argjson processing_ms "$processing_ms" \
      '{text:$text,raw_text:$raw_text,mode:$mode,application_class:$application_class,
        application_title:$application_title,target_address:$target_address,scene:$scene,
        audio_path:$audio_path,polished:$polished,duration_ms:$duration_ms,
        processing_ms:$processing_ms}' > "$review_tmp"
    chmod 600 "$review_tmp"
    mv -f "$review_tmp" "$review_file"
    "$state_cmd" set reviewing --mode "$mode" --text "$text" --raw-text "$raw_text" \
      --duration-ms "$duration_ms" --processing-ms "$processing_ms" \
      --application-class "$focused_class" --application-title "$focused_title"
    refresh_overlay
    rm -f "$started_file"
  else
    "$state_cmd" set error --mode "$mode" --error "$(message "No speech was recognized" "没有识别到文字")"
    refresh_overlay
    notify-send -u critical -a "LocalType" "$(message "No speech was recognized" "没有识别到文字")"
  fi
else
  if ! curl --fail --silent --max-time 2 "$health_url" >/dev/null; then
    notify-send -u critical -a "LocalType" "$(message "Models are not ready yet. Please try again shortly." "模型尚未就绪，请稍后再试")"
    exit 1
  fi

  rm -f "$audio_file" "$stream_session_file" "$review_file"
  printf '%s' "$requested_mode" > "$mode_file"
  date +%s%3N > "$started_file"
  focused_window=$(hyprctl activewindow -j)
  focused_class=$(jq -r '.class // ""' <<<"$focused_window")
  systemd-run --user --quiet --collect --unit="$record_unit" \
    /usr/bin/python3 "$stream_recorder" \
    --output "$audio_file" \
    --mode "$requested_mode" \
    --context "$focused_class" \
    --health-url "$health_url" \
    --state-command "$state_cmd" \
    --session-file "$stream_session_file"
  "$state_cmd" set recording --mode "$requested_mode"
  refresh_overlay
fi
