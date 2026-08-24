# LocalType Desktop Design QA

## Result

passed

## Test setup

- Implementation: native Omarchy Shell QML panel displayed as a centered floating window.
- Viewport: 1400 × 980 physical pixels.
- State: Ristretto theme, service ready, Qwen3-ASR-1.7B and Qwen3-0.6B loaded on an RTX 5070.
- Reference images: generated product mockups for Workspace, History, Dictionary, Scenes, and Models.
- Reference dimensions: 1484–1487 × 1058–1060; each reference was center-cropped after proportional scaling to 1400 × 980 before comparison.
- Evidence directory: local `qa/` captures and side-by-side comparison images (intentionally ignored by Git).

## Required fidelity surfaces

- Ristretto background, foreground, muted, urgent, and accent tokens.
- 300 px sidebar at the tested viewport, persistent model/GPU status card, and six-page navigation.
- Workspace recording surface, mode selection, recent transcript, and F9 action.
- History filters and cards, dictionary editor/table, scene rule editor, model/device status, and settings controls.
- Omarchy-native borders, typography, controls, spacing, window behavior, and dynamic theme inheritance.

## Comparison evidence

- Full Workspace: `qa/workspace-comparison-final-v2.png`
- Focused Workspace content: `qa/workspace-focus-comparison-final-v2.png`
- Full History: `qa/history-comparison-final.png`
- Full Scenes: `qa/scenes-comparison-final.png`
- Final six-page contact sheet: `qa/final-contact-sheet.png`

Each comparison places the normalized reference on the left and the running implementation on the right.

## Iterations and findings

1. Corrected the QML component context and a loader name collision so the desktop panel opens reliably.
2. Added a managed Hyprland rule for an opaque, centered 1400 × 980 floating window.
3. Increased typography and vertical rhythm to match the visual reference while retaining Omarchy design tokens.
4. Corrected History delegate width/height and exposed both polished and original text without clipping.
5. Loaded the latest persisted transcript on Workspace and made its copy action use the visible text.
6. Removed a two-second QML refresh warning found during runtime log inspection.

No P0, P1, or P2 visual or interaction issues remain in the tested viewport. Differences from the mockups are limited to real user data volume and Omarchy's theme-native toggle treatment, both intentional.
