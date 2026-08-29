# LocalType 0.5.0 Design QA

## Test setup

- Product target: selected Typeless-inspired option 2, implemented as the native Omarchy Shell QML panel.
- Source truth: `/home/xinzhang/.codex/generated_images/01a02ea5-7e4f-7591-8000-e38c75327d9a/exec-38a5d946-c7b1-41d8-925d-48ecd346e2b5.png`.
- Render viewport: 1400 × 980 physical pixels at density 1; no viewport normalization was required for implementation captures.
- Tested states: Dictate idle, History with persisted local data, Dictionary with saved terms and correction review, Settings collapsed, and Settings advanced.
- Native runtime: Quickshell offscreen renderer using the installed Omarchy `Commons` and `Ui` modules. The isolated renderer intentionally had no user D-Bus or speech service access, so captures show the offline state.

## Required fidelity surfaces

- Flat Omarchy theme tokens, restrained borders, monospace typography, mint accent, and compact square controls.
- Three primary destinations only: Dictate, History, and Dictionary.
- A single horizontal recording surface with Polished/Verbatim mode selection.
- A compact recent-transcript list with correction and copy actions.
- Dictionary management and correction review in one place.
- Settings behind the gear button, with language, shortcuts, and privacy first; prompt and diagnostics collapsed under Advanced settings.
- No model inventory, GPU telemetry, scene editor, or learning page in the daily navigation.

## Comparison evidence

- Full source reference: `/home/xinzhang/.codex/generated_images/01a02ea5-7e4f-7591-8000-e38c75327d9a/exec-38a5d946-c7b1-41d8-925d-48ecd346e2b5.png`.
- Full Dictate implementation: `qa/typeless-option-2/workspace.png`.
- Focused reference/implementation crops: `qa/typeless-option-2/source-focus.png` and `qa/typeless-option-2/implementation-focus.png`.
- Route captures: `qa/typeless-option-2/history.png`, `dictionary.png`, `settings.png`, and `settings-advanced.png`.

The source and implementation were inspected together at the same target viewport. The implementation intentionally uses four real recent entries instead of the mock's three, omits decorative waveform art, and reports service offline only in the isolated QA renderer.

## Iterations and findings

1. Replaced the six-item sidebar with three top-level destinations and a gear-only Settings entry.
2. Fixed the recording card and recent-row width calculations after the first render exposed right-edge overflow.
3. Rebuilt History as a compact searchable list after comparison showed the previous card/filter treatment remained too administrative.
4. Merged correction review into Dictionary and fixed staged loading so dictionary entries and pending corrections are both retained.
5. Reduced Settings to General and Shortcuts, moved prompt/preload/diagnostics under a collapsed Advanced section, and adjusted spacing so its entry remains visible at 1400 × 980.
6. Added an explicit mint border to the recording action to match the selected visual direction.
7. Verified English-default copy, Simplified Chinese selection, editable shortcuts, correction actions, prompt editing, history controls, and compatibility aliases for old launch payloads.

No P0, P1, or P2 visual or interaction issues remain at the tested viewport. The remaining P3 difference is the omitted decorative waveform from the concept image; the production UI uses the existing Nerd Font microphone icon so it stays native to Omarchy.

final result: passed
