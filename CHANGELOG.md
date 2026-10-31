# Changelog

## 0.5.0

- Group native settings into touchscreen, shortcut, and permission cards, with aligned controls, concise status, expandable connection details, and scrolling.
- Keep the app in the menu bar when settings close, hide its Dock icon, and reopen settings or quit through the TouchHop menu.
- Add menu actions for touch mapping, shortcut toggling, and locator preview, plus Command + W to close settings.
- Replace the yellow locator with an animated rainbow ring and opaque black/white rims for contrast across backgrounds; retain the enlarged pointer, automatic fade, and click-through behavior.
- Respect Reduce Motion by keeping the rainbow ring static.

## 0.4.0

- Restore each screen's last departure position when cycling screens; use the center only when that screen has no position yet.
- Remember positions during normal mouse movement and touchscreen jumps, retaining the enlarged pointer and locator ring.
- Keep one point per physical display in memory only, using relative coordinates across layout, resolution, and connection changes.
- Reject delayed pointer events that would overwrite a newer position, including events queued before a display-layout change.
- Expand deterministic checks to 71, covering independent screen positions, stale events, display identity, resizing, and edge coordinates.

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
