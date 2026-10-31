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
    return TouchPacket(down: bytes[offset] & 1 != 0, x: x, y: y)
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

func displayName(_ id: CGDirectDisplayID) -> String {
    NSScreen.screens.first {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
    }?.localizedName ?? "外接显示器"
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

final class TouchMapper {
    var manager: IOHIDManager?
    var sessions: [Int: PanelSession] = [:]
    var targetUUID = ""
    var rotation = 0
    var running = false
    var reports = 0
    var events = 0
    var invalidReports = 0
    var message = "尚未启用"
    var lastReport = "尚未收到触控数据"
    var activeLocation: Int?
    var isDown = false
    var lastPoint = CGPoint.zero
    var activeBounds = CGRect.zero
    var suppressedLocation: Int?
    var lastClickTime: TimeInterval = 0
    var lastClickPoint = CGPoint(x: -100000, y: -100000)
    var clickCount: Int64 = 1
    let eventSource = CGEventSource(stateID: .hidSystemState)
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
        guard targetBounds() != nil else { message = "所选外屏未连接，未接管触控"; return }
        guard AXIsProcessTrusted() else { message = "需要允许鼠标控制权限"; return }
        guard IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            message = "需要在系统设置中允许输入监控"; return
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
            if mapper.activeLocation == location { mapper.releasePointer() }
            if mapper.suppressedLocation == location { mapper.suppressedLocation = nil }
            mapper.sessions.removeValue(forKey: location)
        }, context)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        let result = IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
        guard result == kIOReturnSuccess else {
            stop()
            message = "无法接管触控接口（\(returnCode(result))），请检查权限或关闭其他触控驱动"
            return
        }
        running = true
        message = "触控定位已启用"
    }

    func connect(_ device: IOHIDDevice) {
        guard let session = PanelSession(device: device, mapper: self) else {
            message = "设备坐标格式与已检查的外屏不符，已忽略该接口"
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
        lastReport = "已收到 \(reports) 份数据，最近报告编号 \(reportID)，长度 \(bytes.count)"
        guard let packet = decodeMouseReport(bytes, reportID: reportID, maxX: session.maxX, maxY: session.maxY) else {
            invalidReports += 1; return
        }
        if let suppressedLocation {
            if session.location == suppressedLocation && !packet.down { self.suppressedLocation = nil }
            return
        }
        guard let bounds = targetBounds() else {
            releasePointer()
            suppressedLocation = packet.down ? session.location : nil
            message = "外屏未连接，触控已暂停"
            return
        }
        if isDown && bounds != activeBounds {
            releasePointer()
            suppressedLocation = packet.down ? session.location : nil
            return
        }
        // The display exposes two USB controller locations. One contact owns the
        // pointer until release, so simultaneous reports cannot create duplicate clicks.
        if let activeLocation, activeLocation != session.location { return }
        let point = mappedPoint(packet, maxX: session.maxX, maxY: session.maxY,
                                bounds: bounds, rotation: rotation)
        if packet.down {
            if !isDown {
                onTouchStart?()
                activeLocation = session.location
                activeBounds = bounds
                let now = ProcessInfo.processInfo.systemUptime
                let close = hypot(point.x - lastClickPoint.x, point.y - lastClickPoint.y) < 6
                clickCount = now - lastClickTime < NSEvent.doubleClickInterval && close ? min(3, clickCount + 1) : 1
                lastClickTime = now
                lastClickPoint = point
                post(.mouseMoved, at: point)
                post(.leftMouseDown, at: point)
                isDown = true
            } else if point != lastPoint {
                post(.leftMouseDragged, at: point)
            }
            lastPoint = point
        } else if isDown {
            lastPoint = point
            releasePointer()
        }
    }

    func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: eventSource, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickCount)
        event.timestamp = mousePositionTimestamp()
        event.post(tap: .cghidEventTap)
        events += 1
    }

    func releasePointer() {
        if isDown { post(.leftMouseUp, at: lastPoint) }
        isDown = false
        activeLocation = nil
    }

    func suspendTouchForCursorReturn() {
        let location = activeLocation
        releasePointer()
        if let location { suppressedLocation = location }
    }

    func stop() {
        running = false
        releasePointer()
        if let m = manager {
            IOHIDManagerUnscheduleFromRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            IOHIDManagerClose(m, 0)
        }
        manager = nil
        sessions.removeAll()
        suppressedLocation = nil
        message = "触控定位已停用，系统恢复原来的触控方式"
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
    var statusItem: NSStatusItem!
    var menuStatus: NSMenuItem!
    var menuTouchToggle: NSMenuItem!
    var menuShortcutToggle: NSMenuItem!
    var statusLabel: NSTextField!
    var dataLabel: NSTextField!
    var toggleButton: NSButton!
    var displayIDs: [CGDirectDisplayID] = []
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
        NSApp.setActivationPolicy(.accessory)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示设置窗口", action: #selector(showWindow), keyEquivalent: ",").target = self
        appMenu.addItem(withTitle: "关闭窗口", action: #selector(closeSettingsWindow), keyEquivalent: "w").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TouchHop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        returnShortcut.onPress = { [weak self] in self?.cycleScreen() }
        shortcutRecorder.onBegin = { [weak self] in
            self?.returnShortcut.pause()
            self?.shortcutStatus.stringValue = "请按单键或组合键；单独修饰键松开后确认，Esc 取消"
        }
        shortcutRecorder.onCancel = { [weak self] in self?.resumeReturnShortcut() }
        shortcutRecorder.onCapture = { [weak self] candidate in
            guard let self else { return false }
            guard let candidate else {
                self.shortcutStatus.stringValue = "此按键暂不支持，请使用普通按键或左右 Command、Control、Option、Shift、Fn"
                return false
            }
            do {
                if self.isShortcutEnabled { try self.returnShortcut.register(candidate) }
                self.savedShortcut = candidate
                self.shortcutRecorder.shortcut = candidate
                defaults.set(try JSONEncoder().encode(candidate), forKey: "returnToMainShortcut")
                self.shortcutStatus.stringValue = self.isShortcutEnabled ? "快捷键已保存：\(candidate.title)" : "快捷键已保存，当前未启用"
                return true
            } catch {
                self.shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? "无法保存快捷键，请重试"
                return false
            }
        }
        resumeReturnShortcut()
    }
    func resumeReturnShortcut() {
        guard isShortcutEnabled else { shortcutStatus.stringValue = "切屏快捷键已停用"; return }
        do {
            try returnShortcut.register(savedShortcut)
            shortcutStatus.stringValue = "快捷键已启用：\(savedShortcut.title)"
        } catch { shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? "无法注册快捷键" }
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
        } catch { shortcutStatus.stringValue = (error as? ShortcutError)?.message ?? "无法恢复默认快捷键" }
    }
    @objc func previewCursorBeacon() {
        if let point = CGEvent(source: nil)?.location { cursorBeacon.show(at: point) }
    }
    func cycleScreen() {
        guard AXIsProcessTrusted() else { shortcutStatus.stringValue = "请先允许鼠标控制权限"; return }
        guard let current = CGEvent(source: nil) else { return }
        let screens = activeCycleScreens()
        let timestamp = mousePositionTimestamp()
        mousePositionTracker.updateScreens(screens, since: timestamp)
        screenPositions.observe(current.location, screens: screens, timestamp: timestamp)
        guard let target = nextScreenDestination(cursor: current.location, screens: screens),
              let destination = screenPositions.destination(for: target) else { return }
        let remembered = screenPositions.hasPosition(for: target)
        if CGEventSource.buttonState(.combinedSessionState, button: .right) ||
           CGEventSource.buttonState(.combinedSessionState, button: .center) ||
           (!mapper.isDown && CGEventSource.buttonState(.combinedSessionState, button: .left)) {
            shortcutStatus.stringValue = "请先松开鼠标按键，再切换屏幕"; return
        }
        mapper.suspendTouchForCursorReturn()
        guard CGWarpMouseCursorPosition(destination) == .success else {
            shortcutStatus.stringValue = "无法移动鼠标，请检查鼠标控制权限"; return
        }
        if let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                               mouseCursorPosition: destination, mouseButton: .left) {
            moved.timestamp = mousePositionTimestamp()
            moved.post(tap: .cghidEventTap)
            screenPositions.observe(destination, screens: screens, timestamp: moved.timestamp)
        }
        cursorBeacon.show(at: destination)
        shortcutStatus.stringValue = remembered ? "已回到上次离开的位置：\(displayName(target.id))" : "尚无位置记录，已定位中央：\(displayName(target.id))"
    }
    func refreshDisplays() {
        mousePositionTracker.updateScreens(activeCycleScreens(), since: mousePositionTimestamp())
        let saved = UserDefaults.standard.string(forKey: "displayUUID")
        displayIDs = externalDisplays()
        displayPicker.removeAllItems()
        for id in displayIDs {
            let b = CGDisplayBounds(id)
            displayPicker.addItem(withTitle: "\(displayName(id)) · \(Int(b.width)) × \(Int(b.height))")
        }
        if let index = displayIDs.firstIndex(where: { uuidForDisplay($0) == saved }) {
            displayPicker.selectItem(at: index)
        } else if saved != nil {
            displayPicker.addItem(withTitle: "先前绑定的外屏未连接")
            displayPicker.selectItem(at: displayIDs.count)
        }
        if displayIDs.isEmpty { displayPicker.addItem(withTitle: "未检测到外接显示器") }
    }
    @objc func displaysChanged() {
        mapper.releasePointer()
        refreshDisplays()
        refreshStatus()
    }
    var selectedUUID: String? {
        let index = displayPicker.indexOfSelectedItem
        return displayIDs.indices.contains(index) ? uuidForDisplay(displayIDs[index]) : nil
    }
    @objc func changeDisplay() {
        if let uuid = selectedUUID { UserDefaults.standard.set(uuid, forKey: "displayUUID") }
        if mapper.running { enable() }
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
        autoStartPending = false
        if mapper.running {
            mapper.stop()
            UserDefaults.standard.set(false, forKey: "enabled")
        } else { enable() }
        refreshStatus()
    }
    func enable() {
        guard let uuid = selectedUUID else { mapper.message = "请先选择已连接的外屏"; return }
        mapper.start(uuid: uuid, rotation: rotationPicker.indexOfSelectedItem * 90)
        if mapper.running {
            UserDefaults.standard.set(uuid, forKey: "displayUUID")
            UserDefaults.standard.set(true, forKey: "enabled")
        }
    }
    func refreshStatus() {
        let control = AXIsProcessTrusted()
        let monitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        controlStateLabel.stringValue = control ? "已允许" : "待允许"
        monitoringStateLabel.stringValue = monitoring ? "已允许" : "待允许"
        controlStateLabel.textColor = control ? .systemGreen : .secondaryLabelColor
        monitoringStateLabel.textColor = monitoring ? .systemGreen : .secondaryLabelColor
        controlPermissionButton.title = control ? "查看设置" : "允许控制"
        monitoringPermissionButton.title = monitoring ? "查看设置" : "允许监控"
        if mapper.running && (!control || !monitoring) { mapper.stop() }
        if isShortcutEnabled && control && monitoring {
            if !mousePositionTracker.isRunning {
                shortcutStatus.stringValue = mousePositionTracker.start() ? "已开始记忆各屏幕离开位置" : "位置记忆尚未启用，请检查输入监控权限"
            }
        } else { mousePositionTracker.stop() }
        if savedShortcut.isSingle && (!control || !monitoring) && returnShortcut.isRegistered {
            returnShortcut.pause()
            shortcutStatus.stringValue = "单键快捷键等待鼠标控制和输入监控权限"
        }
        if control && monitoring && isShortcutEnabled && !shortcutRecorder.recording && !returnShortcut.isRegistered {
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastShortcutRetry > 2 { lastShortcutRetry = now; resumeReturnShortcut() }
        }
        if autoStartPending && control && monitoring && selectedUUID != nil {
            autoStartPending = false
            enable()
        }
        toggleButton.title = mapper.running ? "停用触控定位" : "启用触控定位"
        statusLabel.stringValue = mapper.message
        let needsPermission = !control || !monitoring
        summaryLabel.stringValue = needsPermission ? "● 待授权" : (mapper.running ? "● 运行中" : "● 触控已暂停")
        summaryLabel.textColor = needsPermission ? .systemOrange : (mapper.running ? .systemGreen : .secondaryLabelColor)
        updateStatusItem()
        dataLabel.stringValue = "已连接触控接口：\(mapper.sessions.count) · 已发送操作：\(mapper.events)\n\(mapper.lastReport)"
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
    let origin = TouchPacket(down: true, x: 0, y: 0)
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:0) == b.origin, "top/left edge")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:90) == CGPoint(x:-1,y:-1080), "90 degree transform")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:180) == CGPoint(x:-1,y:1649), "180 degree transform")
    require(mappedPoint(origin,maxX:maxX,maxY:maxY,bounds:b,rotation:270) == CGPoint(x:-2048,y:1649), "270 degree transform")
    let up = decodeMouseReport([7,0,0,0,0,0,0],reportID:7,maxX:maxX,maxY:maxY)!
    require(!up.down, "liftoff decoded")
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
    require(hotkey.title.contains("右 Command"), "side-specific shortcut label")
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
    print("PASS: \(checks) packet, coordinate and shortcut checks; no device opened and no input posted")
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
