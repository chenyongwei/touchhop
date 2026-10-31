# Changelog

## 0.3.0

- Allow ordinary single keys and side-specific modifier keys; default to a solo right Command press/release.
- Preserve normal Command combinations and modifier+mouse gestures by canceling the solo-key action when another input participates.
- Cycle between connected display centers on repeated shortcut presses instead of returning only to the main display.
- Show a temporary enlarged pointer and locator ring after each switch, with a preview button.
- Migrate the former default Control + Option + H binding to right Command on first upgrade, retaining other custom bindings.
- Expand deterministic checks to 52, including modifier tap state, screen cycling, settings migration, and overlay positioning.

## 0.2.0

- Add a configurable global shortcut to move the cursor to the center of the current system main display. The default is Control + Option + H.
- Add shortcut recording, Escape cancellation, reset, conflict feedback, and an independent enabled state, persisted across app restarts.
- Preserve the previous binding when a replacement cannot be registered.
- Release and suppress an active touch contact until liftoff when returning the cursor, preventing immediate movement back to the external display.
- Expand deterministic checks from 11 to 25, covering shortcut persistence/validation and main-display return geometry.

## 0.1.0

- Initial USB absolute-mouse touchscreen mapping for controller `0x056A:0x8191`.
