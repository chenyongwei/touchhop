# Contributing

Build and check the app with:

```sh
./scripts/build.sh
./scripts/test.sh
```

The current HID matcher and report parser are intentionally specific to one controller. When adding another controller, provide its USB vendor/product IDs, absolute mouse interface descriptor, report layout, and macOS/architecture information. Add a separate report profile and packet fixtures before enabling that device; a matching vendor/product ID alone does not establish that its byte layout is compatible.

Do not broaden the filter to all mice or digitizers. Built-in pointing devices and unrelated input interfaces must remain outside the matcher. Preserve release of a held mouse button on stop, disconnect, and normal app termination.

For hardware validation, check touch from another display, the target's corners and center, dragging, disconnect/reconnect, and app restart. Describe what was actually tested and keep unverified compatibility explicit.

The automated self-test must remain free of HID access, permission prompts, and synthetic input. Ordinary software changes do not require a physical touchscreen to run the self-test.
