# Phorganize GUI update — 2026-09-21

## Design contract

Keep the local, single-window photo/video organization workflow and per-window state. Present source and destination together, then organization rules, with the action and progress always outside the scrolling content. Keep common options visible; disclose concurrency settings on demand. Use native controls, semantic colors, localized labels and selectable paths/results. Preserve macOS 13 support, security-scoped bookmarks, file safety, and the Help menu's privacy/support links. No new network access or custom animation.

The chosen 620 × 560 minimum and 760 × 820 default content sizes are project layout decisions, not HIG requirements. Compact windows scroll the form while keeping the action visible.

## Evidence and decisions

Baseline: clean working tree at `0a41991`. The installed app was inspected through a live screenshot and accessibility tree before editing; its binary was not independently matched to that revision. Source confirmed the same large fixed-height folder regions, dense horizontal controls, unnamed mode picker and scrolling action area.

| ID | Evidence / impact | Change | Validation |
| --- | --- | --- | --- |
| GUI-01 | OBSERVATION: source minimum was 900 × 860; fixed 140/170-point folder boxes and one-line option rows reduced flexibility. | Content-sized folder panels; vertically grouped controls; smaller resizable layout. | Rendered English/Japanese at 760 × 820 and 620 × 560; no overlapping controls in inspected states. |
| GUI-02 | OBSERVATION: primary action and progress shared the scrolling content with all results. | Persistent bottom action area; hide idle progress; scrollable, selectable results above it. | Inspected compact renders at top and bottom, including results and progress. |
| GUI-03 | OBSERVATION: move executed immediately through the Return default action despite deleting originals after verification. | Move requests show an explicit explanation and cancel/destructive confirmation. Plain Return is no longer assigned to the main action; Command-Return uses the same request route as the button. | Unit tests establish that a request or cancellation touches no files; invalid/stale requests cannot start processing. Live alert keyboard behavior remains unverified. |
| GUI-04 | OBSERVATION: app actions absent from File menu; empty mode picker label. | Active-scene File commands: Command-O source, Shift-Command-O destination, Command-Return run; named mode picker; system sheet folder selection. | Build/source validation; live menu routing and sheet focus checks blocked. |
| GUI-05 | OBSERVATION: warning text used orange alone within fixed-height overlays; arbitrary file URL drops could reach folder selection. | Wrapping warning text with an icon, readable semantic foreground, selectable full paths; reject non-folder/multiple-item drops with feedback. | Long-path warnings inspected in Dark appearance. Drag/drop execution remains unverified. |
| GUI-06 | OBSERVATION: controls could change displayed settings during an active operation. | Disable folder/rule controls while processing; guard asynchronous folder acceptance; show move-specific progress text. | Unit test verifies selected folders remain unchanged; progress render verifies disabled controls. |

## Apple source ledger

Retrieved 2026-09-21 from current Apple primary sources. HIG HTML was JavaScript-only, so the skill's DocC reader retrieved the official text; no HIG corpus was added to this repository.

- APPLE-HIG: [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos), Best practices: comfortable density, resizable windows, menu access and keyboard shortcuts. These are design recommendations.
- APPLE-HIG: [Buttons](https://developer.apple.com/design/human-interface-guidelines/buttons), Style, Role and macOS Push buttons: system controls, clear hierarchy, destructive/default-role distinction, ellipsis for buttons requiring further input. Applied to native buttons and move confirmation; no mobile target-size rule imposed on desktop controls.
- APPLE-HIG / ACCESSIBILITY: [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility), interaction alternatives, descriptive labels, keyboard access and testing. Semantic labels and visible symbols are implemented; actual VoiceOver task completion is not established.
- APPLE-SDK: [focusedSceneObject(_:)](https://developer.apple.com/documentation/swiftui/view/focusedsceneobject(_:)), official DocC declaration and discussion: available on macOS 13, exposes the active scene's observable state to commands. Used with `@FocusedObject` so each window retains its model.
- Version context: [Apple releases](https://developer.apple.com/news/releases/) listed public macOS 27.0 (26A428) / Xcode 27 (27A266a), September 14, 2026, and macOS 27.2 beta (26B5086k), September 16. No prerelease APIs or custom Liquid Glass work is introduced.

## Verification

Environment: macOS 27.0 (26A428), Xcode 27.0 (27A266a), arm64. Deployment target remains macOS 13. Global keyboard UI mode was read as `2`; it was not changed.

- PASS: Debug Xcode build, scheme Phorganize. Used `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`, derived data `.xcode-derived/hig-build`, ad-hoc signing and the isolated bundle ID `st.rio.phorganize.higpreview`. Production signing and identity in the project were not changed. The App Intents metadata notice is unrelated to compilation.
- PASS: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`: 47 core tests + 14 app tests = 61, zero failures. Three app tests cover the new confirmation/processing guards.
- PASS: `git diff --check` and localized string plist parsing.
- PASS, rendered evidence only: an offscreen AppKit `NSHostingView` harness compiled the actual view source and native controls, with only the model initializer/disclosure initial state substituted for fixtures. Captured PNGs were opened and visually inspected. This does not establish screen-reader behavior, live window interaction, menus or alert focus.
- BLOCKED: after the baseline screenshot, computer-use calls failed with `Sky Computer Use native pipe closed before response`, including retry by isolated bundle ID and a session reset. No alternative desktop automation was used. Live keyboard traversal, menu command routing between windows, folder-sheet focus restoration, actual drag/drop, and move-alert Escape/Return behavior remain to be checked.
- NOT RUN: VoiceOver task execution; macOS 13 runtime; increased contrast, Reduce Transparency and system text-size variations. No custom motion was added, but Reduce Motion runtime comparison was not performed.
- NOT RUN: App Store submission/release validation; this is a GUI change, not a release qualification.

Local ignored evidence folder: `.xcode-derived/hig-evidence/`.

| Artifact | State |
| --- | --- |
| `ja-light.png` | Japanese, Light, empty, 760 × 820 |
| `en-dark-compact.png` | English, Dark, empty, 620 × 560, scroll top |
| `ja-warning.png` | Japanese, Dark, long saved paths / missing bookmarks |
| `en-advanced-compact.png` | English, Light, expanded performance options, 620 × 560, scroll bottom |
| `ja-progress.png` | Japanese, Dark, synthetic progress / disabled controls |
| `ja-results-compact.png` | Japanese, Light, synthetic mixed results, 620 × 560, scroll bottom |
| `build.log`, `tests.log` | Build and test output |
| `Render.swift`, `Views.swift`, `Render.app` | Offscreen fixture harness; not shipped |

All displayed paths and result/progress data in the after-change renders are fixtures. Existing user media and installed app preferences were not changed. At the end of the GUI-only task, no commit, push or installation over `/Applications/Phorganize.app` had been performed. Subsequent release preparation is recorded separately in `app-store-preparation-2026-09-21.md`.

## Remaining interaction checks

On the built app, choose disposable source/destination folders via Command-O and Shift-Command-O; cancel each sheet with Escape and confirm focus returns. Traverse controls with keyboard navigation enabled, expand performance options and adjust steppers. Open two windows with different folders and verify menu commands affect the active window. Try valid folder, file and multiple-item drops. In move mode, Command-Return must open confirmation; Escape must leave originals untouched; plain Return must not start a move from the main form. Perform VoiceOver reading/activation across folders, mode, rules, status, results and confirmation. These are pending checks, not claimed passes.
