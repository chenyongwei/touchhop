// TouchHop — Touch your screen. Your cursor follows.
// Copyright (c) 2026 chenyongwei. SPDX-License-Identifier: MIT
// See THIRD_PARTY_NOTICES.md for attribution of the display helpers.

import AppKit
import IOKit
import IOKit.hid
import CoreGraphics
import ColorSync
import ApplicationServices
import Carbon

// This utility accepts only the absolute Mouse interface observed on this panel.
// The built-in trackpad, keyboards, digitizer/pen interfaces and other mice are excluded.
let panelVendor = 0x056A
let panelProduct = 0x8191

struct TouchPacket {
    let down: Bool
    let x: Int
    let y: Int
    let wheel: Int32
}

func decodeMouseReport(_ bytes: [UInt8], reportID: UInt32, maxX: Int, maxY: Int) -> TouchPacket? {
    guard reportID == 7 else { return nil }
    let offset: Int
    if bytes.count == 7, bytes[0] == 7 { offset = 1 }
    else if bytes.count == 6 { offset = 0 }
    else { return nil }
    let x = Int(bytes[offset + 1]) | Int(bytes[offset + 2]) << 8
    let y = Int(bytes[offset + 3]) | Int(bytes[offset + 4]) << 8
    guard maxX > 0, maxY > 0, x <= maxX, y <= maxY else { return nil }
    let wheel = Int32(Int8(bitPattern: bytes[offset + 5]))
    return TouchPacket(down: bytes[offset] & 1 != 0, x: x, y: y, wheel: wheel)
}

func mappedPoint(_ p: TouchPacket, maxX: Int, maxY: Int, bounds: CGRect, rotation: Int) -> CGPoint {
    var u = Double(p.x) / Double(maxX)
    var v = Double(p.y) / Double(maxY)
    switch rotation {
    case 90: (u, v) = (1 - v, u)
    case 180: (u, v) = (1 - u, 1 - v)
    case 270: (u, v) = (v, 1 - u)
    default: break
    }
    return CGPoint(x: bounds.minX + u * max(0, bounds.width - 1),
                   y: bounds.minY + v * max(0, bounds.height - 1))
}

func uuidForDisplay(_ id: CGDirectDisplayID) -> String? {
    guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, uuid) as String?
}

func externalDisplays() -> [CGDirectDisplayID] {
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(0, nil, &count) == .success else { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
    return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
}

// Display-side IDs read from the tested panel. Its USB controller uses different IDs.
struct ExternalPanel {
    let uuid: String
    let vendor: UInt32
    let model: UInt32

    static func automaticTarget(in displays: [ExternalPanel]) -> String? {
        let matches = displays.filter { $0.vendor == 0x312B && $0.model == 0x3360 }
        return matches.count == 1 ? matches[0].uuid : nil
    }
}

func displayName(_ id: CGDirectDisplayID) -> String {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName ?? L("display.external")
}

func returnCode(_ code: IOReturn) -> String { String(format: "0x%08X", UInt32(bitPattern: code)) }

final class PanelSession {
    let device: IOHIDDevice
    let location: Int
    let maxX: Int
    let maxY: Int
    let buffer: UnsafeMutablePointer<UInt8>
    weak var mapper: TouchMapper?
    init?(device: IOHIDDevice, mapper: TouchMapper) {
        self.device = device
        self.mapper = mapper
        location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, 0) as? [IOHIDElement] ?? []
        func axis(_ usage: UInt32) -> IOHIDElement? {
            elements.first { IOHIDElementGetUsagePage($0) == 1 && IOHIDElementGetUsage($0) == usage &&
                IOHIDElementGetReportID($0) == 7 && !IOHIDElementIsRelative($0) }
        }
        guard let x = axis(0x30), let y = axis(0x31),
              IOHIDElementGetLogicalMin(x) == 0, IOHIDElementGetLogicalMin(y) == 0,
              IOHIDElementGetLogicalMax(x) > 0, IOHIDElementGetLogicalMax(y) > 0 else { return nil }
        maxX = IOHIDElementGetLogicalMax(x)
        maxY = IOHIDElementGetLogicalMax(y)
        buffer = .allocate(capacity: 64)
        buffer.initialize(repeating: 0, count: 64)
    }
    deinit { buffer.deinitialize(count: 64); buffer.deallocate() }
}

struct PanelEvent {
    let type: CGEventType
    let point: CGPoint
    var clickCount: Int64 = 0
    var verticalPixels: Int32 = 0

    func post(source: CGEventSource?) -> Bool {
        let event: CGEvent?
        if type == .scrollWheel {
            event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1,
                            wheel1: verticalPixels, wheel2: 0, wheel3: 0)
            event?.location = point
        } else {
            event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
        }
        guard let event else { return false }
        event.timestamp = mousePositionTimestamp()
        event.post(tap: .cghidEventTap)
        return true
    }
}

