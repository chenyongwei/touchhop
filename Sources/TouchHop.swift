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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let mapper = TouchMapper()
    var window: NSWindow!
    var displayPicker: NSPopUpButton!
    var rotationPicker: NSPopUpButton!
    var permissionLabel: NSTextField!
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

    func label(_ text: String, size: CGFloat = 14, bold: Bool = false) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        field.widthAnchor.constraint(equalToConstant: 510).isActive = true
        return field
    }
    func button(_ text: String, action: Selector) -> NSButton {
        NSButton(title: text, target: self, action: action)
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "显示设置窗口", action: #selector(showWindow), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 TouchHop", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 740),
            styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "TouchHop"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 15
        stack.edgeInsets = NSEdgeInsets(top: 26, left: 28, bottom: 24, right: 28)
        stack.addArrangedSubview(label("点外屏，鼠标直接到对应位置", size: 21, bold: true))
        stack.addArrangedSubview(label("专用于当前 TOUCH 外屏。支持点按、双击和单指拖动；普通鼠标和 Mac 触控板照常使用。"))
        displayPicker = NSPopUpButton()
        displayPicker.target = self
        displayPicker.action = #selector(changeDisplay)
        displayPicker.widthAnchor.constraint(equalToConstant: 510).isActive = true
        stack.addArrangedSubview(label("触控目标屏幕", bold: true))
        stack.addArrangedSubview(displayPicker)
        rotationPicker = NSPopUpButton()
        rotationPicker.addItems(withTitles: ["方向正常（0°）", "顺时针 90°", "旋转 180°", "逆时针 90°"])
        rotationPicker.target = self
        rotationPicker.action = #selector(changeRotation)
        rotationPicker.selectItem(at: UserDefaults.standard.integer(forKey: "rotation") / 90)
        stack.addArrangedSubview(rotationPicker)
        permissionLabel = label("")
        stack.addArrangedSubview(permissionLabel)
        let permissionButtons = NSStackView(views: [
            button("1. 允许鼠标控制", action: #selector(requestControl)),
            button("2. 打开输入监控设置", action: #selector(openMonitoring))])
        permissionButtons.spacing = 12
        stack.addArrangedSubview(permissionButtons)
        toggleButton = button("启用触控定位", action: #selector(toggle))
        toggleButton.bezelStyle = .rounded
        stack.addArrangedSubview(toggleButton)
        statusLabel = label("尚未启用", bold: true)
        dataLabel = label("尚未收到触控数据", size: 12)
        dataLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(statusLabel)
        stack.addArrangedSubview(dataLabel)
        stack.addArrangedSubview(label("返回当前主屏", bold: true))
        shortcutEnabled = NSButton(checkboxWithTitle: "启用返回主屏快捷键", target: self,
                                   action: #selector(toggleReturnShortcut))
        stack.addArrangedSubview(shortcutEnabled)
        shortcutRecorder = ShortcutRecorderButton()
        shortcutRecorder.bezelStyle = .rounded
        let shortcutRow = NSStackView(views: [shortcutRecorder,
            button("恢复默认", action: #selector(resetReturnShortcut))])
        shortcutRow.spacing = 12
        stack.addArrangedSubview(shortcutRow)
        let shortcutHint = label("点击组合键可重新录入。需包含 Control 或 Command；Esc 取消。鼠标返回当前主屏中央，已在主屏时保持原位。", size: 12)
        shortcutHint.textColor = .secondaryLabelColor
        stack.addArrangedSubview(shortcutHint)
        shortcutStatus = label("", size: 12)
        stack.addArrangedSubview(shortcutStatus)
        let content = NSView()
        content.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor)])
        window.contentView = content
        window.center()
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

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func configureReturnShortcut() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "returnToMainShortcut"),
           let decoded = try? JSONDecoder().decode(KeyboardShortcut.self, from: data) { savedShortcut = decoded }
        isShortcutEnabled = defaults.object(forKey: "returnToMainShortcutEnabled") as? Bool ?? true
        shortcutEnabled.state = isShortcutEnabled ? .on : .off
        shortcutRecorder.shortcut = savedShortcut
        returnShortcut.onPress = { [weak self] in self?.returnToMainScreen() }
        shortcutRecorder.onBegin = { [weak self] in
            self?.returnShortcut.pause()
            self?.shortcutStatus.stringValue = "请按下新的组合键；按 Esc 保留原来的快捷键"
        }
        shortcutRecorder.onCancel = { [weak self] in self?.resumeReturnShortcut() }
        shortcutRecorder.onCapture = { [weak self] candidate in
            guard let self else { return false }
            guard let candidate else {
                self.shortcutStatus.stringValue = "组合键需包含 Control 或 Command，并加上一个其他按键"
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
        guard isShortcutEnabled else { shortcutStatus.stringValue = "返回主屏快捷键已停用"; return }
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
        if !isShortcutEnabled { returnShortcut.pause() }
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
    func returnToMainScreen() {
        guard AXIsProcessTrusted() else { shortcutStatus.stringValue = "请先允许鼠标控制权限"; return }
        let display = CGMainDisplayID() // Resolve the current system main display on every press.
        guard CGDisplayIsActive(display) != 0, let cursor = CGEvent(source: nil)?.location else { return }
        guard let destination = primaryReturnPoint(cursor: cursor, bounds: CGDisplayBounds(display)) else {
            shortcutStatus.stringValue = "鼠标已在当前主屏"; return
        }
        if CGEventSource.buttonState(.combinedSessionState, button: .right) ||
           CGEventSource.buttonState(.combinedSessionState, button: .center) ||
           (!mapper.isDown && CGEventSource.buttonState(.combinedSessionState, button: .left)) {
            shortcutStatus.stringValue = "请先松开鼠标按键，再返回主屏"; return
        }
        mapper.suspendTouchForCursorReturn()
        guard CGWarpMouseCursorPosition(destination) == .success else {
            shortcutStatus.stringValue = "无法移动鼠标，请检查鼠标控制权限"; return
        }
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: destination,
                mouseButton: .left)?.post(tap: .cghidEventTap)
        shortcutStatus.stringValue = "已返回当前主屏：\(displayName(display))"
    }
    func refreshDisplays() {
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
        permissionLabel.stringValue = "鼠标控制：\(control ? "已允许" : "待允许")    输入监控：\(monitoring ? "已允许" : "待允许")"
        if mapper.running && (!control || !monitoring) { mapper.stop() }
        if autoStartPending && control && monitoring && selectedUUID != nil {
            autoStartPending = false
            enable()
        }
        toggleButton.title = mapper.running ? "停用触控定位" : "启用触控定位"
        statusLabel.stringValue = mapper.message
        dataLabel.stringValue = "已连接触控接口：\(mapper.sessions.count) · 已发送操作：\(mapper.events)\n\(mapper.lastReport)"
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return false
    }
    func applicationWillTerminate(_ notification: Notification) { returnShortcut.pause(); mapper.stop() }
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
    require(KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey | optionKey)) == hotkey, "default shortcut")
    require(KeyboardShortcut(keyCode: 4, modifiers: 0) == nil, "ordinary typing cannot be registered")
    require(KeyboardShortcut(keyCode: 4, modifiers: UInt32(shiftKey | optionKey)) == nil, "modifier requirement")
    require(KeyboardShortcut(keyCode: 55, modifiers: UInt32(cmdKey)) == nil, "modifier-only key rejected")
    require(KeyboardShortcut(keyCode: 53, modifiers: UInt32(cmdKey)) == nil, "Escape remains recorder cancel")
    require(KeyboardShortcut(keyCode: 127, modifiers: UInt32(controlKey)) == nil, "invalid key code rejected")
    require(KeyboardShortcut(keyCode: 4, modifiers: UInt32(controlKey) | (1 << 30)) == nil, "unknown modifiers rejected")
    let shortcutData = try! JSONEncoder().encode(hotkey)
    require((try? JSONDecoder().decode(KeyboardShortcut.self, from: shortcutData)) == hotkey, "shortcut settings round-trip")
    require((try? JSONDecoder().decode(KeyboardShortcut.self, from: Data("{\"keyCode\":4,\"modifiers\":0}".utf8))) == nil,
            "invalid persisted shortcut rejected")
    let primary = CGRect(x: 0, y: 0, width: 1470, height: 956)
    require(primaryReturnPoint(cursor: CGPoint(x: -500, y: 200), bounds: primary) == CGPoint(x: 735, y: 478), "return from external screen")
    require(primaryReturnPoint(cursor: CGPoint(x: 22, y: 33), bounds: primary) == nil, "already on main screen stays put")
    require(primaryReturnPoint(cursor: CGPoint(x: 2000, y: 300), bounds: CGRect(x: -1000, y: -500, width: 800, height: 600)) == CGPoint(x: -600, y: -200), "return respects supplied main display geometry")
    require(primaryReturnPoint(cursor: .zero, bounds: .null) == nil, "missing main screen ignored")
    require(primaryReturnPoint(cursor: CGPoint(x: CGFloat.nan, y: 0), bounds: primary) == nil, "invalid cursor ignored")
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
