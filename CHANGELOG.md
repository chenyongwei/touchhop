# Changelog

## 0.2.0

- Add a configurable global shortcut to move the cursor to the center of the current system main display. The default is Control + Option + H.
- Add shortcut recording, Escape cancellation, reset, conflict feedback, and an independent enabled state, persisted across app restarts.
- Preserve the previous binding when a replacement cannot be registered.
- Release and suppress an active touch contact until liftoff when returning the cursor, preventing immediate movement back to the external display.
- Expand deterministic checks from 11 to 25, covering shortcut persistence/validation and main-display return geometry.

## 0.1.0

- Initial USB absolute-mouse touchscreen mapping for controller `0x056A:0x8191`.