final class TouchMapper {
    var manager: IOHIDManager?
    var sessions: [Int: PanelSession] = [:]
    var targetUUID = ""
    var rotation = 0
    var running = false
    var reports = 0
    var events = 0
    var invalidReports = 0
    var message = L("touch.inactive")
    var lastReport = L("details.no_reports")
    private struct Scroll {
        let location: Int
        let anchor: CGPoint
        var lastWheel: TimeInterval
        var held: Bool
        var released = false
        var muted = false
    }
    private var scroll: Scroll?
    private var pressTimer: Timer?
    private var pressTime: TimeInterval = 0
    var doubleClickInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }
    let sendEvent: (PanelEvent, CGEventSource?) -> Bool
    init(sendEvent: @escaping (PanelEvent, CGEventSource?) -> Bool = { $0.post(source: $1) }) {
        self.sendEvent = sendEvent
    }
    var activeLocation: Int?
    var isDown = false
    var lastPoint = CGPoint.zero
    var activeBounds = CGRect.zero
    var suppressedLocation: Int?
    var lastClickTime: TimeInterval = 0
    var lastClickPoint = CGPoint(x: -100000, y: -100000)
    var clickCount: Int64 = 1
    let eventSource: CGEventSource? = {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return nil }
        // Keep physical key transitions visible while posting touchscreen mouse input.
        // Preserve the system policy for competing mouse and tablet events.
        for state in [CGEventSuppressionState.eventSuppressionStateSuppressionInterval, .eventSuppressionStateRemoteMouseDrag] {
            let filter = source.getLocalEventsFilterDuringSuppressionState(state)
            source.setLocalEventsFilterDuringSuppressionState(filter.union(.permitLocalKeyboardEvents), state: state)
        }
        return source
    }()
    var onTouchStart: (() -> Void)?

    func targetBounds() -> CGRect? {
        guard let id = externalDisplays().first(where: { uuidForDisplay($0) == targetUUID }) else { return nil }
        let b = CGDisplayBounds(id)
        return b.width > 1 && b.height > 1 ? b : nil
    }

    func start(uuid: String, rotation: Int) {
        stop()
        targetUUID = uuid
        self.rotation = rotation
        guard targetBounds() != nil else { message = L("touch.disconnected"); return }
        guard AXIsProcessTrusted() else { message = L("touch.control_required"); return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            message = L("touch.monitoring_required"); return
        }
        let m = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        manager = m
        IOHIDManagerSetDeviceMatching(m, [kIOHIDVendorIDKey: panelVendor,
            kIOHIDProductIDKey: panelProduct, kIOHIDTransportKey: "USB",
            kIOHIDPrimaryUsagePageKey: 1, kIOHIDPrimaryUsageKey: 2] as CFDictionary)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { ctx, result, _, device in
            guard let ctx, result == kIOReturnSuccess else { return }
            Unmanaged<TouchMapper>.fromOpaque(ctx).takeUnretainedValue().connect(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(m, { ctx, _, _, device in
            guard let ctx else { return }
            let mapper = Unmanaged<TouchMapper>.fromOpaque(ctx).takeUnretainedValue()
            let location = (IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey as CFString) as? NSNumber)?.intValue ?? 0
            if mapper.scroll?.location == location { mapper.scroll = nil }
            if mapper.activeLocation == location { mapper.releasePointer() }
            if mapper.suppressedLocation == location { mapper.suppressedLocation = nil }
            mapper.sessions.removeValue(forKey: location)
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            stop()
            message = L("touch.capture_failed", returnCode(result))
            return
        }
        running = true
        message = L("touch.running")
    }

    func connect(_ device: IOHIDDevice) {
        guard let session = PanelSession(device: device, mapper: self) else {
            message = L("touch.unsupported")
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            return
        }
        sessions[session.location] = session
        IOHIDDeviceRegisterInputReportCallback(device, session.buffer, 64, { ctx, result, _, _, reportID, data, length in
            guard let ctx, result == kIOReturnSuccess, length > 0, length <= 64 else { return }
            let session = Unmanaged<PanelSession>.fromOpaque(ctx).takeUnretainedValue()
            session.mapper?.receive(Array(UnsafeBufferPointer(start: data, count: length)),
                                    reportID: reportID, session: session)
        }, Unmanaged.passUnretained(session).toOpaque())
    }

    func receive(_ bytes: [UInt8], reportID: UInt32, session: PanelSession) {
        guard running else { return }
        reports += 1
        lastReport = L("details.report", reports, reportID, bytes.count)
        guard let packet = decodeMouseReport(bytes, reportID: reportID, maxX: session.maxX, maxY: session.maxY) else {
            invalidReports += 1; return
        }
        guard let bounds = targetBounds() else {
            suspendTouchForCursorReturn()
            if packet.down { suppressedLocation = session.location }
            else if session.location == suppressedLocation && packet.wheel == 0 { suppressedLocation = nil }
            if packet.wheel == 0 && !packet.down && scroll?.location == session.location { scroll = nil }
            message = L("touch.paused_disconnected")
            return
        }
        let point = mappedPoint(packet, maxX: session.maxX, maxY: session.maxY,
                                bounds: bounds, rotation: rotation)
        handle(packet, at: point, location: session.location, bounds: bounds, now: ProcessInfo.processInfo.systemUptime)
    }

    func handle(_ packet: TouchPacket, at point: CGPoint, location: Int, bounds: CGRect, now: TimeInterval) {
        if let suppressedLocation {
            if location == suppressedLocation {
                if packet.wheel != 0 {
                    // The firmware can switch from an absolute press to buttonless wheel reports.
                    scroll = Scroll(location: location, anchor: point, lastWheel: now, held: packet.down, muted: true)
                    self.suppressedLocation = nil
                } else if !packet.down { self.suppressedLocation = nil }
            }
            return
        }
        if (activeLocation != nil || scroll != nil) && bounds != activeBounds {
            suspendTouchForCursorReturn()
            activeBounds = bounds
            return
        }

        // Wheel-only reports have no gesture-end bit. Keep one USB owner for a burst,
        // accepting a handoff after silence. A real button release also ends the held tail.
        if let burst = scroll, !burst.held && now - burst.lastWheel >= 0.15 { scroll = nil }
        if packet.wheel != 0 {
            if let burst = scroll, burst.location != location { return }
            if scroll == nil {
                let anchor: CGPoint
                if activeLocation != nil { anchor = lastPoint }
                else if packet.x == 0 && packet.y == 0 && !packet.down {
                    let cursor = CGEvent(source: nil)?.location
                    anchor = cursor.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
                } else { anchor = point }
                onTouchStart?()
                releasePointer()
                lastClickTime = -.infinity
                activeBounds = bounds
                scroll = Scroll(location: location, anchor: anchor, lastWheel: now, held: packet.down)
                post(.mouseMoved, at: anchor)
            }
            scroll?.lastWheel = now
            scroll?.held = packet.down
            scroll?.released = false
            if let burst = scroll, !burst.muted { postWheel(packet.wheel, at: burst.anchor) }
            return
        }
        if let burst = scroll {
            guard burst.location == location else { return }
            if packet.down && burst.released {
                scroll = nil
            } else {
                scroll?.held = packet.down
                scroll?.released = !packet.down
                return
            }
        }
        if let activeLocation, activeLocation != location { return }
        if packet.down {
            if activeLocation == nil {
                onTouchStart?()
                activeLocation = location
                activeBounds = bounds
                lastPoint = point
                pressTime = now
                post(.mouseMoved, at: point)
                // Allow the first finger of a two-finger gesture to land without clicking.
                // A tap commits on release, a drag on movement, and a hold on this timer.
                let timer = Timer(timeInterval: 0.15, repeats: false) { [weak self] _ in self?.commitPress() }
                pressTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            } else if point != lastPoint {
                if !isDown && hypot(point.x - lastPoint.x, point.y - lastPoint.y) < 3 { return }
                commitPress()
                post(.leftMouseDragged, at: point)
                lastPoint = point
            }
        } else if activeLocation != nil {
            commitPress()
            lastPoint = point
            releasePointer()
        }
    }

    private func commitPress() {
        guard activeLocation != nil, !isDown else { return }
        pressTimer?.invalidate()
        pressTimer = nil
        let close = hypot(lastPoint.x - lastClickPoint.x, lastPoint.y - lastClickPoint.y) < 6
        clickCount = pressTime - lastClickTime < doubleClickInterval() && close ? min(3, clickCount + 1) : 1
        lastClickTime = pressTime
        lastClickPoint = lastPoint
        post(.leftMouseDown, at: lastPoint)
        isDown = true
    }

    private func postWheel(_ delta: Int32, at point: CGPoint) {
        // The panel reports positive for a finger moving up. Negative Quartz deltas
        // reveal content farther down the page, so the content follows the fingers.
        deliver(PanelEvent(type: .scrollWheel, point: point, verticalPixels: -8 * delta))
    }

    func post(_ type: CGEventType, at point: CGPoint) {
        deliver(PanelEvent(type: type, point: point, clickCount: clickCount))
    }

    private func deliver(_ event: PanelEvent) {
        if sendEvent(event, eventSource) { events += 1 }
    }

    func releasePointer() {
        pressTimer?.invalidate()
        pressTimer = nil
        if isDown { post(.leftMouseUp, at: lastPoint) }
        isDown = false
        activeLocation = nil
    }

    func suspendTouchForCursorReturn() {
        scroll?.muted = true
        let location = activeLocation
        releasePointer()
        if let location { suppressedLocation = location }
    }

    func stop() {
        running = false
        scroll = nil
        releasePointer()
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, 0)
        }
        manager = nil
        sessions.removeAll()
        suppressedLocation = nil
        message = L("touch.stopped")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let mapper = TouchMapper()
    var window: NSWindow!
    var displayPicker: NSPopUpButton!
    var rotationPicker: NSPopUpButton!
    var summaryLabel: NSTextField!
    var controlStateLabel: NSTextField!
    var monitoringStateLabel: NSTextField!
    var controlPermissionButton: NSButton!
    var monitoringPermissionButton: NSButton!
    var detailsButton: NSButton!
    var loginItemCheckbox: NSButton!
    var loginItemStatus: NSTextField!
    var loginItemSettingsButton: NSButton!
    var loginItemError: String?
    var statusItem: NSStatusItem!
    var menuStatus: NSMenuItem!
    var menuTouchToggle: NSMenuItem!
    var menuShortcutToggle: NSMenuItem!
    var statusLabel: NSTextField!
    var dataLabel: NSTextField!
    var toggleButton: NSButton!
    var selectedUUID: String?
    var timer: Timer?
    var autoStartPending = false
    let returnShortcut = GlobalShortcut()
    var shortcutRecorder: ShortcutRecorderButton!
    var shortcutEnabled: NSButton!
    var shortcutStatus: NSTextField!
    var savedShortcut = KeyboardShortcut.defaultReturn
    var isShortcutEnabled = true
    let cursorBeacon = CursorBeacon()
    var lastShortcutRetry: TimeInterval = 0
    let mousePositionTracker = MousePositionTracker()
    var screenPositions = ScreenPositionMemory()

    func label(_ text: String, size: CGFloat = 14, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }
    func button(_ text: String, action: Selector) -> NSButton {
        NSButton(title: text, target: self, action: action)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["enabled": true])
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("menu.show_settings"), action: #selector(showWindow), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: L("menu.close"), action: #selector(closeSettingsWindow), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("menu.quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        buildSettingsWindow()
        setupStatusItem()
        mousePositionTracker.onPosition = { [weak self] point, timestamp, screens in
            self?.screenPositions.observe(point, screens: screens, timestamp: timestamp)
        }
        mapper.onTouchStart = { [weak self] in self?.mousePositionTracker.captureCurrentPosition() }
        refreshDisplays()
        configureReturnShortcut()
        configureLoginItem()
        showWindow()
        timer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: true) { [weak self] _ in self?.refreshStatus() }
        NotificationCenter.default.addObserver(self, selector: #selector(displaysChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(windowResignedKey),
            name: NSWindow.didResignKeyNotification, object: window)
        // An enabled installation resumes only after the same two system grants exist.
        autoStartPending = UserDefaults.standard.bool(forKey: "enabled")
        refreshStatus()
    }

    @objc func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        if loginItemCheckbox != nil { refreshLoginItem() }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        shortcutRecorder.cancelRecording()
        sender.orderOut(nil)
        return false
    }
    @objc func closeSettingsWindow() { window.performClose(nil) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func configureReturnShortcut() {
        let defaults = UserDefaults.standard
        let decoded = defaults.data(forKey: "returnToMainShortcut").flatMap {
            try? JSONDecoder().decode(KeyboardShortcut.self, from: $0)
        }
        savedShortcut = migratedShortcut(decoded, schema: defaults.integer(forKey: "shortcutSchemaVersion"))
        defaults.set(try? JSONEncoder().encode(savedShortcut), forKey: "returnToMainShortcut")
        defaults.set(3, forKey: "shortcutSchemaVersion")
        isShortcutEnabled = defaults.object(forKey: "returnToMainShortcutEnabled") as? Bool ?? true
        shortcutEnabled.state = isShortcutEnabled ? .on : .off
        shortcutRecorder.shortcut = savedShortcut
        returnShortcut.onPress = { [weak self] duringLeftPress in self?.cycleScreen(duringLeftPress: duringLeftPress) }
        shortcutRecorder.onBegin = { [weak self] in
            self?.returnShortcut.pause()
            self?.shortcutStatus.stringValue = L("shortcut.record_hint")
        }
        shortcutRecorder.onCancel = { [weak self] in self?.resumeReturnShortcut() }
        shortcutRecorder.onCapture = { [weak self] candidate in
            guard let self else { return false }
            guard let candidate else {
                self.shortcutStatus.stringValue = L("shortcut.unsupported")
                return false
            }
            do {
                if self.isShortcutEnabled { try self.returnShortcut.register(candidate) }
                self.savedShortcut = candidate
                self.shortcutRecorder.shortcut = candidate
                defaults.set(try JSONEncoder().encode(candidate), forKey: "returnToMainShortcut")
                self.shortcutStatus.stringValue = self.isShortcutEnabled ? L("shortcut.saved", candidate.title) : L("shortcut.saved_disabled")
                return true
            } catch {
                self.shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? L("shortcut.save_failed")
                return false
            }
        }
        resumeReturnShortcut()
    }
    func resumeReturnShortcut() {
        guard isShortcutEnabled else { shortcutStatus.stringValue = L("shortcut.disabled"); return }
        do {
            try returnShortcut.register(savedShortcut)
            shortcutStatus.stringValue = L("shortcut.active", savedShortcut.title)
        } catch { shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? L("shortcut.register_failed") }
    }
    @objc func windowResignedKey() { shortcutRecorder.cancelRecording() }
    @objc func toggleReturnShortcut() {
        shortcutRecorder.cancelRecording()
        isShortcutEnabled = shortcutEnabled.state == .on
        UserDefaults.standard.set(isShortcutEnabled, forKey: "returnToMainShortcutEnabled")
        if !isShortcutEnabled { returnShortcut.pause(); mousePositionTracker.stop() }
        resumeReturnShortcut()
    }
    @objc func resetReturnShortcut() {
        shortcutRecorder.cancelRecording()
        do {
            let candidate = KeyboardShortcut.defaultReturn
            if isShortcutEnabled { try returnShortcut.register(candidate) }
            savedShortcut = candidate
            shortcutRecorder.shortcut = candidate
            UserDefaults.standard.set(try JSONEncoder().encode(candidate), forKey: "returnToMainShortcut")
            resumeReturnShortcut()
        } catch { shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? L("shortcut.reset_failed") }
    }
    @objc func previewCursorBeacon() {
        if let point = CGEvent(source: nil)?.location { cursorBeacon.show(at: point) }
    }
    func cycleScreen(duringLeftPress: Bool) {
        guard AXIsProcessTrusted() else { shortcutStatus.stringValue = L("shortcut.control_required"); return }
        guard let current = CGEvent(source: nil) else { return }
        let screens = activeCycleScreens()
        let timestamp = mousePositionTimestamp()
        mousePositionTracker.updateScreens(screens, since: timestamp)
        screenPositions.observe(current.location, screens: screens, timestamp: timestamp)
        guard let target = nextScreenDestination(cursor: current.location, screens: screens),
              let destination = screenPositions.destination(for: target) else { return }
        let remembered = screenPositions.hasPosition(for: target)
        if CGEventSource.buttonState(.combinedSessionState, button: .right) ||
           CGEventSource.buttonState(.combinedSessionState, button: .center) {
            shortcutStatus.stringValue = L("shortcut.release_buttons"); return
        }
        let leftDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        guard duringLeftPress == leftDown else { return }
        if leftDown && !mapper.isDown {
            guard !target.bounds.contains(current.location),
                  let landing = mousePositionTracker.windowDrag.destination(near: destination, on: target) else {
                shortcutStatus.stringValue = L("shortcut.release_buttons"); return
            }
            guard CGEventSource.buttonState(.combinedSessionState, button: .left) else { return }
            guard let timestamp = mousePositionTracker.windowDrag.postDrag(to: landing) else {
                shortcutStatus.stringValue = L("shortcut.move_failed"); return
            }
            screenPositions.observe(landing, screens: screens, timestamp: timestamp)
            cursorBeacon.show(at: landing)
            shortcutStatus.stringValue = L("shortcut.window_moved", displayName(target.id))
            return
        }
        mapper.suspendTouchForCursorReturn()
        guard CGWarpMouseCursorPosition(destination) == .success else {
            shortcutStatus.stringValue = L("shortcut.move_failed"); return
        }
        if let moved = CGEvent(mouseEventSource: mapper.eventSource, mouseType: .mouseMoved,
                               mouseCursorPosition: destination, mouseButton: .left) {
            moved.timestamp = mousePositionTimestamp()
            moved.post(tap: .cghidEventTap)
            screenPositions.observe(destination, screens: screens, timestamp: moved.timestamp)
        }
        cursorBeacon.show(at: destination)
        shortcutStatus.stringValue = remembered ? L("shortcut.restored", displayName(target.id)) : L("shortcut.centered", displayName(target.id))
    }
    func refreshDisplays() {
        mousePositionTracker.updateScreens(activeCycleScreens(), since: mousePositionTimestamp())
        let saved = UserDefaults.standard.string(forKey: "displayUUID")
        let displays = externalDisplays().compactMap { id -> (panel: ExternalPanel, title: String)? in
            guard let uuid = uuidForDisplay(id) else { return nil }
            let bounds = CGDisplayBounds(id)
            let panel = ExternalPanel(uuid: uuid, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id))
            return (panel, "\(displayName(id)) · \(Int(bounds.width)) × \(Int(bounds.height))")
        }
        let automatic = ExternalPanel.automaticTarget(in: displays.map { $0.panel })
        let detected = displays.first { $0.panel.uuid == automatic }
        displayPicker.removeAllItems()
        displayPicker.addItem(withTitle: detected.map { L("display.automatic_target", $0.title) } ?? L("display.automatic_wait"))
        for display in displays {
            let item = NSMenuItem(title: display.title, action: nil, keyEquivalent: "")
            item.representedObject = display.panel.uuid
            displayPicker.menu?.addItem(item)
        }
        if let saved {
            if let index = displays.firstIndex(where: { $0.panel.uuid == saved }) {
                displayPicker.selectItem(at: index + 1)
                selectedUUID = saved
            } else {
                displayPicker.addItem(withTitle: L("display.saved_disconnected"))
                displayPicker.lastItem?.isEnabled = false
                displayPicker.selectItem(at: displayPicker.numberOfItems - 1)
                selectedUUID = nil
            }
        } else {
            displayPicker.selectItem(at: 0)
            selectedUUID = automatic
        }
    }
    @objc func displaysChanged() {
        mapper.suspendTouchForCursorReturn()
        mousePositionTracker.windowDrag.reset()
        refreshDisplays()
        if mapper.running && mapper.targetUUID != selectedUUID { mapper.stop() }
        autoStartPending = !mapper.running && UserDefaults.standard.bool(forKey: "enabled")
        refreshStatus()
    }
    @objc func changeDisplay() {
        UserDefaults.standard.set(displayPicker.selectedItem?.representedObject as? String, forKey: "displayUUID")
        displaysChanged()
    }
    @objc func changeRotation() {
        UserDefaults.standard.set(rotationPicker.indexOfSelectedItem * 90, forKey: "rotation")
        if mapper.running { enable() }
    }
    @objc func requestControl() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    @objc func openMonitoring() {
        _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func toggle() {
        if mapper.running || autoStartPending {
            autoStartPending = false
            mapper.stop()
            UserDefaults.standard.set(false, forKey: "enabled")
        } else if selectedUUID == nil {
            UserDefaults.standard.set(true, forKey: "enabled")
            autoStartPending = true
        } else { enable() }
        refreshStatus()
    }
    func enable() {
        guard let uuid = selectedUUID else { mapper.message = L("touch.select_display"); return }
        mapper.start(uuid: uuid, rotation: rotationPicker.indexOfSelectedItem * 90)
        if mapper.running {
            UserDefaults.standard.set(true, forKey: "enabled")
        }
    }
    func refreshStatus() {
        let control = AXIsProcessTrusted()
        let monitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        controlStateLabel.stringValue = control ? L("permissions.allowed") : L("permissions.pending")
        monitoringStateLabel.stringValue = monitoring ? L("permissions.allowed") : L("permissions.pending")
        controlStateLabel.textColor = control ? .systemGreen : .secondaryLabelColor
        monitoringStateLabel.textColor = monitoring ? .systemGreen : .secondaryLabelColor
        controlPermissionButton.title = control ? L("permissions.settings") : L("permissions.allow_control")
        monitoringPermissionButton.title = monitoring ? L("permissions.settings") : L("permissions.allow_monitoring")
        if mapper.running && (!control || !monitoring) { mapper.stop() }
        if isShortcutEnabled && control && monitoring {
            if !mousePositionTracker.isRunning {
                shortcutStatus.stringValue = mousePositionTracker.start() ? L("shortcut.memory_ready") : L("shortcut.memory_failed")
            }
        } else { mousePositionTracker.stop() }
        if savedShortcut.isSingle && (!control || !monitoring) && returnShortcut.isRegistered {
            returnShortcut.pause()
            shortcutStatus.stringValue = L("shortcut.waiting_permissions")
        }
        if control && monitoring && isShortcutEnabled && !shortcutRecorder.recording && !returnShortcut.isRegistered {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShortcutRetry > 2 { lastShortcutRetry = now; resumeReturnShortcut() }
        }
        if autoStartPending && control && monitoring && selectedUUID != nil {
            autoStartPending = false
            enable()
        }
        toggleButton.title = mapper.running || autoStartPending ? L("touch.disable") : L("touch.enable")
        statusLabel.stringValue = autoStartPending && selectedUUID == nil ? (displayPicker.titleOfSelectedItem ?? mapper.message) : mapper.message
        let needsPermission = !control || !monitoring
        summaryLabel.stringValue = needsPermission ? L("summary.permission") : (mapper.running ? L("summary.running") : L("summary.paused"))
        summaryLabel.textColor = needsPermission ? .systemOrange : (mapper.running ? .systemGreen : .secondaryLabelColor)
        updateStatusItem()
        dataLabel.stringValue = L("details.stats", mapper.sessions.count, mapper.events, mapper.lastReport)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return false
    }
    func applicationWillTerminate(_ notification: Notification) {
        cursorBeacon.stop(); mousePositionTracker.stop(); returnShortcut.pause(); mapper.stop()
    }
}

