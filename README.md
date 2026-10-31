# TouchHop

**Touch your screen. Your cursor follows.**

[简体中文](README.zh-CN.md)

TouchHop is a small native macOS app that maps an external touchscreen's absolute mouse input to the display you select. Touching that display moves the cursor to your finger and sends the corresponding mouse action, even when the cursor started on the Mac's built-in screen.

## Compatibility

This initial version targets one observed USB controller and report format. **It is not a universal touchscreen driver.**

| Item | Current scope |
| --- | --- |
| USB vendor / product | `0x056A` / `0x8191`, advertised as `TOUCH` |
| Interface | USB Generic Desktop / Mouse, with absolute X/Y |
| Report format | Report ID `7`, three button bits, 16-bit little-endian X/Y and an 8-bit wheel field |
| Target display | One selected external display, remembered by its display UUID |
| Deployment target | macOS 14.0 or later; earlier supported versions have not been hardware-tested |
| Hardware validation | Apple M4, macOS 27.2, one 2048 × 2730 external touchscreen exposing two mouse interfaces |

On that setup, touching the external screen from the built-in screen was confirmed to move the pointer to the correct position, including checks near the corners and center. App restart also restored the saved binding and enabled state. Other controllers, Intel hardware, and other macOS versions remain unverified.

The app reads the device's declared coordinate limits instead of assuming the tested screen's resolution. The current settings UI is in Simplified Chinese.

## Features

- Direct touch-to-cursor positioning across displays.
- Single-finger press/release and dragging, with mouse click-count handling for double-clicks.
- Optional 90°, 180°, and 270° coordinate rotation.
- Saved target display, rotation, and enabled state.
- Exclusive access to the matching touch mouse interfaces, preventing macOS from also mapping the same input to the wrong display.
- A visible settings window with permission status, interface count, and input activity.
- No network requests, telemetry, kernel extension, or administrator service.

Double-click and dragging are implemented but have not had separate hardware acceptance tests. Multitouch gestures, scrolling, pen input, and arbitrary HID report layouts are not implemented.

## Build

Install Apple's Xcode Command Line Tools if they are not already available:

```sh
xcode-select --install
```

Clone the repository and build with the installed Apple Swift compiler:

```sh
git clone https://github.com/chenyongwei/touchhop.git
cd touchhop
./scripts/build.sh
./scripts/test.sh
```

The output is `build/TouchHop.app`. The build script uses the host architecture (`arm64` or `x86_64`) and a macOS 14.0 deployment target. You can override the architecture with `TOUCHHOP_ARCH`; cross-compilation does not validate that architecture on hardware.

The app is ad-hoc signed for local development. Builds are not Apple-notarized. The build script does not install the app or change system permissions.

To make a distributable development archive:

```sh
ditto -c -k --keepParent build/TouchHop.app build/TouchHop-macos.zip
```

## Use

1. Quit any other touch-mapping app using the same panel.
2. Copy `build/TouchHop.app` to Applications, then open it.
3. Select the target external display.
4. Use **1. 允许鼠标控制** to grant Accessibility / mouse-control access. macOS may label this panel **Device Control and Data Access**. Complete any system authentication yourself.
5. Use **2. 打开输入监控设置** to request Input Monitoring. If macOS asks you to restart the app, do so.
6. Click **启用触控定位** to enable mapping. Place the cursor on the built-in display, then touch an empty area on the external screen to check alignment.
7. If necessary, change the rotation setting and check the corners and center again.

**停用触控定位** disables mapping. Quitting the app also releases the interfaces and any mouse button it is holding. Closing its settings window leaves mapping running; reopening TouchHop brings the settings back.

For login startup, add TouchHop in **System Settings → General → Login Items**. An enabled installation resumes after launch when the saved target display and the required permissions are available.

TouchHop uses a new app identity relative to the earlier local prototype named 外屏触控定位. Its permissions and preferences are separate. Quit the prototype before enabling TouchHop; this repository does not replace or modify an existing installation.

## How it works

TouchHop matches only the configured USB vendor/product and the absolute mouse interface. It takes exclusive access through IOKit, decodes each complete report, converts the position into the selected display's current global bounds, and posts mouse events through Core Graphics. Relative mouse motion, the built-in trackpad, keyboards, and pen/digitizer interfaces are outside this filter.

If the selected display is unavailable, touch is not redirected to the built-in display. Settings are kept in local `UserDefaults`; touch trajectories and keyboard input are not recorded.

## Validation

`./scripts/test.sh` runs 11 deterministic checks for report decoding, liftoff, invalid/truncated report rejection, negative desktop coordinates, edge positions, and rotations. These checks do not open a HID device, request permissions, or post input.

The GitHub Actions workflow builds the app, runs these checks, and uploads a development ZIP. CI does not test physical touch hardware, permissions, or actual login startup.

See [CONTRIBUTING.md](CONTRIBUTING.md) for adding a controller profile.

## License and acknowledgments

TouchHop is available under the [MIT License](LICENSE).

The display identity/enumeration helpers draw on [mac-touchscreen-mapper](https://github.com/markstrom/mac-touchscreen-mapper). Its MIT notice is included in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and the built app. [Touch-Up issue #34](https://github.com/shueber/Touch-Up/issues/34) provides background on panels that send mouse-emulation reports instead of multitouch reports.