func selfTest() {
    var checks = 0
    func require(_ condition: Bool, _ label: String) {
        guard condition else { fputs("FAIL: \(label)\n", stderr); exit(1) }
        checks += 1
    }
    let monitor = ExternalPanel(uuid: "ordinary", vendor: 0x30AE, model: 0x66C9)
    let touch = ExternalPanel(uuid: "touch", vendor: 0x312B, model: 0x3360)
    let reconnected = ExternalPanel(uuid: "new-port", vendor: touch.vendor, model: touch.model)
    require(ExternalPanel.automaticTarget(in: [monitor, touch]) == touch.uuid, "touch panel on secondary display")
    require(ExternalPanel.automaticTarget(in: [monitor]) == nil, "wait after unplugging touch display")
    require(ExternalPanel.automaticTarget(in: [reconnected, monitor]) == reconnected.uuid, "reconnect on another port")
    require(ExternalPanel.automaticTarget(in: [touch, reconnected]) == nil, "ambiguous panel models require selection")
    let touchSource = TouchMapper().eventSource
    let keyboard = CGEventFilterMask.permitLocalKeyboardEvents
    require(touchSource?.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateSuppressionInterval)
        .contains(keyboard) == true, "physical shortcut remains available immediately after touch")
    require(touchSource?.getLocalEventsFilterDuringSuppressionState(.eventSuppressionStateRemoteMouseDrag)
        .contains(keyboard) == true, "physical shortcut remains available during a touch drag")
    let maxX = 16383, maxY = 9599
    let down: [UInt8] = [7, 1, 0xFF, 0x3F, 0x7F, 0x25, 0]
    let p = decodeMouseReport(down, reportID: 7, maxX: maxX, maxY: maxY)!
    require(p.down && p.x == maxX && p.y == maxY, "descriptor-sized report with ID")
    let noID = decodeMouseReport(Array(down.dropFirst()), reportID: 7, maxX: maxX, maxY: maxY)!
    require(noID.down && noID.x == maxX && noID.y == maxY, "report without leading ID")
    require(decodeMouseReport([7, 1, 0], reportID: 7, maxX: maxX, maxY: maxY) == nil, "truncated packet rejected")
    require(decodeMouseReport(down, reportID: 13, maxX: maxX, maxY: maxY) == nil, "unrelated report rejected")
    require(decodeMouseReport([7,1,255,255,0,0,0], reportID:7,maxX:maxX,maxY:maxY) == nil, "invalid coordinates rejected")
    let b = CGRect(x: -2048, y: -1080, width: 2048, height: 2730)
    let q = mappedPoint(p, maxX:maxX,maxY:maxY,bounds:b,rotation:0)
    require(q == CGPoint(x: -1, y: 1649), "negative desktop origin and bottom/right edge")
    let origin = TouchPacket(down: true, x: 0, y: 0, wheel: 0)
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:0) == b.origin, "top/left edge")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:90) == CGPoint(x:-1,y:-1080), "90 degree transform")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:180) == CGPoint(x:-1,y:1649), "180 degree transform")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:270) == CGPoint(x:-2048,y:1649), "270 degree transform")
    let up = decodeMouseReport([7,0,0,0,0,0,0],reportID:7,maxX:maxX,maxY:maxY)!
    require(!up.down, "liftoff decoded")
    checkPanelScroll(require)
    let hotkey = KeyboardShortcut.defaultReturn
    require(KeyboardShortcut(keyCode: 54, modifiers: 0) == hotkey, "right Command default")
    require(KeyboardShortcut(keyCode: 4, modifiers: 0) != nil, "single ordinary key allowed")
    require(KeyboardShortcut(keyCode: 4, modifiers: UInt32(shiftKey | optionKey)) != nil, "optional combination modifiers")
    require(KeyboardShortcut(keyCode: 55, modifiers: UInt32(cmdKey)) == nil, "modifier key must be standalone")
    require(KeyboardShortcut(keyCode: 53, modifiers: UInt32(cmdKey)) == nil, "Escape remains recorder cancel")
    require(KeyboardShortcut(keyCode: 127, modifiers: UInt32(controlKey)) == nil, "invalid key code rejected")
    require(KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey) | (1 << 30)) == nil, "unknown modifiers rejected")
    let shortcutData = try! JSONEncoder().encode(hotkey)
    require((try? JSONDecoder().decode(KeyboardShortcut.self, from: shortcutData)) == hotkey, "shortcut settings round-trip")
    require((try? JSONDecoder().decode(KeyboardShortcut.self, from: Data("{\"keyCode\":54,\"modifiers\":256}".utf8))) == nil,
            "invalid persisted shortcut rejected")
    require(hotkey.title == L("key.right_command"), "side-specific shortcut label")
    require(KeyboardShortcut(keyCode: 55, modifiers: 0) != hotkey, "left and right Command differ")
    require(KeyboardShortcut(keyCode: 57, modifiers: 0) == nil, "latching Caps Lock not treated as a tap")
    require(KeyboardShortcut(keyCode: 63, modifiers: 0) != nil, "Fn key allowed")
    require(migratedShortcut(.legacyDefault, schema: 0) == hotkey, "old default migrates to right Command")
    require(migratedShortcut(.legacyDefault, schema: 3) == .legacyDefault, "explicit legacy combination preserved after migration")
    let custom = KeyboardShortcut(keyCode: 38, modifiers: 0)!
    require(migratedShortcut(custom, schema: 0) == custom, "custom shortcut preserved")
    require(migratedShortcut(nil, schema: 0) == hotkey, "fresh settings default")
    let primary = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let mainScreen = ScreenDestination(id: 1, bounds: primary)
    let external = ScreenDestination(id: 2, bounds: b)
    let third = ScreenDestination(id: 3, bounds: CGRect(x: 1470, y: 0, width: 1600, height: 900))
    require(nextScreenDestination(cursor: external.center, screens: [mainScreen, external]) == mainScreen, "external to main")
    require(nextScreenDestination(cursor: mainScreen.center, screens: [mainScreen, external]) == external, "main back to external")
    require(nextScreenDestination(cursor: external.center, screens: [mainScreen, external, third]) == third, "three-screen forward cycle")
    require(nextScreenDestination(cursor: third.center, screens: [mainScreen, external, third]) == mainScreen, "screen cycle wraps")
    require(nextScreenDestination(cursor: CGPoint(x: 9000, y: 9000), screens: [mainScreen, external]) == mainScreen, "off-desktop cursor recovers to main")
    require(nextScreenDestination(cursor: .zero, screens: []) == nil, "no screens ignored")
    require(nextScreenDestination(cursor: CGPoint(x: CGFloat.nan, y: 0), screens: [mainScreen]) == nil, "invalid cursor ignored")
    require(nextScreenDestination(cursor: .zero, screens: [ScreenDestination(id: 9, bounds: .null)]) == nil, "invalid screen ignored")
    require(nextScreenDestination(cursor: .zero, screens: [mainScreen])?.center == CGPoint(x: 735, y: 478), "single-screen centering")
    require(cursorBeaconOrigin(cursor: CGPoint(x: -1024, y: 285), mainHeight: 956, panelSize: 180) == CGPoint(x: -1114, y: 581), "beacon external coordinates")
    require(cursorBeaconOrigin(cursor: mainScreen.center, mainHeight: 956, panelSize: 180) == CGPoint(x: 645, y: 388), "beacon main coordinates")

    var physicalCommand = ModifierTapRecognizer(keyCode: 54)
    require(!physicalCommand.flagsChanged(key: 54, flags: CGEventFlags(rawValue: 0x100110)),
            "physical right Command press after touchscreen release")
    require(physicalCommand.flagsChanged(key: 54, flags: CGEventFlags(rawValue: 0x100)),
            "physical right Command release with non-coalesced event flag")
    let rightDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
    let leftDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x08)
    let bothDown = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x18)
    var tap = ModifierTapRecognizer(keyCode: 54)
    require(!tap.flagsChanged(key: 54, flags: rightDown), "modifier press waits for release")
    require(tap.flagsChanged(key: 54, flags: []), "standalone right Command release fires")
    require(!tap.flagsChanged(key: 54, flags: []), "duplicate release does not fire")
    require(!tap.flagsChanged(key: 55, flags: leftDown), "left Command does not arm right Command")
    require(!tap.flagsChanged(key: 55, flags: []), "left Command release ignored")
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    tap.cancel() // A normal key-down (e.g. Command+C) or a mouse gesture cancels the standalone tap.
    require(!tap.flagsChanged(key: 54, flags: []), "Command combination does not switch screens")
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    tap.cancel()
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    require(!tap.flagsChanged(key: 54, flags: []), "duplicate flags cannot rearm a canceled combination")
    _ = tap.flagsChanged(key: 54, flags: bothDown)
    _ = tap.flagsChanged(key: 55, flags: rightDown)
    require(!tap.flagsChanged(key: 54, flags: []), "both Command keys are not a solo tap")
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    _ = tap.flagsChanged(key: 56, flags: CGEventFlags(rawValue: rightDown.rawValue | CGEventFlags.maskShift.rawValue | 0x02))
    _ = tap.flagsChanged(key: 56, flags: rightDown)
    require(!tap.flagsChanged(key: 54, flags: []), "another modifier cancels solo tap")
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    require(!tap.flagsChanged(key: 54, flags: rightDown), "held modifier does not repeat")
    require(tap.flagsChanged(key: 54, flags: []), "new solo tap still works after cancellation")
    var controlTap = ModifierTapRecognizer(keyCode: 62)
    _ = controlTap.flagsChanged(key: 62, flags: CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x2000))
    require(controlTap.flagsChanged(key: 62, flags: []), "right Control single key")
    var fnTap = ModifierTapRecognizer(keyCode: 63)
    _ = fnTap.flagsChanged(key: 63, flags: .maskSecondaryFn)
    require(fnTap.flagsChanged(key: 63, flags: []), "Fn single key")
    _ = tap.flagsChanged(key: 54, flags: rightDown, leftButtonHeld: true)
    tap.mouseEvent(.leftMouseDragged)
    require(tap.flagsChanged(key: 54, flags: []), "modifier tap survives motion in an existing left drag")
    _ = tap.flagsChanged(key: 54, flags: rightDown, leftButtonHeld: true)
    tap.mouseEvent(.leftMouseUp)
    require(!tap.flagsChanged(key: 54, flags: []), "ending the drag cancels its pending modifier tap")
    _ = tap.flagsChanged(key: 54, flags: rightDown)
    tap.mouseEvent(.leftMouseDown)
    tap.mouseEvent(.leftMouseDragged)
    require(!tap.flagsChanged(key: 54, flags: []), "pressing the modifier before the drag remains a mouse chord")

    let grabbedWindow = CGRect(x: 100, y: 120, width: 400, height: 300)
    let grabbedAt = CGPoint(x: 240, y: 134)
    let draggedTo = CGPoint(x: 265, y: 174)
    require(followsWindowDrag(start: grabbedWindow, current: grabbedWindow.offsetBy(dx: 25, dy: 40),
                              from: grabbedAt, to: draggedTo), "window translation follows the grabbed point")
    require(!followsWindowDrag(start: grabbedWindow, current: grabbedWindow,
                               from: grabbedAt, to: draggedTo), "content dragging leaves window bounds unchanged")
    require(!followsWindowDrag(start: grabbedWindow, current: grabbedWindow.insetBy(dx: -25, dy: -40),
                               from: grabbedAt, to: draggedTo), "window resizing is excluded")
    let workArea = CGRect(x: -1200, y: -500, width: 900, height: 600)
    require(windowDragDestination(CGPoint(x: -730, y: -410), cursor: grabbedAt, window: grabbedWindow, visible: workArea)
            == CGPoint(x: -730, y: -410), "window uses the remembered point when it fits")
    require(windowDragDestination(CGPoint(x: -320, y: 90), cursor: grabbedAt, window: grabbedWindow, visible: workArea)
            == CGPoint(x: -560, y: -186), "window fits at the bottom and right while keeping its grab point")
    let oversized = CGRect(x: 0, y: 0, width: 1800, height: 1400)
    require(workArea.contains(windowDragDestination(.zero, cursor: CGPoint(x: 1650, y: 12),
                                                    window: oversized, visible: workArea)),
            "oversized window retains its grab point on the target display")

    let screenA = ScreenDestination(id: 41, bounds: CGRect(x: 0, y: 0, width: 1000, height: 800), identity: "panel-A")
    let screenB = ScreenDestination(id: 42, bounds: CGRect(x: -1200, y: 0, width: 1200, height: 900), identity: "panel-B")
    let pair = [screenA, screenB]
    var memory = ScreenPositionMemory()
    func near(_ point: CGPoint?, _ expected: CGPoint) -> Bool {
        guard let point else { return false }
        return hypot(point.x - expected.x, point.y - expected.y) < 0.000001
    }
    require(memory.destination(for: screenB) == screenB.center, "unvisited screen falls back to center")
    require(!memory.hasPosition(for: screenB), "fallback does not create a false history")
    memory.observe(CGPoint(x: 250, y: 200), screens: pair, timestamp: 10)
    require(near(memory.destination(for: screenA), CGPoint(x: 250, y: 200)), "remember local cursor point")
    memory.observe(CGPoint(x: -900, y: 300), screens: pair, timestamp: 20)
    require(near(memory.destination(for: screenA), CGPoint(x: 250, y: 200)), "direct touch jump preserves departed display")
    require(near(memory.destination(for: screenB), CGPoint(x: -900, y: 300)), "remember destination display independently")
    memory.observe(CGPoint(x: 10, y: 10), screens: pair, timestamp: 5)
    require(near(memory.destination(for: screenA), CGPoint(x: 250, y: 200)), "delayed event cannot overwrite a newer cursor point")
    memory.observe(CGPoint(x: CGFloat.nan, y: 10), screens: pair, timestamp: 100)
    require(near(memory.destination(for: screenA), CGPoint(x: 250, y: 200)), "invalid pointer sample ignored")
    memory.observe(CGPoint(x: 9000, y: 9000), screens: pair, timestamp: 100)
    require(near(memory.destination(for: screenB), CGPoint(x: -900, y: 300)), "off-desktop sample ignored")
    memory.observe(CGPoint(x: 600, y: 480), screens: pair, timestamp: 30)
    require(near(memory.destination(for: screenA), CGPoint(x: 600, y: 480)), "latest point replaces the old point")
    memory.observe(CGPoint(x: -500, y: 450), screens: pair, timestamp: 40)
    memory.observe(CGPoint(x: -800, y: 50), screens: pair, timestamp: 35)
    require(near(memory.destination(for: screenB), CGPoint(x: -500, y: 450)), "arrival timestamp protects target history")
    let movedA = ScreenDestination(id: 41, bounds: CGRect(x: -2000, y: -500, width: 1000, height: 800), identity: "panel-A")
    require(near(memory.destination(for: movedA), CGPoint(x: -1400, y: -20)), "display rearrangement preserves screen-relative point")
    let resizedA = ScreenDestination(id: 141, bounds: CGRect(x: -1000, y: -400, width: 2000, height: 1600), identity: "panel-A")
    require(near(memory.destination(for: resizedA), CGPoint(x: 200, y: 560)), "resizing and reconnection use physical display identity")
    let replacement = ScreenDestination(id: 41, bounds: screenA.bounds, identity: "different-panel")
    require(memory.destination(for: replacement) == replacement.center, "recycled display ID does not inherit another panel's point")
    require(!memory.hasPosition(for: replacement), "physical identities remain independent")
    require(memory.destination(for: ScreenDestination(id: 99, bounds: .null)) == nil, "invalid target geometry rejected")
    let edge = CGPoint(x: 999.999, y: 799.999)
    memory.observe(edge, screens: pair, timestamp: 50)
    require(near(memory.destination(for: screenA), edge), "fractional edge coordinates retained")
    require(screenA.bounds.contains(memory.destination(for: screenA)!), "restored edge remains inside its screen")
    require(ScreenPositionMemory().destination(for: screenA) == screenA.center, "history is session-only")
    memory.observe(CGPoint(x: 500, y: 400), screens: pair, timestamp: 200)
    memory.observe(CGPoint(x: -600, y: 225), screens: pair, timestamp: 150)
    require(near(memory.destination(for: screenB), CGPoint(x: -600, y: 225)), "event ordering is guarded separately per display")
    checkLocalizations(require)
    print("PASS: \(checks) input, coordinate, shortcut and localization checks; no device opened and no input posted")
}

@main
enum TouchHopApplication {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { selfTest(); return }
        if CommandLine.arguments.contains("--list-displays") {
            for id in externalDisplays() { print("\(uuidForDisplay(id) ?? "?") \(CGDisplayBounds(id))") }
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime(delegate) { application.run() }
    }
}
